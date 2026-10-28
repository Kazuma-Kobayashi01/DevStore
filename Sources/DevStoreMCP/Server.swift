import DevStoreCore
import Foundation

/// Minimal MCP server (JSON-RPC 2.0 over newline-delimited stdio).
///
/// Agents may inspect, plan, run sessions and verify. Executing a plan requires authority the
/// agent cannot create: a user grant from `devstore approve` in a terminal, or a mount policy.
/// No tool accepts a self-reported confirmation.
public struct MCPServer {
    public static let protocolVersion = "2025-06-18"
    public static let outputLimit = 64_000

    var library: Library
    var ops: Operations
    var auth: Authorizer

    public init(library: Library = Library()) {
        self.library = library
        ops = Operations(library: library)
        auth = Authorizer(paths: library.paths)
    }

    // MARK: transport

    public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = handle(line: line) {
                output.write(Data((reply + "\n").utf8))
            }
        }
    }

    /// Returns the serialized response, or nil for notifications.
    public func handle(line: String) -> String? {
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        guard let id else { return nil }   // notification (e.g. notifications/initialized)
        let result: [String: Any]
        switch method {
        case "initialize":
            result = ["protocolVersion": Self.protocolVersion,
                      "capabilities": ["tools": ["listChanged": false]],
                      "serverInfo": ["name": "devstore", "version": "0.1.0"],
                      "instructions": Self.instructions]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": Self.tools]
        case "tools/call":
            result = callTool(name: params["name"] as? String ?? "", arguments: params["arguments"] as? [String: Any] ?? [:])
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func encode(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: tools

    static let instructions = """
    DevStore manages development environments stored in APFS volumes mounted at ~/.local/dev/<kind>/<slot>. \
    Read with devstore_status / devstore_inspect. Changes (import, mount, unmount) are two-step: create a plan \
    with a devstore_plan_* tool, then ask the user to approve it in their terminal with `devstore approve <planId>`; \
    after that, devstore_apply executes it. Mount/unmount can also run without per-plan approval when the user set a \
    policy with `devstore policy allow <env>`. You cannot approve plans yourself. devstore_run selects the environment \
    for a command; it is not a security sandbox (confine only blocks reading the original install).
    """

    static func schema(_ props: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }

    static var envProp: [String: Any] { ["type": "string", "description": "Environment id (or prefix), kind/slot, or display name"] }

    static var tools: [[String: Any]] { [
        ["name": "devstore_status", "description": "List environments on this host with mount, lease and verification state.",
         "inputSchema": schema([:], required: []), "annotations": ["readOnlyHint": true]],
        ["name": "devstore_inspect", "description": "Full records (environment, active image, status) for one environment.",
         "inputSchema": schema(["environment": envProp], required: ["environment"]), "annotations": ["readOnlyHint": true]],
        ["name": "devstore_plan_mount", "description": "Create a mount plan. Does not mount; returns the plan and how it gets approved.",
         "inputSchema": schema(["environment": envProp], required: ["environment"])],
        ["name": "devstore_plan_unmount", "description": "Create an unmount plan (never forced). Does not unmount.",
         "inputSchema": schema(["environment": envProp], required: ["environment"])],
        ["name": "devstore_plan_import",
         "description": "Create a plan to import an unmounted .sparsebundle as a new environment (APFS clone). Does not import.",
         "inputSchema": schema(["source": ["type": "string"], "store": ["type": "string", "description": "Store id prefix or path"],
                                "kind": ["type": "string", "default": "miniconda"], "slot": ["type": "string", "default": "current"],
                                "name": ["type": "string"]], required: ["source", "store", "name"])],
        ["name": "devstore_apply",
         "description": "Execute a saved plan. Succeeds only if the user approved it in a terminal or a mount policy covers it.",
         "inputSchema": schema(["planId": ["type": "string"]], required: ["planId"])],
        ["name": "devstore_run",
         "description": "Run a command with a mounted environment's session variables; captures output. Not isolation.",
         "inputSchema": schema(["environment": envProp,
                                "command": ["type": "array", "items": ["type": "string"], "minItems": 1],
                                "confine": ["type": "boolean", "default": true,
                                            "description": "Deny reading the original install, Homebrew and /usr/local"],
                                "denyNetwork": ["type": "boolean", "default": false],
                                "workingDirectory": ["type": "string"]], required: ["environment", "command"])],
        ["name": "devstore_env", "description": "Session variables for a mounted environment.",
         "inputSchema": schema(["environment": envProp], required: ["environment"]), "annotations": ["readOnlyHint": true]],
        ["name": "devstore_verify",
         "description": "Run the adapter verification suite (sandboxed, offline; creates and removes a probe env) and record it.",
         "inputSchema": schema(["environment": envProp, "stage": ["type": "string", "default": "mcp"]], required: ["environment"])],
        ["name": "devstore_journal", "description": "Recent transaction journal entries.",
         "inputSchema": schema(["limit": ["type": "integer", "default": 20]], required: []), "annotations": ["readOnlyHint": true]],
    ] }

    func callTool(name: String, arguments a: [String: Any]) -> [String: Any] {
        do {
            let value: Any = try dispatch(name, a)
            return textResult(value, isError: false)
        } catch {
            return textResult(["error": String(describing: error)], isError: true)
        }
    }

    func textResult(_ value: Any, isError: Bool) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data("\(value)".utf8)
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": isError]
    }

    func jsonObject<T: Encodable>(_ v: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONIO.encoder(pretty: false).encode(v))
    }

    func string(_ a: [String: Any], _ key: String) throws -> String {
        guard let s = a[key] as? String, !s.isEmpty else { throw DevStoreError("missing argument \(key)") }
        return s
    }

    func planResponse(_ plan: Plan) throws -> Any {
        let envId = plan.targets["environmentId"] ?? ""
        let covered = try auth.policyAllows(environmentId: envId, action: plan.action)
        return ["plan": try jsonObject(plan),
                "approval": covered
                    ? "A standing policy covers this action; call devstore_apply with this planId."
                    : "Ask the user to run `devstore approve \(plan.planId)` in a terminal, then call devstore_apply."]
    }

    func dispatch(_ name: String, _ a: [String: Any]) throws -> Any {
        switch name {
        case "devstore_status":
            return try jsonObject(try library.environments().map(library.status))
        case "devstore_inspect":
            let r = try library.resolve(try string(a, "environment"))
            return ["status": try jsonObject(library.status(r)), "environment": try jsonObject(r.environment),
                    "image": try r.image.map(jsonObject) ?? NSNull()]
        case "devstore_plan_mount":
            return try planResponse(try ops.planMount(try string(a, "environment")))
        case "devstore_plan_unmount":
            return try planResponse(try ops.planUnmount(try string(a, "environment")))
        case "devstore_plan_import":
            return try planResponse(try ops.planImport(source: try string(a, "source"), storeQuery: try string(a, "store"),
                                                       kind: a["kind"] as? String ?? "miniconda",
                                                       slot: a["slot"] as? String ?? "current", name: try string(a, "name")))
        case "devstore_apply":
            let plan = try ops.loadPlan(try string(a, "planId"))
            if let g = try auth.usableGrant(for: plan) {
                try auth.consume(plan, grantId: g.id)
            } else if let envId = plan.targets["environmentId"], try auth.policyAllows(environmentId: envId, action: plan.action) {
                try auth.consume(plan, grantId: "policy")
            } else {
                throw DevStoreError("not authorized: the user must run `devstore approve \(plan.planId)` in a terminal first")
            }
            return ["result": try ops.execute(plan)]
        case "devstore_run":
            let r = try library.resolve(try string(a, "environment"))
            guard let command = a["command"] as? [String], !command.isEmpty else { throw DevStoreError("command must be a non-empty string array") }
            let res = try Session(library: library).capture(r, command: command, confine: a["confine"] as? Bool ?? true,
                                                            denyNetwork: a["denyNetwork"] as? Bool ?? false,
                                                            workingDirectory: a["workingDirectory"] as? String)
            return ["exitCode": res.status, "stdout": String(res.stdout.suffix(Self.outputLimit)),
                    "stderr": String(res.stderr.suffix(Self.outputLimit)),
                    "truncated": res.stdout.count > Self.outputLimit || res.stderr.count > Self.outputLimit]
        case "devstore_env":
            return try Session(library: library).environment(for: try library.resolve(try string(a, "environment")))
        case "devstore_verify":
            let r = try library.resolve(try string(a, "environment"))
            let run = try Verifier(library: library).verify(r, stage: a["stage"] as? String ?? "mcp")
            return ["runId": run.runId, "passed": run.passed, "total": run.total,
                    "failed": run.checks.filter { !$0.passed }.map(\.name), "notCovered": run.notCovered]
        case "devstore_journal":
            let limit = a["limit"] as? Int ?? 20
            return try jsonObject(Array(try JSONIO.readLines(JournalEntry.self, from: library.paths.journal).suffix(limit)))
        default:
            throw DevStoreError("unknown tool \(name)")
        }
    }
}
