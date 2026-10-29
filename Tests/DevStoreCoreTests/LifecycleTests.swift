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

    func testInstallerHeaderAndChecksumRefusal() throws {
        let fake = root.appendingPathComponent("fake.sh")
        try "#!/bin/sh\n# NAME:  Miniconda3\n# VER:   py314_26.9.4-0\n# PLAT:  osx-arm64\nexit 0\n".write(to: fake, atomically: true, encoding: .utf8)
        let h = Operations.installerHeader(fake.path)
        XCTAssertEqual(h["NAME"], "Miniconda3")
        XCTAssertEqual(h["VER"], "py314_26.9.4-0")
        XCTAssertEqual(try Operations.sha256(file: fake.path).count, 64)
        XCTAssertEqual(PlanAction.installSDK.level, .mutate)
    }

    /// Real Miniconda install into a temporary volume. Set DEVSTORE_INSTALLER=<path> and
    /// DEVSTORE_INSTALLER_SHA256=<hex> to run (takes a few minutes).
    func testInstallSDKIntoEmptyEnvironment() throws {
        let envVars = ProcessInfo.processInfo.environment
        guard let installer = envVars["DEVSTORE_INSTALLER"], let sum = envVars["DEVSTORE_INSTALLER_SHA256"] else {
            throw XCTSkip("set DEVSTORE_INSTALLER and DEVSTORE_INSTALLER_SHA256")
        }
        let lib = ops.library
        _ = try ops.execute(try ops.planCreate(storeQuery: storeRef.storeId, kind: "miniconda", slot: "t1", name: "Miniconda test", sizeGiB: 8))
        XCTAssertThrowsError(try ops.planInstallSDK("miniconda/t1", installer: installer, sha256: sum), "must be mounted")
        _ = try ops.execute(try ops.planMount("miniconda/t1"))
        XCTAssertThrowsError(try ops.planInstallSDK("miniconda/t1", installer: installer, sha256: String(repeating: "0", count: 64)),
                             "wrong checksum is refused")
        let plan = try ops.planInstallSDK("miniconda/t1", installer: installer, sha256: sum)
        print(try ops.execute(plan))
        let r = try lib.resolve("miniconda/t1")
        XCTAssertEqual(r.environment.adapter.id, "miniconda")
        XCTAssertEqual(lib.readManifest(mount: r.slotPath)?.adapter.id, "miniconda")
        XCTAssertNotNil(r.image?.sdk)
        XCTAssertEqual(lib.status(r).verification, "unverified")
        let run = try Verifier(library: lib).verify(r, stage: "test") { name, ok in print(ok ? "✓" : "✗", name) }
        XCTAssertEqual(run.passed, run.total, "\(run.checks.filter { !$0.passed }.map { ($0.name, $0.stderr ?? "") })")
        XCTAssertThrowsError(try ops.execute(plan), "plan cannot run twice")
        _ = try ops.execute(try ops.planUnmount("miniconda/t1"))
        _ = try ops.execute(try ops.planDelete("miniconda/t1"))
    }
}
