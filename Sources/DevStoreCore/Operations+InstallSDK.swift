import Foundation

/// Identified SDK package: a Miniconda `.sh` installer or an official Go `goX.Y.Z.darwin-<arch>.tar.gz`.
public struct SDKPackage: Sendable {
    public var name: String          // Miniconda3 | Go
    public var version: String
    public var platform: String      // osx-arm64 | darwin-arm64
    public var adapter: String       // miniconda | go
    public var directory: String     // top-level directory created in the volume
    public var supportedHere: Bool   // platform matches this Mac
}

/// Writes an SDK into a mounted empty environment from a verified package, then switches the
/// environment to the matching adapter.
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

    public static func identifySDK(_ path: String) -> SDKPackage? {
        let arch = machineArch()
        let name = URL(fileURLWithPath: path).lastPathComponent
        let header = installerHeader(path)
        if header["NAME"] == "Miniconda3" {
            let plat = header["PLAT"] ?? "?"
            return SDKPackage(name: "Miniconda3", version: header["VER"] ?? "?", platform: plat, adapter: "miniconda",
                              directory: "miniconda3", supportedHere: plat == "osx-\(arch)")
        }
        if let m = name.range(of: #"^go(\d+\.\d+(\.\d+)?)\.darwin-(arm64|amd64)\.tar\.gz$"#, options: .regularExpression) {
            let stem = String(name[m]).dropFirst(2).dropLast(".tar.gz".count)       // 1.27.3.darwin-arm64
            let parts = stem.split(separator: ".")
            let platform = String(parts.last ?? "")                                  // darwin-arm64
            let version = parts.dropLast().joined(separator: ".")
            // The archive must contain go/VERSION matching its file name.
            let v = (try? Shell.run("/usr/bin/tar", ["-xzOf", path, "go/VERSION"]))?.stdout.split(separator: "\n").first.map(String.init)
            guard v == "go\(version)" else { return nil }
            return SDKPackage(name: "Go", version: version, platform: platform, adapter: "go",
                              directory: "go", supportedHere: platform == "darwin-\(arch == "x86_64" ? "amd64" : arch)")
        }
        return nil
    }

    public func planInstallSDK(_ query: String, installer: String, sha256 expected: String) throws -> Plan {
        let r = try library.resolve(query)
        let path = URL(fileURLWithPath: installer).standardizedFileURL.path
        guard let pkg = Self.identifySDK(path) else {
            throw DevStoreError("\(path) is not a recognized SDK package (Miniconda .sh installer or official go*.darwin-*.tar.gz)")
        }
        let prefix = r.slotPath + "/" + pkg.directory
        let targets = ["environmentId": r.environment.environmentId, "imageId": r.image?.imageId ?? "",
                       "kind": r.environment.kind, "slot": r.environment.slot, "slotPath": r.slotPath,
                       "prefix": prefix, "installer": path, "installerSHA256": expected.lowercased(),
                       "sdk": pkg.name, "sdkVersion": pkg.version, "sdkPlatform": pkg.platform, "adapterTo": pkg.adapter]
        let checks = try installSDKChecks(targets)
        try requireAll(checks)
        let origin = Adapters.named(pkg.adapter)?.originPathsToDeny(home: NSHomeDirectory()) ?? []
        let run = pkg.adapter == "go"
            ? "extract \(URL(fileURLWithPath: path).lastPathComponent) into \(r.slotPath) (creates \(prefix)); create gopath/, cache/go-build, state/go/env"
            : "run `bash \(path) -b -p \(prefix)` (batch mode, no `conda init`) with HOME, TMPDIR and caches on the volume; write state/condarc"
        return try finish(Plan(
            planId: newId(), action: .installSDK, level: PlanAction.installSDK.level, targets: targets,
            preconditions: checks.map(\.description),
            effects: [
                run,
                "sandboxed: no network; no reads of \((origin + ["/opt/homebrew", "/usr/local"]).joined(separator: ", ")); writes only to \(r.slotPath) and /private/tmp",
                "write persistence markers; switch the environment from the empty adapter to the \(pkg.adapter) adapter",
                "on failure remove the partial \(prefix)",
            ],
            notTouched: origin + [NSHomeDirectory() + "/.zshrc and other shell configuration", path],
            createdAt: timestamp()))
    }

    func installSDKChecks(_ t: [String: String]) throws -> [Precondition] {
        let r = try library.resolve(t["environmentId"]!)
        let installer = t["installer"]!, prefix = t["prefix"]!
        let actual = (try? Self.sha256(file: installer)) ?? ""
        let free = (try? URL(fileURLWithPath: t["slotPath"]!).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init) ?? 0
        let pkg = Self.identifySDK(installer)
        return [
            Precondition(description: "environment uses the empty adapter (no SDK yet)", ok: r.environment.adapter.id == "empty"),
            Precondition(description: "environment is mounted with a verified identity", ok: library.identityVerified(r)),
            Precondition(description: "package is \(t["sdk"] ?? "?") \(t["sdkVersion"] ?? "?") for \(t["sdkPlatform"] ?? "?"), matching this Mac",
                         ok: pkg?.supportedHere == true && pkg?.name == t["sdk"] && pkg?.version == t["sdkVersion"]),
            Precondition(description: "package SHA-256 equals \(t["installerSHA256"]!)",
                         ok: !t["installerSHA256"]!.isEmpty && actual == t["installerSHA256"]),
            Precondition(description: "\(prefix) does not exist yet", ok: !fm.fileExists(atPath: prefix)),
            Precondition(description: "volume has ≥ 3 GiB available", ok: free >= Self.minimumInstallFreeBytes),
        ]
    }

    func executeInstallSDK(_ plan: Plan, _ journal: Journal) throws -> String {
        let t = plan.targets
        let r = try library.resolve(t["environmentId"]!)
        let adapterId = t["adapterTo"] ?? "miniconda"
        guard let adapter = Adapters.named(adapterId) else { throw DevStoreError("unknown adapter \(adapterId)") }
        let mount = r.slotPath, prefix = t["prefix"]!, home = NSHomeDirectory()
        var env = EmptyAdapter().sessionEnvironment(mount: mount)
        env["CONDARC"] = mount + "/state/condarc"
        let denied = adapter.originPathsToDeny(home: home) + ["/opt/homebrew", "/usr/local"]
        let profile = "(version 1)\n(allow default)\n(deny network*)\n(deny file-read*\n"
            + denied.map { "  (subpath \"\($0)\")" }.joined(separator: "\n")
            + ")\n(deny file-write*)\n(allow file-write*\n  (subpath \"\(mount)\")\n  (subpath \"/private/tmp\")\n"
            + "  (subpath \"/private/var/folders\")\n  (literal \"/dev/null\"))\n"
        let log = r.imageDir!.appendingPathComponent("install-sdk-\(journal.transactionId.prefix(8)).log")
        do {
            let t0 = Date()
            let cmd = adapterId == "go"
                ? ["/usr/bin/tar", "-xzf", t["installer"]!, "-C", mount]
                : ["/bin/bash", t["installer"]!, "-b", "-p", prefix]
            let res = try Shell.run("/usr/bin/sandbox-exec", ["-p", profile] + cmd, environment: env, currentDirectory: mount + "/tmp")
            try (res.stdout + "\n--- stderr ---\n" + res.stderr).write(to: log, atomically: true, encoding: .utf8)
            journal.log("step", step: "installer", detail: "exit \(res.status) in \(Int(Date().timeIntervalSince(t0)))s; log \(log.path)")
            guard res.status == 0 else { throw DevStoreError("installer failed (exit \(res.status)); see \(log.path)") }
            if adapterId == "go" {
                guard fm.isExecutableFile(atPath: prefix + "/bin/go") else { throw DevStoreError("\(prefix)/bin/go missing after extraction") }
                for d in GoAdapter.layout { try fm.createDirectory(atPath: mount + "/" + d, withIntermediateDirectories: true) }
                if !fm.fileExists(atPath: mount + "/state/go/env") {
                    try "# GOENV for this DevStore volume (go env -w writes here).\n".write(toFile: mount + "/state/go/env", atomically: true, encoding: .utf8)
                }
                try "go-build-cache-on-same-volume\n".write(toFile: mount + "/cache/go-build/devstore-marker", atomically: true, encoding: .utf8)
            } else {
                guard MinicondaAdapter().builtMountPath(volumeRoot: mount) == mount else {
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
                try "cache-on-same-volume\n".write(toFile: mount + "/cache/pip/volume-marker", atomically: true, encoding: .utf8)
            }
            try "single-volume-persistence-20261029\n".write(toFile: mount + "/state/persistence-marker.txt", atomically: true, encoding: .utf8)
            journal.log("step", step: "layout+markers")
        } catch {
            try? fm.removeItem(atPath: prefix)
            journal.log("rolledBack", detail: "removed partial \(prefix)")
            throw error
        }

        // Switch adapters everywhere the environment is described.
        var manifest = library.readManifest(mount: mount)!
        manifest.adapter = adapter.ref
        manifest.writtenAt = timestamp()
        try JSONIO.writeAtomically(manifest, to: URL(fileURLWithPath: mount).appendingPathComponent(".devstore/manifest.json"))
        var envRecord = r.environment
        envRecord.adapter = adapter.ref
        envRecord.origin.note = "empty volume + \(t["sdk"]!) \(t["sdkVersion"]!)"
        try JSONIO.writeAtomically(envRecord, to: r.environmentDir.appendingPathComponent("environment.json"))
        var image = r.image!
        image.sdk = SDKRecord(name: t["sdk"]!, version: t["sdkVersion"]!, installer: URL(fileURLWithPath: t["installer"]!).lastPathComponent,
                              installerSHA256: t["installerSHA256"]!, installedAt: timestamp())
        image.components = adapter.discoverComponents(mount: mount)
        image.knownWarnings = []
        image.mutatedSinceVerification = true
        try library.saveImage(image, in: r)
        journal.log("step", step: "adapter", detail: "empty -> \(adapterId)")
        let first = image.components.first
        return "installed \(t["sdk"]!) \(t["sdkVersion"]!) into \(prefix) (\(first.map { "\($0.name) \($0.version ?? $0.python ?? "")" } ?? "")); run verify next"
    }
}
