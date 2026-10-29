import AppKit
import DevStoreCore
import SwiftUI

struct EnvironmentDetailView: View {
    @Environment(AppModel.self) private var model
    var row: EnvRow

    var s: EnvironmentStatus { row.status }
    var mountedOK: Bool { s.identityVerified == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                if let progress = model.verifyProgress[row.id], !progress.isEmpty { verifyProgress(progress) }
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        storageCard
                        archiveCard
                    }
                    VStack(spacing: 16) {
                        if let sdk = row.image?.sdk { sdkCard(sdk) }
                        componentsCard
                        policyCard
                    }
                }
                identityCard
                if !s.knownWarnings.isEmpty { warningsCard }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle(s.displayName)
        .navigationSubtitle("\(s.kind)/\(s.slot)")
    }

    // MARK: header & actions

    var header: some View {
        HStack(alignment: .center, spacing: 16) {
            KindIcon(kind: s.kind, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(s.displayName).font(.title.bold())
                Text(s.slotPath).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 6) {
                    Badge(text: row.stateLabel, color: row.stateColor)
                    Badge(text: row.verificationLabel.0, color: row.verificationLabel.1)
                    Badge(text: row.sdkLabel, color: .blue)
                }
            }
            Spacer()
        }
    }

    var actions: some View {
        HStack(spacing: 8) {
            Button { Task { await model.toggleMount(row) } } label: {
                Label(s.mounted ? "卸载" : "挂载", systemImage: s.mounted ? "eject.fill" : "externaldrive.fill.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy != nil || !s.storeOnline)

            if row.environment.adapter.id == "empty" {
                Button { model.sheet = .installSDK(row.id) } label: { Label("写入 SDK…", systemImage: "square.and.arrow.down.on.square") }
                    .disabled(model.busy != nil || !mountedOK)
                    .help(mountedOK ? "在卷内安装 Miniconda 或 Go" : "请先挂载")
            }
            Button { Task { await model.verify(row) } } label: { Label("验证", systemImage: "checkmark.seal") }
                .disabled(model.busy != nil || !mountedOK)
            Button { Task { await model.copySessionEnvironment(row) } } label: { Label("复制环境变量", systemImage: "terminal") }
                .disabled(!mountedOK)
                .help("复制 export 语句，粘贴到终端即可在该环境中工作")
            Button {
                let target = s.mounted ? s.slotPath : (row.bundlePath ?? s.slotPath)
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
            } label: { Label("Finder", systemImage: "folder") }
            Spacer()
            Button(role: .destructive) {
                Task { await model.prepare("正在生成删除计划…") { try $0.planDelete(row.id) } }
            } label: { Label("删除…", systemImage: "trash") }
                .disabled(model.busy != nil || s.mounted)
                .help(s.mounted ? "请先卸载" : "移到废纸篓并解除槽位")
        }
        .controlSize(.large)
    }

    func verifyProgress(_ items: [(name: String, ok: Bool)]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("验证进度").font(.headline)
                    Spacer()
                    Text("\(items.filter(\.ok).count)/\(items.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Label(item.name, systemImage: item.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(item.ok ? .green : .red).font(.caption)
                    }
                }
            }
        }
    }

    // MARK: cards

    var storageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("存储与空间", systemImage: "internaldrive").font(.headline)
                LabeledContent("映像已分配") { Text(bytes(row.bundleBytes)).monospacedDigit() }
                if let c = row.image?.lastCompaction {
                    LabeledContent("上次回收") {
                        Text("\(bytes(c.beforeBytes - c.afterBytes)) · \(c.at.prefix(16))").monospacedDigit()
                    }
                }
                Button { Task { await model.prepare("正在生成回收计划…") { [id = row.id] in try $0.planCompact(id) } } } label: {
                    Label("回收剩余空间", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .disabled(model.busy != nil || s.mounted)
                .help(s.mounted ? "请先卸载" : "在副本上压实映像，核对内容一致后替换")
                Text("先在副本上回收，核对内容一致后才替换；原映像放入废纸篓。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var archiveCard: some View {
        let cps = model.checkpoints(for: row.id)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("归档与冷备份", systemImage: "archivebox").font(.headline)
                    Spacer()
                    Button { model.sheet = .archive(row.id) } label: { Label("压缩归档…", systemImage: "plus") }
                        .disabled(model.busy != nil || s.mounted)
                        .help(s.mounted ? "请先卸载" : "生成压缩、可选加密的只读检查点")
                }
                if cps.isEmpty {
                    Text("还没有归档。卸载后可以压缩归档，再导出到外置盘。").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(cps, id: \.checkpointId) { cp in CheckpointRow(cp: cp) }
            }
        }
    }

    func sdkCard(_ sdk: SDKRecord) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("SDK", systemImage: "shippingbox").font(.headline)
                LabeledContent(sdk.name) { Text(sdk.version).monospaced() }
                LabeledContent("安装器") { Text(sdk.installer).lineLimit(1).truncationMode(.middle) }
                LabeledContent("SHA-256") { Text(sdk.installerSHA256.prefix(16) + "…").monospaced().help(sdk.installerSHA256) }
                LabeledContent("写入时间") { Text(sdk.installedAt.prefix(16)) }
            }
        }
    }

    var componentsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("组件", systemImage: "square.stack.3d.up").font(.headline)
                let components = row.image?.components ?? []
                if components.isEmpty { Text("暂无（写入 SDK 后显示）").foregroundStyle(.secondary).font(.callout) }
                ForEach(components, id: \.name) { c in
                    LabeledContent(c.name) {
                        Text([c.version.map { $0 == "tool" ? "工具" : $0 }, c.python.map { "Python \($0)" }, c.condaPackages.map { "\($0) 包" }]
                            .compactMap { $0 }.joined(separator: " · "))
                    }
                }
                if let v = s.lastVerification {
                    Divider()
                    LabeledContent("最近验证") { Text("\(v.passed)/\(v.total) · \(v.at.prefix(16))").monospacedDigit() }
                }
            }
        }
    }

    var policyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(get: { row.policyAllowsMount }, set: { allow in Task { await model.setPolicy(row, allow: allow) } })) {
                    Label("允许 Agent 直接挂载/卸载", systemImage: "person.badge.key")
                }
                Text("只覆盖挂载与卸载；新建、写入、回收、归档、删除始终需要逐次批准。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var identityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("位置与身份", systemImage: "number").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    row("映像", row.bundlePath ?? "—")
                    row("环境 ID", s.environmentId)
                    row("映像 ID", s.imageId ?? "—")
                    row("卷 UUID", s.volumeUUID ?? "—")
                    row("存储库", s.storeId)
                    if let lease = s.lease { row("租约", "主机 \(lease.hostId.prefix(8)) · \(lease.mountedAt)") }
                    row("来源", row.image?.lineage.reason ?? row.environment.origin.type)
                }
            }
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }

    var warningsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("已知警告", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                ForEach(s.knownWarnings, id: \.self) { Text("• " + $0).font(.callout) }
            }
        }
    }
}

struct CheckpointRow: View {
    @Environment(AppModel.self) private var model
    var cp: CheckpointRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: cp.encryption == "aes256" ? "lock.doc.fill" : "doc.zipper")
                .foregroundStyle(cp.encryption == "aes256" ? .orange : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(cp.createdAt.prefix(16)) · \(bytes(cp.fileBytes))").font(.callout.monospacedDigit())
                Text("\(cp.format == "ULFO" ? "LZFSE" : "LZMA")\(cp.encryption == "aes256" ? " · AES-256" : "") · \(cp.imageChecksumVerified ? "校验通过" : "校验未通过") · 导出 \(cp.exports.count) 次")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("导出…") { chooseExport() }.controlSize(.small).disabled(model.busy != nil)
        }
        .padding(.vertical, 2)
    }

    func chooseExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到这里"
        panel.message = "选择冷备份位置（例如外置盘上的文件夹）。复制后会核对 SHA-256。"
        if panel.runModal() == .OK, let url = panel.url { Task { await model.export(cp, to: url) } }
    }
}
