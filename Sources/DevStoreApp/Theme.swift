import DevStoreCore
import SwiftUI

/// Visual identity per environment kind.
enum KindStyle {
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "miniconda", "conda", "python": "leaf.fill"
        case "go": "hare.fill"
        case "rust": "gearshape.2.fill"
        case "dotnet", "csharp": "number.square.fill"
        case "flutter", "dart": "bird.fill"
        case "android", "java": "cup.and.saucer.fill"
        case "node", "javascript": "curlybraces"
        default: "shippingbox.fill"
        }
    }

    static func colors(_ kind: String) -> [Color] {
        switch kind {
        case "miniconda", "conda", "python": [Color(red: 0.20, green: 0.70, blue: 0.45), Color(red: 0.05, green: 0.45, blue: 0.40)]
        case "go": [Color(red: 0.25, green: 0.75, blue: 0.90), Color(red: 0.10, green: 0.45, blue: 0.75)]
        case "rust": [Color(red: 0.95, green: 0.50, blue: 0.25), Color(red: 0.70, green: 0.25, blue: 0.15)]
        case "dotnet", "csharp": [Color(red: 0.55, green: 0.40, blue: 0.95), Color(red: 0.35, green: 0.20, blue: 0.75)]
        case "flutter", "dart": [Color(red: 0.30, green: 0.65, blue: 1.00), Color(red: 0.10, green: 0.35, blue: 0.80)]
        case "android", "java": [Color(red: 0.55, green: 0.80, blue: 0.30), Color(red: 0.30, green: 0.55, blue: 0.15)]
        default: [Color(red: 0.55, green: 0.60, blue: 0.70), Color(red: 0.30, green: 0.35, blue: 0.45)]
        }
    }
}

struct KindIcon: View {
    var kind: String
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: KindStyle.colors(kind), startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: KindStyle.symbol(kind))
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: KindStyle.colors(kind)[1].opacity(0.35), radius: size * 0.12, y: size * 0.05)
    }
}

/// Rounded card background used across the app.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var caption: String
    var symbol: String
    var tint: Color

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 26, height: 26)
                        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

enum ActivityStyle {
    static func symbol(_ a: PlanAction) -> String {
        switch a {
        case .importImage: "square.and.arrow.down"
        case .create: "plus.rectangle.on.folder"
        case .installSDK: "shippingbox"
        case .copySDK: "doc.on.doc"
        case .mount: "externaldrive.badge.plus"
        case .unmount: "eject"
        case .compact: "arrow.down.right.and.arrow.up.left"
        case .archive: "archivebox"
        case .export: "square.and.arrow.up"
        case .delete: "trash"
        }
    }

    static func relative(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return iso }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

extension EnvRow {
    var stateLabel: String {
        if !status.storeOnline { return "存储库离线" }
        if status.mounted { return status.identityVerified == true ? "已挂载" : "身份未核实" }
        return "未挂载"
    }

    var stateColor: Color {
        if !status.storeOnline { return .orange }
        if status.mounted { return status.identityVerified == true ? .green : .red }
        return .secondary
    }

    var verificationLabel: (String, Color) {
        switch status.verification {
        case "passed": ("验证通过", .green)
        case "failed": ("验证失败", .red)
        case "stale": ("需重新验证", .orange)
        default: ("未验证", .secondary)
        }
    }

    var sdkLabel: String {
        if let sdk = image?.sdk { return "\(sdk.name) \(sdk.version)" }
        if environment.adapter.id == "empty" { return "空环境 · 尚未写入 SDK" }
        return "适配器 \(environment.adapter.id)"
    }
}
