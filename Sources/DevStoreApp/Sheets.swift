import AppKit
import DevStoreCore
import SwiftUI
import UniformTypeIdentifiers

/// Shows a plan exactly as the core recorded it; approving here creates the grant.
struct PlanSheet: View {
    @Environment(AppModel.self) private var model
    var plan: Plan
    var fromAgent: Bool
    @State private var passphrase = ""
    @State private var repeatPassphrase = ""

    var encrypted: Bool { plan.targets["encryption"] == "aes256" }
    var passphraseOK: Bool { !encrypted || (passphrase.count >= 8 && passphrase == repeatPassphrase) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(AppModel.actionName(plan.action))计划").font(.title2.bold())
                Badge(text: AppModel.levelName(plan.level), color: plan.level == .destructive ? .red : (plan.level == .mutate ? .orange : .blue))
                Spacer()
                Text(plan.planId.prefix(8)).monospaced().foregroundStyle(.secondary)
            }
            if fromAgent {
                Label("这个计划由 Agent 或命令行生成。批准后它可以执行一次，10 分钟内有效。", systemImage: "person.badge.shield.checkmark")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if plan.level == .destructive {
                Label("破坏性操作：需要 Touch ID 或登录密码。环境目录会被移到废纸篓。", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    group("目标", plan.targets.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }, "scope")
                    group("前置条件（生成时全部满足，执行前会重新检查）", plan.preconditions, "checkmark.circle")
                    group("将会", plan.effects, "arrow.right.circle")
                    group("不会触碰", plan.notTouched, "hand.raised")
                    Text("摘要 \(plan.planDigest)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if encrypted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("加密口令（至少 8 个字符）。DevStore 不保存口令，遗失后无法打开归档。", systemImage: "key.fill")
                        .font(.callout).foregroundStyle(.orange)
                    HStack {
                        SecureField("口令", text: $passphrase)
                        SecureField("再输一次", text: $repeatPassphrase)
                    }
                    if !passphrase.isEmpty && !passphraseOK {
                        Text(passphrase.count < 8 ? "口令太短" : "两次输入不一致").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            HStack {
                if fromAgent {
                    Button("拒绝", role: .destructive) { Task { await model.reject(plan) } }
                }
                Spacer()
                Button("取消") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                if fromAgent && !encrypted {
                    Button("仅批准") { Task { await model.approve(plan, execute: false) } }
                        .help("交给 Agent 用 devstore_apply 执行")
                }
                Button(plan.level == .destructive ? "验证身份并执行" : "批准并执行") {
                    let secret = encrypted ? passphrase : nil
                    Task { await model.approve(plan, execute: true, passphrase: secret) }
                }
                .buttonStyle(.borderedProminent)
                .tint(plan.level == .destructive ? .red : .accentColor)
                .disabled(!passphraseOK)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }

    func group(_ title: String, _ items: [String], _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ForEach(items, id: \.self) { Label($0, systemImage: icon).font(.callout).textSelection(.enabled) }
        }
    }
}

struct StorePicker: View {
    @Environment(AppModel.self) private var model
    @Binding var storeId: String
    var body: some View {
        Picker("存储库", selection: $storeId) {
            ForEach(model.snapshot.stores.filter(\.online)) { s in Text(s.ref.path).tag(s.ref.storeId) }
        }
        .onAppear { if storeId.isEmpty { storeId = model.snapshot.stores.first(where: \.online)?.ref.storeId ?? "" } }
    }
}

struct CreateSheet: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var kind = ""
    @State private var slot = "current"
    @State private var size = 20
    @State private var storeId = ""

    var valid: Bool { !name.isEmpty && Adapters.validName(kind) && Adapters.validName(slot) && !storeId.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建空环境").font(.title2.bold())
            Text("创建一个空的可写 APFS 卷，按需增长。挂载后在 ~/.local/dev/<类型>/<槽位> 安装你需要的工具。")
                .foregroundStyle(.secondary)
            Form {
                TextField("名称", text: $name, prompt: Text("例如 Go 1.25"))
                TextField("类型", text: $kind, prompt: Text("小写，例如 go、rust、dotnet"))
                TextField("槽位", text: $slot)
                Stepper("最大容量：\(size) GiB", value: $size, in: 1...2048, step: size < 10 ? 1 : 5)
                StorePicker(storeId: $storeId)
                if !kind.isEmpty {
                    LabeledContent("挂载路径") {
                        Text(model.library.paths.slotPath(kind: kind, slot: slot)).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("生成计划…") {
                    let (store, k, sl, n, sz) = (storeId, kind, slot, name, size)
                    Task { await model.prepare("正在生成计划…") { try $0.planCreate(storeQuery: store, kind: k, slot: sl, name: n, sizeGiB: sz) } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!valid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @State private var source: URL?
    @State private var name = ""
    @State private var slot = "current"
    @State private var storeId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入映像").font(.title2.bold())
            Text("把一个未挂载的 .sparsebundle 以 APFS 克隆方式导入存储库，原映像不会被修改。目前只支持 Miniconda，且映像必须是为所选槽位路径构建的。")
                .foregroundStyle(.secondary)
            Form {
                LabeledContent("映像") {
                    HStack {
                        Text(source?.path ?? "未选择").lineLimit(1).truncationMode(.middle)
                        Button("选择…") { choose() }
                    }
                }
                TextField("名称", text: $name)
                TextField("槽位", text: $slot)
                LabeledContent("类型") { Text("miniconda") }
                StorePicker(storeId: $storeId)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("生成计划…") {
                    let (src, sl, n, store) = (source!.path, slot, name, storeId)
                    Task { await model.prepare("正在生成计划…") { try $0.planImport(source: src, storeQuery: store, kind: "miniconda", slot: sl, name: n) } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(source == nil || name.isEmpty || storeId.isEmpty || !Adapters.validName(slot))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sparsebundle") ?? .item]
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK { source = panel.url }
    }
}

struct InstallSDKSheet: View {
    @Environment(AppModel.self) private var model
    var environmentId: String
    @State private var installer: URL?
    @State private var sha256 = ""

    var header: [String: String] { installer.map { Operations.installerHeader($0.path) } ?? [:] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("写入 SDK").font(.title2.bold())
            Text("在卷内以批处理模式安装 Miniconda（不运行 conda init，不修改 shell 配置）。安装器在沙箱中运行：禁网、不能读原安装、只能写这个卷。")
                .foregroundStyle(.secondary)
            Form {
                LabeledContent("安装器") {
                    HStack {
                        Text(installer?.lastPathComponent ?? "未选择").lineLimit(1).truncationMode(.middle)
                        Button("选择…") { choose() }
                    }
                }
                if installer != nil {
                    LabeledContent("版本") { Text("\(header["NAME"] ?? "?") \(header["VER"] ?? "?") · \(header["PLAT"] ?? "?")") }
                }
                TextField("官方公布的 SHA-256", text: $sha256, prompt: Text("从 repo.anaconda.com/miniconda 复制"))
                    .monospaced()
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("生成计划…") {
                    let (id, path, sum) = (environmentId, installer!.path, sha256.trimmingCharacters(in: .whitespaces))
                    Task { await model.prepare("正在核对安装器…") { try $0.planInstallSDK(id, installer: path, sha256: sum) } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(installer == nil || sha256.trimmingCharacters(in: .whitespaces).count != 64)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sh") ?? .item]
        if panel.runModal() == .OK { installer = panel.url }
    }
}

struct ArchiveSheet: View {
    @Environment(AppModel.self) private var model
    var environmentId: String
    @State private var encrypt = false
    @State private var lzma = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill").font(.title).foregroundStyle(.orange)
                Text("压缩归档").font(.title2.bold())
            }
            Text("把卸载状态的环境转换成压缩的只读磁盘映像，存入存储库的 checkpoints/。原映像不变。之后可以导出到冷备份位置。")
                .foregroundStyle(.secondary)
            Form {
                Toggle("AES-256 加密", isOn: $encrypt)
                Toggle("使用 LZMA（更小、更慢；默认 LZFSE）", isOn: $lzma)
                if encrypt {
                    Text("口令在批准执行时输入，不会被保存。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("生成计划…") {
                    let (id, e, l) = (environmentId, encrypt, lzma)
                    Task { await model.prepare("正在生成归档计划…") { try $0.planArchive(id, encrypt: e, format: l ? "ULMO" : "ULFO") } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
