import Foundation

/// Runs commands with the adapter's session variables injected into the child process only.
/// This is environment selection, not isolation: the child can still reach the host.
public struct Session: Sendable {
    public var library: Library

    public init(library: Library = Library()) { self.library = library }

    public func environment(for r: ResolvedEnvironment) throws -> [String: String] {
        guard let adapter = Adapters.forKind(r.environment.kind) else {
            throw DevStoreError("no adapter for kind \(r.environment.kind)")
        }
        guard library.identityVerified(r) else {
            throw DevStoreError("\(r.environment.kind)/\(r.environment.slot) is not mounted with a verified identity; run `devstore mount` first")
        }
        var env = adapter.sessionEnvironment(mount: r.slotPath)
        if let term = ProcessInfo.processInfo.environment["TERM"] { env["TERM"] = term }
        return env
    }

    /// Sandbox profile denying reads of the adapter's origin paths (and optionally network).
    public func confinementProfile(for r: ResolvedEnvironment, denyNetwork: Bool) -> String {
        let adapter = Adapters.forKind(r.environment.kind)!
        let deny = adapter.originPathsToDeny(home: NSHomeDirectory()) + ["/opt/homebrew", "/usr/local"]
        let rules = deny.map { "  (subpath \"\($0)\")" }.joined(separator: "\n")
        return "(version 1)\n(allow default)\n" + (denyNetwork ? "(deny network*)\n" : "")
            + "(deny file-read*\n\(rules))\n"
    }

    /// Like `run`, but captures output (for MCP callers).
    public func capture(_ r: ResolvedEnvironment, command: [String], confine: Bool, denyNetwork: Bool,
                        workingDirectory: String? = nil) throws -> ShellResult {
        guard !command.isEmpty else { throw DevStoreError("no command given") }
        let env = try environment(for: r)
        if confine {
            return try Shell.run("/usr/bin/sandbox-exec",
                                 ["-p", confinementProfile(for: r, denyNetwork: denyNetwork), "/usr/bin/env"] + command,
                                 environment: env, currentDirectory: workingDirectory)
        }
        return try Shell.run("/usr/bin/env", command, environment: env, currentDirectory: workingDirectory)
    }

    public func run(_ r: ResolvedEnvironment, command: [String], confine: Bool, denyNetwork: Bool) throws -> Int32 {
        guard !command.isEmpty else { throw DevStoreError("no command given") }
        let env = try environment(for: r)
        // /usr/bin/env resolves the program against the session PATH.
        if confine {
            return try Shell.runInheriting("/usr/bin/sandbox-exec",
                                           ["-p", confinementProfile(for: r, denyNetwork: denyNetwork), "/usr/bin/env"] + command,
                                           environment: env)
        }
        return try Shell.runInheriting("/usr/bin/env", command, environment: env)
    }
}
