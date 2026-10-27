import AppKit
import SwiftUI

@main
struct MCleanApp: App {
    @State private var model = AppModel()

    init() {
        // Lets `swift run MCleanApp` show a real window and Dock icon outside the .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("MClean", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 580)
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Analisar o Mac") { Task { await model.runScan() } }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
            }
        }
    }
}
