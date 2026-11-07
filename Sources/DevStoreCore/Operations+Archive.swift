import Foundation

/// Immutable compressed copy of an image, stored at `<store>/checkpoints/<environmentId>/<checkpointId>.dmg`
/// with this record beside it as `<checkpointId>.json`.
public struct CheckpointRecord: Codable, Sendable {
    public var schemaVersion = 1
    public var checkpointId: String
    public var environmentId: String
    public var kind: String
    public var slot: String
    public var displayName: String
    public var sourceImageId: String
    public var purpose: String                 // archive | manual
    public var format: String                  // ULFO (LZFSE) | ULMO (LZMA)
    public var encryption: String              // none | aes256
    public var fileBytes: Int64
    public var sha256: String
    public var sourceAllocatedBytes: Int64
    public var contentEntries: Int
    public var contentDigest: String
    public var imageChecksumVerified: Bool
    public var fixedMountPath: String
    public var sdk: SDKRecord?
    public var createdAt: String
    public var exports: [ExportRecord] = []
}

public struct ExportRecord: Codable, Sendable {
    public var path: String
    public var at: String
    public var sha256Verified: Bool
}

public struct CompactionRecord: Codable, Sendable {
    public var at: String
    public var beforeBytes: Int64
    public var afterBytes: Int64
    public var contentEntries: Int
    public var contentDigest: String
}

/// Digest over every entry of a mounted volume (path, type, mode, size, content SHA-256, link target).
/// Two volumes with equal digests have identical content as far as DevStore can observe.
public enum ContentManifest {
    static let skipped: Set<String> = [".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100"]

    public static func digest(root: String) throws -> (entries: Int, digest: String) {
        var lines: [String] = []
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root) else { throw DevStoreError("cannot read \(root)") }
        while let rel = e.nextObject() as? String {
            if skipped.contains(rel.split(separator: "/").first.map(String.init) ?? "") {
                e.skipDescendants()
                continue
            }
            let full = root + "/" + rel
            var st = stat()
            guard lstat(full, &st) == 0 else { throw DevStoreError("cannot stat \(full)") }
            let mode = String(st.st_mode & 0o7777, radix: 8)
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                lines.append("\(rel)\tf\t\(mode)\t\(st.st_size)\t\(try Operations.sha256(file: full))")
            case S_IFDIR:
                lines.append("\(rel)\td\t\(mode)")
            case S_IFLNK:
                lines.append("\(rel)\tl\t\(mode)\t\((try? fm.destinationOfSymbolicLink(atPath: full)) ?? "")")
            default:
                lines.append("\(rel)\to\t\(mode)")
            }
        }
        lines.sort()
        return (lines.count, "sha256:" + JSONIO.sha256Hex(Data(lines.joined(separator: "\n").utf8)))
    }

    /// Attaches a bundle read-only at a private temporary mount point (never the slot), digests it, detaches.
    public static func digest(bundle: String) throws -> (entries: Int, digest: String) {
        let mnt = "/private/tmp/devstore-mnt-\(newId().prefix(8))"
        try FileManager.default.createDirectory(atPath: mnt, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: mnt) }
        try DiskImage.attach(bundle: bundle, mountPoint: mnt, readOnly: true)
        defer { try? DiskImage.detach(mountPoint: mnt) }
        return try digest(root: mnt)
    }
}

extension Operations {
    // MARK: shared

    func unmountedImageChecks(_ r: ResolvedEnvironment) -> [Precondition] {
        let mounted = (try? DiskImage.mountedImageVolumeUUIDs())?[r.image?.volumeUUID ?? "-"] != nil
        return [
            Precondition(description: "store \(r.store.storeId) is online", ok: library.isOnline(r.store)),
            Precondition(description: "environment has an active image bundle", ok: r.bundlePath.map(DiskImage.isSparseBundle) ?? false),
            Precondition(description: "environment is not mounted (slot and volume UUID)", ok: !DiskImage.isMountPoint(r.slotPath) && !mounted),
            library.leaseAssessment(r).precondition,
        ]
    }

    public func checkpoints(environmentId: String? = nil) throws -> [CheckpointRecord] {
        try library.loadRegistry().stores.filter(library.isOnline).flatMap { store -> [CheckpointRecord] in
            let dir = URL(fileURLWithPath: store.path).appendingPathComponent("checkpoints")
            let envs = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            return envs.filter { environmentId == nil || $0 == environmentId }.flatMap { env -> [CheckpointRecord] in
                let names = (try? fm.contentsOfDirectory(atPath: dir.path + "/" + env)) ?? []
                return names.filter { $0.hasSuffix(".json") }.compactMap {
                    try? JSONIO.read(CheckpointRecord.self, from: dir.appendingPathComponent(env).appendingPathComponent($0))
                }
            }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func checkpointLocation(_ id: String) throws -> (record: CheckpointRecord, dmg: URL, json: URL) {
        for store in try library.loadRegistry().stores where library.isOnline(store) {
            let dir = URL(fileURLWithPath: store.path).appendingPathComponent("checkpoints")
            for env in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                for name in (try? fm.contentsOfDirectory(atPath: dir.path + "/" + env)) ?? []
                where name.hasSuffix(".json") && name.hasPrefix(id.lowercased()) {
                    let json = dir.appendingPathComponent(env).appendingPathComponent(name)
                    let rec = try JSONIO.read(CheckpointRecord.self, from: json)
                    return (rec, json.deletingPathExtension().appendingPathExtension("dmg"), json)
                }
            }
        }
        throw DevStoreError("no checkpoint matches \(id)")
    }

    // MARK: compact

    public func planCompact(_ query: String) throws -> Plan {
        let r = try library.resolve(query)
        let targets = ["environmentId": r.environment.environmentId, "imageId": r.image?.imageId ?? "",
                       "kind": r.environment.kind, "slot": r.environment.slot, "bundle": r.bundlePath ?? ""]
        let checks = try compactChecks(targets)
        try requireAll(checks)
        return try finish(Plan(
            planId: newId(), action: .compact, level: PlanAction.compact.level, targets: targets,
            preconditions: checks.map(\.description),
            effects: reclaimEffects(activeImageLease(r)) + [
                "APFS-clone the image to a temporary bundle and run `hdiutil compact` on the clone only",
                "attach the clone read-only at a private temporary mount point before and after compaction and compare content digests",
                "if identical and smaller: move the original bundle to the Trash and put the compacted clone in its place",
                "if nothing was reclaimed or content differs: delete the clone and leave the original untouched",
            ],
            notTouched: ["the slot path (the environment stays unmounted)", "volume content", "other environments"],
            createdAt: timestamp()))
    }

    func compactChecks(_ t: [String: String]) throws -> [Precondition] {
        let r = try library.resolve(t["environmentId"]!)
        return unmountedImageChecks(r) + [
            Precondition(description: "image \(t["imageId"]!) is the active image", ok: r.image?.imageId == t["imageId"]),
        ]
    }

    func executeCompact(_ plan: Plan, _ journal: Journal) throws -> String {
        let r = try library.resolve(plan.targets["environmentId"]!)
        try reclaimStaleLeases(activeImageLease(r), journal)
        let bundle = r.bundlePath!
        let work = r.imageDir!.appendingPathComponent("compact-\(journal.transactionId.prefix(8)).sparsebundle").path
        var cleanup = true
        defer { if cleanup { try? fm.removeItem(atPath: work) } }
        let before = DiskImage.allocatedBytes(bundle)
        try DiskImage.cloneBundle(from: bundle, to: work)
        journal.log("step", step: "clone", detail: work)
        let d1 = try ContentManifest.digest(bundle: work)
        journal.log("step", step: "digest-before", detail: "\(d1.entries) entries \(d1.digest)")
        let res = try Shell.run("/usr/bin/hdiutil", ["compact", work])
        guard res.status == 0 else { throw DiskImageError.command("hdiutil compact", res) }
        let after = DiskImage.allocatedBytes(work)
        journal.log("step", step: "compact", detail: "\(before) -> \(after) bytes")
        let d2 = try ContentManifest.digest(bundle: work)
        guard d1.digest == d2.digest, d1.entries == d2.entries else {
            throw DevStoreError("content changed during compaction (\(d1.digest) vs \(d2.digest)); original left untouched")
        }
        journal.log("step", step: "digest-after", detail: "identical")
        guard after < before else { return "nothing to reclaim (\(before) bytes allocated); original left untouched" }
        let trashed = try trash(URL(fileURLWithPath: bundle))
        try fm.moveItem(atPath: work, toPath: bundle)
        cleanup = false
        journal.log("step", step: "swap", detail: "original moved to \(trashed.path)")
        var image = r.image!
        image.lastCompaction = CompactionRecord(at: timestamp(), beforeBytes: before, afterBytes: after,
                                                contentEntries: d2.entries, contentDigest: d2.digest)
        try library.saveImage(image, in: r)
        let reclaimed = ByteCountFormatter.string(fromByteCount: before - after, countStyle: .file)
        return "compacted \(r.environment.kind)/\(r.environment.slot): reclaimed \(reclaimed) (\(d2.entries) entries verified identical); previous bundle is in the Trash until emptied"
    }

    // MARK: archive

    public func planArchive(_ query: String, encrypt: Bool, format: String = "ULFO") throws -> Plan {
        guard ["ULFO", "ULMO"].contains(format) else { throw DevStoreError("format must be ULFO (LZFSE) or ULMO (LZMA)") }
        let r = try library.resolve(query)
        let checkpointId = newId()
        let dir = URL(fileURLWithPath: r.store.path).appendingPathComponent("checkpoints/\(r.environment.environmentId)")
        let targets = ["environmentId": r.environment.environmentId, "imageId": r.image?.imageId ?? "",
                       "kind": r.environment.kind, "slot": r.environment.slot, "bundle": r.bundlePath ?? "",
                       "checkpointId": checkpointId, "format": format, "encryption": encrypt ? "aes256" : "none",
                       "destination": dir.appendingPathComponent("\(checkpointId).dmg").path]
        let checks = try archiveChecks(targets)
        try requireAll(checks)
        return try finish(Plan(
            planId: newId(), action: .archive, level: PlanAction.archive.level, targets: targets,
            preconditions: checks.map(\.description),
            effects: reclaimEffects(activeImageLease(r)) + [
                "attach the image read-only at a private temporary mount point and record a content digest",
                "convert it to a compressed read-only disk image (\(format == "ULFO" ? "LZFSE" : "LZMA")) at \(targets["destination"]!)"
                    + (encrypt ? ", AES-256 encrypted with a passphrase entered at execution (never stored)" : ""),
                "record SHA-256 and verify the archive with `hdiutil verify`",
            ],
            notTouched: ["the active image (read only)", "the slot path", "other environments"],
            createdAt: timestamp()))
    }

    func archiveChecks(_ t: [String: String]) throws -> [Precondition] {
        let r = try library.resolve(t["environmentId"]!)
        let free = (try? URL(fileURLWithPath: r.store.path).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init) ?? 0
        let need = r.bundlePath.map(DiskImage.allocatedBytes) ?? 0
        return unmountedImageChecks(r) + [
            Precondition(description: "image \(t["imageId"]!) is the active image", ok: r.image?.imageId == t["imageId"]),
            Precondition(description: "checkpoint file does not exist yet", ok: !fm.fileExists(atPath: t["destination"]!)),
            Precondition(description: "store volume has ≥ \(need) bytes free (uncompressed worst case)", ok: free >= need),
        ]
    }

    func executeArchive(_ plan: Plan, _ journal: Journal, passphrase: String?) throws -> String {
        let t = plan.targets
        let encrypted = t["encryption"] == "aes256"
        if encrypted {
            guard let passphrase, passphrase.count >= 8 else {
                throw DevStoreError("an encrypted archive needs a passphrase of at least 8 characters, entered by the user at execution")
            }
        }
        let r = try library.resolve(t["environmentId"]!)
        try reclaimStaleLeases(activeImageLease(r), journal)
        let bundle = t["bundle"]!, dest = t["destination"]!
        try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do {
            let content = try ContentManifest.digest(bundle: bundle)
            journal.log("step", step: "digest", detail: "\(content.entries) entries \(content.digest)")
            var args = ["convert", bundle, "-format", t["format"]!, "-o", dest]
            if encrypted { args += ["-encryption", "AES-256", "-stdinpass"] }
            let t0 = Date()
            let res = try Shell.run("/usr/bin/hdiutil", args, input: encrypted ? Data(passphrase!.utf8) : nil)
            guard res.status == 0 else { throw DiskImageError.command("hdiutil convert", res) }
            journal.log("step", step: "convert", detail: "\(Int(Date().timeIntervalSince(t0)))s")
            var vargs = ["verify", dest]
            if encrypted { vargs.append("-stdinpass") }
            let verify = try Shell.run("/usr/bin/hdiutil", vargs, input: encrypted ? Data(passphrase!.utf8) : nil)
            journal.log("step", step: "verify", detail: "hdiutil verify exit \(verify.status)")
            let size = Int64((try? fm.attributesOfItem(atPath: dest)[.size] as? NSNumber)??.int64Value ?? 0)
            let record = CheckpointRecord(
                checkpointId: t["checkpointId"]!, environmentId: r.environment.environmentId, kind: r.environment.kind,
                slot: r.environment.slot, displayName: r.environment.displayName, sourceImageId: t["imageId"]!,
                purpose: "archive", format: t["format"]!, encryption: t["encryption"]!, fileBytes: size,
                sha256: try Self.sha256(file: dest), sourceAllocatedBytes: DiskImage.allocatedBytes(bundle),
                contentEntries: content.entries, contentDigest: content.digest,
                imageChecksumVerified: verify.status == 0, fixedMountPath: r.slotPath, sdk: r.image?.sdk,
                createdAt: timestamp())
            try JSONIO.writeAtomically(record, to: URL(fileURLWithPath: dest).deletingPathExtension().appendingPathExtension("json"))
            journal.log("step", step: "record")
            let saved = record.sourceAllocatedBytes > 0
                ? 100 * (1 - Double(record.fileBytes) / Double(record.sourceAllocatedBytes)) : 0
            return "archived \(r.environment.kind)/\(r.environment.slot) as checkpoint \(record.checkpointId.prefix(8)): "
                + "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) (\(String(format: "%.1f", saved))% smaller), "
                + (encrypted ? "AES-256, " : "") + "verify \(record.imageChecksumVerified ? "ok" : "FAILED")"
        } catch {
            try? fm.removeItem(atPath: dest)
            journal.log("rolledBack", detail: "removed partial \(dest)")
            throw error
        }
    }

    // MARK: export

    public func planExport(checkpoint: String, to directory: String) throws -> Plan {
        let loc = try checkpointLocation(checkpoint)
        let dir = URL(fileURLWithPath: directory).standardizedFileURL.path
        let name = "\(loc.record.kind)-\(loc.record.slot)-\(loc.record.createdAt.prefix(10))-\(loc.record.checkpointId.prefix(8))"
        let targets = ["checkpointId": loc.record.checkpointId, "environmentId": loc.record.environmentId,
                       "kind": loc.record.kind, "slot": loc.record.slot, "source": loc.dmg.path,
                       "destination": dir + "/" + name + ".dmg", "sha256": loc.record.sha256]
        let checks = try exportChecks(targets)
        try requireAll(checks)
        return try finish(Plan(
            planId: newId(), action: .export, level: PlanAction.export.level, targets: targets,
            preconditions: checks.map(\.description),
            effects: ["copy \(loc.dmg.lastPathComponent) to \(targets["destination"]!) with its record (.json)",
                      "re-hash the copy and compare with SHA-256 \(loc.record.sha256.prefix(16))…; delete the copy on mismatch",
                      "append the export to the checkpoint record"],
            notTouched: ["the source checkpoint", "environments and images"], createdAt: timestamp()))
    }

    func exportChecks(_ t: [String: String]) throws -> [Precondition] {
        let dest = t["destination"]!
        let dir = (dest as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        let free = (try? URL(fileURLWithPath: dir).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init) ?? 0
        let size = Int64((try? fm.attributesOfItem(atPath: t["source"]!)[.size] as? NSNumber)??.int64Value ?? 0)
        return [
            Precondition(description: "checkpoint file exists", ok: fm.fileExists(atPath: t["source"]!)),
            Precondition(description: "destination directory \(dir) exists and is writable",
                         ok: fm.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue && fm.isWritableFile(atPath: dir)),
            Precondition(description: "\(dest) does not exist yet", ok: !fm.fileExists(atPath: dest)),
            Precondition(description: "destination has ≥ \(size) bytes free", ok: free >= size),
        ]
    }

    func executeExport(_ plan: Plan, _ journal: Journal) throws -> String {
        let t = plan.targets
        let loc = try checkpointLocation(t["checkpointId"]!)
        let dest = URL(fileURLWithPath: t["destination"]!)
        try fm.copyItem(at: loc.dmg, to: dest)
        journal.log("step", step: "copy", detail: dest.path)
        let sum = try Self.sha256(file: dest.path)
        guard sum == t["sha256"] else {
            try? fm.removeItem(at: dest)
            throw DevStoreError("copy SHA-256 mismatch (\(sum)); copy removed")
        }
        try fm.copyItem(at: loc.json, to: dest.deletingPathExtension().appendingPathExtension("json"))
        var rec = loc.record
        rec.exports.append(ExportRecord(path: dest.path, at: timestamp(), sha256Verified: true))
        try JSONIO.writeAtomically(rec, to: loc.json)
        journal.log("step", step: "verified", detail: sum)
        return "exported checkpoint \(rec.checkpointId.prefix(8)) to \(dest.path) (SHA-256 verified)"
    }
}
