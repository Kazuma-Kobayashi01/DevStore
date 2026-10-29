import Foundation

public struct DataClass: Codable, Sendable {
    public var id: String
    public var paths: [String]        // relative to the mount point
    public var rebuildable: Bool
    public var backup: Bool
}

/// An adapter is declarative: paths, session variables, data classes and known warnings.
/// Only small, versioned pieces of logic live here (prefix detection, component discovery).
public protocol EnvironmentAdapter: Sendable {
    var ref: AdapterRef { get }
    var dataClasses: [DataClass] { get }
    /// Whether existing images can be imported (content must be recognizable).
    var supportsImport: Bool { get }
    var knownWarnings: [String] { get }
    func sessionEnvironment(mount: String) -> [String: String]
    func originPathsToDeny(home: String) -> [String]
    /// The mount path the volume's content was built for, or nil if unrecognized.
    func builtMountPath(volumeRoot: String) -> String?
    func discoverComponents(mount: String) -> [Component]
}

public enum Adapters {
    /// Adapter recorded on an environment (`EnvironmentRecord.adapter.id`).
    public static func named(_ id: String) -> (any EnvironmentAdapter)? {
        switch id {
        case "miniconda": MinicondaAdapter()
        case "empty": EmptyAdapter()
        case "go": GoAdapter()
        default: nil
        }
    }

    /// Adapter used to import existing images of a kind; only kinds with recognizable content.
    public static func forImport(kind: String) -> (any EnvironmentAdapter)? {
        kind == "miniconda" ? MinicondaAdapter() : nil
    }

    public static func validName(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9][a-z0-9.-]{0,63}$", options: .regularExpression) != nil && s != ".devstore"
    }
}

/// A new, empty writable volume with a conventional layout. The user installs tools into it.
public struct EmptyAdapter: EnvironmentAdapter {
    public let ref = AdapterRef(id: "empty", version: "0.1.0")
    public let supportsImport = false
    public let knownWarnings: [String] = []
    public static let layout = ["bin", "deps", "state/home", "state/config", "state/share", "cache", "tmp"]

    public let dataClasses = [
        DataClass(id: "tools", paths: ["bin", "deps"], rebuildable: false, backup: true),
        DataClass(id: "state", paths: ["state"], rebuildable: false, backup: true),
        DataClass(id: "cacheRebuildable", paths: ["cache"], rebuildable: true, backup: false),
        DataClass(id: "tmp", paths: ["tmp"], rebuildable: true, backup: false),
    ]

    public init() {}

    public func sessionEnvironment(mount: String) -> [String: String] {
        ["HOME": mount + "/state/home", "USER": NSUserName(), "LOGNAME": NSUserName(), "LANG": "en_US.UTF-8",
         "PATH": mount + "/bin:/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": mount + "/tmp",
         "XDG_CACHE_HOME": mount + "/cache", "XDG_CONFIG_HOME": mount + "/state/config",
         "XDG_DATA_HOME": mount + "/state/share", "DEVSTORE_ENVIRONMENT": mount]
    }

    public func originPathsToDeny(home: String) -> [String] { [] }
    public func builtMountPath(volumeRoot: String) -> String? { nil }
    public func discoverComponents(mount: String) -> [Component] { [] }

    public func prepareLayout(mount: String) throws {
        for d in Self.layout {
            try FileManager.default.createDirectory(atPath: mount + "/" + d, withIntermediateDirectories: true)
        }
    }
}

public struct MinicondaAdapter: EnvironmentAdapter {
    public let ref = AdapterRef(id: "miniconda", version: "0.1.0")
    public let supportsImport = true

    public let dataClasses = [
        DataClass(id: "sdk", paths: ["miniconda3"], rebuildable: false, backup: true),
        DataClass(id: "envs", paths: ["miniconda3/envs"], rebuildable: false, backup: true),
        DataClass(id: "state", paths: ["state"], rebuildable: false, backup: true),
        DataClass(id: "cacheRebuildable", paths: ["cache/pip", "cache/xdg"], rebuildable: true, backup: false),
        DataClass(id: "cacheCostly", paths: ["miniconda3/pkgs"], rebuildable: true, backup: false),
        DataClass(id: "tmp", paths: ["tmp"], rebuildable: true, backup: false),
    ]

    public let knownWarnings = [
        "Source package cache was missing; conda-pack treated packages as unmanaged, so binary prefixes were not rewritten.",
        "About 703 binaries and 7,784 .pyc files still embed the original install path (2026-10-29 residue scan); tested features do not depend on them.",
        "base python.app was packed from its post-link layout; GUI Python is untested.",
    ]

    public init() {}

    public func sessionEnvironment(mount: String) -> [String: String] {
        let base = mount + "/miniconda3"
        return [
            "HOME": mount + "/state/home",
            "USER": NSUserName(), "LOGNAME": NSUserName(), "LANG": "en_US.UTF-8",
            "PATH": base + "/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "CONDARC": mount + "/state/condarc",
            "CONDA_ENVS_PATH": base + "/envs",
            "CONDA_PKGS_DIRS": base + "/pkgs",
            "CONDA_AUTO_UPDATE_CONDA": "false", "DO_NOT_TRACK": "1",
            "PYTHONNOUSERSITE": "1",
            "PIP_CACHE_DIR": mount + "/cache/pip",
            "XDG_CACHE_HOME": mount + "/cache/xdg",
            "TMPDIR": mount + "/tmp",
            "IPYTHONDIR": mount + "/state/ipython",
            "JUPYTER_CONFIG_DIR": mount + "/state/jupyter",
            "MPLCONFIGDIR": mount + "/state/matplotlib",
            "TORCH_HOME": mount + "/cache/torch",
            "SSL_CERT_FILE": base + "/ssl/cert.pem",
            "REQUESTS_CA_BUNDLE": base + "/ssl/cert.pem",
            "OPENSSL_MODULES": base + "/lib/ossl-modules",
            "OPENSSL_CONF": base + "/ssl/openssl.cnf",
            "DEVSTORE_ENVIRONMENT": mount,
        ]
    }

    public func originPathsToDeny(home: String) -> [String] {
        [home + "/miniconda3", home + "/.conda", home + "/.condarc"]
    }

    /// Reads the shebang of `miniconda3/bin/conda`: `#!<mount>/miniconda3/bin/python`.
    public func builtMountPath(volumeRoot: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: volumeRoot + "/miniconda3/bin/conda") else { return nil }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
        guard let line = head.split(separator: "\n").first, line.hasPrefix("#!") else { return nil }
        let interp = line.dropFirst(2).split(separator: " ").first.map(String.init) ?? ""
        let suffix = "/miniconda3/bin/python"
        guard interp.hasSuffix(suffix) else { return nil }
        return String(interp.dropLast(suffix.count))
    }

    public func discoverComponents(mount: String) -> [Component] {
        let base = mount + "/miniconda3"
        var prefixes = [("base", base)]
        let envs = (try? FileManager.default.contentsOfDirectory(atPath: base + "/envs")) ?? []
        for e in envs.sorted() where !e.hasPrefix("__") && !e.hasPrefix(".") {
            prefixes.append((e, base + "/envs/" + e))
        }
        let env = sessionEnvironment(mount: mount)
        return prefixes.map { name, prefix in
            let r = try? Shell.run(prefix + "/bin/python", ["-I", "-B", "-c", "import sys;print(sys.version.split()[0])"],
                                   environment: env)
            let metas = (try? FileManager.default.contentsOfDirectory(atPath: prefix + "/conda-meta")) ?? []
            return Component(name: name,
                             python: r?.status == 0 ? r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                             condaPackages: metas.filter { $0.hasSuffix(".json") }.count)
        }
    }
}

/// Go SDK (official archive) with GOPATH, module cache, build cache and GOENV on the volume.
/// The Go toolchain is relocatable, so no prefix rewriting is involved.
public struct GoAdapter: EnvironmentAdapter {
    public let ref = AdapterRef(id: "go", version: "0.1.0")
    public let supportsImport = false
    public let knownWarnings: [String] = []
    public static let layout = ["gopath/bin", "gopath/pkg/mod", "cache/go-build", "state/home", "state/go", "tmp"]

    public let dataClasses = [
        DataClass(id: "sdk", paths: ["go"], rebuildable: false, backup: true),
        DataClass(id: "tools", paths: ["gopath/bin"], rebuildable: false, backup: true),
        DataClass(id: "cacheCostly", paths: ["gopath/pkg/mod"], rebuildable: true, backup: false),
        DataClass(id: "cacheRebuildable", paths: ["cache/go-build"], rebuildable: true, backup: false),
        DataClass(id: "state", paths: ["state"], rebuildable: false, backup: true),
        DataClass(id: "tmp", paths: ["tmp"], rebuildable: true, backup: false),
    ]

    public init() {}

    public func sessionEnvironment(mount: String) -> [String: String] {
        ["HOME": mount + "/state/home", "USER": NSUserName(), "LOGNAME": NSUserName(), "LANG": "en_US.UTF-8",
         "PATH": mount + "/go/bin:" + mount + "/gopath/bin:/usr/bin:/bin:/usr/sbin:/sbin",
         "GOPATH": mount + "/gopath", "GOMODCACHE": mount + "/gopath/pkg/mod", "GOCACHE": mount + "/cache/go-build",
         "GOENV": mount + "/state/go/env", "TMPDIR": mount + "/tmp", "DEVSTORE_ENVIRONMENT": mount]
    }

    public func originPathsToDeny(home: String) -> [String] {
        [home + "/.local/go", home + "/Library/Caches/go-build", home + "/Library/Application Support/go"]
    }

    public func builtMountPath(volumeRoot: String) -> String? { nil }

    public func discoverComponents(mount: String) -> [Component] {
        let env = sessionEnvironment(mount: mount)
        let v = (try? Shell.run(mount + "/go/bin/go", ["env", "GOVERSION"], environment: env))?.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = [Component(name: "go", python: nil, condaPackages: nil, version: v.map { String($0.dropFirst(2)) })]
        let tools = (try? FileManager.default.contentsOfDirectory(atPath: mount + "/gopath/bin")) ?? []
        for t in tools.sorted() where !t.hasPrefix(".") {
            result.append(Component(name: t, python: nil, condaPackages: nil, version: "tool"))
        }
        return result
    }
}
