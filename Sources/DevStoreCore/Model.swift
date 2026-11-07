import Foundation

// Records follow docs/design/v3数据模型.md. Every persisted file carries schemaVersion.

public struct AdapterRef: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
}

public struct Origin: Codable, Sendable {
    public var type: String            // imported | created | restored
    public var sourcePath: String?
    public var note: String?
}

public struct EnvironmentRecord: Codable, Sendable {
    public var schemaVersion = 1
    public var environmentId: String
    public var kind: String
    public var slot: String
    public var displayName: String
    public var adapter: AdapterRef
    public var activeImageId: String?
    public var origin: Origin
    public var secretsPolicy = "none"
    public var createdAt: String
}

public enum ImageRole: String, Codable, Sendable { case active, standby, retired }

public struct HostBinding: Codable, Equatable, Sendable {
    public var user: String
    public var homePath: String
    public var arch: String
    public var osVersion: String

    public static func current() -> HostBinding {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return HostBinding(user: NSUserName(), homePath: NSHomeDirectory(), arch: machineArch(),
                           osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }

    /// OS version may differ; user, home and arch must match because prefixes are absolute.
    public func compatible(with other: HostBinding) -> Bool {
        user == other.user && homePath == other.homePath && arch == other.arch
    }
}

public struct Lineage: Codable, Sendable {
    public var parentImageId: String?
    public var fromCheckpointId: String?
    public var reason: String
}

public struct Component: Codable, Sendable {
    public var name: String
    public var python: String?
    public var condaPackages: Int?
    public var version: String? = nil
}

/// SDK written into an empty environment by `install-sdk`.
public struct SDKRecord: Codable, Sendable {
    public var name: String
    public var version: String
    public var installer: String
    public var installerSHA256: String
    public var installedAt: String
}

public struct VerificationRef: Codable, Sendable {
    public var runId: String
    public var stage: String
    public var passed: Int
    public var total: Int
    public var at: String
}

public struct ImageRecord: Codable, Sendable {
    public var schemaVersion = 1
    public var imageId: String
    public var environmentId: String
    public var storeId: String
    public var relativePath: String     // bundle path relative to the store root
    public var format = "UDSB"
    public var volumeUUID: String?
    public var role: ImageRole
    public var lineage: Lineage
    public var fixedMountPath: String
    public var hostBinding: HostBinding
    public var components: [Component] = []
    public var knownWarnings: [String] = []
    public var sdk: SDKRecord?
    public var lastCompaction: CompactionRecord?
    public var lastVerification: VerificationRef?
    public var mutatedSinceVerification = false
    public var createdAt: String
}

/// Written inside the volume at `<mount>/.devstore/manifest.json`.
public struct VolumeManifest: Codable, Sendable {
    public var schemaVersion = 1
    public var environmentId: String
    public var imageId: String
    public var kind: String
    public var slot: String
    public var adapter: AdapterRef
    public var fixedMountPath: String
    public var writtenAt: String
}

public struct Lease: Codable, Sendable {
    public var schemaVersion = 1
    public var hostId: String
    public var imageId: String
    public var mountedAt: String
    public var transactionId: String
}

public struct StoreRecord: Codable, Sendable {
    public var schemaVersion = 1
    public var storeId: String
    public var createdAt: String
}

public struct StoreRef: Codable, Sendable {
    public var storeId: String
    public var path: String
}

public struct SlotBinding: Codable, Sendable {
    public var kind: String
    public var slot: String
    public var environmentId: String
    public var storeId: String
}

/// Host registry: an index and nothing more; it can be rebuilt by scanning stores.
public struct HostRegistry: Codable, Sendable {
    public var schemaVersion = 1
    public var hostId: String
    public var stores: [StoreRef] = []
    public var slots: [SlotBinding] = []
}

public enum CapabilityLevel: String, Codable, Sendable, Comparable {
    case inspect, plan, session, mount, mutate, destructive

    private var rank: Int {
        switch self {
        case .inspect: 0
        case .plan: 1
        case .session: 2
        case .mount: 3
        case .mutate: 4
        case .destructive: 5
        }
    }

    public static func < (a: CapabilityLevel, b: CapabilityLevel) -> Bool { a.rank < b.rank }
}

public enum PlanAction: String, Codable, Sendable, CaseIterable {
    case importImage = "import"
    case create
    case installSDK = "install-sdk"
    case copySDK = "copy-sdk"
    case mount
    case unmount
    case compact
    case archive
    case export
    case delete
    case clearLease = "clear-lease"

    public var level: CapabilityLevel {
        switch self {
        case .importImage, .create, .installSDK, .copySDK, .compact, .archive, .export: .mutate
        case .mount, .unmount: .mount
        case .delete, .clearLease: .destructive
        }
    }
}

public struct Plan: Codable, Sendable {
    public var schemaVersion = 1
    public var planId: String
    public var action: PlanAction
    public var level: CapabilityLevel
    public var targets: [String: String]
    public var preconditions: [String]
    public var effects: [String]
    public var notTouched: [String]
    public var requiresNetwork = false
    public var createdAt: String
    public var planDigest = ""
}

func machineArch() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}

public func timestamp(_ date: Date = Date()) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

public func newId() -> String { UUID().uuidString.lowercased() }
