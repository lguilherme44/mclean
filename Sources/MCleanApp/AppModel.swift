import AppKit
import CleanerCore
import Foundation
import Observation

enum Page: String, CaseIterable, Identifiable {
    case overview, cleanup, spaceLens, nodeModules, uninstaller, hibernate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Visão geral"
        case .cleanup: "Limpeza"
        case .spaceLens: "Space Lens"
        case .nodeModules: "node_modules"
        case .uninstaller: "Desinstalar apps"
        case .hibernate: "Hibernar apps"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "internaldrive"
        case .cleanup: "sparkles"
        case .spaceLens: "square.grid.3x3.square"
        case .nodeModules: "shippingbox"
        case .uninstaller: "trash.square"
        case .hibernate: "moon.zzz"
        }
    }
}

/// Owns every long-running operation. Work runs off the main actor in detached tasks;
/// only finished, Sendable results come back here, so the UI never blocks on the disk.
@MainActor @Observable
final class AppModel {
    var page: Page = .overview
    var disk: DiskStatus?
    var errorMessage: String?

    // MARK: Cleanup

    enum ScanPhase {
        case idle
        case scanning(step: String)
        case done([RuleResult])
    }

    var scan: ScanPhase = .idle
    var selection: Set<String> = []
    var isCleaning = false
    var lastReport: CleanReport?

    var results: [RuleResult] {
        if case let .done(results) = scan { return results }
        return []
    }

    var selectedResults: [RuleResult] { results.filter { selection.contains($0.rule.id) } }
    var selectedBytes: Int64 { selectedResults.reduce(0) { $0 + $1.bytes } }

    /// Re-checked on every disk refresh and when the app comes back to the front (the user may
    /// have just granted it in System Settings).
    var hasFullDiskAccess = Permissions.hasFullDiskAccess

    let historyStore = HistoryStore()
    var history = History()

    /// Every disk measurement is also a history point (throttled to one per hour by `History`).
    func refreshDisk() async {
        let store = historyStore
        let (status, history) = await Task.detached { () -> (DiskStatus, History) in
            let status = DiskStatus.current()
            return (status, store.recordSample(status))
        }.value
        disk = status
        self.history = history
        hasFullDiskAccess = Permissions.hasFullDiskAccess
    }

    /// `freedByVolume` must be MEASURED (df delta), never the estimate: the forecast subtracts it.
    func recordCleanup(source: String, freedByVolume: [String: Int64], items: [String]) async {
        let store = historyStore
        let (status, history) = await Task.detached { () -> (DiskStatus, History) in
            let status = DiskStatus.current()
            return (status, store.recordCleanup(source: source, freedByVolume: freedByVolume, items: items, status: status))
        }.value
        disk = status
        self.history = history
    }

    func runScan() async {
        guard !isScanning else { return }
        let rules: [Rule]
        do {
            rules = try RuleSet.loadDefault()
        } catch {
            errorMessage = "Regras inválidas: \(error)"
            return
        }
        scan = .scanning(step: "Preparando…")
        let results = await Task.detached {
            Scanner().scan(rules) { rule in
                let name = rule.name
                // The model lives as long as the app, so a strong capture is fine.
                Task { @MainActor in
                    if case .scanning = self.scan { self.scan = .scanning(step: name) }
                }
            }
        }.value
        scan = .done(results)
        selection = Set(results.filter(Self.isSelectedByDefault).map(\.rule.id))
    }

    var isScanning: Bool {
        if case .scanning = scan { return true }
        return false
    }

    /// Pre-selected: only what is safe, actionable and non-empty.
    static func isSelectedByDefault(_ result: RuleResult) -> Bool {
        result.rule.safety == .safe && isSelectable(result)
            && (result.bytes > 0 || result.rule.paths.isEmpty)
    }

    static func isSelectable(_ result: RuleResult) -> Bool {
        if case .report = result.rule.action { return false }
        return result.runningBlockers.isEmpty && result.missingTool == nil && !result.timedOut
    }

    func clean() async {
        // Apps may have opened since the scan: re-check blockers right before deleting.
        let selected = selectedResults
        isCleaning = true
        let report = await Task.detached {
            Cleaner().clean(selected.map { $0.refreshingBlockers() }, dryRun: false)
        }.value
        isCleaning = false
        lastReport = report
        let cleaned = report.outcomes.filter { [.cleaned, .partial].contains($0.status) }.map(\.ruleID)
        if !cleaned.isEmpty {
            await recordCleanup(source: "Limpeza", freedByVolume: report.measuredFreedBytes, items: cleaned)
        } else {
            await refreshDisk()
        }
        await runScan()
    }

    // MARK: Space Lens

    enum LensPhase {
        case idle
        case scanning(files: Int, path: String)
        case done
    }

    var lensPhase: LensPhase = .idle
    /// Trail from the scanned root to the directory on screen.
    var lensTrail: [SpaceNode] = []
    private var lensTask: Task<Void, Never>?

    func scanLens(root: String) {
        lensTask?.cancel()
        lensPhase = .scanning(files: 0, path: root)
        lensTask = Task {
            let node = await Task.detached {
                SpaceLens.scan(root: root, depth: 3, isCancelled: { Task.isCancelled }) { progress in
                    Task { @MainActor in
                        if case .scanning = self.lensPhase {
                            self.lensPhase = .scanning(files: progress.files, path: progress.currentPath)
                        }
                    }
                }
            }.value
            guard !Task.isCancelled else { return }
            if let node {
                // Replace the tail when re-scanning a directory already in the trail.
                if let index = lensTrail.firstIndex(where: { $0.path == node.path }) {
                    lensTrail = Array(lensTrail[..<index]) + [node]
                } else if let last = lensTrail.last, node.path.hasPrefix(last.path + "/") {
                    lensTrail.append(node)
                } else {
                    lensTrail = [node]
                }
                lensPhase = .done
                await refreshLensVolume()
            } else {
                errorMessage = "Não foi possível ler \(root)."
                lensPhase = lensTrail.isEmpty ? .idle : .done
            }
        }
    }

    struct LensVolume: Sendable {
        let name: String
        let status: DiskStatus
    }

    /// Capacity of the volume holding the scanned folder: the indicator follows the folder, not `/`.
    var lensVolume: LensVolume?

    func refreshLensVolume() async {
        guard let root = lensTrail.first?.path else { return }
        // Same moment for the sidebar: two different "free" numbers on screen read as a bug.
        await refreshDisk()
        lensVolume = await Task.detached { () -> LensVolume? in
            guard let volume = Cleaner.volume(of: root) else { return nil }
            let name = (try? URL(fileURLWithPath: volume).resourceValues(forKeys: [.volumeLocalizedNameKey]))?
                .volumeLocalizedName ?? volume
            return LensVolume(name: name, status: DiskStatus.current(volume: volume))
        }.value
    }

    func cancelLens() {
        lensTask?.cancel()
        lensPhase = lensTrail.isEmpty ? .idle : .done
    }

    func open(_ node: SpaceNode) {
        guard node.isDirectory else { return }
        if node.children.isEmpty && node.isTruncated {
            scanLens(root: node.path)
        } else {
            lensTrail.append(node)
        }
    }

    func goBack(to node: SpaceNode) {
        guard let index = lensTrail.firstIndex(of: node) else { return }
        lensTrail = Array(lensTrail[...index])
    }

    /// Paths selected in the current folder; cleared whenever the folder changes.
    var lensSelection: Set<String> = []

    var lensSelectedNodes: [SpaceNode] {
        lensTrail.last?.children.filter { lensSelection.contains($0.path) } ?? []
    }

    struct ReviewRequest: Identifiable {
        let id = UUID()
        let plan: DeletionPlan
    }

    /// Item shown in Quick Look, if any.
    var lensPreview: URL?

    /// Open review sheet, if any. Removal only ever happens from that sheet.
    var lensReview: ReviewRequest?

    func requestLensReview(_ nodes: [SpaceNode]) {
        guard !nodes.isEmpty else { return }
        lensReview = ReviewRequest(plan: DeletionPlanner.plan(nodes))
    }

    /// Trashes the plan (reversible) and removes every success from each level of the trail.
    func executeDeletion(_ plan: DeletionPlan) -> [DeletionPlanner.Outcome] {
        let outcomes = DeletionPlanner.execute(plan)
        for outcome in outcomes where outcome.error == nil {
            lensTrail = lensTrail.map { level in
                var copy = level
                copy.removeDescendant(path: outcome.unit.path, bytes: outcome.unit.bytes)
                return copy
            }
            lensSelection.remove(outcome.unit.path)
        }
        let moved = outcomes.filter { $0.error == nil }.map(\.unit.path)
        Task {
            // Moved to the Trash: nothing is freed until it is emptied, so the log says 0 bytes.
            if !moved.isEmpty { await recordCleanup(source: "Space Lens", freedByVolume: [:], items: moved) }
            await refreshLensVolume()
        }
        return outcomes
    }

    // MARK: node_modules

    /// The folders the user picked are remembered; the defaults are only common project folders.
    var nodeRoots: [String] = UserDefaults.standard.stringArray(forKey: "nodeRoots") ?? AppModel.defaultNodeRoots() {
        didSet { UserDefaults.standard.set(nodeRoots, forKey: "nodeRoots") }
    }
    var idleDays = 14
    var nodeCandidates: [NodeModulesCandidate]?
    /// Paths still being measured; their `bytes` is 0 until they leave this set.
    var nodeMeasuring: Set<String> = []
    var nodeSelection: Set<String> = []
    var isSearchingNodeModules = false
    var nodeFreedBytes: Int64?

    static func defaultNodeRoots() -> [String] {
        let home = NSHomeDirectory()
        return ["Developer", "Projects", "projects", "code", "src", "dev", "Desktop"].map { "\(home)/\($0)" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Shows the list as soon as discovery ends (<1 s) and fills sizes in as they are measured,
    /// instead of a spinner for the minute it takes to size tens of GB of node_modules.
    func findNodeModules() async {
        isSearchingNodeModules = true
        nodeFreedBytes = nil
        let roots = nodeRoots
        let days = idleDays
        let idle = await Task.detached { NodeModulesFinder.discover(roots: roots, idleDays: days) }.value
        nodeCandidates = idle.map { NodeModulesCandidate(path: $0.path, bytes: 0, lastActivity: $0.lastActivity) }
        nodeSelection = Set(idle.map(\.path))
        nodeMeasuring = Set(idle.map(\.path))
        isSearchingNodeModules = false

        await withTaskGroup(of: (String, Int64).self) { group in
            var pending = idle.map(\.path)[...]
            func startNext() {
                guard let path = pending.popFirst() else { return }
                group.addTask { (path, await Task.detached { NodeModulesFinder.measure(path) }.value) }
            }
            for _ in 0..<min(4, pending.count) { startNext() }
            for await (path, bytes) in group {
                if let index = nodeCandidates?.firstIndex(where: { $0.path == path }), let old = nodeCandidates?[index] {
                    nodeCandidates?[index] = NodeModulesCandidate(path: path, bytes: bytes, lastActivity: old.lastActivity)
                }
                nodeMeasuring.remove(path)
                startNext()
            }
        }
        // Workspace members hold a few KB of symlinks: real but pointless to list.
        let tiny = nodeCandidates?.filter { $0.bytes < Self.minimumNodeModulesBytes } ?? []
        nodeHiddenTinyCount = tiny.count
        nodeSelection.subtract(tiny.map(\.path))
        nodeCandidates = nodeCandidates?
            .filter { $0.bytes >= Self.minimumNodeModulesBytes }
            .sorted { $0.bytes > $1.bytes }
    }

    static let minimumNodeModulesBytes: Int64 = 1_000_000
    var nodeHiddenTinyCount = 0

    /// `paths`: the checked folders on screen; ones a search hides stay checked and untouched.
    func deleteNodeModules(_ paths: Set<String>) async {
        guard let candidates = nodeCandidates else { return }
        let targets = candidates.filter { paths.contains($0.path) }.map(\.path)
        isSearchingNodeModules = true
        let (freed, failures) = await Task.detached { () -> ([String: Int64], [String]) in
            let guardrail = SafetyGuard()
            let volumes = Set(targets.compactMap(Cleaner.volume(of:)))
            let before = volumes.reduce(into: [String: Int64]()) { $0[$1] = Cleaner.freeBytes($1) }
            var failures: [String] = []
            for path in targets {
                guard guardrail.check(path) == .allowed else { failures.append(path); continue }
                do { try FileManager.default.removeItem(atPath: path) } catch { failures.append(path) }
            }
            var freed: [String: Int64] = [:]
            for (volume, value) in before {
                if let after = Cleaner.freeBytes(volume) { freed[volume] = after - value }
            }
            return (freed, failures)
        }.value
        nodeFreedBytes = freed.values.reduce(0, +)
        if !failures.isEmpty {
            errorMessage = "\(failures.count) pasta(s) não foram apagadas (protegidas ou sem permissão)."
        }
        let removed = targets.filter { !failures.contains($0) }
        nodeCandidates = candidates.filter { !removed.contains($0.path) }
        nodeSelection.subtract(targets)
        isSearchingNodeModules = false
        if removed.isEmpty {
            await refreshDisk()
        } else {
            await recordCleanup(source: "node_modules", freedByVolume: freed, items: removed)
        }
    }
    // MARK: Uninstaller

    struct AppRow: Identifiable, Sendable {
        var id: String { app.path }
        let app: InstalledApp
        let leftovers: [Leftover]
        let lastUsed: Date?
        /// nil while being measured.
        var appBytes: Int64?
        var leftoverBytes: Int64?

        var totalBytes: Int64 { (appBytes ?? 0) + (leftoverBytes ?? 0) }
    }

    var appRows: [AppRow]?
    var isLoadingApps = false
    var uninstallReview: UninstallRequest?

    struct UninstallRequest: Identifiable {
        let id = UUID()
        let app: InstalledApp
        let plan: DeletionPlan
        let nameMatched: Set<String>
        let isRunning: Bool
    }

    /// Inventory and leftovers first (well under a second), sizes filled in 4 at a time after.
    func loadApps() async {
        isLoadingApps = true
        let rows = await Task.detached { () -> [AppRow] in
            let installed = AppInventory.installed()
            let finder = LeftoverFinder()
            return installed.filter { !$0.isApple }.map { app in
                let leftovers = finder.leftovers(of: app, installed: installed)
                return AppRow(app: app, leftovers: leftovers,
                              lastUsed: AppInventory.lastActivity(spotlight: AppInventory.lastUsed(app.path), leftovers: leftovers))
            }
        }.value
        appRows = rows
        isLoadingApps = false
        await withTaskGroup(of: (String, Int64, Int64).self) { group in
            var pending = rows[...]
            func next() {
                guard let row = pending.popFirst() else { return }
                group.addTask {
                    let sizer = SizeCalculator()
                    return (row.app.path, sizer.allocatedSize(of: row.app.path),
                            row.leftovers.reduce(0) { $0 + sizer.allocatedSize(of: $1.path) })
                }
            }
            for _ in 0..<4 { next() }
            for await (path, appBytes, leftoverBytes) in group {
                if let index = appRows?.firstIndex(where: { $0.app.path == path }) {
                    appRows?[index].appBytes = appBytes
                    appRows?[index].leftoverBytes = leftoverBytes
                }
                next()
            }
        }
    }

    /// Builds the plan off the main actor; leftovers matched only by name start unchecked.
    func requestUninstall(_ row: AppRow) async {
        let app = row.app
        let leftovers = row.leftovers
        let plan = await Task.detached { UninstallPlanner.plan(app: app, leftovers: leftovers) }.value
        uninstallReview = UninstallRequest(
            app: app, plan: plan,
            nameMatched: Set(leftovers.filter { $0.match == .name }.map(\.path)),
            isRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty)
    }

    // MARK: Hibernation

    var hibernated: [HibernatedApp] = []
    var hibernationVolumes: [String] = []
    var hibernationTarget: String?
    var isHibernating = false
    var hibernationMessage: String?

    func loadHibernation() async {
        let (entries, volumes) = await Task.detached { (Hibernator().list(), Hibernator.candidateVolumes()) }.value
        hibernated = entries
        hibernationVolumes = volumes
        if hibernationTarget.map({ !volumes.contains($0) }) ?? true { hibernationTarget = volumes.first }
        if appRows == nil { await loadApps() }
    }

    func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func hibernationProblem(_ row: AppRow) -> String? {
        if hibernated.contains(where: { $0.bundleID == row.app.bundleID }) { return "já está hibernado" }
        return Hibernator().ineligibility(of: row.app, isRunning: isRunning(row.app.bundleID))
    }

    /// Measured on the Mac's disk (df delta), recorded in the history like any cleanup.
    func hibernate(_ row: AppRow) async {
        guard let volume = hibernationTarget else { return }
        isHibernating = true
        let app = row.app
        let running = isRunning(app.bundleID)
        let outcome = await Task.detached { () -> Result<(HibernatedApp, Int64), Error> in
            let before = Cleaner.freeBytes("/") ?? 0
            do {
                let entry = try Hibernator().hibernate(app, to: Hibernator.storeFolder(onVolume: volume), isRunning: running)
                return .success((entry, (Cleaner.freeBytes("/") ?? 0) - before))
            } catch { return .failure(error) }
        }.value
        isHibernating = false
        switch outcome {
        case let .success((entry, freed)):
            // The bundle size is the fact; a df delta of a few MB is lost in swap/cache noise.
            hibernationMessage = "\(entry.name) hibernado em \(volume): \(formatBytes(entry.bytes)) saíram do disco do Mac."
            await recordCleanup(source: "Hibernar", freedByVolume: ["/": freed], items: [entry.originalPath])
        case let .failure(error):
            errorMessage = "\(error)"
        }
        await loadHibernation()
        await loadApps()
    }

    func wake(_ entry: HibernatedApp) async {
        isHibernating = true
        let running = isRunning(entry.bundleID)
        let result = await Task.detached { () -> Result<String?, Error> in
            Result { try Hibernator().wake(entry, isRunning: running) }
        }.value
        isHibernating = false
        switch result {
        case let .success(leftover):
            hibernationMessage = "\(entry.name) está de volta em \((entry.originalPath as NSString).deletingLastPathComponent)."
                + (leftover.map { " A cópia em \($0) não pôde ser apagada: remova pelo Finder." } ?? "")
        case let .failure(error):
            errorMessage = "\(error)"
        }
        await loadHibernation()
        await loadApps()
    }

    // MARK: Leftovers of removed apps

    struct OrphanRow: Identifiable, Sendable {
        var id: String { group.bundleID }
        let group: OrphanFinder.Group
        let sizes: [String: Int64]
        var totalBytes: Int64 { sizes.values.reduce(0, +) }
    }

    var orphanRows: [OrphanRow]?
    var isLoadingOrphans = false
    var orphanReview: OrphanRequest?

    struct OrphanRequest: Identifiable {
        let id = UUID()
        let plan: DeletionPlan
        let dataPaths: Set<String>
    }

    func loadOrphans() async {
        isLoadingOrphans = true
        orphanRows = await Task.detached { () -> [OrphanRow] in
            let apps = AppInventory.installed()
            let ids = apps.map(\.bundleID) + apps.flatMap { AppInventory.embeddedBundleIDs(in: $0.path) }
            let sizer = SizeCalculator()
            return OrphanFinder(installedIDs: ids).find().map { group in
                OrphanRow(group: group, sizes: Dictionary(uniqueKeysWithValues: group.items.map { ($0.path, sizer.allocatedSize(of: $0.path)) }))
            }
            .sorted { $0.totalBytes > $1.totalBytes }
        }.value
        isLoadingOrphans = false
    }

    /// One review for all of them: caches start checked, app data (Containers, Preferences...) does not.
    /// `rows`: what is on screen (the search may have filtered it); all of them by default.
    func requestOrphanReview(_ visible: [OrphanRow]? = nil) {
        guard let rows = visible ?? orphanRows, !rows.isEmpty else { return }
        let nodes = rows.flatMap { row in
            row.group.items.map { SpaceNode(path: $0.path, isDirectory: true, bytes: row.sizes[$0.path] ?? 0, children: [], isTruncated: false) }
        }
        let data = rows.flatMap { $0.group.items.filter { !$0.isRegenerable }.map(\.path) }
        orphanReview = OrphanRequest(plan: DeletionPlanner.plan(nodes), dataPaths: Set(data))
    }

    func executeOrphanCleanup(_ plan: DeletionPlan) -> [DeletionPlanner.Outcome] {
        let outcomes = DeletionPlanner.execute(plan)
        let moved = outcomes.filter { $0.error == nil }.map(\.unit.path)
        Task {
            if !moved.isEmpty { await recordCleanup(source: "Sobras de apps removidos", freedByVolume: [:], items: moved) }
            await loadOrphans()
        }
        return outcomes
    }

    func executeUninstall(_ plan: DeletionPlan) -> [DeletionPlanner.Outcome] {
        let outcomes = DeletionPlanner.execute(plan)
        let moved = outcomes.filter { $0.error == nil }.map(\.unit.path)
        Task {
            if !moved.isEmpty { await recordCleanup(source: "Desinstalador", freedByVolume: [:], items: moved) }
            await loadApps()
        }
        return outcomes
    }
}

extension SpaceNode {
    /// Removes `path` from the subtree and subtracts its bytes from every ancestor on the way.
    mutating func removeDescendant(path: String, bytes removed: Int64) {
        guard path.hasPrefix(self.path + "/") else { return }
        if let index = children.firstIndex(where: { $0.path == path }) {
            children.remove(at: index)
            bytes -= removed
            return
        }
        if let index = children.firstIndex(where: { path.hasPrefix($0.path + "/") }) {
            children[index].removeDescendant(path: path, bytes: removed)
            bytes -= removed
        }
    }

}
