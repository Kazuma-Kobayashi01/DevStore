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

    /// Compact (clone → compact → digest compare → swap), archive (plain and AES-256) and export.
    /// Real hdiutil in /private/tmp. Set DEVSTORE_INTEGRATION=1 to run.
    func testCompactArchiveExport() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEVSTORE_INTEGRATION"] == "1", "set DEVSTORE_INTEGRATION=1")
        let lib = ops.library
        _ = try ops.execute(try ops.planCreate(storeQuery: storeRef.storeId, kind: "go", slot: "t2", name: "Archive test", sizeGiB: 2))
        _ = try ops.execute(try ops.planMount("go/t2"))
        let mount = try lib.resolve("go/t2").slotPath
        try "keep me\n".write(toFile: mount + "/state/home/note.txt", atomically: true, encoding: .utf8)
        let filler = mount + "/tmp/fill.bin"
        XCTAssertEqual(try Shell.run("/bin/dd", ["if=/dev/urandom", "of=\(filler)", "bs=8m", "count=40"]).status, 0)
        XCTAssertThrowsError(try ops.planCompact("go/t2"), "mounted environments cannot be compacted")
        _ = try ops.execute(try ops.planUnmount("go/t2"))
        _ = try ops.execute(try ops.planMount("go/t2"))
        try FileManager.default.removeItem(atPath: filler)
        _ = try ops.execute(try ops.planUnmount("go/t2"))

        let bundle = try lib.resolve("go/t2").bundlePath!
        let before = DiskImage.allocatedBytes(bundle)
        let out = try ops.execute(try ops.planCompact("go/t2"))
        print(out)
        XCTAssertTrue(out.contains("reclaimed"), out)
        XCTAssertLessThan(DiskImage.allocatedBytes(bundle), before)
        XCTAssertNotNil(try lib.resolve("go/t2").image?.lastCompaction)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trashDir.path).filter { $0.hasSuffix(".sparsebundle") }.count, 1)

        let plain = try ops.planArchive("go/t2", encrypt: false)
        print(try ops.execute(plain))
        let enc = try ops.planArchive("go/t2", encrypt: true)
        XCTAssertThrowsError(try ops.execute(enc), "encrypted archive needs a passphrase")
        let enc2 = try ops.planArchive("go/t2", encrypt: true)
        print(try ops.execute(enc2, passphrase: "correct horse battery"))
        let cps = try ops.checkpoints(environmentId: try lib.resolve("go/t2").environment.environmentId)
        XCTAssertEqual(cps.count, 2)
        XCTAssertTrue(cps.allSatisfy(\.imageChecksumVerified))
        XCTAssertEqual(Set(cps.map(\.encryption)), ["none", "aes256"])
        XCTAssertEqual(Set(cps.map(\.contentDigest)).count, 1, "both archives hold the same content")
        // An encrypted archive cannot be attached without the passphrase.
        let encrypted = try ops.checkpointLocation(cps.first { $0.encryption == "aes256" }!.checkpointId).dmg.path
        XCTAssertNotEqual(try Shell.run("/usr/bin/hdiutil", ["imageinfo", "-stdinpass", encrypted], input: Data("wrong passphrase".utf8)).status, 0)

        let cold = root.appendingPathComponent("cold")
        try FileManager.default.createDirectory(at: cold, withIntermediateDirectories: true)
        let exp = try ops.planExport(checkpoint: cps[0].checkpointId, to: cold.path)
        print(try ops.execute(exp))
        let copies = try FileManager.default.contentsOfDirectory(atPath: cold.path)
        XCTAssertEqual(copies.filter { $0.hasSuffix(".dmg") }.count, 1)
        XCTAssertEqual(copies.filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertEqual(try ops.checkpoints().first { $0.checkpointId == cps[0].checkpointId }?.exports.count, 1)
        XCTAssertThrowsError(try ops.planExport(checkpoint: cps[0].checkpointId, to: cold.path), "no overwrite")

        // Content survived compaction.
        _ = try ops.execute(try ops.planMount("go/t2"))
        XCTAssertEqual(try String(contentsOfFile: mount + "/state/home/note.txt", encoding: .utf8), "keep me\n")
        _ = try ops.execute(try ops.planUnmount("go/t2"))
    }
}

/// Go archive into an empty environment, then the Go suite. Set DEVSTORE_GO_ARCHIVE and
/// DEVSTORE_GO_SHA256 to run; DEVSTORE_GO_TOOL optionally copies one tool into gopath/bin.
final class GoInstallTests: XCTestCase {
    func testInstallGoAndVerify() throws {
        let e = ProcessInfo.processInfo.environment
        guard let archive = e["DEVSTORE_GO_ARCHIVE"], let sum = e["DEVSTORE_GO_SHA256"] else { throw XCTSkip("set DEVSTORE_GO_ARCHIVE") }
        let root = URL(fileURLWithPath: "/private/tmp/dsg-\(newId().prefix(8))")
        defer {
            let slot = root.path + "/slots/go/t1"
            if DiskImage.isMountPoint(slot) { try? DiskImage.detach(mountPoint: slot) }
            try? FileManager.default.removeItem(at: root)
        }
        let paths = DevStorePaths(hostRoot: root.appendingPathComponent("host"), slotRoot: root.appendingPathComponent("slots"))
        let ops = Operations(library: Library(paths: paths)) { $0 }
        let store = try ops.library.addStore(path: root.appendingPathComponent("store").path, create: true)
        _ = try ops.execute(try ops.planCreate(storeQuery: store.storeId, kind: "go", slot: "t1", name: "Go test", sizeGiB: 8))
        _ = try ops.execute(try ops.planMount("go/t1"))
        XCTAssertNotNil(Operations.identifySDK(archive))
        XCTAssertThrowsError(try ops.planInstallSDK("go/t1", installer: archive, sha256: String(repeating: "0", count: 64)))
        print(try ops.execute(try ops.planInstallSDK("go/t1", installer: archive, sha256: sum)))
        let r = try ops.library.resolve("go/t1")
        XCTAssertEqual(r.environment.adapter.id, "go")
        if let tool = e["DEVSTORE_GO_TOOL"] {
            try FileManager.default.copyItem(atPath: tool, toPath: r.slotPath + "/gopath/bin/" + URL(fileURLWithPath: tool).lastPathComponent)
        }
        let run = try Verifier(library: ops.library).verify(r, stage: "test") { name, ok in print(ok ? "✓" : "✗", name) }
        XCTAssertEqual(run.passed, run.total, "\(run.checks.filter { !$0.passed }.map { ($0.name, $0.stderr ?? "") })")
        _ = try ops.execute(try ops.planUnmount("go/t1"))
    }
}

/// Builds a throwaway demo registry for UI screenshots. Set DEVSTORE_DEMO_HOME=<dir> to run;
/// leaves `<dir>/slots/go/current` mounted — detach and delete <dir> afterwards.
final class DemoDataTests: XCTestCase {
    func testMakeDemo() throws {
        guard let dir = ProcessInfo.processInfo.environment["DEVSTORE_DEMO_HOME"] else { throw XCTSkip("set DEVSTORE_DEMO_HOME") }
        let root = URL(fileURLWithPath: dir)
        let paths = DevStorePaths(hostRoot: root.appendingPathComponent("host"), slotRoot: root.appendingPathComponent("slots"))
        let ops = Operations(library: Library(paths: paths))
        let store = try ops.library.addStore(path: root.appendingPathComponent("store").path, create: true)
        _ = try ops.execute(try ops.planCreate(storeQuery: store.storeId, kind: "rust", slot: "current", name: "Rust stable", sizeGiB: 4))
        _ = try ops.execute(try ops.planArchive("rust/current", encrypt: false))
        _ = try ops.execute(try ops.planCreate(storeQuery: store.storeId, kind: "go", slot: "current", name: "Go 1.25", sizeGiB: 4))
        _ = try ops.execute(try ops.planMount("go/current"))
        _ = try Verifier(library: ops.library).verify(try ops.library.resolve("go/current"), stage: "demo")
        _ = try ops.planCompact("rust/current")
    }
}
