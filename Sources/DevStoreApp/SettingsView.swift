import AppKit
import DevStoreCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
            AgentSettings().tabItem { Label("Agent", systemImage: "cpu") }
            AboutSettings().tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 380)
    }
}

struct PathRow: View {
    var title: String
    var path: String
    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(path).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
            }
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section("位置") {
                PathRow(title: "主机登记", path: model.library.paths.hostRoot.path)
                PathRow(title: "挂载根目录", path: model.library.paths.slotRoot.path)
                ForEach(model.snapshot.stores) { s in PathRow(title: "存储库", path: s.ref.path) }
            }
            Section("刷新") {
                LabeledContent("自动刷新") { Text("每 4 秒") }
                Text("状态、待批准计划和日志都直接读取磁盘上的记录，CLI 与 Agent 的改动会自动出现在这里。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AgentSettings: View {
    var helpers: String { Bundle.main.bundlePath + "/Contents/Helpers" }
    var command: String { "claude mcp add devstore -- \"\(helpers)/devstore-mcp\"" }

    var body: some View {
        Form {
            Section("MCP Server") {
                Text("把 DevStore 注册为 Claude Code 的 MCP Server，Agent 即可查看环境、生成计划、在环境中运行命令。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(command).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
            }
            Section("命令行") {
                PathRow(title: "devstore", path: helpers + "/devstore")
            }
            Section("授权") {
                Label("Agent 只能生成计划，批准始终由你在这里或终端完成。", systemImage: "hand.raised")
                Label("删除等破坏性操作还需要 Touch ID 或登录密码。", systemImage: "touchid")
                Label("加密归档的口令只在执行时输入，不会保存。", systemImage: "key")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("DevStore").font(.title.bold())
            Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                .foregroundStyle(.secondary)
            Text("把每个开发环境放进独立的可写 APFS 卷：固定路径挂载、按需回收空间、压缩归档与冷备份。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
