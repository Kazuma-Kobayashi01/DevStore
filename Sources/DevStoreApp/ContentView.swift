import DevStoreCore
import SwiftUI

enum SidebarItem: Hashable {
    case environment(String)
    case pending
    case stores
    case journal
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .pending

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $selection) {
                Section("环境") {
                    if model.snapshot.environments.isEmpty {
                        Text("还没有环境").foregroundStyle(.secondary)
                    }
                    ForEach(model.snapshot.environments) { row in
                        NavigationLink(value: SidebarItem.environment(row.id)) {
                            HStack {
                                StateDot(row: row)
                                VStack(alignment: .leading) {
                                    Text(row.status.displayName)
                                    Text("\(row.status.kind)/\(row.status.slot)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section("管理") {
                    NavigationLink(value: SidebarItem.pending) {
                        Label("待批准计划", systemImage: "checkmark.shield")
                    }
                    .badge(model.snapshot.pending.filter { $0.state == .pending }.count)
                    NavigationLink(value: SidebarItem.stores) { Label("存储库", systemImage: "externaldrive") }
                    NavigationLink(value: SidebarItem.journal) { Label("事务日志", systemImage: "list.bullet.rectangle") }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            switch selection {
            case let .environment(id):
                if let row = model.row(id) { EnvironmentDetailView(row: row) } else { ContentUnavailableView("环境已移除", systemImage: "tray") }
            case .pending, nil: PendingPlansView()
            case .stores: StoresView()
            case .journal: JournalView()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                }
                Button { model.sheet = .create } label: { Label("新建空环境", systemImage: "plus.rectangle.on.folder") }
                    .disabled(model.snapshot.stores.isEmpty)
                    .help(model.snapshot.stores.isEmpty ? "请先登记一个存储库" : "新建空环境")
                Button { model.sheet = .importImage } label: { Label("导入映像", systemImage: "square.and.arrow.down") }
                    .disabled(model.snapshot.stores.isEmpty)
                Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .create: CreateSheet()
            case .importImage: ImportSheet()
            case let .installSDK(id): InstallSDKSheet(environmentId: id)
            case let .plan(plan, fromAgent): PlanSheet(plan: plan, fromAgent: fromAgent)
            }
        }
        .alert("操作失败", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .safeAreaInset(edge: .bottom) {
            if let notice = model.notice {
                HStack {
                    Image(systemName: "info.circle")
                    Text(notice).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("关闭") { model.notice = nil }.buttonStyle(.borderless)
                }
                .padding(10)
                .background(.thinMaterial)
            }
        }
    }
}

struct StateDot: View {
    var row: EnvRow
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9).help(label)
    }
    var color: Color {
        if !row.status.storeOnline { return .orange }
        if row.status.mounted { return row.status.identityVerified == true ? .green : .red }
        return .secondary
    }
    var label: String {
        if !row.status.storeOnline { return "存储库离线" }
        if row.status.mounted { return row.status.identityVerified == true ? "已挂载" : "已挂载（身份未核实）" }
        return "未挂载"
    }
}

struct Badge: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }
}

func bytes(_ n: Int64?) -> String {
    n.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
}
