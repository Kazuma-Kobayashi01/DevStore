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

/// Miniconda core suite (23 checks), ported from the 2026-10-29 experiment script.
/// Every check runs under sandbox-exec: no network, origin installs unreadable, writes only
/// to the volume and /private/tmp. The negative control must pass or the run is invalid.
public struct Verifier: Sendable {
    public var library: Library

    public init(library: Library = Library()) { self.library = library }

    public func verify(_ r: ResolvedEnvironment, stage: String, progress: (String, Bool) -> Void = { _, _ in }) throws -> VerificationRun {
        guard r.environment.kind == "miniconda", let adapter = Adapters.forKind("miniconda") else {
            throw DevStoreError("no verification suite for kind \(r.environment.kind)")
        }
        guard library.identityVerified(r), var image = r.image else {
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
        guard FileManager.default.fileExists(atPath: control) else {
            throw DevStoreError("negative control target \(control) is missing; cannot prove origin is blocked")
        }
        run("negative-control-original-install-blocked", ["/bin/cat", control]) {
            $0.status != 0 && $0.stderr.contains("Operation not permitted") && !$0.stderr.contains("sandbox_init")
        }
        guard checks[0].passed else { throw DevStoreError("negative control failed; run invalid") }

        let names = ["base", "llama-cpp", "neocloud", "python3.10"]
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
        let neo = base + "/envs/neocloud"
        run("conda-shell-activate", ["/bin/bash", "--noprofile", "--norc", "-e", "-c",
            "eval \"$(\"\(base)/bin/conda\" shell.bash hook)\"\nconda activate \"\(neo)\"\npython -B -c 'import sys; assert sys.prefix == \"\(neo)\"; print(sys.prefix)'\nconda deactivate\n"])
        run("conda-run", [base + "/bin/conda", "run", "-p", base + "/envs/llama-cpp", "--no-capture-output",
                          "python", "-B", "-c", "import sys; print(sys.prefix)"])
        run("neocloud-packages", [neo + "/bin/python", "-I", "-B", "-c",
            "import fastapi,pydantic,requests; print(fastapi.__version__,pydantic.__version__,requests.__version__)"])
        run("llama-cpp-httpx", [base + "/envs/llama-cpp/bin/python", "-I", "-B", "-c", "import httpx; print(httpx.__version__)"])
        run("python3.10-numpy-pytorch", [base + "/envs/python3.10/bin/python", "-I", "-B", "-c",
            "import numpy as np,torch; assert float(np.arange(4).sum())==6; assert torch.tensor([2,3]).sum().item()==5; print(np.__version__,torch.__version__)"])

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
        try JSONIO.writeAtomically(run, to: r.imageDir!.appendingPathComponent("verifications/\(run.runId).json"))
        image.lastVerification = VerificationRef(runId: run.runId, stage: stage, passed: passed, total: checks.count, at: run.finishedAt)
        image.mutatedSinceVerification = false
        try library.saveImage(image, in: r)
        return run
    }
}
