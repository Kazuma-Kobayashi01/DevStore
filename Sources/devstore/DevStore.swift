import ArgumentParser
import DevStoreCore
import Foundation

@main
struct DevStore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devstore",
        abstract: "Manage development environments that live in mountable APFS volumes.",
        subcommands: [StoreCommand.self, Create.self, Import.self, Status.self, Inspect.self, Mount.self, Unmount.self,
                      Delete.self, Plans.self, Approve.self, Reject.self, Apply.self, Policy.self, Run.self, Env.self,
                      Verify.self, JournalCommand.self])
}

// MARK: helpers

enum Terminal {
    static var isInteractive: Bool { isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 }

    static func confirm(_ prompt: String) -> Bool {
        print(prompt, terminator: " ")
        fflush(stdout)
        guard let line = readLine() else { return false }
        return ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func requireInteractive(_ what: String) throws {
        guard isInteractive else {
            throw DevStoreError("\(what) must be done by the user in an interactive terminal")
        }
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    print(String(decoding: try JSONIO.encoder().encode(value), as: UTF8.self))
}

func describe(_ plan: Plan) -> String {
    var lines = ["Plan \(plan.planId)  [\(plan.action.rawValue), level \(plan.level.rawValue)]",
                 "Digest \(plan.planDigest)", "Targets:"]
    lines += plan.targets.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }
    lines.append("Preconditions (all met when planned):")
    lines += plan.preconditions.map { "  ✓ \($0)" }
    lines.append("Effects:")
    lines += plan.effects.map { "  • \($0)" }
    lines.append("Not touched:")
    lines += plan.notTouched.map { "  – \($0)" }
    if plan.requiresNetwork { lines.append("Requires network") }
    return lines.joined(separator: "\n")
}

/// Executes a plan only with authority from the user: an unused grant, a mount policy for this
/// environment, or an interactive confirmation right now. Self-reported flags are never accepted.
func authorizeAndExecute(_ plan: Plan, ops: Operations) throws {
    let auth = Authorizer(paths: ops.library.paths)
    if try auth.authorizeAndConsume(plan) != nil {
        print(try ops.execute(plan))
        return
    }
    guard Terminal.isInteractive else {
        print(describe(plan))
        throw DevStoreError("not authorized: the user must run `devstore approve \(plan.planId)` in a terminal, then `devstore apply \(plan.planId)`")
    }
    print(describe(plan))
    guard confirmInTerminal(plan) else { throw DevStoreError("cancelled") }
    let g = try auth.grant(plan, via: "cli-tty")
    try auth.consume(plan, grantId: g.id)
    print(try ops.execute(plan))
}

/// Destructive plans require typing kind/slot; everything else a y/N answer.
func confirmInTerminal(_ plan: Plan) -> Bool {
    if plan.level == .destructive, let kind = plan.targets["kind"], let slot = plan.targets["slot"] {
        print("\nThis is destructive. Type \(kind)/\(slot) to confirm:", terminator: " ")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespaces) == "\(kind)/\(slot)"
    }
    return Terminal.confirm("\nProceed? [y/N]")
}

struct PlanOptions: ParsableArguments {
    @Flag(help: "Only create and print the plan; do not execute.")
    var planOnly = false
    @Flag(help: "Print the plan as JSON.")
    var json = false
}

func handle(_ plan: Plan, _ options: PlanOptions, _ ops: Operations) throws {
    if options.planOnly {
        if options.json { try printJSON(plan) } else { print(describe(plan)) }
        return
    }
    try authorizeAndExecute(plan, ops: ops)
}

// MARK: store

struct StoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "store", abstract: "Register or list stores.",
                                                    subcommands: [Add.self, List.self])

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Register a store directory on this host.")
        @Argument var path: String
        @Flag(help: "Create store.json if the directory is not a store yet.") var create = false
        func run() throws {
            let ref = try Library().addStore(path: path, create: create)
            print("store \(ref.storeId) at \(ref.path)")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List registered stores.")
        func run() throws {
            let lib = Library()
            for s in try lib.loadRegistry().stores {
                print("\(s.storeId)  \(lib.isOnline(s) ? "online " : "offline")  \(s.path)")
            }
        }
    }
}

// MARK: lifecycle

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Import an existing image as a new managed environment (clones it).")
    @Argument(help: "Path to an unmounted .sparsebundle.") var bundle: String
    @Option var store: String
    @Option var kind = "miniconda"
    @Option var slot = "current"
    @Option var name: String
    @OptionGroup var options: PlanOptions
    func run() throws {
        let ops = Operations()
        try handle(try ops.planImport(source: bundle, storeQuery: store, kind: kind, slot: slot, name: name), options, ops)
    }
}

struct Mount: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Mount an environment at its fixed slot path.")
    @Argument(help: "Environment id, kind/slot, or name.") var environment: String
    @OptionGroup var options: PlanOptions
    func run() throws {
        let ops = Operations()
        try handle(try ops.planMount(environment), options, ops)
    }
}

struct Unmount: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unmount an environment (never forced).")
    @Argument var environment: String
    @OptionGroup var options: PlanOptions
    func run() throws {
        let ops = Operations()
        try handle(try ops.planUnmount(environment), options, ops)
    }
}

struct Approve: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Approve a saved plan (interactive terminal only).")
    @Argument var planId: String
    func run() throws {
        try Terminal.requireInteractive("approving a plan")
        let ops = Operations()
        let plan = try ops.loadPlan(planId)
        print(describe(plan))
        print("\nApproval is valid for \(Int(Authorizer.grantLifetime / 60)) minutes.")
        guard confirmInTerminal(plan) else { throw DevStoreError("not approved") }
        let g = try Authorizer(paths: ops.library.paths).grant(plan, via: "cli-tty")
        print("approved: grant \(g.id), expires \(g.expiresAt ?? "?")")
    }
}

struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a new empty environment (empty APFS sparse bundle).")
    @Option var store: String
    @Option var kind: String
    @Option var slot = "current"
    @Option var name: String
    @Option(help: "Maximum size in GiB; the bundle grows on demand.") var size = 20
    @OptionGroup var options: PlanOptions
    func run() throws {
        let ops = Operations()
        try handle(try ops.planCreate(storeQuery: store, kind: kind, slot: slot, name: name, sizeGiB: size), options, ops)
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete an unmounted environment: move its directory (all images) to the Trash and unbind its slot.")
    @Argument var environment: String
    @OptionGroup var options: PlanOptions
    func run() throws {
        let ops = Operations()
        try handle(try ops.planDelete(environment), options, ops)
    }
}

struct Plans: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List saved plans that have not run or been rejected.")
    @Flag var json = false
    func run() throws {
        let entries = try Operations().pendingPlans()
        if json { try printJSON(entries.map(\.plan)); return }
        if entries.isEmpty { print("no pending plans") }
        for e in entries {
            let t = e.plan.targets
            print("\(e.plan.planId.prefix(8))  \(e.state.rawValue)  \(e.plan.action.rawValue)  \(t["kind"].map { "\($0)/\(t["slot"] ?? "")" } ?? t["slotPath"] ?? "")  \(e.plan.createdAt)")
        }
    }
}

struct Reject: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Reject a saved plan so it can never run (interactive terminal only).")
    @Argument var planId: String
    func run() throws {
        try Terminal.requireInteractive("rejecting a plan")
        let ops = Operations()
        let plan = try ops.loadPlan(planId)
        try Authorizer(paths: ops.library.paths).reject(plan, via: "cli-tty")
        print("rejected \(plan.planId)")
    }
}

struct Apply: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Execute a saved plan that the user approved.")
    @Argument var planId: String
    func run() throws {
        let ops = Operations()
        try authorizeAndExecute(try ops.loadPlan(planId), ops: ops)
    }
}

struct Policy: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Standing mount/unmount policy for one environment (interactive terminal only to change).")
    @Argument(help: "allow | revoke | show") var verb: String
    @Argument var environment: String
    func run() throws {
        let lib = Library()
        let r = try lib.resolve(environment)
        let auth = Authorizer(paths: lib.paths)
        switch verb {
        case "allow", "revoke":
            try Terminal.requireInteractive("changing a policy")
            guard Terminal.confirm("\(verb == "allow" ? "Allow" : "Revoke") standing mount/unmount for \(r.environment.kind)/\(r.environment.slot)? [y/N]") else {
                throw DevStoreError("cancelled")
            }
            try auth.setPolicy(environmentId: r.environment.environmentId, allow: verb == "allow", via: "cli-tty")
            print("policy \(verb == "allow" ? "set" : "revoked")")
        case "show":
            for a in Authorizer.policyActions.sorted(by: { $0.rawValue < $1.rawValue }) {
                print("\(a.rawValue): \(try auth.policyAllows(environmentId: r.environment.environmentId, action: a) ? "allowed" : "requires approval")")
            }
        default:
            throw ValidationError("verb must be allow, revoke or show")
        }
    }
}

// MARK: inspection

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show every environment bound on this host.")
    @Flag var json = false
    func run() throws {
        let lib = Library()
        let all = try lib.environments().map(lib.status)
        if json { try printJSON(all); return }
        if all.isEmpty { print("no environments; import one with `devstore import`") }
        for s in all {
            let mount = s.mounted ? (s.identityVerified == true ? "mounted" : "mounted(UNVERIFIED IDENTITY)") : "unmounted"
            print("\(s.kind)/\(s.slot)  \(s.displayName)  \(mount)  verification=\(s.verification)  env=\(s.environmentId.prefix(8))  store=\(s.storeOnline ? "online" : "offline")")
        }
    }
}

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show records for one environment as JSON.")
    @Argument var environment: String
    func run() throws {
        let lib = Library()
        let r = try lib.resolve(environment)
        struct Out: Encodable {
            var status: EnvironmentStatus
            var environment: EnvironmentRecord
            var image: ImageRecord?
            var bundlePath: String?
        }
        try printJSON(Out(status: lib.status(r), environment: r.environment, image: r.image, bundlePath: r.bundlePath))
    }
}

struct JournalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "journal", abstract: "Show recent transaction journal entries.")
    @Option var limit = 20
    func run() throws {
        let lib = Library()
        for e in try JSONIO.readLines(JournalEntry.self, from: lib.paths.journal).suffix(limit) {
            print("\(e.at)  \(e.transactionId.prefix(8))  \(e.action.rawValue)  \(e.event)\(e.step.map { " " + $0 } ?? "")\(e.detail.map { "  " + $0 } ?? "")")
        }
    }
}

// MARK: session

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command with the environment's session variables (not an isolation boundary).")
    @Argument var environment: String
    @Flag(help: "Deny reading the original installation, Homebrew and /usr/local (sandbox-exec).") var confine = false
    @Flag(help: "With --confine, also deny network access.") var denyNetwork = false
    @Argument(parsing: .postTerminator) var command: [String] = []
    func run() throws {
        let lib = Library()
        let status = try Session(library: lib).run(try lib.resolve(environment), command: command,
                                                   confine: confine, denyNetwork: denyNetwork)
        throw ExitCode(status)
    }
}

struct Env: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the session variables for a mounted environment.")
    @Argument var environment: String
    @Flag var json = false
    func run() throws {
        let lib = Library()
        let env = try Session(library: lib).environment(for: try lib.resolve(environment))
        if json { try printJSON(env); return }
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            print("export \(k)='\(v.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
    }
}

struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the adapter's verification suite (sandboxed, offline) and record the result.")
    @Argument var environment: String
    @Option var stage = "manual"
    func run() throws {
        let lib = Library()
        let result = try Verifier(library: lib).verify(try lib.resolve(environment), stage: stage) { name, ok in
            print("\(ok ? "✓" : "✗") \(name)")
        }
        print("\(result.passed)/\(result.total) passed  run \(result.runId)")
        if result.passed != result.total { throw ExitCode(1) }
    }
}
