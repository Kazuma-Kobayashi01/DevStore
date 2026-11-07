import DevStoreCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    var open: (SidebarItem) -> Void

    var envs: [EnvRow] { model.snapshot.environments }
    var stores: [StoreRow] { model.snapshot.stores }
    var mounted: Int { envs.filter { $0.status.mounted }.count }
    var pending: Int { model.snapshot.pending.filter { $0.state == .pending }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                stats
                if pending > 0 { pendingBanner }
                if envs.isEmpty { gettingStarted } else { environments }
                HStack(alignment: .top, spacing: 16) {
                    capacity.frame(maxWidth: .infinity)
                    activity.frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("总览")
        .navigationSubtitle(envs.isEmpty ? "尚无环境" : "\(envs.count) 个环境 · \(mounted) 个已挂载")
    }

    // MARK: stats

    var stats: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatTile(title: "环境", value: "\(envs.count)",
                         caption: envs.isEmpty ? "尚未创建" : "\(Set(envs.map(\.status.kind)).count) 种类型",
                         symbol: "square.stack.3d.up.fill", tint: .blue)
                StatTile(title: "已挂载", value: "\(mounted)",
                         caption: mounted == 0 ? "全部已卸载" : "位于 ~/.local/dev",
                         symbol: "externaldrive.fill.badge.checkmark", tint: .green)
                StatTile(title: "映像占用", value: bytes(envs.compactMap(\.bundleBytes).reduce(0, +)),
                         caption: freeCaption, symbol: "internaldrive.fill", tint: .purple)
                StatTile(title: "归档", value: "\(model.snapshot.checkpoints.count)",
                         caption: archiveCaption, symbol: "archivebox.fill", tint: .orange)
            }
        }
    }

    var freeCaption: String {
        guard let free = stores.first(where: \.online)?.freeBytes else { return "未登记存储库" }
        return "存储库剩余 \(bytes(free))"
    }

    var archiveCaption: String {
        let cps = model.snapshot.checkpoints
        guard !cps.isEmpty else { return "尚无冷备份" }
        let exported = cps.filter { !$0.exports.isEmpty }.count
        return "\(exported)/\(cps.count) 已导出"
    }

    var pendingBanner: some View {
        Button { open(.pending) } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(pending) 个计划等待批准").font(.headline)
                    Text("Agent 或命令行生成的改动，批准前不会执行。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("查看").foregroundStyle(.tint)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    // MARK: environments

    var environments: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "环境") {
                Button { model.sheet = .create } label: { Label("新建空环境", systemImage: "plus") }
                    .disabled(stores.isEmpty)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach(envs) { row in EnvironmentCard(row: row) { open(.environment(row.id)) } }
            }
        }
    }

    var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "开始使用") { EmptyView() }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    StepRow(number: 1, title: "登记存储库", detail: "选择一个文件夹（可以在外置 SSD）保存环境映像。",
                            done: !stores.isEmpty, action: stores.isEmpty ? ("登记…", { open(.stores) }) : nil)
                    Divider().padding(.leading, 56)
                    StepRow(number: 2, title: "新建空环境", detail: "创建一个按需增长的可写 APFS 卷，固定挂载到 ~/.local/dev/<类型>/<槽位>。",
                            done: false, action: stores.isEmpty ? nil : ("新建…", { model.sheet = .create }))
                    Divider().padding(.leading, 56)
                    StepRow(number: 3, title: "写入 SDK 并验证", detail: "挂载后在卷内安装 Miniconda，DevStore 在沙箱中验证它不依赖原安装。",
                            done: false, action: nil)
                }
            }
        }
    }

    // MARK: capacity & activity

    var capacity: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "存储库") {
                Button("管理") { open(.stores) }.buttonStyle(.link)
            }
            Card {
                if stores.isEmpty {
                    Text("还没有登记存储库。").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(stores) { s in CapacityRow(store: s) }
                    }
                }
            }
        }
    }

    var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "最近活动") {
                Button("全部") { open(.journal) }.buttonStyle(.link)
            }
            Card {
                let items = model.snapshot.journal.filter { ["committed", "failed", "rolledBack"].contains($0.event) }.prefix(6)
                if items.isEmpty {
                    Text("还没有操作记录。").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, e in ActivityRow(entry: e) }
                    }
                }
            }
        }
    }
}

struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            trailing.controlSize(.small)
        }
    }
}

struct StepRow: View {
    var number: Int
    var title: String
    var detail: String
    var done: Bool
    var action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.18)).frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(done ? .secondary : .primary)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let action { Button(action.0, action: action.1).buttonStyle(.borderedProminent).controlSize(.regular) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

struct CapacityRow: View {
    var store: StoreRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: store.online ? "externaldrive.fill" : "externaldrive.badge.xmark")
                    .foregroundStyle(store.online ? Color.secondary : Color.orange)
                Text(store.volumeName ?? URL(fileURLWithPath: store.ref.path).lastPathComponent).font(.callout.weight(.medium))
                Spacer()
                if let free = store.freeBytes { Text("剩余 \(bytes(free))").font(.caption).foregroundStyle(.secondary) }
            }
            if let total = store.totalBytes, total > 0, let free = store.freeBytes {
                let devstore = store.imageBytes + store.archiveBytes
                let other = max(0, total - free - devstore)
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        Rectangle().fill(Color.accentColor).frame(width: max(devstore > 0 ? 2 : 0, geo.size.width * CGFloat(devstore) / CGFloat(total)))
                        Rectangle().fill(Color.secondary.opacity(0.45)).frame(width: geo.size.width * CGFloat(other) / CGFloat(total))
                        Rectangle().fill(Color.secondary.opacity(0.12))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .frame(height: 8)
                HStack(spacing: 12) {
                    Legend(color: .accentColor, text: "DevStore \(bytes(devstore))")
                    Legend(color: .secondary.opacity(0.45), text: "其他 \(bytes(other))")
                    Spacer()
                    Text(store.ref.path).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            } else {
                Text(store.online ? store.ref.path : "离线：\(store.ref.path)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct Legend: View {
    var color: Color
    var text: String
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }
}

struct ActivityRow: View {
    var entry: JournalEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ActivityStyle.symbol(entry.action))
                .foregroundStyle(entry.event == "committed" ? Color.accentColor : .red)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppModel.actionName(entry.action) + (entry.event == "committed" ? "" : "失败")).font(.callout)
                Text(ActivityStyle.relative(entry.at)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.transactionId.prefix(8)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
    }
}

struct EnvironmentCard: View {
    @Environment(AppModel.self) private var model
    var row: EnvRow
    var open: () -> Void

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    KindIcon(kind: row.status.kind, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.status.displayName).font(.headline).lineLimit(1)
                        Text("\(row.status.kind)/\(row.status.slot)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(row.stateColor).frame(width: 8, height: 8).padding(.top, 6).help(row.stateLabel)
                }
                Text(row.sdkLabel).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Badge(text: row.stateLabel, color: row.stateColor)
                    Badge(text: row.verificationLabel.0, color: row.verificationLabel.1)
                    Spacer()
                    Label(bytes(row.bundleBytes), systemImage: "internaldrive").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Button(row.status.mounted ? "卸载" : "挂载") { Task { await model.toggleMount(row) } }
                        .disabled(model.busy != nil || !row.status.storeOnline)
                    Spacer()
                    Button("打开") { open() }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
        .contentShape(.rect(cornerRadius: 18))
        .onTapGesture(count: 2) { open() }
    }
}
