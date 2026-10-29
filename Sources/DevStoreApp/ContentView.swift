import DevStoreCore
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case environment(String)
    case pending
    case archives
    case stores
    case journal
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $selection) {
                NavigationLink(value: SidebarItem.overview) { Label("总览", systemImage: "square.grid.2x2") }
                Section("环境") {
                    if model.snapshot.environments.isEmpty {
                        Text("无").foregroundStyle(.tertiary).font(.callout)
                    }
                    ForEach(model.snapshot.environments) { row in
                        NavigationLink(value: SidebarItem.environment(row.id)) {
                            HStack(spacing: 9) {
                                KindIcon(kind: row.status.kind, size: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.status.displayName).lineLimit(1)
                                    Text("\(row.status.kind)/\(row.status.slot)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Circle().fill(row.stateColor).frame(width: 7, height: 7).help(row.stateLabel)
                            }
                        }
                    }
                }
                Section("管理") {
                    NavigationLink(value: SidebarItem.pending) { Label("待批准计划", systemImage: "checkmark.shield") }
                        .badge(model.snapshot.pending.filter { $0.state == .pending }.count)
                    NavigationLink(value: SidebarItem.archives) { Label("归档", systemImage: "archivebox") }
                        .badge(model.snapshot.checkpoints.count)
                    NavigationLink(value: SidebarItem.stores) { Label("存储库", systemImage: "externaldrive") }
                    NavigationLink(value: SidebarItem.journal) { Label("事务日志", systemImage: "list.bullet.rectangle") }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 230, ideal: 250)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            switch selection {
            case .overview, nil: OverviewView { selection = $0 }
            case let .environment(id):
                if let row = model.row(id) { EnvironmentDetailView(row: row) } else { ContentUnavailableView("环境已移除", systemImage: "tray") }
            case .pending: PendingPlansView()
            case .archives: ArchivesView()
            case .stores: StoresView()
            case .journal: JournalView()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if let busy = model.busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busy).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 6)
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
            case let .archive(id): ArchiveSheet(environmentId: id)
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
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(notice).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.notice)
    }
}

struct Badge: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule()).foregroundStyle(color)
    }
}

func bytes(_ n: Int64?) -> String {
    n.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
}

/// Host summary pinned to the bottom of the sidebar.
struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    static var hostLine: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) · \(HostBinding.current().arch)"
    }
    var body: some View {
        let online = model.snapshot.stores.filter(\.online).count
        HStack(spacing: 8) {
            Circle().fill(online > 0 ? Color.green : Color.orange).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(online > 0 ? "\(online) 个存储库在线" : "没有在线存储库").font(.caption.weight(.medium))
                Text(Self.hostLine)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
