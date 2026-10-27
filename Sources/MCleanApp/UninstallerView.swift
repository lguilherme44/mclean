import CleanerCore
import SwiftUI

/// Apps with what each one really takes (bundle + leftovers in the Library) and when it was last
/// opened. Removing goes through the shared review: leftovers found only by name start unchecked.
struct UninstallerView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @AppStorage("sort.apps") private var sort: Sort = .size
    @State private var selection: String?
    // `MCLEAN_UNINSTALLER_MODE=orphans` opens straight on the leftovers (visual QA).
    @State private var mode: Mode = ProcessInfo.processInfo.environment["MCLEAN_UNINSTALLER_MODE"] == "orphans" ? .orphans : .installed

    enum Mode: String, CaseIterable {
        case installed = "Apps instalados", orphans = "Sobras de apps removidos"
    }

    enum Sort: String, CaseIterable {
        case size = "Tamanho", unused = "Mais parados", name = "Nome"
    }

    private var rows: [AppModel.AppRow] {
        let all = (model.appRows ?? []).filter {
            search.isEmpty || $0.app.name.localizedCaseInsensitiveContains(search)
                || $0.app.bundleID.localizedCaseInsensitiveContains(search)
        }
        switch sort {
        case .size: return all.sorted { $0.totalBytes > $1.totalBytes }
        // No recorded activity first, then the longest idle: the "do I still need this?" order.
        case .unused: return all.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .name: return all.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        }
    }

    var body: some View {
        content
            .navigationTitle("Desinstalar apps")
            .searchable(text: $search, prompt: mode == .installed ? "Buscar app" : "Buscar identificador")
            .toolbar {
                ToolbarItem {
                    Button { Task { await model.loadApps() } } label: { Label("Atualizar", systemImage: "arrow.clockwise") }
                        .disabled(model.isLoadingApps)
                }
            }
            .task { if model.appRows == nil { await model.loadApps() } }
            .task(id: mode) { if mode == .orphans, model.orphanRows == nil { await model.loadOrphans() } }
            .sheet(item: Bindable(model).orphanReview) { request in
                ReviewSheet(
                    plan: request.plan,
                    title: "Sobras de apps removidos",
                    notes: Dictionary(uniqueKeysWithValues: request.plan.units.map {
                        ($0.path, request.dataPaths.contains($0.path)
                            ? "Dados do app (\((($0.path as NSString).deletingLastPathComponent as NSString).lastPathComponent)): confira antes"
                            : "Cache: o app recriaria se voltasse")
                    }),
                    initiallyExcluded: request.dataPaths,
                    onExecute: model.executeOrphanCleanup)
            }
            .sheet(item: Bindable(model).uninstallReview) { request in
                ReviewSheet(
                    plan: request.plan,
                    title: "Desinstalar \(request.app.name)",
                    blockingWarning: request.isRunning ? "\(request.app.name) está aberto: feche o app e tente de novo." : nil,
                    notes: Dictionary(uniqueKeysWithValues: request.nameMatched.map {
                        ($0, "Achado pelo nome do app: confira antes de marcar")
                    }),
                    initiallyExcluded: request.nameMatched,
                    onExecute: model.executeUninstall)
            }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            Picker("Mostrar", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.top, 10)
            if mode == .installed { installedContent } else { OrphanList(search: search) }
        }
    }

    @ViewBuilder private var installedContent: some View {
        if model.appRows == nil {
            ProgressView("Listando apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(rows.count) apps · sobras = dados na Library além do app")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    SortPicker(selection: $sort)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                List(rows, selection: $selection) { row in
                    AppRowView(row: row).tag(row.id)
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let row = rows.first(where: { ids.contains($0.id) }) {
                        Button("Mostrar no Finder") { Finder.reveal(row.app.path) }
                        Button("Desinstalar…", role: .destructive) { Task { await model.requestUninstall(row) } }
                    }
                } primaryAction: { ids in
                    if let row = rows.first(where: { ids.contains($0.id) }) { Task { await model.requestUninstall(row) } }
                }
                actionBar
            }
        }
    }

    private var actionBar: some View {
        let row = rows.first { $0.id == selection }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let row {
                    Text(row.app.name).font(.headline).lineLimit(1)
                    Text("\(formatBytes(row.totalBytes)) com \(row.leftovers.count) sobras")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("Nenhum app selecionado").font(.headline).foregroundStyle(.secondary)
                    Text("Duplo clique abre a revisão do que sai").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Desinstalar…") { if let row { Task { await model.requestUninstall(row) } } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(row == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct AppRowView: View {
    let row: AppModel.AppRow

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.path))
                .resizable().frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.app.name).lineLimit(1)
                Text([row.app.version.map { "v\($0)" }, row.app.bundleID].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            Text(row.lastUsed?.relativeDescription ?? "sem registro")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .help(row.lastUsed.map { "Última atividade: \($0.formatted(date: .long, time: .shortened)) (Spotlight ou dados do app)" }
                      ?? "Nem o Spotlight nem as pastas de dados do app registram uso")
            Group {
                if let appBytes = row.appBytes, let leftovers = row.leftoverBytes {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(formatBytes(appBytes + leftovers)).monospacedDigit()
                        Text(leftovers > 0 ? "+\(formatBytes(leftovers)) de sobras" : "sem sobras")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Leftovers of apps no longer installed, grouped by bundle id, largest first.
private struct OrphanList: View {
    @Environment(AppModel.self) private var model
    let search: String
    @AppStorage("sort.orphans") private var sort: Sort = .size

    enum Sort: String, CaseIterable {
        case size = "Tamanho", name = "Identificador"
    }

    var body: some View {
        if let all = model.orphanRows {
            let found = search.isEmpty ? all : all.filter { $0.group.bundleID.localizedCaseInsensitiveContains(search) }
            // The model already orders by size.
            let rows = sort == .size ? found : found.sorted { $0.group.bundleID.localizedStandardCompare($1.group.bundleID) == .orderedAscending }
            let total = rows.reduce(0) { $0 + $1.totalBytes }
            VStack(spacing: 0) {
                HStack {
                    Text("Pastas com o identificador de apps que não estão mais instalados (nem em outro disco).")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    SortPicker(selection: $sort)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                if rows.isEmpty && !search.isEmpty {
                    NoMatches(search: search)
                } else if rows.isEmpty {
                    ContentUnavailableView("Nenhuma sobra encontrada", systemImage: "checkmark.circle")
                } else {
                    List(rows) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.group.bundleID).lineLimit(1).truncationMode(.middle)
                                Text(Set(row.group.items.map { (($0.path as NSString).deletingLastPathComponent as NSString).lastPathComponent })
                                        .sorted().joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(formatBytes(row.totalBytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            if let first = row.group.items.first { Button("Mostrar no Finder") { Finder.reveal(first.path) } }
                        }
                    }
                    .listStyle(.inset)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(formatBytes(total)) em \(rows.count) apps removidos").font(.headline).monospacedDigit()
                        Text("Na revisão, só os caches vêm marcados").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revisar e remover…") { model.requestOrphanReview(rows) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(rows.isEmpty)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .top) { Divider() }
            }
        } else {
            ProgressView("Procurando sobras…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
