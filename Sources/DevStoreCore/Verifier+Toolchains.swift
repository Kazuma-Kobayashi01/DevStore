import Foundation

/// Shared sandboxed runner for the rust, dotnet and flutter suites.
struct SuiteRunner {
    let mount: String
    let profile: String
    var env: [String: String]
    let progress: (String, Bool) -> Void
    var checks: [CheckResult] = []

    init(mount: String, denied: [String], env: [String: String], progress: @escaping (String, Bool) -> Void) {
        self.mount = mount
        self.env = env
        self.progress = progress
        profile = "(version 1)\n(allow default)\n(deny network*)\n(deny file-read*\n"
            + denied.map { "  (subpath \"\($0)\")" }.joined(separator: "\n")
            + ")\n(deny file-write*)\n(allow file-write*\n  (subpath \"\(mount)\")\n  (subpath \"/private/tmp\")\n"
            + "  (subpath \"/private/var/folders\")\n  (literal \"/dev/null\"))\n"
    }

    mutating func add(_ name: String, _ ok: Bool, _ detail: String? = nil) {
        checks.append(CheckResult(name: name, passed: ok, stdout: detail))
        progress(name, ok)
    }

    @discardableResult
    mutating func run(_ name: String, _ cmd: [String], cwd: String, extra: [String: String] = [:],
                      accept: ((ShellResult) -> Bool)? = nil) -> ShellResult? {
        let t0 = Date()
        var e = env
        e.merge(extra) { _, n in n }
        do {
            let res = try Shell.run("/usr/bin/sandbox-exec", ["-p", profile] + cmd, environment: e, currentDirectory: cwd)
            let ok = accept.map { $0(res) } ?? (res.status == 0)
            checks.append(CheckResult(name: name, passed: ok, exitCode: res.status,
                                      seconds: (Date().timeIntervalSince(t0) * 1000).rounded() / 1000,
                                      stdout: String(res.stdout.suffix(4000)), stderr: String(res.stderr.suffix(4000))))
            progress(name, ok)
            return res
        } catch {
            add(name, false, String(describing: error))
            return nil
        }
    }

    /// Origins must be unreadable when present; absent origins are recorded as such.
    mutating func negativeControls(_ origins: [String]) throws {
        let present = origins.filter { FileManager.default.fileExists(atPath: $0) }
        for o in present {
            let res = run("negative-control-blocked:\(o)", ["/bin/ls", o], cwd: mount + "/tmp") {
                $0.status != 0 && $0.stderr.contains("Operation not permitted")
            }
            guard res != nil, checks.last!.passed else { throw DevStoreError("negative control failed for \(o); run invalid") }
        }
        if present.isEmpty { add("negative-control-origins-absent", true, origins.joined(separator: ", ")) }
    }

    mutating func persistence() {
        let ok = (try? String(contentsOfFile: mount + "/state/persistence-marker.txt", encoding: .utf8)) == "single-volume-persistence-20261029\n"
        add("state-persisted", ok)
    }
}

extension Verifier {
    func finishRun(_ runner: SuiteRunner, _ r: ResolvedEnvironment, stage: String, suite: String, adapter: AdapterRef,
                   denied: [String], startedAt: String, notCovered: [String]) throws -> VerificationRun {
        let passed = runner.checks.filter(\.passed).count
        let run = VerificationRun(
            runId: newId(), target: ["environmentId": r.environment.environmentId, "imageId": r.image!.imageId],
            stage: stage, suite: AdapterRef(id: suite, version: "1"), adapterVersion: adapter.version, host: .current(),
            confinement: ["deniedReadTrees": denied, "network": ["denied"], "writeAllowed": [r.slotPath, "/private/tmp"]],
            negativeControlPassed: true, checks: runner.checks, passed: passed, total: runner.checks.count,
            startedAt: startedAt, finishedAt: timestamp(), notCovered: notCovered)
        try record(run, r)
        return run
    }

    func probeDir(_ mount: String, _ name: String) throws -> String {
        let dir = mount + "/tmp/devstore-\(name)-probe"
        try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func verifyRust(_ r: ResolvedEnvironment, stage: String, progress: @escaping (String, Bool) -> Void) throws -> VerificationRun {
        guard library.identityVerified(r) else { throw DevStoreError("environment must be mounted with a verified identity") }
        let a = RustAdapter(), mount = r.slotPath, startedAt = timestamp()
        let origins = a.originPathsToDeny(home: NSHomeDirectory())
        let denied = origins + ["/opt/homebrew", "/usr/local"]
        var s = SuiteRunner(mount: mount, denied: denied, env: a.sessionEnvironment(mount: mount).merging(["CARGO_NET_OFFLINE": "true"]) { _, n in n }, progress: progress)
        let dir = try probeDir(mount, "rust")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "[package]\nname = \"devstoreprobe\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n"
            .write(toFile: dir + "/Cargo.toml", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        try "fn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n\nfn main() {\n    println!(\"devstore-rust-ok {}\", add(2, 3));\n}\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn adds() {\n        assert_eq!(super::add(2, 3), 5);\n    }\n}\n"
            .write(toFile: dir + "/src/main.rs", atomically: true, encoding: .utf8)
        let bin = mount + "/cargo/bin"
        try s.negativeControls(origins)
        s.run("rustc-version", [bin + "/rustc", "-V"], cwd: dir) { $0.status == 0 && $0.stdout.hasPrefix("rustc ") }
        s.run("rustup-home-on-volume", [bin + "/rustup", "show", "home"], cwd: dir) { $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == mount + "/rustup" }
        s.run("rustup-active-toolchain", [bin + "/rustup", "show", "active-toolchain"], cwd: dir)
        s.run("sysroot-on-volume", [bin + "/rustc", "--print", "sysroot"], cwd: dir) { $0.stdout.hasPrefix(mount + "/rustup/toolchains/") }
        s.run("cargo-build-run", ["/bin/sh", "-c", "\"\(bin)/cargo\" build -q --offline && ./target/debug/devstoreprobe"], cwd: dir) {
            $0.status == 0 && $0.stdout.contains("devstore-rust-ok 5")
        }
        s.run("cargo-test", [bin + "/cargo", "test", "-q", "--offline"], cwd: dir)
        s.run("cargo-clippy", [bin + "/cargo", "clippy", "-q", "--offline"], cwd: dir)
        s.run("cargo-fmt", [bin + "/cargo", "fmt", "--check"], cwd: dir)
        let targets = (try? Shell.run(bin + "/rustup", ["target", "list", "--installed"], environment: s.env))?.stdout
            .split(separator: "\n").map(String.init) ?? []
        if targets.contains("x86_64-apple-darwin") {
            s.run("cross-build-x86_64-apple-darwin", [bin + "/cargo", "build", "-q", "--offline", "--target", "x86_64-apple-darwin"], cwd: dir)
        }
        for t in targets where t.contains("android") {
            s.run("target-libdir:\(t)", [bin + "/rustc", "--print", "target-libdir", "--target", t], cwd: dir) { r in
                let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return r.status == 0 && p.hasPrefix(mount) && FileManager.default.fileExists(atPath: p)
            }
        }
        // Tools installed with `cargo install` (recorded in .crates.toml).
        let crates = (try? String(contentsOfFile: mount + "/cargo/.crates.toml", encoding: .utf8)) ?? ""
        let bins = crates.split(separator: "\n").flatMap { line -> [String] in
            guard let r = line.range(of: "= [") else { return [] }
            return line[r.upperBound...].split(separator: "\"").map(String.init).filter { !$0.contains(",") && !$0.contains("]") && !$0.isEmpty }
        }
        for tool in bins {
            guard FileManager.default.isExecutableFile(atPath: bin + "/" + tool) else { continue }
            let args = tool.hasPrefix("cargo-") ? [bin + "/cargo", String(tool.dropFirst(6)), "--version"] : [bin + "/" + tool, "--version"]
            s.run("tool:\(tool)", args, cwd: dir)
        }
        s.persistence()
        return try finishRun(s, r, stage: stage, suite: "rust-core", adapter: a.ref, denied: denied, startedAt: startedAt,
                             notCovered: ["network crate downloads", "Android linking (needs NDK)", "external SSD", "cross-Mac"])
    }

    func verifyDotnet(_ r: ResolvedEnvironment, stage: String, progress: @escaping (String, Bool) -> Void) throws -> VerificationRun {
        guard library.identityVerified(r) else { throw DevStoreError("environment must be mounted with a verified identity") }
        let a = DotnetAdapter(), mount = r.slotPath, startedAt = timestamp()
        let origins = a.originPathsToDeny(home: NSHomeDirectory())
        let denied = origins + ["/opt/homebrew"]
        var s = SuiteRunner(mount: mount, denied: denied,
                            env: a.sessionEnvironment(mount: mount).merging(["DOTNET_CLI_TELEMETRY_OPTOUT": "1", "DOTNET_SKIP_FIRST_TIME_EXPERIENCE": "1"]) { _, n in n },
                            progress: progress)
        let dir = try probeDir(mount, "dotnet")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let feed = dir + "/empty-feed"
        try FileManager.default.createDirectory(atPath: feed, withIntermediateDirectories: true)
        let dotnet = mount + "/dotnet/dotnet"
        try s.negativeControls(origins)
        s.run("dotnet-version", [dotnet, "--version"], cwd: dir)
        s.run("sdk-base-path-on-volume", [dotnet, "--info"], cwd: dir) { $0.stdout.contains(mount + "/dotnet/sdk/") }
        s.run("nuget-packages-on-volume", [dotnet, "nuget", "locals", "global-packages", "--list"], cwd: dir) { $0.stdout.contains(mount + "/nuget/packages") }
        s.run("new-console", [dotnet, "new", "console", "-o", "app", "--no-restore"], cwd: dir)
        s.run("restore-offline", [dotnet, "restore", "app", "--source", feed], cwd: dir)
        s.run("build", [dotnet, "build", "app", "--no-restore", "-nologo", "-v", "q"], cwd: dir)
        s.run("run", [dotnet, "run", "--project", "app", "--no-build"], cwd: dir) { $0.status == 0 && $0.stdout.contains("Hello, World!") }
        s.run("new-classlib-build", ["/bin/sh", "-c", "\"\(dotnet)\" new classlib -o lib --no-restore >/dev/null && \"\(dotnet)\" restore lib --source \"\(feed)\" >/dev/null && \"\(dotnet)\" build lib --no-restore -nologo -v q"], cwd: dir)
        s.persistence()
        return try finishRun(s, r, stage: stage, suite: "dotnet-core", adapter: a.ref, denied: denied, startedAt: startedAt,
                             notCovered: ["NuGet downloads", "workloads (none installed)", "dev certificates", "external SSD", "cross-Mac"])
    }

    func verifyFlutter(_ r: ResolvedEnvironment, stage: String, progress: @escaping (String, Bool) -> Void) throws -> VerificationRun {
        guard library.identityVerified(r) else { throw DevStoreError("environment must be mounted with a verified identity") }
        let a = FlutterAdapter(), mount = r.slotPath, startedAt = timestamp()
        let origins = a.originPathsToDeny(home: NSHomeDirectory())
        let denied = origins + ["/opt/homebrew", "/usr/local"]
        var s = SuiteRunner(mount: mount, denied: denied, env: a.sessionEnvironment(mount: mount).merging(["CI": "true"]) { _, n in n }, progress: progress)
        let dir = try probeDir(mount, "flutter")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "int add(int a, int b) => a + b;\n\nvoid main() {\n  print('devstore-dart-ok ${add(2, 3)}');\n}\n"
            .write(toFile: dir + "/hello.dart", atomically: true, encoding: .utf8)
        let fbin = mount + "/flutter/bin"
        try s.negativeControls(origins)
        s.run("flutter-version", [fbin + "/flutter", "--version", "--machine"], cwd: dir) { r in
            guard r.status == 0, let d = (try? JSONSerialization.jsonObject(with: r.stdoutData)) as? [String: Any] else { return false }
            return (d["flutterRoot"] as? String) == mount + "/flutter" && d["frameworkVersion"] != nil
        }
        s.run("dart-version", [fbin + "/dart", "--version"], cwd: dir) { $0.status == 0 && ($0.stdout + $0.stderr).contains("Dart SDK version") }
        s.run("dart-sdk-on-volume", [fbin + "/dart", "--print-sdk-path"], cwd: dir) { _ in true }
        s.run("dart-run", [fbin + "/dart", "run", "hello.dart"], cwd: dir) { $0.status == 0 && $0.stdout.contains("devstore-dart-ok 5") }
        s.run("dart-analyze", [fbin + "/dart", "analyze", "hello.dart"], cwd: dir)
        s.run("dart-format", [fbin + "/dart", "format", "--output=none", "--set-exit-if-changed", "hello.dart"], cwd: dir)
        s.run("dart-compile-exe", ["/bin/sh", "-c", "\"\(fbin)/dart\" compile exe hello.dart -o hello >/dev/null && ./hello"], cwd: dir) {
            $0.status == 0 && $0.stdout.contains("devstore-dart-ok 5")
        }
        s.run("pub-cache-on-volume", [fbin + "/dart", "pub", "cache", "list"], cwd: dir) { _ in
            FileManager.default.fileExists(atPath: mount + "/pub-cache")
        }
        s.persistence()
        return try finishRun(s, r, stage: stage, suite: "flutter-core", adapter: a.ref, denied: denied, startedAt: startedAt,
                             notCovered: ["flutter create/pub get (network)", "iOS/Android/macOS app builds (Xcode, Android SDK)", "external SSD", "cross-Mac"])
    }
}
