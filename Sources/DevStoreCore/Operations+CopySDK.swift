import Foundation

/// Copies an existing local SDK installation (rust, dotnet, flutter) into a mounted empty
/// environment, scans the copy for references to the original paths, then switches adapters.
/// The originals are only read.
extension Operations {
    public struct ResidueSummary: Sendable {
        public var files: Int
        public var executableText: [String]
        public var sample: [String] = []
    }

    /// Files under `root` whose bytes contain any of `needles` (symlinks not followed).
    public static func residueScan(root: String, needles: [String]) -> ResidueSummary {
        let patterns = needles.map { Data($0.utf8) }
        var files = 0
        var execText: [String] = []
        var sample: [String] = []
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root) else { return ResidueSummary(files: 0, executableText: []) }
        while let rel = e.nextObject() as? String {
            let full = root + "/" + rel
            var st = stat()
            guard lstat(full, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: full), options: .alwaysMapped) else { continue }
            guard patterns.contains(where: { data.range(of: $0) != nil }) else { continue }
            files += 1
            if sample.count < 10 { sample.append(rel) }
            let isBinary = data.prefix(8192).contains(0)
            if !isBinary && (st.st_mode & 0o111) != 0 && execText.count < 50 { execText.append(rel) }
        }
        return ResidueSummary(files: files, executableText: execText, sample: sample)
    }

    public func planCopySDK(_ query: String, adapter adapterId: String) throws -> Plan {
        guard let adapter = Adapters.copyable(adapterId) else {
            throw DevStoreError("copy-sdk supports rust, dotnet and flutter (got \(adapterId))")
        }
        let r = try library.resolve(query)
        let sources = adapter.copySources(home: NSHomeDirectory())
        let copies = String(decoding: try JSONIO.encoder(pretty: false).encode(sources), as: UTF8.self)
        let targets = ["environmentId": r.environment.environmentId, "imageId": r.image?.imageId ?? "",
                       "kind": r.environment.kind, "slot": r.environment.slot, "slotPath": r.slotPath,
                       "adapterTo": adapterId, "copies": copies]
        let checks = try copySDKChecks(targets)
        try requireAll(checks)
        let present = sources.filter { fm.fileExists(atPath: $0.from) }
        return try finish(Plan(
            planId: newId(), action: .copySDK, level: PlanAction.copySDK.level, targets: targets,
            preconditions: checks.map(\.description),
            effects: present.map { "copy \($0.from) → \(r.slotPath)/\($0.to) (ditto; originals are only read)" } + [
                "scan the copy for references to the original paths and record them as known warnings",
                "switch the environment from the empty adapter to the \(adapterId) adapter",
                "on failure remove everything copied in this transaction",
            ],
            notTouched: present.map(\.from) + [NSHomeDirectory() + "/.zshrc and other shell configuration"],
            createdAt: timestamp()))
    }

    func decodeCopies(_ t: [String: String]) throws -> [CopySource] {
        try JSONDecoder().decode([CopySource].self, from: Data((t["copies"] ?? "[]").utf8))
    }

    func copySDKChecks(_ t: [String: String]) throws -> [Precondition] {
        let r = try library.resolve(t["environmentId"]!)
        let copies = try decodeCopies(t)
        let need = copies.filter { fm.fileExists(atPath: $0.from) }.map { DiskImage.allocatedBytes($0.from) }.reduce(0, +)
        let free = (try? URL(fileURLWithPath: t["slotPath"]!).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init) ?? 0
        var checks = [
            Precondition(description: "environment uses the empty adapter (no SDK yet)", ok: r.environment.adapter.id == "empty"),
            Precondition(description: "environment is mounted with a verified identity", ok: library.identityVerified(r)),
        ]
        for c in copies {
            if c.required { checks.append(Precondition(description: "\(c.from) exists", ok: fm.fileExists(atPath: c.from))) }
            checks.append(Precondition(description: "\(t["slotPath"]!)/\(c.to) does not exist yet",
                                       ok: !fm.fileExists(atPath: t["slotPath"]! + "/" + c.to)))
        }
        checks.append(Precondition(description: "volume has ≥ \(ByteCountFormatter.string(fromByteCount: need + (1 << 30), countStyle: .file)) available",
                                   ok: free >= need + (1 << 30)))
        return checks
    }

    func executeCopySDK(_ plan: Plan, _ journal: Journal) throws -> String {
        let t = plan.targets
        let r = try library.resolve(t["environmentId"]!)
        let adapter = Adapters.copyable(t["adapterTo"]!)!
        let mount = r.slotPath
        let copies = try decodeCopies(t).filter { fm.fileExists(atPath: $0.from) }
        var done: [String] = []
        do {
            for c in copies {
                let dest = mount + "/" + c.to
                try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                let t0 = Date()
                let res = try Shell.run("/usr/bin/ditto", [c.from, dest])
                guard res.status == 0 else { throw DevStoreError("ditto \(c.from) failed: \(res.stderr)") }
                done.append(dest)
                journal.log("step", step: "copy", detail: "\(c.from) → \(dest) in \(Int(Date().timeIntervalSince(t0)))s")
            }
            for d in adapter.layout { try fm.createDirectory(atPath: mount + "/" + d, withIntermediateDirectories: true) }
            try "single-volume-persistence-20261029\n".write(toFile: mount + "/state/persistence-marker.txt", atomically: true, encoding: .utf8)
        } catch {
            for d in done { try? fm.removeItem(atPath: d) }
            journal.log("rolledBack", detail: "removed \(done.count) copied trees")
            throw error
        }
        let residue = Self.residueScan(root: mount, needles: copies.map(\.from))
        journal.log("step", step: "residue-scan", detail: "\(residue.files) files reference original paths; executable text: \(residue.executableText.count); sample: \(residue.sample.joined(separator: ", "))")

        var manifest = library.readManifest(mount: mount)!
        manifest.adapter = adapter.ref
        manifest.writtenAt = timestamp()
        try JSONIO.writeAtomically(manifest, to: URL(fileURLWithPath: mount).appendingPathComponent(".devstore/manifest.json"))
        var envRecord = r.environment
        envRecord.adapter = adapter.ref
        envRecord.origin = Origin(type: "copied", sourcePath: copies.first?.from, note: "copy-sdk from local installation")
        try JSONIO.writeAtomically(envRecord, to: r.environmentDir.appendingPathComponent("environment.json"))
        var image = r.image!
        image.components = adapter.discoverComponents(mount: mount)
        image.sdk = SDKRecord(name: t["adapterTo"]!, version: image.components.first?.version ?? "?",
                              installer: "copy of " + copies.map(\.from).joined(separator: ", "), installerSHA256: "-",
                              installedAt: timestamp())
        image.knownWarnings = adapter.knownWarnings
        if residue.files > 0 {
            image.knownWarnings.append("\(residue.files) copied files still mention the original paths (e.g. \(residue.sample.prefix(3).joined(separator: ", ")))"
                + (residue.executableText.isEmpty ? " (none are executable scripts)" : "; executable scripts: \(residue.executableText.prefix(5).joined(separator: ", "))"))
        }
        image.mutatedSinceVerification = true
        try library.saveImage(image, in: r)
        journal.log("step", step: "adapter", detail: "empty -> \(t["adapterTo"]!)")
        return "copied \(copies.count) trees into \(mount) (\(image.components.first.map { "\($0.name) \($0.version ?? "")" } ?? "")); "
            + "\(residue.files) files mention original paths; run verify next"
    }
}
