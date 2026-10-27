import AppKit
import CleanerCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Page.allCases, selection: $model.page) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { SidebarDiskFooter() }
        } detail: {
            switch model.page {
            case .overview: OverviewView()
            case .cleanup: CleanupView()
            case .spaceLens: SpaceLensView()
            case .nodeModules: NodeModulesView()
            case .uninstaller: UninstallerView()
            case .hibernate: HibernateView()
            }
        }
        .alert("Algo deu errado", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.hasFullDiskAccess = Permissions.hasFullDiskAccess
        }
        .task {
            await model.refreshDisk()
            // Development hooks: open a page and/or start a scan straight away (visual QA).
            let env = ProcessInfo.processInfo.environment
            if let raw = env["MCLEAN_PAGE"], let page = Page(rawValue: raw) { model.page = page }
            if let root = env["MCLEAN_LENS_ROOT"] { model.scanLens(root: root) }
            Task { await DevSnapshot.runIfRequested(model: model) }
            if env["MCLEAN_AUTOSCAN"] == "1" { await model.runScan() }
            if env["MCLEAN_NODE_SEARCH"] == "1" { await model.findNodeModules() }
        }
    }
}

private struct SidebarDiskFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let disk = model.disk {
            VStack(alignment: .leading, spacing: 6) {
                CapacityBar(used: disk.totalBytes - disk.freeBytes, total: disk.totalBytes)
                Text("\(formatBytes(disk.freeBytes)) livres")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(12)
        }
    }
}
