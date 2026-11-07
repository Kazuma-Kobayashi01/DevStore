import Foundation

/// What an image's `lease.json` means right now.
public enum LeaseState: String, Codable, Sendable {
    /// No lease file.
    case none
    /// Lease from this host and the volume (or the slot) is mounted.
    case active
    /// Lease from this host, nothing mounted yet, and its mount transaction is still running.
    case pending
    /// Lease from this host but the volume is gone: the host rebooted, the volume was detached outside
    /// DevStore, or the mount transaction ended without removing it. Reclaimed by the next operation.
    case stale
    /// Lease from another host. Blocks; only a user-approved clear-lease plan removes it.
    case foreign
}

public struct LeaseAssessment: Sendable {
    /// A mount transaction older than this without a terminal journal entry is treated as dead.
    public static let pendingLimit: TimeInterval = 600

    public var state: LeaseState
    public var lease: Lease?
    /// One sentence describing the actual state; nil for `.none`. CLI, MCP and the app all show this text.
    public var summary: String?

    /// Whether the image may be mounted or changed (a stale lease is reclaimed first).
    public var permitsUse: Bool { state == .none || state == .stale }

    /// Precondition text for operations that need the image free of leases.
    public var precondition: Precondition {
        switch state {
        case .none: Precondition(description: "image holds no lease", ok: true)
        case .stale: Precondition(description: summary! + "; it will be reclaimed", ok: true)
        case .active, .pending, .foreign: Precondition(description: summary!, ok: false)
        }
    }

    /// Classifies a lease. Stale needs all of: this host, no mounted volume with the image's UUID, the slot is
    /// not a mount point, and either the lease predates boot, its transaction ended, or it is older than `pendingLimit`.
    public static func assess(lease: Lease?, hostId: String, volumeUUID: String?, volumeMountPoint: String?,
                              slotPath: String, slotIsMountPoint: Bool, bootTime: Date, transactionEnded: Bool,
                              environment: String, now: Date = Date()) -> LeaseAssessment {
        guard let lease else { return LeaseAssessment(state: .none) }
        let uuid = volumeUUID ?? "?"
        let since = "since \(lease.mountedAt)"
        guard lease.hostId == hostId else {
            return LeaseAssessment(state: .foreign, lease: lease, summary:
                "image holds a lease from host \(lease.hostId) (another host) \(since); that host may still have it mounted"
                + " — once it has unmounted, remove the lease with `devstore lease clear \(environment)`")
        }
        let owner = "image holds a lease from host \(lease.hostId) (this host) \(since)"
        if let mp = volumeMountPoint {
            return LeaseAssessment(state: .active, lease: lease, summary: "\(owner); volume \(uuid) is mounted at \(mp)")
        }
        if slotIsMountPoint {
            return LeaseAssessment(state: .active, lease: lease, summary: "\(owner); \(slotPath) is a mount point")
        }
        let mountedAt = ISO8601DateFormatter().date(from: lease.mountedAt) ?? .distantPast
        let stale = "\(owner), but no volume with UUID \(uuid) is mounted — stale lease"
        if mountedAt < bootTime {
            return LeaseAssessment(state: .stale, lease: lease, summary: "\(stale) (host rebooted at \(timestamp(bootTime)))")
        }
        if transactionEnded {
            return LeaseAssessment(state: .stale, lease: lease, summary: "\(stale) (volume detached outside DevStore)")
        }
        if now.timeIntervalSince(mountedAt) > pendingLimit {
            return LeaseAssessment(state: .stale, lease: lease,
                                   summary: "\(stale) (mount transaction \(lease.transactionId) never finished)")
        }
        return LeaseAssessment(state: .pending, lease: lease, summary:
            "\(owner) for mount transaction \(lease.transactionId), which has not finished (mount in progress?)")
    }
}

public enum HostClock {
    /// `kern.boottime`.
    public static func bootTime() -> Date {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }
}

extension Library {
    /// Lease of the active image.
    public func leaseAssessment(_ r: ResolvedEnvironment) -> LeaseAssessment {
        guard let dir = r.imageDir else { return LeaseAssessment(state: .none) }
        return leaseAssessment(imageDir: dir, volumeUUID: r.image?.volumeUUID, slotPath: r.slotPath,
                               environment: "\(r.environment.kind)/\(r.environment.slot)")
    }

    func leaseAssessment(imageDir: URL, volumeUUID: String?, slotPath: String, environment: String) -> LeaseAssessment {
        guard let lease = try? JSONIO.readIfPresent(Lease.self, from: imageDir.appendingPathComponent("lease.json")) else {
            return LeaseAssessment(state: .none)
        }
        let mounted = volumeUUID.flatMap { (try? DiskImage.mountedImageVolumeUUIDs())?[$0] }
        let ended = ((try? JSONIO.readLines(JournalEntry.self, from: paths.journal)) ?? []).contains {
            $0.transactionId == lease.transactionId && ["committed", "failed", "rolledBack"].contains($0.event)
        }
        return LeaseAssessment.assess(
            lease: lease, hostId: (try? loadRegistry().hostId) ?? "", volumeUUID: volumeUUID, volumeMountPoint: mounted,
            slotPath: slotPath, slotIsMountPoint: DiskImage.isMountPoint(slotPath), bootTime: HostClock.bootTime(),
            transactionEnded: ended, environment: environment)
    }
}

extension Operations {
    /// Leases of every image under an environment directory, with the lease file URL.
    func imageLeases(environmentDir: String, slotPath: String, environment: String) -> [(url: URL, assessment: LeaseAssessment)] {
        let images = URL(fileURLWithPath: environmentDir).appendingPathComponent("images")
        return ((try? fm.contentsOfDirectory(atPath: images.path)) ?? []).sorted().map { name in
            let dir = images.appendingPathComponent(name)
            let uuid = (try? JSONIO.read(ImageRecord.self, from: dir.appendingPathComponent("image.json")))?.volumeUUID
            return (dir.appendingPathComponent("lease.json"),
                    library.leaseAssessment(imageDir: dir, volumeUUID: uuid, slotPath: slotPath, environment: environment))
        }
    }

    /// Plan effect announcing that a stale lease will be reclaimed.
    func reclaimEffects(_ leases: [(url: URL, assessment: LeaseAssessment)]) -> [String] {
        leases.filter { $0.assessment.state == .stale }.map {
            "reclaim stale lease \($0.url.path) (this host, transaction \($0.assessment.lease!.transactionId)) and journal it"
        }
    }

    /// Removes this host's stale leases and journals each (`lease-reclaimed`). Runs after the preconditions
    /// passed, so every lease here is either absent or stale.
    func reclaimStaleLeases(_ leases: [(url: URL, assessment: LeaseAssessment)], _ journal: Journal) throws {
        for (url, a) in leases where a.state == .stale {
            try fm.removeItem(at: url)
            journal.log("step", step: "lease-reclaimed", detail: "transaction \(a.lease!.transactionId): \(a.summary!)")
        }
    }

    /// Lease of the active image paired with its file, for the helpers above.
    func activeImageLease(_ r: ResolvedEnvironment) -> [(url: URL, assessment: LeaseAssessment)] {
        r.leaseURL.map { [($0, library.leaseAssessment(r))] } ?? []
    }

    // MARK: clear-lease

    /// Plan to remove a lease this host is not using (another host's, or a stale one of this host).
    /// Destructive: if the other host still has the image attached, both may write the same volume.
    public func planClearLease(_ query: String) throws -> Plan {
        let r = try library.resolve(query)
        let a = library.leaseAssessment(r)
        guard let lease = a.lease else { throw DevStoreError("\(r.environment.kind)/\(r.environment.slot): image holds no lease") }
        let targets = ["environmentId": r.environment.environmentId, "imageId": r.image!.imageId,
                       "kind": r.environment.kind, "slot": r.environment.slot, "lease": r.leaseURL!.path,
                       "leaseHostId": lease.hostId, "leaseMountedAt": lease.mountedAt,
                       "leaseTransactionId": lease.transactionId]
        let checks = try clearLeaseChecks(targets)
        try requireAll(checks)
        return try finish(Plan(
            planId: newId(), action: .clearLease, level: PlanAction.clearLease.level, targets: targets,
            preconditions: checks.map(\.description),
            effects: ["remove lease \(r.leaseURL!.path) (host \(lease.hostId), since \(lease.mountedAt), transaction \(lease.transactionId)) and journal it"],
            notTouched: ["image content", "the other host: if it still has the image attached, both hosts may write the same volume"],
            createdAt: timestamp()))
    }

    func clearLeaseChecks(_ t: [String: String]) throws -> [Precondition] {
        let r = try library.resolve(t["environmentId"]!)
        let a = library.leaseAssessment(r)
        let mounted = (try? DiskImage.mountedImageVolumeUUIDs())?[r.image?.volumeUUID ?? "-"] != nil
        return [
            Precondition(description: "store \(r.store.storeId) is online", ok: library.isOnline(r.store)),
            Precondition(description: "image \(t["imageId"]!) is the active image", ok: r.image?.imageId == t["imageId"]),
            Precondition(description: "environment is not mounted on this host (slot and volume UUID)",
                         ok: !DiskImage.isMountPoint(r.slotPath) && !mounted),
            Precondition(description: "the lease is still the one planned (transaction \(t["leaseTransactionId"]!))",
                         ok: a.lease?.transactionId == t["leaseTransactionId"]),
            Precondition(description: a.state == .foreign || a.state == .stale
                             ? "lease is not in use on this host: \(a.summary!)"
                             : "lease is another host's or stale (now: \(a.summary ?? "no lease"))",
                         ok: a.state == .foreign || a.state == .stale),
        ]
    }

    func executeClearLease(_ plan: Plan, _ journal: Journal) throws -> String {
        let t = plan.targets
        try fm.removeItem(atPath: t["lease"]!)
        journal.log("step", step: "lease-cleared",
                    detail: "transaction \(t["leaseTransactionId"]!), host \(t["leaseHostId"]!), mountedAt \(t["leaseMountedAt"]!)")
        return "cleared the lease of \(t["kind"]!)/\(t["slot"]!) (host \(t["leaseHostId"]!), since \(t["leaseMountedAt"]!))"
    }
}
