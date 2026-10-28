import AppKit
import DevStoreCore
import Foundation
import LocalAuthentication
import Observation

struct EnvRow: Identifiable, Sendable {
    var id: String { status.environmentId }
    var status: EnvironmentStatus
    var environment: EnvironmentRecord
    var image: ImageRecord?
    var bundlePath: String?
    var bundleBytes: Int64?
    var policyAllowsMount: Bool
}

struct StoreRow: Identifiable, Sendable {
    var id: String { ref.storeId }
    var ref: StoreRef
    var online: Bool
    var environments: Int
}

struct Snapshot: Sendable {
    var environments: [EnvRow] = []
    var stores: [StoreRow] = []
    var pending: [Operations.PlanEntry] = []
    var journal: [JournalEntry] = []

    static func load(_ lib: Library) -> Snapshot {
        let auth = Authorizer(paths: lib.paths)
        let envs = (try? lib.environments()) ?? []
        let rows = envs.map { r in
            EnvRow(status: lib.status(r), environment: r.environment, image: r.image, bundlePath: r.bundlePath,
                   bundleBytes: r.bundlePath.map(DiskImage.allocatedBytes),
                   policyAllowsMount: (try? auth.policyAllows(environmentId: r.environment.environmentId, action: .mount)) ?? false)
        }.sorted { ($0.status.kind, $0.status.slot) < ($1.status.kind, $1.status.slot) }
        let reg = try? lib.loadRegistry()
        let stores = (reg?.stores ?? []).map { s in
            StoreRow(ref: s, online: lib.isOnline(s), environments: (reg?.slots ?? []).filter { $0.storeId == s.storeId }.count)
        }
        return Snapshot(environments: rows, stores: stores,
                        pending: (try? Operations(library: lib).pendingPlans()) ?? [],
                        journal: Array(((try? JSONIO.readLines(JournalEntry.self, from: lib.paths.journal)) ?? []).suffix(300).reversed()))
    }
}

enum ActiveSheet: Identifiable {
    case create
    case importImage
    case plan(Plan, fromAgent: Bool)

    var id: String {
        switch self {
        case .create: "create"
        case .importImage: "import"
        case let .plan(p, _): p.planId
        }
    }
}

/// UI state. All core calls run off the main actor; the core types are Sendable values.
@MainActor @Observable
final class AppModel {
    let library = Library()
    var snapshot = Snapshot()
    var busy: String?
    var errorMessage: String?
    var notice: String?
    var sheet: ActiveSheet?
    var verifyProgress: [String: [(name: String, ok: Bool)]] = [:]
    private var refreshTask: Task<Void, Never>?

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func refresh() async {
        let lib = library
        snapshot = await Task.detached { Snapshot.load(lib) }.value
    }

    func row(_ id: String) -> EnvRow? { snapshot.environments.first { $0.id == id } }

    // MARK: running work

    private func background<T: Sendable>(_ label: String, _ work: @escaping @Sendable () throws -> T) async -> T? {
        busy = label
        defer { busy = nil }
        do {
            return try await Task.detached(operation: work).value
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Plans are created off-main, then shown for confirmation.
    func prepare(_ label: String, fromAgent: Bool = false, _ make: @escaping @Sendable (Operations) throws -> Plan) async {
        let lib = library
        if let plan = await background(label, { try make(Operations(library: lib)) }) {
            sheet = .plan(plan, fromAgent: fromAgent)
        }
        await refresh()
    }

    /// The user confirmed in the app. Destructive plans also need device-owner authentication.
    func approve(_ plan: Plan, execute: Bool) async {
        sheet = nil
        if plan.level == .destructive {
            guard await authenticate("确认删除 \(plan.targets["kind"] ?? "")/\(plan.targets["slot"] ?? "")") else {
                errorMessage = "未通过身份验证，已取消。"
                return
            }
        }
        let lib = library
        let result = await background(execute ? "正在执行 \(Self.actionName(plan.action))…" : "正在批准…") { () -> String in
            let auth = Authorizer(paths: lib.paths)
            let g = try auth.grant(plan, via: plan.level == .destructive ? "gui-authenticated" : "gui")
            guard execute else { return "已批准计划 \(plan.planId.prefix(8))，有效期至 \(g.expiresAt ?? "?")" }
            guard try auth.authorizeAndConsume(plan) != nil else { throw DevStoreError("授权失败") }
            return try Operations(library: lib).execute(plan)
        }
        if let result { notice = result }
        await refresh()
    }

    func reject(_ plan: Plan) async {
        sheet = nil
        let lib = library
        _ = await background("正在拒绝…") { try Authorizer(paths: lib.paths).reject(plan, via: "gui") }
        notice = "已拒绝计划 \(plan.planId.prefix(8))"
        await refresh()
    }

    /// Mount/unmount are direct user actions in the app: plan, grant (via gui), execute.
    func toggleMount(_ row: EnvRow) async {
        let lib = library, id = row.id, mounted = row.status.mounted
        let result = await background(mounted ? "正在卸载…" : "正在挂载…") { () -> String in
            let ops = Operations(library: lib)
            let plan = mounted ? try ops.planUnmount(id) : try ops.planMount(id)
            let auth = Authorizer(paths: lib.paths)
            _ = try auth.grant(plan, via: "gui")
            guard try auth.authorizeAndConsume(plan) != nil else { throw DevStoreError("授权失败") }
            return try ops.execute(plan)
        }
        if let result { notice = result }
        await refresh()
    }

    func verify(_ row: EnvRow) async {
        let lib = library, id = row.id
        verifyProgress[id] = []
        let result = await background("正在验证 \(row.status.kind)/\(row.status.slot)…") { () -> String in
            let run = try Verifier(library: lib).verify(try lib.resolve(id), stage: "app") { name, ok in
                Task { @MainActor [weak self] in self?.verifyProgress[id, default: []].append((name, ok)) }
            }
            return "验证完成：\(run.passed)/\(run.total) 通过"
        }
        if let result { notice = result }
        await refresh()
    }

    func setPolicy(_ row: EnvRow, allow: Bool) async {
        let lib = library, id = row.id
        _ = await background("正在更新策略…") {
            try Authorizer(paths: lib.paths).setPolicy(environmentId: id, allow: allow, via: "gui")
        }
        await refresh()
    }

    func addStore(_ url: URL) async {
        let lib = library
        if let ref = await background("正在登记存储库…", { try lib.addStore(path: url.path, create: true) }) {
            notice = "已登记存储库 \(ref.path)"
        }
        await refresh()
    }

    func copySessionEnvironment(_ row: EnvRow) async {
        let lib = library, id = row.id
        guard let env = await background("", { try Session(library: lib).environment(for: try lib.resolve(id)) }) else { return }
        let text = env.sorted { $0.key < $1.key }
            .map { "export \($0.key)='\($0.value.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text + "\n", forType: .string)
        notice = "已复制 \(env.count) 个环境变量，可粘贴到终端"
    }

    private func authenticate(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    static func actionName(_ a: PlanAction) -> String {
        switch a {
        case .importImage: "导入"
        case .create: "新建空环境"
        case .mount: "挂载"
        case .unmount: "卸载"
        case .delete: "删除"
        }
    }

    static func levelName(_ l: CapabilityLevel) -> String {
        switch l {
        case .inspect: "只读"
        case .plan: "计划"
        case .session: "会话"
        case .mount: "挂载"
        case .mutate: "修改"
        case .destructive: "破坏性"
        }
    }
}
