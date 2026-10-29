import AppKit
import DevStoreCore
import ServiceManagement
import SwiftUI

/// Menu bar icon: filled when every environment is mounted, outlined otherwise.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let envs = model.snapshot.environments
        let mounted = envs.filter { $0.status.mounted }.count
        Image(systemName: envs.isEmpty || mounted < envs.count ? "square.stack.3d.up" : "square.stack.3d.up.fill")
            .task { model.start() }
            .help("DevStore：\(mounted)/\(envs.count) 已挂载")
    }
}

/// Popover shown from the menu bar: environments with quick mount/eject, pending plans, storage.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var expanded: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var envs: [EnvRow] { model.snapshot.environments }
    var mounted: Int { envs.filter { $0.status.mounted }.count }
    var pending: Int { model.snapshot.pending.filter { $0.state == .pending }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = model.errorMessage { banner(error, symbol: "exclamationmark.triangle.fill", tint: .red) { model.errorMessage = nil } }
                    if let notice = model.notice { banner(notice, symbol: "checkmark.circle.fill", tint: .green) { model.notice = nil } }
                    if pending > 0 { pendingRow }
                    sectionTitle("环境")
                    if envs.isEmpty {
                        Text("还没有环境").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                    VStack(spacing: 6) {
                        ForEach(envs) { row in EnvironmentMenuRow(row: row, expanded: $expanded) }
                    }
                    if !model.snapshot.stores.isEmpty {
                        sectionTitle("存储库")
                        VStack(spacing: 10) {
                            ForEach(model.snapshot.stores) { s in CapacityRow(store: s) }
                        }
                        .padding(10)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 520)
            Divider()
            footer
        }
        .frame(width: 380)
    }

    // MARK: parts

    var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("DevStore").font(.headline)
                Text(envs.isEmpty ? "尚无环境" : "\(mounted)/\(envs.count) 已挂载 · \(bytes(envs.compactMap(\.bundleBytes).reduce(0, +)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let busy = model.busy {
                ProgressView().controlSize(.small).help(busy)
            }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("刷新")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    func sectionTitle(_ t: String) -> some View {
        Text(t).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
    }

    var pendingRow: some View {
        Button { openMain() } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.orange)
                Text("\(pending) 个计划等待批准").font(.callout)
                Spacer()
                Text("打开").font(.callout).foregroundStyle(.tint)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    func banner(_ text: String, symbol: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.caption).lineLimit(4).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption) }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Button { Task { await model.mountAll() } } label: { Label("全部挂载", systemImage: "externaldrive.fill.badge.plus") }
                    .disabled(model.busy != nil || mounted == envs.count)
                Button { Task { await model.unmountAll() } } label: { Label("全部弹出", systemImage: "eject.fill") }
                    .disabled(model.busy != nil || mounted == 0)
                Spacer()
            }
            .controlSize(.small)
            HStack {
                Toggle("登录时启动", isOn: Binding(get: { launchAtLogin }, set: { on in setLaunchAtLogin(on) }))
                    .toggleStyle(.switch).controlSize(.mini).font(.caption)
                Spacer()
                Button { openMain() } label: { Label("打开 DevStore", systemImage: "macwindow") }
                    .buttonStyle(.borderless).font(.caption)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help("退出 DevStore")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            model.errorMessage = "无法\(on ? "开启" : "关闭")登录时启动：\(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct EnvironmentMenuRow: View {
    @Environment(AppModel.self) private var model
    var row: EnvRow
    @Binding var expanded: String?
    @State private var hovering = false

    var isOpen: Bool { expanded == row.id }
    var s: EnvironmentStatus { row.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                KindIcon(kind: s.kind, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.displayName).font(.callout.weight(.medium)).lineLimit(1)
                    Text("\(s.kind)/\(s.slot) · \(bytes(row.bundleBytes))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(row.stateColor).frame(width: 7, height: 7).help(row.stateLabel)
                Button { Task { await model.toggleMount(row) } } label: {
                    Image(systemName: s.mounted ? "eject.fill" : "externaldrive.fill.badge.plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(model.busy != nil || !s.storeOnline)
                .help(s.mounted ? "弹出（不强制）" : "挂载")
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded = isOpen ? nil : row.id } }

            if isOpen { details.transition(.opacity) }
        }
        .padding(10)
        .background(hovering || isOpen ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
    }

    var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            detail("状态", row.stateLabel)
            detail("验证", s.lastVerification.map { "\($0.passed)/\($0.total) · \($0.at.prefix(16))" } ?? row.verificationLabel.0)
            detail("SDK", row.sdkLabel)
            detail("挂载点", s.slotPath)
            detail("卷 UUID", s.volumeUUID ?? "—")
            if let lease = s.lease { detail("租约", "\(lease.hostId.prefix(8)) · \(lease.mountedAt.prefix(16))") }
            GridRow {
                Text("")
                HStack(spacing: 12) {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.mounted ? s.slotPath : (row.bundlePath ?? s.slotPath))])
                    }
                    Button("复制环境变量") { Task { await model.copySessionEnvironment(row) } }
                        .disabled(s.identityVerified != true)
                }
                .buttonStyle(.link).font(.caption)
            }
        }
        .font(.caption)
        .padding(.leading, 40)
    }

    func detail(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }
}
