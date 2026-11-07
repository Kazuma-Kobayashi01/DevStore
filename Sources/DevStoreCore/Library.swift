import Foundation

public struct DevStoreError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public struct DevStorePaths: Sendable {
    /// Host registry directory; `DEVSTORE_HOME` overrides it (tests).
    public var hostRoot: URL
    /// Slot root, fixed at `~/.local/dev`; `DEVSTORE_SLOT_ROOT` overrides it (tests only).
    public var slotRoot: URL

    public static func standard() -> DevStorePaths {
        let env = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let hostRoot = env["DEVSTORE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Library/Application Support/DevStore")
        let slotRoot = env["DEVSTORE_SLOT_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/dev")
        return DevStorePaths(hostRoot: hostRoot, slotRoot: slotRoot)
    }

    public var registry: URL { hostRoot.appendingPathComponent("registry.json") }
    public var journal: URL { hostRoot.appendingPathComponent("journal.jsonl") }
    public var grants: URL { hostRoot.appendingPathComponent("grants.jsonl") }
    public var plansDir: URL { hostRoot.appendingPathComponent("plans") }

    public func slotPath(kind: String, slot: String) -> String {
        slotRoot.appendingPathComponent(kind).appendingPathComponent(slot).path
    }
}

/// Resolved view of one environment and its active image.
public struct ResolvedEnvironment: Sendable {
    public var environment: EnvironmentRecord
    public var store: StoreRef
    public var image: ImageRecord?
    public var environmentDir: URL
    public var slotPath: String

    public var imageDir: URL? {
        image.map { environmentDir.appendingPathComponent("images").appendingPathComponent($0.imageId) }
    }
    public var bundlePath: String? { imageDir?.appendingPathComponent("environment.sparsebundle").path }
    public var leaseURL: URL? { imageDir?.appendingPathComponent("lease.json") }
}

public struct EnvironmentStatus: Codable, Sendable {
    public var environmentId: String
    public var kind: String
    public var slot: String
    public var displayName: String
    public var slotPath: String
    public var storeId: String
    public var storeOnline: Bool
    public var imageId: String?
    public var role: ImageRole?
    public var volumeUUID: String?
    public var mounted: Bool
    public var identityVerified: Bool?
    public var lease: Lease?
    public var leaseState: LeaseState
    public var leaseSummary: String?
    public var verification: String
    public var lastVerification: VerificationRef?
    public var knownWarnings: [String]
}

public struct Library: Sendable {
    public var paths: DevStorePaths

    public init(paths: DevStorePaths = .standard()) { self.paths = paths }

    // MARK: registry

    public func loadRegistry() throws -> HostRegistry {
        if let r = try JSONIO.readIfPresent(HostRegistry.self, from: paths.registry) { return r }
        let r = HostRegistry(hostId: newId())
        try JSONIO.writeAtomically(r, to: paths.registry)
        return r
    }

    public func saveRegistry(_ r: HostRegistry) throws {
        try JSONIO.writeAtomically(r, to: paths.registry)
    }

    // MARK: stores

    public static func storeRecordURL(_ root: URL) -> URL { root.appendingPathComponent("store.json") }

    public func addStore(path: String, create: Bool) throws -> StoreRef {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let recordURL = Self.storeRecordURL(root)
        let record: StoreRecord
        if let existing = try JSONIO.readIfPresent(StoreRecord.self, from: recordURL) {
            record = existing
        } else {
            guard create else { throw DevStoreError("\(root.path) is not a DevStore store (no store.json); pass --create") }
            record = StoreRecord(storeId: newId(), createdAt: timestamp())
            try JSONIO.writeAtomically(record, to: recordURL)
        }
        var reg = try loadRegistry()
        reg.stores.removeAll { $0.storeId == record.storeId }
        let ref = StoreRef(storeId: record.storeId, path: root.path)
        reg.stores.append(ref)
        try saveRegistry(reg)
        return ref
    }

    public func isOnline(_ store: StoreRef) -> Bool {
        guard let r = try? JSONIO.read(StoreRecord.self, from: Self.storeRecordURL(URL(fileURLWithPath: store.path))) else {
            return false
        }
        return r.storeId == store.storeId
    }

    public func resolveStore(_ query: String) throws -> StoreRef {
        let reg = try loadRegistry()
        let std = URL(fileURLWithPath: query).standardizedFileURL.path
        if let s = reg.stores.first(where: { $0.storeId.hasPrefix(query.lowercased()) || $0.path == std }) { return s }
        throw DevStoreError("unknown store \(query); register it with `devstore store add`")
    }

    func environmentDir(store: StoreRef, kind: String, environmentId: String) -> URL {
        URL(fileURLWithPath: store.path).appendingPathComponent("environments")
            .appendingPathComponent(kind).appendingPathComponent(environmentId)
    }

    // MARK: environments

    /// All environments bound to slots on this host.
    public func environments() throws -> [ResolvedEnvironment] {
        let reg = try loadRegistry()
        return reg.slots.compactMap { b in
            guard let store = reg.stores.first(where: { $0.storeId == b.storeId }) else { return nil }
            let dir = environmentDir(store: store, kind: b.kind, environmentId: b.environmentId)
            let env = (try? JSONIO.read(EnvironmentRecord.self, from: dir.appendingPathComponent("environment.json")))
                ?? EnvironmentRecord(environmentId: b.environmentId, kind: b.kind, slot: b.slot,
                                     displayName: "(store offline)", adapter: AdapterRef(id: b.kind, version: "?"),
                                     origin: Origin(type: "unknown"), createdAt: "")
            let image = env.activeImageId.flatMap {
                try? JSONIO.read(ImageRecord.self, from: dir.appendingPathComponent("images/\($0)/image.json"))
            }
            return ResolvedEnvironment(environment: env, store: store, image: image, environmentDir: dir,
                                       slotPath: paths.slotPath(kind: b.kind, slot: b.slot))
        }
    }

    /// Accepts an environment id (or unique prefix), `kind/slot`, or display name.
    public func resolve(_ query: String) throws -> ResolvedEnvironment {
        let all = try environments()
        let q = query.lowercased()
        let matches = all.filter {
            $0.environment.environmentId.hasPrefix(q)
                || "\($0.environment.kind)/\($0.environment.slot)" == q
                || $0.environment.displayName == query
        }
        guard matches.count == 1 else {
            throw DevStoreError(matches.isEmpty ? "no environment matches \(query)"
                                                : "\(query) is ambiguous; use the environment id")
        }
        return matches[0]
    }

    public func readManifest(mount: String) -> VolumeManifest? {
        try? JSONIO.read(VolumeManifest.self, from: URL(fileURLWithPath: mount).appendingPathComponent(".devstore/manifest.json"))
    }

    /// True only when the slot is a mount point whose manifest and volume UUID match the active image.
    public func identityVerified(_ r: ResolvedEnvironment) -> Bool {
        guard let image = r.image, DiskImage.isMountPoint(r.slotPath),
              let m = readManifest(mount: r.slotPath),
              m.imageId == image.imageId, m.environmentId == r.environment.environmentId,
              m.fixedMountPath == r.slotPath,
              let info = try? DiskImage.volumeInfo(mountPoint: r.slotPath),
              info.volumeUUID == image.volumeUUID else { return false }
        return true
    }

    public func status(_ r: ResolvedEnvironment) -> EnvironmentStatus {
        let mounted = DiskImage.isMountPoint(r.slotPath)
        let lease = leaseAssessment(r)
        let verification: String
        if let v = r.image?.lastVerification {
            verification = r.image?.mutatedSinceVerification == true ? "stale" : (v.passed == v.total ? "passed" : "failed")
        } else {
            verification = "unverified"
        }
        return EnvironmentStatus(
            environmentId: r.environment.environmentId, kind: r.environment.kind, slot: r.environment.slot,
            displayName: r.environment.displayName, slotPath: r.slotPath, storeId: r.store.storeId,
            storeOnline: isOnline(r.store), imageId: r.image?.imageId, role: r.image?.role,
            volumeUUID: r.image?.volumeUUID, mounted: mounted,
            identityVerified: mounted ? identityVerified(r) : nil, lease: lease.lease,
            leaseState: lease.state, leaseSummary: lease.summary,
            verification: verification, lastVerification: r.image?.lastVerification,
            knownWarnings: r.image?.knownWarnings ?? [])
    }

    public func saveImage(_ image: ImageRecord, in r: ResolvedEnvironment) throws {
        try JSONIO.writeAtomically(image, to: r.environmentDir.appendingPathComponent("images/\(image.imageId)/image.json"))
    }
}
