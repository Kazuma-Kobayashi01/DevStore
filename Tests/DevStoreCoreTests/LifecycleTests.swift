@testable import DevStoreCore
import XCTest

final class LifecycleTests: XCTestCase {
    var root: URL!
    var paths: DevStorePaths!
    var trashDir: URL!
    var ops: Operations!
    var storeRef: StoreRef!

    override func setUpWithError() throws {
        // Short path: mount points under long temp paths are fine, but keep logs readable.
        root = URL(fileURLWithPath: "/private/tmp/dst-\(newId().prefix(8))")
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

    func testCreateValidation() {
        XCTAssertThrowsError(try ops.planCreate(storeQuery: storeRef.storeId, kind: "Go!", slot: "current", name: "x", sizeGiB: 5))
        XCTAssertThrowsError(try ops.planCreate(storeQuery: storeRef.storeId, kind: "go", slot: ".devstore", name: "x", sizeGiB: 5))
        XCTAssertThrowsError(try ops.planCreate(storeQuery: storeRef.storeId, kind: "go", slot: "current", name: "x", sizeGiB: 0))
        XCTAssertThrowsError(try ops.planCreate(storeQuery: "nope", kind: "go", slot: "current", name: "x", sizeGiB: 5))
    }

    func testCreatePlanLevelsAndPendingList() throws {
        let p = try ops.planCreate(storeQuery: storeRef.storeId, kind: "go", slot: "current", name: "Go", sizeGiB: 5)
        XCTAssertEqual(p.level, .mutate)
        XCTAssertEqual(try ops.pendingPlans().map(\.plan.planId), [p.planId])
        let auth = Authorizer(paths: paths)
        _ = try auth.grant(p, via: "test")
        XCTAssertEqual(try ops.pendingPlans().first?.state, .approved)
        try auth.reject(p, via: "test")
        XCTAssertTrue(try ops.pendingPlans().isEmpty)
        XCTAssertThrowsError(try auth.authorizeAndConsume(p), "rejected plans never run")
    }

    func testPolicyNeverCoversDelete() throws {
        let auth = Authorizer(paths: paths)
        try auth.setPolicy(environmentId: "e1", allow: true, via: "test")
        XCTAssertFalse(try auth.policyAllows(environmentId: "e1", action: .delete))
        XCTAssertFalse(try auth.policyAllows(environmentId: "e1", action: .create))
        XCTAssertEqual(PlanAction.delete.level, .destructive)
    }

    /// Real hdiutil round trip in /private/tmp. Set DEVSTORE_INTEGRATION=1 to run.
    func testCreateMountVerifyUnmountDelete() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEVSTORE_INTEGRATION"] == "1", "set DEVSTORE_INTEGRATION=1")
        let lib = ops.library
        let create = try ops.planCreate(storeQuery: storeRef.storeId, kind: "go", slot: "t1", name: "Go test", sizeGiB: 1)
        XCTAssertTrue(try ops.execute(create).contains("created empty environment"))
        let r = try lib.resolve("go/t1")
        XCTAssertEqual(r.environment.adapter.id, "empty")
        XCTAssertFalse(DiskImage.isMountPoint(r.slotPath))
        XCTAssertThrowsError(try ops.planCreate(storeQuery: storeRef.storeId, kind: "go", slot: "t1", name: "dup", sizeGiB: 1))

        _ = try ops.execute(try ops.planMount("go/t1"))
        XCTAssertTrue(lib.identityVerified(try lib.resolve("go/t1")))
        XCTAssertThrowsError(try ops.planDelete("go/t1"), "mounted environments cannot be deleted")
        let run = try Verifier(library: lib).verify(try lib.resolve("go/t1"), stage: "test")
        XCTAssertEqual(run.passed, run.total, "\(run.checks.filter { !$0.passed })")
        XCTAssertEqual(lib.status(try lib.resolve("go/t1")).verification, "passed")
        let out = try Session(library: lib).capture(try lib.resolve("go/t1"), command: ["sh", "-c", "echo $HOME"],
                                                    confine: true, denyNetwork: true)
        XCTAssertEqual(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines), r.slotPath + "/state/home")
        _ = try ops.execute(try ops.planUnmount("go/t1"))

        let del = try ops.planDelete("go/t1")
        XCTAssertEqual(del.level, .destructive)
        XCTAssertTrue(try ops.execute(del).contains("moved to"))
        XCTAssertThrowsError(try lib.resolve("go/t1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashDir.appendingPathComponent(r.environment.environmentId).path + "/environment.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.slotPath), "empty placeholder removed")
        XCTAssertThrowsError(try ops.execute(del), "plan cannot run twice")
    }
}
