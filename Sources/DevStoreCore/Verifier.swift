import Foundation

public struct CheckResult: Codable, Sendable {
    public var name: String
    public var passed: Bool
    public var exitCode: Int32?
    public var seconds: Double?
    public var stdout: String?
    public var stderr: String?
}

public struct VerificationRun: Codable, Sendable {
    public var schemaVersion = 1
    public var runId: String
    public var target: [String: String]
    public var stage: String
    public var suite: AdapterRef
    public var adapterVersion: String
    public var host: HostBinding
    public var confinement: [String: [String]]
    public var negativeControlPassed: Bool
    public var checks: [CheckResult]
    public var passed: Int
    public var total: Int
    public var startedAt: String
    public var finishedAt: String
    public var notCovered: [String]
}

/// Miniconda core suite, ported from the 2026-10-29 experiment script (23 checks on that image;
/// the count follows the environments present).
/// Every check runs under sandbox-exec: no network, origin installs unreadable, writes only
/// to the volume and /private/tmp. The negative control must pass or the run is invalid.
public struct Verifier: Sendable {
    public var library: Library

    public init(library: Library = Library()) { self.library = library }

    public func verify(_ r: ResolvedEnvironment, stage: String, progress: (String, Bool) -> Void = { _, _ in }) throws -> VerificationRun {
        switch r.environment.adapter.id {
        case "miniconda": return try verifyMiniconda(r, stage: stage, progress: progress)
        case "empty": return try verifyEmpty(r, stage: stage, progress: progress)
        case "go": return try verifyGo(r, stage: stage, progress: progress)
        case "rust": return try withoutActuallyEscaping(progress) { try verifyRust(r, stage: stage, progress: $0) }
        case "dotnet": return try withoutActuallyEscaping(progress) { try verifyDotnet(r, stage: stage, progress: $0) }
        case "flutter": return try withoutActuallyEscaping(progress) { try verifyFlutter(r, stage: stage, progress: $0) }
        case "android": return try withoutActuallyEscaping(progress) { try verifyAndroid(r, stage: stage, progress: $0) }
        default: throw DevStoreError("no verification suite for adapter \(r.environment.adapter.id)")
        }
    }

    func record(_ run: VerificationRun, _ r: ResolvedEnvironment) throws {
        guard var image = r.image else { return }
        try JSONIO.writeAtomically(run, to: r.imageDir!.appendingPathComponent("verifications/\(run.runId).json"))
        image.lastVerification = VerificationRef(runId: run.runId, stage: run.stage, passed: run.passed, total: run.total, at: run.finishedAt)
        image.mutatedSinceVerification = false
        try library.saveImage(image, in: r)
    }

    /// Basic suite for an empty environment: layout, writability, session variables.
    func verifyEmpty(_ r: ResolvedEnvironment, stage: String, progress: (String, Bool) -> Void) throws -> VerificationRun {
        guard library.identityVerified(r), let image = r.image else {
            throw DevStoreError("environment must be mounted with a verified identity")
        }
        let mount = r.slotPath, startedAt = timestamp()
        let env = EmptyAdapter().sessionEnvironment(mount: mount)
        var checks: [CheckResult] = []
        func add(_ name: String, _ ok: Bool, _ detail: String? = nil) {
            checks.append(CheckResult(name: name, passed: ok, stderr: detail))
            progress(name, ok)
        }
        add("identity-verified", true)
        let missing = EmptyAdapter.layout.filter { !FileManager.default.fileExists(atPath: mount + "/" + $0) }
        add("layout-present", missing.isEmpty, missing.isEmpty ? nil : "missing: \(missing)")
        let probe = mount + "/tmp/.devstore-probe-\(newId())"
        let wrote = (try? "probe\n".write(toFile: probe, atomically: true, encoding: .utf8)) != nil
        add("volume-writable", wrote && (try? String(contentsOfFile: probe, encoding: .utf8)) == "probe\n")
        try? FileManager.default.removeItem(atPath: probe)
        let shell = try? Shell.run("/bin/sh", ["-c", "printf '%s|%s' \"$HOME\" \"$TMPDIR\""], environment: env)
        add("session-variables", shell?.stdout == mount + "/state/home|" + mount + "/tmp", shell?.stdout)
        let passed = checks.filter(\.passed).count
        let run = VerificationRun(
            runId: newId(), target: ["environmentId": r.environment.environmentId, "imageId": image.imageId],
            stage: stage, suite: AdapterRef(id: "empty-basic", version: "1"), adapterVersion: EmptyAdapter().ref.version,
            host: .current(), confinement: [:], negativeControlPassed: true, checks: checks,
            passed: passed, total: checks.count, startedAt: startedAt, finishedAt: timestamp(),
            notCovered: ["tool installation", "external SSD", "cross-Mac"])
        try record(run, r)
        return run
    }

    /// Go suite: toolchain and every Go directory on the volume, offline build/test/vet/fmt/install,
    /// cgo with the host compiler, build info of migrated tools, persistence. Origin installs unreadable.
    func verifyGo(_ r: ResolvedEnvironment, stage: String, progress: (String, Bool) -> Void) throws -> VerificationRun {
        guard library.identityVerified(r), let image = r.image else {
            throw DevStoreError("environment must be mounted with a verified identity")
        }
        let adapter = GoAdapter(), fm = FileManager.default
        let mount = r.slotPath, home = NSHomeDirectory(), startedAt = timestamp()
        let denied = adapter.originPathsToDeny(home: home) + ["/opt/homebrew", "/usr/local"]
        let profile = "(version 1)\n(allow default)\n(deny network*)\n(deny file-read*\n"
            + denied.map { "  (subpath \"\($0)\")" }.joined(separator: "\n")
            + ")\n(deny file-write*)\n(allow file-write*\n  (subpath \"\(mount)\")\n  (subpath \"/private/tmp\")\n"
            + "  (subpath \"/private/var/folders\")\n  (literal \"/dev/null\"))\n"
        var env = adapter.sessionEnvironment(mount: mount)
        env.merge(["GOPROXY": "off", "GOTOOLCHAIN": "local", "GOFLAGS": "-mod=mod", "GONOSUMDB": "*", "GOSUMDB": "off"]) { _, n in n }
        let probe = mount + "/tmp/devstore-go-probe"
        try? fm.removeItem(atPath: probe)
        try fm.createDirectory(atPath: probe, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: probe) }
        try "module devstoreprobe\n\ngo 1.21\n".write(toFile: probe + "/go.mod", atomically: true, encoding: .utf8)
        try "package main\n\nimport \"fmt\"\n\nfunc add(a, b int) int { return a + b }\n\nfunc main() { fmt.Println(\"devstore-go-ok\", add(2, 3)) }\n"
            .write(toFile: probe + "/main.go", atomically: true, encoding: .utf8)
        try "package main\n\nimport \"testing\"\n\nfunc TestAdd(t *testing.T) {\n\tif add(2, 3) != 5 {\n\t\tt.Fatal(\"add\")\n\t}\n}\n"
            .write(toFile: probe + "/main_test.go", atomically: true, encoding: .utf8)
        let cgo = probe + "/cgo"
        try fm.createDirectory(atPath: cgo, withIntermediateDirectories: true)
        try "package main\n\n// int twice(int x) { return 2 * x; }\nimport \"C\"\nimport \"fmt\"\n\nfunc main() { fmt.Println(\"cgo\", C.twice(21)) }\n"
            .write(toFile: cgo + "/main.go", atomically: true, encoding: .utf8)

        var checks: [CheckResult] = []
        func run(_ name: String, _ cmd: [String], cwd: String? = nil, extra: [String: String] = [:],
                 accept: ((ShellResult) -> Bool)? = nil) {
            let t0 = Date()
            var e = env
            e.merge(extra) { _, n in n }
            do {
                let res = try Shell.run("/usr/bin/sandbox-exec", ["-p", profile] + cmd, environment: e, currentDirectory: cwd ?? probe)
                let ok = accept.map { $0(res) } ?? (res.status == 0)
                checks.append(CheckResult(name: name, passed: ok, exitCode: res.status,
                                          seconds: (Date().timeIntervalSince(t0) * 1000).rounded() / 1000,
                                          stdout: String(res.stdout.suffix(4000)), stderr: String(res.stderr.suffix(4000))))
            } catch {
                checks.append(CheckResult(name: name, passed: false, stderr: String(describing: error)))
            }
            progress(name, checks.last!.passed)
        }
        let blocked: (ShellResult) -> Bool = { $0.status != 0 && $0.stderr.contains("Operation not permitted") }

        let origin = home + "/.local/go"
        if fm.fileExists(atPath: origin) {
            run("negative-control-original-gopath-blocked", ["/bin/ls", origin], accept: blocked)
            guard checks.last!.passed else { throw DevStoreError("negative control failed; run invalid") }
        } else {
            checks.append(CheckResult(name: "negative-control-original-gopath-absent", passed: true, stderr: "\(origin) does not exist"))
            progress("negative-control-original-gopath-absent", true)
        }
        if fm.fileExists(atPath: "/opt/homebrew/bin/go") {
            run("negative-control-homebrew-go-blocked", ["/opt/homebrew/bin/go", "version"], accept: blocked)
        }
        let go = mount + "/go/bin/go"
        let want = image.sdk.map { "go" + $0.version } ?? "go"
        run("go-version", [go, "version"]) { $0.status == 0 && $0.stdout.contains(want + " ") }
        run("go-env-isolated", [go, "env", "-json", "GOROOT", "GOPATH", "GOMODCACHE", "GOCACHE", "GOENV"]) { r in
            guard r.status == 0, let d = (try? JSONSerialization.jsonObject(with: r.stdoutData)) as? [String: String] else { return false }
            return d.count == 5 && d.values.allSatisfy { $0.hasPrefix(mount + "/") }
        }
        run("go-build-run", ["/bin/sh", "-c", "\"\(go)\" build -o probe . && ./probe"]) { $0.status == 0 && $0.stdout.contains("devstore-go-ok 5") }
        run("go-test", [go, "test", "./..."])
        run("go-vet", [go, "vet", "."])
        run("gofmt", [mount + "/go/bin/gofmt", "-l", "."]) { $0.status == 0 && $0.stdout.isEmpty }
        run("go-install-to-gopath-bin", [go, "install", "."]) { _ in fm.isExecutableFile(atPath: mount + "/gopath/bin/devstoreprobe") }
        try? fm.removeItem(atPath: mount + "/gopath/bin/devstoreprobe")
        run("cgo-host-toolchain", ["/bin/sh", "-c", "\"\(go)\" run ."], cwd: cgo, extra: ["CGO_ENABLED": "1"]) { $0.status == 0 && $0.stdout.contains("cgo 42") }
        for tool in ((try? fm.contentsOfDirectory(atPath: mount + "/gopath/bin")) ?? []).sorted() where !tool.hasPrefix(".") {
            run("tool-\(tool)-buildinfo", [go, "version", "-m", mount + "/gopath/bin/" + tool]) { $0.status == 0 && $0.stdout.contains("path") }
        }
        let modules = ((try? fm.contentsOfDirectory(atPath: mount + "/gopath/pkg/mod/cache/download")) ?? []).count
        checks.append(CheckResult(name: "module-cache-on-volume", passed: fm.fileExists(atPath: mount + "/gopath/pkg/mod"),
                                  stdout: "\(modules) top-level module hosts cached"))
        progress("module-cache-on-volume", checks.last!.passed)
        let persisted = (try? String(contentsOfFile: mount + "/state/persistence-marker.txt", encoding: .utf8)) == "single-volume-persistence-20261029\n"
            && (try? String(contentsOfFile: mount + "/cache/go-build/devstore-marker", encoding: .utf8)) == "go-build-cache-on-same-volume\n"
        checks.append(CheckResult(name: "state-and-cache-persisted", passed: persisted))
        progress("state-and-cache-persisted", persisted)

        let passed = checks.filter(\.passed).count
        let run = VerificationRun(
            runId: newId(), target: ["environmentId": r.environment.environmentId, "imageId": image.imageId],
            stage: stage, suite: AdapterRef(id: "go-core", version: "1"), adapterVersion: adapter.ref.version,
            host: .current(), confinement: ["deniedReadTrees": denied, "network": ["denied"], "writeAllowed": [mount, "/private/tmp"]],
            negativeControlPassed: true, checks: checks, passed: passed, total: checks.count,
            startedAt: startedAt, finishedAt: timestamp(),
            notCovered: ["network module download", "gomobile/gobind end-to-end (needs Android/iOS SDKs)", "external SSD", "cross-Mac"])
        try record(run, r)
        return run
    }

    func verifyMiniconda(_ r: ResolvedEnvironment, stage: String, progress: (String, Bool) -> Void) throws -> VerificationRun {
        let adapter = MinicondaAdapter()
        guard library.identityVerified(r), let image = r.image else {
            throw DevStoreError("environment must be mounted with a verified identity")
        }
        let mount = r.slotPath, base = mount + "/miniconda3", home = NSHomeDirectory()
        let tmp = mount + "/tmp"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let denied = adapter.originPathsToDeny(home: home) + ["/opt/homebrew", "/usr/local"]
        let profile = "(version 1)\n(allow default)\n(deny network*)\n(deny file-read*\n"
            + denied.map { "  (subpath \"\($0)\")" }.joined(separator: "\n")
            + ")\n(deny file-write*)\n(allow file-write*\n  (subpath \"\(mount)\")\n  (subpath \"/private/tmp\")\n  (literal \"/dev/null\"))\n"
        var env = adapter.sessionEnvironment(mount: mount)
        env.merge(["CONDA_OFFLINE": "true", "CONDA_SOLVER": "classic", "CONDA_NO_PLUGINS": "true",
                   "CONDA_REPORT_ERRORS": "false", "PYTHONDONTWRITEBYTECODE": "1",
                   "PIP_DISABLE_PIP_VERSION_CHECK": "1"]) { _, new in new }
        let startedAt = timestamp()
        var checks: [CheckResult] = []

        func run(_ name: String, _ cmd: [String], extra: [String: String] = [:],
                 accept: ((ShellResult) -> Bool)? = nil) {
            let t0 = Date()
            var e = env
            e.merge(extra) { _, new in new }
            do {
                let res = try Shell.run("/usr/bin/sandbox-exec", ["-p", profile] + cmd, environment: e, currentDirectory: tmp)
                let ok = accept.map { $0(res) } ?? (res.status == 0)
                checks.append(CheckResult(name: name, passed: ok, exitCode: res.status,
                                          seconds: (Date().timeIntervalSince(t0) * 1000).rounded() / 1000,
                                          stdout: String(res.stdout.suffix(4000)), stderr: String(res.stderr.suffix(4000))))
            } catch {
                checks.append(CheckResult(name: name, passed: false, stderr: String(describing: error)))
            }
            progress(name, checks.last!.passed)
        }

        func json(_ r: ShellResult) -> [String: Any]? {
            guard r.status == 0 else { return nil }
            return (try? JSONSerialization.jsonObject(with: r.stdoutData)) as? [String: Any]
        }

        let control = home + "/miniconda3/conda-meta/history"
        if FileManager.default.fileExists(atPath: control) {
            run("negative-control-original-install-blocked", ["/bin/cat", control]) {
                $0.status != 0 && $0.stderr.contains("Operation not permitted") && !$0.stderr.contains("sandbox_init")
            }
            guard checks[0].passed else { throw DevStoreError("negative control failed; run invalid") }
        } else if FileManager.default.fileExists(atPath: home + "/miniconda3") {
            throw DevStoreError("\(home)/miniconda3 exists but has no conda-meta/history; cannot prove origin is blocked")
        } else {
            // The original install was removed, so nothing can be borrowed from it.
            checks.append(CheckResult(name: "negative-control-original-install-absent", passed: true,
                                      stderr: "\(home)/miniconda3 does not exist; reads stay denied by the sandbox profile"))
            progress("negative-control-original-install-absent", true)
        }

        // Check every environment that exists on the volume (probe environments excluded).
        let envNames = ((try? FileManager.default.contentsOfDirectory(atPath: base + "/envs")) ?? [])
            .filter { !$0.hasPrefix("__") && !$0.hasPrefix(".") && FileManager.default.fileExists(atPath: base + "/envs/\($0)/conda-meta") }
            .sorted()
        let names = ["base"] + envNames
        func hasEnv(_ n: String) -> Bool { envNames.contains(n) }
        let deniedJSON = String(decoding: try JSONSerialization.data(withJSONObject: denied), as: UTF8.self)
        let stdlib = """
        import sys,sysconfig,os,json,ssl,sqlite3,lzma,ctypes
        p=sys.argv[1]; denied=json.loads(sys.argv[2])
        assert sys.prefix==p,(sys.prefix,p)
        assert not any(d in x for d in denied for x in sys.path),sys.path
        assert os.path.realpath(sys.executable).startswith(p+'/')
        assert sysconfig.get_config_var('prefix')==p
        ssl.create_default_context()
        assert sqlite3.connect(':memory:').execute('select 2+3').fetchone()[0]==5
        assert lzma.decompress(lzma.compress(b'volume-probe'))==b'volume-probe'
        ctypes.CDLL(None)
        print(json.dumps({'python':sys.version.split()[0],'prefix':sys.prefix}))
        """
        for n in names {
            let prefix = n == "base" ? base : base + "/envs/" + n
            run("\(n)-python-stdlib-prefix", [prefix + "/bin/python", "-I", "-B", "-c", stdlib, prefix, deniedJSON])
            run("\(n)-pip", [prefix + "/bin/python", "-I", "-B", "-m", "pip", "--version"])
        }
        run("conda-console-script", [base + "/bin/conda", "--version"])
        let infoOK: (ShellResult) -> Bool = { r in
            guard let d = json(r) else { return false }
            return d["root_prefix"] as? String == base && d["pkgs_dirs"] as? [String] == [base + "/pkgs"]
                && (d["user_rc_path"] as? String ?? "").hasPrefix(mount)
        }
        run("conda-info-isolated", [base + "/bin/conda", "info", "--json"], accept: infoOK)
        run("conda-info-native-plugins", [base + "/bin/conda", "info", "--json"], extra: ["CONDA_NO_PLUGINS": "false"], accept: infoOK)
        run("conda-env-discovery", [base + "/bin/conda", "env", "list", "--json"]) { r in
            guard let found = json(r)?["envs"] as? [String] else { return false }
            return names.dropFirst().allSatisfy { found.contains(base + "/envs/" + $0) } && found.allSatisfy { $0.hasPrefix(mount) }
        }
        // Activate / run in the first user environment, or base when there is none yet.
        let target = envNames.first.map { base + "/envs/" + $0 } ?? base
        run("conda-shell-activate", ["/bin/bash", "--noprofile", "--norc", "-e", "-c",
            "eval \"$(\"\(base)/bin/conda\" shell.bash hook)\"\nconda activate \"\(target)\"\npython -B -c 'import sys; assert sys.prefix == \"\(target)\"; print(sys.prefix)'\nconda deactivate\n"])
        run("conda-run", [base + "/bin/conda", "run", "-p", target, "--no-capture-output",
                          "python", "-B", "-c", "import sys; print(sys.prefix)"])
        // Package checks for the environments of the 2026-10-29 experiment image, only when present.
        if hasEnv("neocloud") {
            run("neocloud-packages", [base + "/envs/neocloud/bin/python", "-I", "-B", "-c",
                "import fastapi,pydantic,requests; print(fastapi.__version__,pydantic.__version__,requests.__version__)"])
        }
        if hasEnv("llama-cpp") {
            run("llama-cpp-httpx", [base + "/envs/llama-cpp/bin/python", "-I", "-B", "-c", "import httpx; print(httpx.__version__)"])
        }
        if hasEnv("python3.10") {
            run("python3.10-numpy-pytorch", [base + "/envs/python3.10/bin/python", "-I", "-B", "-c",
                "import numpy as np,torch; assert float(np.arange(4).sum())==6; assert torch.tensor([2,3]).sum().item()==5; print(np.__version__,torch.__version__)"])
        }

        // Data-only local package: proves offline install, cache and removal stay on this volume.
        let package = tmp + "/dev-volume-probe-0.0.1-0.tar.bz2"
        let makePackage = """
        import io,json,sys,tarfile
        data={'info/index.json':json.dumps({'name':'dev-volume-probe','version':'0.0.1','build':'0','build_number':0,'subdir':'noarch','noarch':'generic','depends':[]}).encode(),
              'info/files':b'share/dev-volume-probe.txt\\n','share/dev-volume-probe.txt':b'single-volume-offline-probe\\n'}
        with tarfile.open(sys.argv[1],'w:bz2') as t:
            for p,c in data.items():
                i=tarfile.TarInfo(p); i.size=len(c); i.mode=0o644; t.addfile(i,io.BytesIO(c))
        """
        _ = try Shell.run("/usr/bin/sandbox-exec", ["-p", profile, base + "/bin/python", "-I", "-B", "-c", makePackage, package],
                          environment: env, currentDirectory: tmp)
        let probe = base + "/envs/__single_volume_probe__"
        guard !FileManager.default.fileExists(atPath: probe) else { throw DevStoreError("\(probe) exists; refusing to overwrite") }
        run("offline-create-environment", [base + "/bin/conda", "create", "-p", probe, "--offline", "--no-default-packages", "-y", "--json"])
        run("offline-install-local-package", [base + "/bin/conda", "install", "-p", probe, "--offline", "-y", "--json", package])
        run("offline-package-content", [base + "/bin/python", "-I", "-B", "-c",
            "from pathlib import Path; import sys; assert Path(sys.argv[1]).read_text()=='single-volume-offline-probe\\n'",
            probe + "/share/dev-volume-probe.txt"])
        run("offline-remove-test-environment", [base + "/bin/conda", "env", "remove", "-p", probe, "-y", "--json"])

        let marker = URL(fileURLWithPath: mount + "/state/persistence-marker.txt")
        let cacheMarker = URL(fileURLWithPath: mount + "/cache/pip/volume-marker")
        let persisted = (try? String(contentsOf: marker, encoding: .utf8)) == "single-volume-persistence-20261029\n"
            && (try? String(contentsOf: cacheMarker, encoding: .utf8)) == "cache-on-same-volume\n"
        checks.append(CheckResult(name: "state-and-cache-persisted", passed: persisted))
        progress("state-and-cache-persisted", persisted)

        let passed = checks.filter(\.passed).count
        let run = VerificationRun(
            runId: newId(), target: ["environmentId": r.environment.environmentId, "imageId": image.imageId],
            stage: stage, suite: AdapterRef(id: "miniconda-core", version: "1"), adapterVersion: adapter.ref.version,
            host: .current(), confinement: ["deniedReadTrees": denied, "network": ["denied"], "writeAllowed": [mount, "/private/tmp"]],
            negativeControlPassed: true, checks: checks, passed: passed, total: checks.count,
            startedAt: startedAt, finishedAt: timestamp(),
            notCovered: ["GPU/MPS", "GUI Python", "online update", "external SSD", "cross-Mac", "all third-party packages"])
        try record(run, r)
        return run
    }
}
