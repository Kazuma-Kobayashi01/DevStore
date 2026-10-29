import AppKit
import DevStoreCore
import SwiftUI

struct EnvironmentDetailView: View {
    @Environment(AppModel.self) private var model
    var row: EnvRow

    var s: EnvironmentStatus { row.status }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.displayName).font(.title2.bold())
                        Text("\(s.kind)/\(s.slot) · 适配器 \(row.environment.adapter.id) \(row.environment.adapter.version)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !s.storeOnline { Badge(text: "存储库离线", color: .orange) }
                    if s.mounted {
                        Badge(text: s.identityVerified == true ? "已挂载" : "身份未核实", color: s.identityVerified == true ? .green : .red)
                    } else {
                        Badge(text: "未挂载", color: .secondary)
                    }
                    verificationBadge
                }
                HStack {
                    Button(s.mounted ? "卸载" : "挂载") { Task { await model.toggleMount(row) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy != nil || !s.storeOnline)
                    if row.environment.adapter.id == "empty" {
                        Button("写入 SDK…") { model.sheet = .installSDK(row.id) }
                            .disabled(model.busy != nil || s.identityVerified != true)
                            .help(s.identityVerified == true ? "在卷内安装 Miniconda" : "请先挂载")
                    }
                    Button("运行验证") { Task { await model.verify(row) } }
                        .disabled(model.busy != nil || s.identityVerified != true)
                    Button("复制环境变量") { Task { await model.copySessionEnvironment(row) } }
                        .disabled(s.identityVerified != true)
                        .help("复制 export 语句，粘贴到终端即可在该环境中工作")
                    Button("在 Finder 中显示") {
                        let target = s.mounted ? s.slotPath : (row.bundlePath ?? s.slotPath)
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
                    }
                    Spacer()
                    Button("删除…", role: .destructive) {
                        Task { await model.prepare("正在生成删除计划…") { try $0.planDelete(row.id) } }
                    }
                    .disabled(model.busy != nil || s.mounted)
                    .help(s.mounted ? "请先卸载" : "移到废纸篓并解除槽位")
                }
            }

            Section("挂载授权") {
                Toggle("允许 Agent 无需逐次批准即可挂载/卸载此环境", isOn: Binding(
                    get: { row.policyAllowsMount },
                    set: { allow in Task { await model.setPolicy(row, allow: allow) } }))
                Text("只覆盖挂载与卸载。导入、新建、删除始终需要逐次批准。").font(.caption).foregroundStyle(.secondary)
            }

            if let sdk = row.image?.sdk {
                Section("SDK") {
                    LabeledContent(sdk.name) { Text(sdk.version) }
                    LabeledContent("安装器") { Text(sdk.installer).textSelection(.enabled) }
                    LabeledContent("SHA-256") { Text(sdk.installerSHA256).monospaced().textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                    LabeledContent("安装时间") { Text(sdk.installedAt) }
                }
            }

            Section("位置与身份") {
                LabeledContent("挂载路径") { Text(s.slotPath).textSelection(.enabled) }
                LabeledContent("映像") { Text(row.bundlePath ?? "—").textSelection(.enabled).lineLimit(2) }
                LabeledContent("映像已分配") { Text(bytes(row.bundleBytes)) }
                LabeledContent("环境 ID") { Text(s.environmentId).textSelection(.enabled).monospaced() }
                LabeledContent("映像 ID") { Text(s.imageId ?? "—").textSelection(.enabled).monospaced() }
                LabeledContent("卷 UUID") { Text(s.volumeUUID ?? "—").textSelection(.enabled).monospaced() }
                LabeledContent("存储库") { Text(s.storeId).monospaced() }
                if let lease = s.lease {
                    LabeledContent("租约") { Text("主机 \(lease.hostId.prefix(8)) · \(lease.mountedAt)") }
                }
                LabeledContent("来源") { Text(row.image?.lineage.reason ?? row.environment.origin.type) }
            }

            if let components = row.image?.components, !components.isEmpty {
                Section("组件") {
                    ForEach(components, id: \.name) { c in
                        LabeledContent(c.name) {
                            Text([c.python.map { "Python \($0)" }, c.condaPackages.map { "\($0) 个 conda 包" }]
                                .compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                }
            }

            Section("验证") {
                if let v = s.lastVerification {
                    LabeledContent("最近一次") { Text("\(v.passed)/\(v.total) 通过 · \(v.stage) · \(v.at)") }
                } else {
                    Text("尚未验证").foregroundStyle(.secondary)
                }
                if let progress = model.verifyProgress[row.id], !progress.isEmpty {
                    ForEach(Array(progress.enumerated()), id: \.offset) { _, item in
                        Label(item.name, systemImage: item.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(item.ok ? .green : .red)
                            .font(.callout)
                    }
                }
            }

            if !s.knownWarnings.isEmpty {
                Section("已知警告") {
                    ForEach(s.knownWarnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(s.displayName)
    }

    @ViewBuilder var verificationBadge: some View {
        switch s.verification {
        case "passed": Badge(text: "验证通过", color: .green)
        case "failed": Badge(text: "验证失败", color: .red)
        case "stale": Badge(text: "需重新验证", color: .orange)
        default: Badge(text: "未验证", color: .secondary)
        }
    }
}
