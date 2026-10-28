import AppKit
import DevStoreCore
import SwiftUI

struct PendingPlansView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.snapshot.pending.isEmpty {
                ContentUnavailableView("没有待批准的计划", systemImage: "checkmark.shield",
                                       description: Text("Agent 通过 MCP 或命令行生成的计划会出现在这里，由你批准或拒绝。"))
            } else {
                List(model.snapshot.pending, id: \.plan.planId) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(AppModel.actionName(entry.plan.action)).font(.headline)
                                Badge(text: AppModel.levelName(entry.plan.level),
                                      color: entry.plan.level == .destructive ? .red : (entry.plan.level == .mutate ? .orange : .blue))
                                if entry.state == .approved { Badge(text: "已批准，等待执行", color: .green) }
                            }
                            Text(target(entry.plan)).foregroundStyle(.secondary)
                            Text("\(entry.plan.planId.prefix(8)) · \(entry.plan.createdAt)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("查看…") { model.sheet = .plan(entry.plan, fromAgent: true) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("待批准计划")
    }

    func target(_ p: Plan) -> String {
        let t = p.targets
        if let kind = t["kind"], let slot = t["slot"] { return "\(t["displayName"].map { $0 + " · " } ?? "")\(kind)/\(slot)" }
        return t["slotPath"] ?? t["environmentId"] ?? ""
    }
}

struct StoresView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading) {
            if model.snapshot.stores.isEmpty {
                ContentUnavailableView("还没有存储库", systemImage: "externaldrive.badge.plus",
                                       description: Text("存储库是保存环境映像的文件夹，可以在内置盘或外置 SSD 上。"))
            } else {
                Table(model.snapshot.stores) {
                    TableColumn("状态") { s in Badge(text: s.online ? "在线" : "离线", color: s.online ? .green : .orange) }.width(60)
                    TableColumn("路径") { s in Text(s.ref.path).textSelection(.enabled) }
                    TableColumn("环境") { s in Text("\(s.environments)") }.width(50)
                    TableColumn("ID") { s in Text(s.ref.storeId.prefix(8)).monospaced() }.width(90)
                    TableColumn("") { s in
                        Button("显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.ref.path)]) }
                            .disabled(!s.online)
                    }.width(60)
                }
            }
        }
        .toolbar {
            Button { addStore() } label: { Label("登记存储库", systemImage: "folder.badge.plus") }
        }
        .navigationTitle("存储库")
    }

    func addStore() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "登记"
        panel.message = "选择一个文件夹作为存储库；如果它还不是存储库，会在其中创建 store.json。"
        if panel.runModal() == .OK, let url = panel.url { Task { await model.addStore(url) } }
    }
}

struct JournalView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Table(model.snapshot.journal.indices.map { IndexedEntry(index: $0, entry: model.snapshot.journal[$0]) }) {
            TableColumn("时间") { Text($0.entry.at) }.width(min: 150, ideal: 170)
            TableColumn("事务") { Text($0.entry.transactionId.prefix(8)).monospaced() }.width(80)
            TableColumn("动作") { Text(AppModel.actionName($0.entry.action)) }.width(70)
            TableColumn("事件") { e in
                Text(e.entry.event + (e.entry.step.map { " · \($0)" } ?? ""))
                    .foregroundStyle(e.entry.event == "failed" || e.entry.event == "rolledBack" ? .red : .primary)
            }.width(min: 120, ideal: 150)
            TableColumn("详情") { Text($0.entry.detail ?? "").textSelection(.enabled).lineLimit(2) }
        }
        .navigationTitle("事务日志")
    }

    struct IndexedEntry: Identifiable {
        var index: Int
        var entry: JournalEntry
        var id: Int { index }
    }
}
