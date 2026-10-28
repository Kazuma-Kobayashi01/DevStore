import AppKit
import SwiftUI

@main
struct DevStoreApp: App {
    @State private var model = AppModel()

    init() {
        // Also behave as a regular app when launched as a bare executable (swift run).
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("DevStore") {
            ContentView()
                .environment(model)
                .frame(minWidth: 920, minHeight: 580)
                .task { model.start() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建空环境…") { model.sheet = .create }.keyboardShortcut("n")
                Button("导入映像…") { model.sheet = .importImage }.keyboardShortcut("i")
            }
            CommandGroup(after: .toolbar) {
                Button("刷新") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
        }
    }
}
