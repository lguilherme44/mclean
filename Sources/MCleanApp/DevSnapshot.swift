import AppKit
import Quartz

/// Visual-QA hook, inert unless `MCLEAN_SNAPSHOT=<png>` is set. Waits for the state named in
/// `MCLEAN_SNAPSHOT_WHEN` (`ready` | `scanDone` | `lensDone`), renders the window itself to PNG
/// and quits. Rendering in-process needs no Screen Recording permission.
@MainActor
enum DevSnapshot {
    static func runIfRequested(model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["MCLEAN_SNAPSHOT"] else { return }
        let when = env["MCLEAN_SNAPSHOT_WHEN"] ?? "ready"
        // `light` | `dark`: check both themes regardless of the system setting.
        switch env["MCLEAN_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if let size = env["MCLEAN_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
           let window = NSApp.windows.first(where: \.isVisible) {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        for _ in 0..<600 {
            if reached(when, model: model) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // `MCLEAN_LENS_SELECT=name,name`: select those children; `MCLEAN_LENS_REVIEW=1`: open the review.
        if let names = env["MCLEAN_LENS_SELECT"]?.split(separator: ",").map(String.init) {
            model.lensSelection = Set(model.lensTrail.last?.children.filter { names.contains($0.name) }.map(\.path) ?? [])
        }
        if env["MCLEAN_LENS_REVIEW"] == "1" { model.requestLensReview(model.lensSelectedNodes) }
        if env["MCLEAN_ORPHANS_REVIEW"] == "1" { model.requestOrphanReview() }
        // `MCLEAN_UNINSTALL=<app name>`: open the uninstall review for that app.
        if let name = env["MCLEAN_UNINSTALL"], let row = model.appRows?.first(where: { $0.app.name == name }) {
            await model.requestUninstall(row)
        }
        // `MCLEAN_LENS_PREVIEW=1`: open Quick Look on the first selected item and report whether the
        // panel came up (its content is drawn by another process, so the PNG cannot show it).
        if env["MCLEAN_LENS_PREVIEW"] == "1", let first = model.lensSelectedNodes.first {
            model.lensPreview = URL(fileURLWithPath: first.path)
            try? await Task.sleep(for: .seconds(2))
            let visible = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
            let shown = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared().currentPreviewItem?.previewItemURL?.path ?? "-" : "-"
            FileHandle.standardError.write(Data("quicklook: visivel=\(visible) item=\(shown)\n".utf8))
        }
        // Render the key-window appearance (accent-colored prominent buttons), as the user sees it.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.isVisible)?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(600)) // let animations settle
        let window = NSApp.windows.first(where: \.isVisible)
        // A sheet is its own window: capture it when one is attached.
        guard let frameView = (window?.attachedSheet ?? window)?.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            FileHandle.standardError.write(Data("snapshot: sem janela\n".utf8))
            exit(2)
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
            exit(3)
        }
        exit(0)
    }

    private static func reached(_ when: String, model: AppModel) -> Bool {
        switch when {
        case "scanDone": if case .done = model.scan { return true } else { return false }
        case "lensDone": if case .done = model.lensPhase { return true } else { return false }
        case "nodeListed": return model.nodeCandidates != nil && !model.isSearchingNodeModules
        case "appsDone": return model.appRows?.allSatisfy { $0.appBytes != nil } ?? false
        case "orphansDone": return model.orphanRows != nil
        case "hibernateReady": return model.appRows?.allSatisfy { $0.appBytes != nil } ?? false
        case "nodeDone": return model.nodeCandidates != nil && !model.isSearchingNodeModules && model.nodeMeasuring.isEmpty
        default: return true
        }
    }
}
