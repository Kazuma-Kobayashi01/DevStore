import Foundation

/// Writes an SDK into a mounted empty environment from a verified installer, then switches the
/// environment to the matching adapter. Only Miniconda installers are supported for now.
extension Operations {
    public static let minimumInstallFreeBytes: Int64 = 3 << 30

    /// Reads `# KEY: value` lines from the text header of a Miniconda/Anaconda installer.
    public static func installerHeader(_ path: String) -> [String: String] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [:] }
        defer { try? h.close() }
        var result: [String: String] = [:]
        for line in String(decoding: h.readData(ofLength: 4096), as: UTF8.self).split(separator: "\n").prefix(40) {
            guard line.hasPrefix("# "), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.index(line.startIndex, offsetBy: 2)..<colon].trimmingCharacters(in: .whitespaces)
            result[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    public static func sha256(file path: String) throws -> String {
        let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? h.close() }
        var hasher = SHA256Stream()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(chunk) }
        return hasher.finalizeHex()
    }

    public func planInstallSDK(_ query: String, installer: String, sha256 expected: String) throws -> Plan {
        let r = try library.resolve(query)
        let path = URL(fileURLWithPath: installer).standardizedFileURL.path
        let header = Self.installerHeader(path)
        let targets = ["environmentId": r.environment.environmentId, "imageId": r.image?.imageId ?? "",
                       "kind": r.environment.kind, "slot": r.environment.slot, "slotPath": r.slotPath,
                       "prefix": r.slotPath + "/miniconda3", "installer": path,
                       "installerSHA256": expected.lowercased(),
                       "sdk": header["NAME"] ?? "?", "sdkVersion": header["VER"] ?? "?", "sdkPlatform": header["PLAT"] ?? "?"]
        let checks = try installSDKChecks(targets)
        try requireAll(checks)
        return try finish(Plan(
            planId: newId(), action: .installSDK, level: PlanAction.installSDK.level, targets: targets,
            preconditions: checks.map(\.description),
            effects: [
                "run `bash \(path) -b -p \(r.slotPath)/miniconda3` (batch mode, no `conda init`) with HOME, TMPDIR and caches on the volume",
                "sandbox the installer: no network; no reads of ~/miniconda3, ~/.conda, ~/.condarc; writes only to \(r.slotPath) and /private/tmp",
                "write \(r.slotPath)/state/condarc (pkgs_dirs and envs_dirs on the volume) and persistence markers",
                "switch the environment from the empty adapter to the miniconda adapter (environment.json, image.json, .devstore/manifest.json)",
                "on failure remove the partial \(r.slotPath)/miniconda3",
            ],
            notTouched: [NSHomeDirectory() + "/miniconda3", NSHomeDirectory() + "/.zshrc and other shell configuration", path],
            createdAt: timestamp()))
    }

    func installSDKChecks(_ t: [String: String]) throws -> [Precondition] {
        let r = try library.resolve(t["environmentId"]!)
        let installer = t["installer"]!, prefix = t["prefix"]!
        let actual = (try? Self.sha256(file: installer)) ?? ""
        let free = (try? URL(fileURLWithPath: t["slotPath"]!).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init) ?? 0
        let header = Self.installerHeader(installer)
        return [
            Precondition(description: "environment uses the empty adapter (no SDK yet)", ok: r.environment.adapter.id == "empty"),
            Precondition(description: "environment is mounted with a verified identity", ok: library.identityVerified(r)),
            Precondition(description: "installer is a Miniconda installer for osx-\(machineArch())",
                         ok: header["NAME"] == "Miniconda3" && header["PLAT"] == "osx-\(machineArch())"),
            Precondition(description: "installer SHA-256 equals \(t["installerSHA256"]!)",
                         ok: !t["installerSHA256"]!.isEmpty && actual == t["installerSHA256"]),
            Precondition(description: "\(prefix) does not exist yet", ok: !fm.fileExists(atPath: prefix)),
            Precondition(description: "volume has ≥ 3 GiB available", ok: free >= Self.minimumInstallFreeBytes),
        ]
    }

    func executeInstallSDK(_ plan: Plan, _ journal: Journal) throws -> String {
        let t = plan.targets
        let r = try library.resolve(t["environmentId"]!)
        let mount = r.slotPath, prefix = t["prefix"]!, home = NSHomeDirectory()
        let miniconda = MinicondaAdapter()
        var env = EmptyAdapter().sessionEnvironment(mount: mount)
        env["CONDARC"] = mount + "/state/condarc"
        let denied = miniconda.originPathsToDeny(home: home) + ["/opt/homebrew", "/usr/local"]
        let profile = "(version 1)\n(allow default)\n(deny network*)\n(deny file-read*\n"
            + denied.map { "  (subpath \"\($0)\")" }.joined(separator: "\n")
            + ")\n(deny file-write*)\n(allow file-write*\n  (subpath \"\(mount)\")\n  (subpath \"/private/tmp\")\n"
            + "  (subpath \"/private/var/folders\")\n  (literal \"/dev/null\"))\n"
        let log = r.imageDir!.appendingPathComponent("install-sdk-\(journal.transactionId.prefix(8)).log")
        do {
            let t0 = Date()
            let res = try Shell.run("/usr/bin/sandbox-exec", ["-p", profile, "/bin/bash", t["installer"]!, "-b", "-p", prefix],
                                    environment: env, currentDirectory: mount + "/tmp")
            try (res.stdout + "\n--- stderr ---\n" + res.stderr).write(to: log, atomically: true, encoding: .utf8)
            journal.log("step", step: "installer", detail: "exit \(res.status) in \(Int(Date().timeIntervalSince(t0)))s; log \(log.path)")
            guard res.status == 0 else { throw DevStoreError("installer failed (exit \(res.status)); see \(log.path)") }
            guard miniconda.builtMountPath(volumeRoot: mount) == mount else {
                throw DevStoreError("installed conda does not point at \(mount); see \(log.path)")
            }
            let condarc = """
            # Written by devstore install-sdk. Package cache and environments stay on this volume.
            auto_activate: false
            pkgs_dirs:
              - \(prefix)/pkgs
            envs_dirs:
              - \(prefix)/envs

            """
            try condarc.write(toFile: mount + "/state/condarc", atomically: true, encoding: .utf8)
            for d in ["cache/pip", "cache/xdg"] { try fm.createDirectory(atPath: mount + "/" + d, withIntermediateDirectories: true) }
            try "single-volume-persistence-20261029\n".write(toFile: mount + "/state/persistence-marker.txt", atomically: true, encoding: .utf8)
            try "cache-on-same-volume\n".write(toFile: mount + "/cache/pip/volume-marker", atomically: true, encoding: .utf8)
            journal.log("step", step: "condarc+markers")
        } catch {
            try? fm.removeItem(atPath: prefix)
            journal.log("rolledBack", detail: "removed partial \(prefix)")
            throw error
        }

        // Switch adapters everywhere the environment is described.
        var manifest = library.readManifest(mount: mount)!
        manifest.adapter = miniconda.ref
        manifest.writtenAt = timestamp()
        try JSONIO.writeAtomically(manifest, to: URL(fileURLWithPath: mount).appendingPathComponent(".devstore/manifest.json"))
        var envRecord = r.environment
        envRecord.adapter = miniconda.ref
        envRecord.origin.note = "empty volume + \(t["sdk"]!) \(t["sdkVersion"]!)"
        try JSONIO.writeAtomically(envRecord, to: r.environmentDir.appendingPathComponent("environment.json"))
        var image = r.image!
        image.sdk = SDKRecord(name: t["sdk"]!, version: t["sdkVersion"]!, installer: URL(fileURLWithPath: t["installer"]!).lastPathComponent,
                              installerSHA256: t["installerSHA256"]!, installedAt: timestamp())
        image.components = miniconda.discoverComponents(mount: mount)
        image.knownWarnings = []
        image.mutatedSinceVerification = true
        try library.saveImage(image, in: r)
        journal.log("step", step: "adapter", detail: "empty -> miniconda")
        let base = image.components.first { $0.name == "base" }
        return "installed \(t["sdk"]!) \(t["sdkVersion"]!) into \(prefix) (Python \(base?.python ?? "?"), \(base?.condaPackages ?? 0) conda packages); run verify next"
    }
}
