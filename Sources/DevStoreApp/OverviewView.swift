import DevStoreCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    var open: (SidebarItem) -> Void

    var envs: [EnvRow] { model.snapshot.environments }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("开发环境").font(.largeTitle.bold())
                    Text("每个环境是一个可写 APFS 卷，挂载在 ~/.local/dev/<类型>/<槽位>。")
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    StatTile(title: "环境", value: "\(envs.count)", symbol: "square.stack.3d.up.fill", tint: .blue)
                    StatTile(title: "已挂载", value: "\(envs.filter { $0.status.mounted }.count)", symbol: "externaldrive.fill.badge.checkmark", tint: .green)
                    StatTile(title: "映像占用", value: bytes(envs.compactMap(\.bundleBytes).reduce(0, +)), symbol: "internaldrive.fill", tint: .purple)
                    StatTile(title: "归档", value: "\(model.snapshot.checkpoints.count)", symbol: "archivebox.fill", tint: .orange)
                }

                if !model.snapshot.pending.isEmpty {
                    Button { open(.pending) } label: {
                        Card {
                            HStack {
                                Image(systemName: "checkmark.shield.fill").font(.title2).foregroundStyle(.orange)
                                VStack(alignment: .leading) {
                                    Text("\(model.snapshot.pending.count) 个计划等待你的批准").font(.headline)
                                    Text("Agent 或命令行生成的改动，批准前不会执行。").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Text("环境").font(.title3.bold())
                    Spacer()
                    Button { model.sheet = .create } label: { Label("新建空环境", systemImage: "plus") }
                        .disabled(model.snapshot.stores.isEmpty)
                }
                if envs.isEmpty {
                    Card {
                        ContentUnavailableView("还没有环境", systemImage: "square.stack.3d.up.slash",
                                               description: Text(model.snapshot.stores.isEmpty
                                                                 ? "先在“存储库”登记一个文件夹，再新建环境。"
                                                                 : "点“新建空环境”创建第一个环境。"))
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(envs) { row in
                            EnvironmentCard(row: row) { open(.environment(row.id)) }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle("总览")
    }
}

struct EnvironmentCard: View {
    @Environment(AppModel.self) private var model
    var row: EnvRow
    var open: () -> Void

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    KindIcon(kind: row.status.kind, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.status.displayName).font(.headline).lineLimit(1)
                        Text("\(row.status.kind)/\(row.status.slot)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(row.sdkLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                HStack(spacing: 6) {
                    Badge(text: row.stateLabel, color: row.stateColor)
                    Badge(text: row.verificationLabel.0, color: row.verificationLabel.1)
                    Spacer()
                    Text(bytes(row.bundleBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack {
                    Button(row.status.mounted ? "卸载" : "挂载") { Task { await model.toggleMount(row) } }
                        .disabled(model.busy != nil || !row.status.storeOnline)
                    Spacer()
                    Button("详情") { open() }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
    }
}
