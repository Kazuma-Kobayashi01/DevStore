@testable import DevStoreCore
import XCTest

final class DevStoreCoreTests: XCTestCase {
    var root: URL!
    var paths: DevStorePaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("devstore-tests-\(newId())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = DevStorePaths(hostRoot: root.appendingPathComponent("host"), slotRoot: root.appendingPathComponent("slots"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func samplePlan() throws -> Plan {
        var p = Plan(planId: newId(), action: .mount, level: .mount, targets: ["environmentId": "e1", "slotPath": "/x"],
                     preconditions: ["a"], effects: ["b"], notTouched: ["c"], createdAt: "2026-10-29T00:00:00+08:00")
        p.planDigest = try p.computedDigest()
        return p
    }

    func testDigestDetectsTampering() throws {
        var p = try samplePlan()
        XCTAssertEqual(try p.computedDigest(), p.planDigest)
        p.targets["slotPath"] = "/elsewhere"
        XCTAssertNotEqual(try p.computedDigest(), p.planDigest)
    }

    func testTamperedSavedPlanIsRejected() throws {
        let ops = Operations(library: Library(paths: paths))
        var p = try samplePlan()
        try ops.save(p)
        XCTAssertNoThrow(try ops.loadPlan(p.planId))
        p.effects = ["something else"]
        try ops.save(p)
        XCTAssertThrowsError(try ops.loadPlan(p.planId))
    }

    func testGrantIsSingleUseAndBoundToDigest() throws {
        let auth = Authorizer(paths: paths)
        let p = try samplePlan()
        XCTAssertNil(try auth.usableGrant(for: p))
        let g = try auth.grant(p, via: "test")
        var other = p
        other.planDigest = "sha256:other"
        XCTAssertNil(try auth.usableGrant(for: other))
        XCTAssertEqual(try auth.usableGrant(for: p)?.id, g.id)
        try auth.consume(p, grantId: g.id)
        XCTAssertNil(try auth.usableGrant(for: p))
    }

    func testGrantExpires() throws {
        let auth = Authorizer(paths: paths)
        let p = try samplePlan()
        _ = try auth.grant(p, via: "test")
        XCTAssertNil(try auth.usableGrant(for: p, now: Date().addingTimeInterval(Authorizer.grantLifetime + 1)))
    }

    func testPolicyOnlyCoversMountAndLatestEventWins() throws {
        let auth = Authorizer(paths: paths)
        XCTAssertFalse(try auth.policyAllows(environmentId: "e1", action: .mount))
        try auth.setPolicy(environmentId: "e1", allow: true, via: "test")
        XCTAssertTrue(try auth.policyAllows(environmentId: "e1", action: .mount))
        XCTAssertTrue(try auth.policyAllows(environmentId: "e1", action: .unmount))
        XCTAssertFalse(try auth.policyAllows(environmentId: "e1", action: .importImage))
        XCTAssertFalse(try auth.policyAllows(environmentId: "e2", action: .mount))
        try auth.setPolicy(environmentId: "e1", allow: false, via: "test")
        XCTAssertFalse(try auth.policyAllows(environmentId: "e1", action: .mount))
    }

    func testConsumedPlanCannotReplayEvenUnderPolicy() throws {
        let auth = Authorizer(paths: paths)
        let p = try samplePlan()
        XCTAssertNil(try auth.authorizeAndConsume(p))
        try auth.setPolicy(environmentId: "e1", allow: true, via: "test")
        XCTAssertEqual(try auth.authorizeAndConsume(p), "policy")
        XCTAssertThrowsError(try auth.authorizeAndConsume(p))
    }

    func testMinicondaBuiltMountPathFromShebang() throws {
        let vol = root.appendingPathComponent("vol")
        let bin = vol.appendingPathComponent("miniconda3/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/Users/x/.local/dev/miniconda/lab/miniconda3/bin/python\nimport sys\n"
            .write(to: bin.appendingPathComponent("conda"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MinicondaAdapter().builtMountPath(volumeRoot: vol.path), "/Users/x/.local/dev/miniconda/lab")
        try "#!/usr/bin/env python\n".write(to: bin.appendingPathComponent("conda"), atomically: true, encoding: .utf8)
        XCTAssertNil(MinicondaAdapter().builtMountPath(volumeRoot: vol.path))
    }

    func testRegistryRoundTripAndStoreRegistration() throws {
        let lib = Library(paths: paths)
        let storeDir = root.appendingPathComponent("store")
        XCTAssertThrowsError(try lib.addStore(path: storeDir.path, create: false))
        let ref = try lib.addStore(path: storeDir.path, create: true)
        XCTAssertTrue(lib.isOnline(ref))
        let again = try lib.addStore(path: storeDir.path, create: false)
        XCTAssertEqual(ref.storeId, again.storeId)
        XCTAssertEqual(try lib.loadRegistry().stores.count, 1)
        XCTAssertEqual(try lib.resolveStore(String(ref.storeId.prefix(8))).path, storeDir.standardizedFileURL.path)
    }

    func testCapabilityOrdering() {
        XCTAssertLessThan(CapabilityLevel.mount, .mutate)
        XCTAssertLessThan(CapabilityLevel.inspect, .destructive)
        XCTAssertEqual(PlanAction.importImage.level, .mutate)
    }
}
