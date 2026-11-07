@testable import DevStoreCore
import XCTest

/// Ticket 001: a lease left behind by a reboot (or a detach outside DevStore) must not block forever,
/// while live leases and other hosts' leases keep blocking.
final class LeaseTests: XCTestCase {
    var root: URL!
    var paths: DevStorePaths!
    var trashDir: URL!
    var ops: Operations!
    var storeRef: StoreRef!
    var lib: Library { ops.library }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/dsl-\(newId().prefix(8))")
        trashDir = root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        paths = DevStorePaths(hostRoot: root.appendingPathComponent("host"), slotRoot: root.appendingPathComponent("slots"))
        let trash = trashDir!
        ops = Operations(library: Library(paths: paths)) { url in
            let dest = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
        storeRef = try ops.library.addStore(path: root.appendingPathComponent("store").path, create: true)
    }

    override func tearDownWithError() throws {
        for slot in (try? FileManager.default.subpathsOfDirectory(atPath: paths.slotRoot.path)) ?? [] {
            let p = paths.slotRoot.path + "/" + slot
            if DiskImage.isMountPoint(p) { try? DiskImage.detach(mountPoint: p) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// Registered environment whose bundle is a stub (enough for planning, not for attaching).
    func makeEnvironment() throws -> ResolvedEnvironment {
        let envId = newId(), imageId = newId()
        let dir = lib.environmentDir(store: storeRef, kind: "go", environmentId: envId)
        let imageDir = dir.appendingPathComponent("images/\(imageId)")
        let bundle = imageDir.appendingPathComponent("environment.sparsebundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bundle.path + "/Info.plist", contents: Data())
        let slotPath = paths.slotPath(kind: "go", slot: "current")
        try FileManager.default.createDirectory(atPath: slotPath, withIntermediateDirectories: true)
        try JSONIO.writeAtomically(ImageRecord(
            imageId: imageId, environmentId: envId, storeId: storeRef.storeId, relativePath: "stub",
            volumeUUID: UUID().uuidString, role: .active, lineage: Lineage(reason: "test"), fixedMountPath: slotPath,
            hostBinding: .current(), createdAt: timestamp()), to: imageDir.appendingPathComponent("image.json"))
        try JSONIO.writeAtomically(EnvironmentRecord(
            environmentId: envId, kind: "go", slot: "current", displayName: "Go", adapter: AdapterRef(id: "empty", version: "1"),
            activeImageId: imageId, origin: Origin(type: "created"), createdAt: timestamp()),
            to: dir.appendingPathComponent("environment.json"))
        var reg = try lib.loadRegistry()
        reg.slots.append(SlotBinding(kind: "go", slot: "current", environmentId: envId, storeId: storeRef.storeId))
        try lib.saveRegistry(reg)
        return try lib.resolve("go/current")
    }

    func writeLease(_ r: ResolvedEnvironment, hostId: String, mountedAt: Date) throws -> Lease {
        let lease = Lease(hostId: hostId, imageId: r.image!.imageId, mountedAt: timestamp(mountedAt), transactionId: newId())
        try JSONIO.writeAtomically(lease, to: r.leaseURL!)
        return lease
    }

    func journal() throws -> [JournalEntry] { try JSONIO.readLines(JournalEntry.self, from: paths.journal) }

    func testClassification() {
        let boot = Date(timeIntervalSinceNow: -3600)
        let me = "host-a"
        func assess(_ lease: Lease, mountedAt mp: String? = nil, slotMounted: Bool = false, ended: Bool = false) -> LeaseState {
            LeaseAssessment.assess(lease: lease, hostId: me, volumeUUID: "UUID-1", volumeMountPoint: mp, slotPath: "/s",
                                   slotIsMountPoint: slotMounted, bootTime: boot, transactionEnded: ended, environment: "go/current").state
        }
        let beforeBoot = Lease(hostId: me, imageId: "i", mountedAt: timestamp(boot.addingTimeInterval(-60)), transactionId: "t")
        let recent = Lease(hostId: me, imageId: "i", mountedAt: timestamp(Date(timeIntervalSinceNow: -5)), transactionId: "t")
        let old = Lease(hostId: me, imageId: "i", mountedAt: timestamp(Date(timeIntervalSinceNow: -LeaseAssessment.pendingLimit - 60)),
                        transactionId: "t")
        XCTAssertEqual(assess(beforeBoot), .stale, "reboot unmounted the volume")
        XCTAssertEqual(assess(beforeBoot, mountedAt: "/Volumes/x"), .active, "a mounted volume keeps the lease live")
        XCTAssertEqual(assess(beforeBoot, slotMounted: true), .active, "something is mounted on the slot")
        XCTAssertEqual(assess(recent), .pending, "another process may be attaching right now")
        XCTAssertEqual(assess(recent, ended: true), .stale, "transaction finished, volume gone: detached outside DevStore")
        XCTAssertEqual(assess(old), .stale, "a mount transaction never takes this long")
        var foreign = beforeBoot
        foreign.hostId = "host-b"
        XCTAssertEqual(assess(foreign), .foreign, "other hosts' leases never become stale here")
        XCTAssertEqual(LeaseAssessment.assess(lease: nil, hostId: me, volumeUUID: nil, volumeMountPoint: nil, slotPath: "/s",
                                              slotIsMountPoint: false, bootTime: boot, transactionEnded: false,
                                              environment: "go/current").state, .none)
    }

    func testStaleLeaseIsReclaimedByMount() throws {
        let r = try makeEnvironment()
        let old = try writeLease(r, hostId: try lib.loadRegistry().hostId, mountedAt: HostClock.bootTime().addingTimeInterval(-60))
        let status = lib.status(r)
        XCTAssertEqual(status.leaseState, .stale)
        XCTAssertTrue(status.leaseSummary!.contains("host rebooted"), status.leaseSummary!)

        let plan = try ops.planMount("go/current")
        XCTAssertTrue(plan.effects.contains { $0.hasPrefix("reclaim stale lease") }, "\(plan.effects)")
        XCTAssertTrue(plan.preconditions.contains { $0.contains("stale lease") && $0.contains("reclaimed") })
        // The stub bundle cannot attach; the stale lease is reclaimed (and journaled) before the attach fails.
        XCTAssertThrowsError(try ops.execute(plan))
        let reclaimed = try journal().filter { $0.step == "lease-reclaimed" }
        XCTAssertEqual(reclaimed.count, 1)
        XCTAssertTrue(reclaimed[0].detail!.contains(old.transactionId))
        XCTAssertEqual(lib.status(r).leaseState, .none)
    }

    func testForeignLeaseBlocksUntilUserClearsIt() throws {
        let r = try makeEnvironment()
        _ = try writeLease(r, hostId: "other-host-0001", mountedAt: Date(timeIntervalSinceNow: -86400))
        XCTAssertEqual(lib.status(r).leaseState, .foreign)
        for plan in [{ try self.ops.planMount("go/current") }, { try self.ops.planCompact("go/current") },
                     { try self.ops.planDelete("go/current") }] {
            XCTAssertThrowsError(try plan()) { error in
                let text = String(describing: error)
                XCTAssertTrue(text.contains("other-host-0001") && text.contains("another host"), text)
                XCTAssertTrue(text.contains("devstore lease clear go/current"), text)
            }
        }

        let clear = try ops.planClearLease("go/current")
        XCTAssertEqual(clear.level, .destructive)
        let auth = Authorizer(paths: paths)
        try auth.setPolicy(environmentId: r.environment.environmentId, allow: true, via: "test")
        XCTAssertNil(try auth.authorizeAndConsume(clear), "no policy covers clearing a lease")
        XCTAssertTrue(try ops.execute(clear).contains("cleared the lease"))
        XCTAssertEqual(try journal().filter { $0.step == "lease-cleared" }.count, 1)
        XCTAssertEqual(lib.status(r).leaseState, .none)
        XCTAssertNoThrow(try ops.planMount("go/current"))
        XCTAssertThrowsError(try ops.planClearLease("go/current"), "nothing left to clear")
    }

    func testPendingLeaseOfThisHostBlocks() throws {
        let r = try makeEnvironment()
        _ = try writeLease(r, hostId: try lib.loadRegistry().hostId, mountedAt: Date())
        XCTAssertEqual(lib.status(r).leaseState, .pending)
        XCTAssertThrowsError(try ops.planMount("go/current")) { XCTAssertTrue(String(describing: $0).contains("has not finished")) }
        XCTAssertThrowsError(try ops.planClearLease("go/current"), "a running mount's lease is not clearable")
    }

    func testDeleteReclaimsStaleLease() throws {
        let r = try makeEnvironment()
        _ = try writeLease(r, hostId: try lib.loadRegistry().hostId, mountedAt: HostClock.bootTime().addingTimeInterval(-60))
        let plan = try ops.planDelete("go/current")
        XCTAssertTrue(plan.effects.first!.hasPrefix("reclaim stale lease"))
        XCTAssertTrue(try ops.execute(plan).contains("moved to"))
        XCTAssertEqual(try journal().filter { $0.step == "lease-reclaimed" }.count, 1)
    }

    /// Real hdiutil: mount, detach behind DevStore's back, mount again. Set DEVSTORE_INTEGRATION=1 to run.
    func testDetachOutsideDevStoreThenMount() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEVSTORE_INTEGRATION"] == "1", "set DEVSTORE_INTEGRATION=1")
        _ = try ops.execute(try ops.planCreate(storeQuery: storeRef.storeId, kind: "go", slot: "t1", name: "Go test", sizeGiB: 1))
        _ = try ops.execute(try ops.planMount("go/t1"))
        XCTAssertEqual(lib.status(try lib.resolve("go/t1")).leaseState, .active)
        let r = try lib.resolve("go/t1")
        let first = try JSONIO.read(Lease.self, from: r.leaseURL!)
        try DiskImage.detach(mountPoint: r.slotPath)
        let s = lib.status(r)
        XCTAssertEqual(s.leaseState, .stale)
        XCTAssertTrue(s.leaseSummary!.contains("detached outside DevStore"), s.leaseSummary!)

        _ = try ops.execute(try ops.planMount("go/t1"))
        XCTAssertTrue(lib.identityVerified(r))
        XCTAssertEqual(lib.status(r).leaseState, .active)
        XCTAssertTrue(try journal().contains { $0.step == "lease-reclaimed" && $0.detail!.contains(first.transactionId) })
        _ = try ops.execute(try ops.planUnmount("go/t1"))
    }
}
