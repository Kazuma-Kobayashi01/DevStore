import Foundation

public enum GrantEventType: String, Codable, Sendable { case grant, consume, policy, revoke }

/// One line of `grants.jsonl`. Grants bind a plan digest and are single-use;
/// policies (mount/unmount only) bind one environment.
public struct GrantEvent: Codable, Sendable {
    public var schemaVersion = 1
    public var type: GrantEventType
    public var id: String
    public var planId: String?
    public var planDigest: String?
    public var environmentId: String?
    public var actions: [String]?
    public var createdAt: String
    public var expiresAt: String?
    public var via: String
}

public struct Authorizer: Sendable {
    public var paths: DevStorePaths
    public static let grantLifetime: TimeInterval = 600
    public static let policyActions: Set<PlanAction> = [.mount, .unmount]

    public init(paths: DevStorePaths) { self.paths = paths }

    func events() throws -> [GrantEvent] { try JSONIO.readLines(GrantEvent.self, from: paths.grants) }

    /// Only the interactive CLI or GUI may call this. `via` records which.
    public func grant(_ plan: Plan, via: String) throws -> GrantEvent {
        let now = Date()
        let g = GrantEvent(type: .grant, id: newId(), planId: plan.planId, planDigest: plan.planDigest,
                           createdAt: timestamp(now), expiresAt: timestamp(now.addingTimeInterval(Self.grantLifetime)),
                           via: via)
        try JSONIO.appendLine(g, to: paths.grants)
        return g
    }

    public func usableGrant(for plan: Plan, now: Date = Date()) throws -> GrantEvent? {
        let all = try events()
        let consumed = Set(all.filter { $0.type == .consume }.compactMap(\.planId))
        let f = ISO8601DateFormatter()
        return all.last { g in
            g.type == .grant && g.planId == plan.planId && g.planDigest == plan.planDigest
                && !consumed.contains(plan.planId)
                && (g.expiresAt.flatMap { f.date(from: $0) }.map { $0 > now } ?? false)
        }
    }

    public func consume(_ plan: Plan, grantId: String) throws {
        try JSONIO.appendLine(GrantEvent(type: .consume, id: grantId, planId: plan.planId, planDigest: plan.planDigest,
                                         createdAt: timestamp(), via: "executor"), to: paths.grants)
    }

    public func setPolicy(environmentId: String, allow: Bool, via: String) throws {
        let e = GrantEvent(type: allow ? .policy : .revoke, id: newId(), environmentId: environmentId,
                           actions: allow ? Self.policyActions.map(\.rawValue).sorted() : nil,
                           createdAt: timestamp(), via: via)
        try JSONIO.appendLine(e, to: paths.grants)
    }

    /// The latest policy or revoke event for the environment decides.
    public func policyAllows(environmentId: String, action: PlanAction) throws -> Bool {
        guard Self.policyActions.contains(action) else { return false }
        let last = try events().last {
            ($0.type == .policy || $0.type == .revoke) && $0.environmentId == environmentId
        }
        return last?.type == .policy && (last?.actions?.contains(action.rawValue) ?? false)
    }
}

public struct JournalEntry: Codable, Sendable {
    public var schemaVersion = 1
    public var transactionId: String
    public var planId: String
    public var action: PlanAction
    public var event: String           // started | step | committed | failed | rolledBack
    public var step: String?
    public var detail: String?
    public var at: String
}

public struct Journal: Sendable {
    public var url: URL
    public var transactionId = newId()
    public var plan: Plan

    public func log(_ event: String, step: String? = nil, detail: String? = nil) {
        let e = JournalEntry(transactionId: transactionId, planId: plan.planId, action: plan.action,
                             event: event, step: step, detail: detail, at: timestamp())
        try? JSONIO.appendLine(e, to: url)
    }
}
