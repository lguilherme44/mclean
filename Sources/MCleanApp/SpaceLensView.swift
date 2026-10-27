import CleanerCore
import QuickLook
import SwiftUI

struct SpaceLensView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ProcessInfo.processInfo.environment["MCLEAN_SEARCH"] ?? ""

    var body: some View {
        content
            .navigationTitle("Space Lens")
            .searchable(text: $search, prompt: "Filtrar nesta pasta")
            .toolbar {
                ToolbarItemGroup {
                    Button("Pasta pessoal") { model.scanLens(root: NSHomeDirectory()) }
                    Button("Escolher pasta…") {
                        if let path = Finder.chooseFolder(prompt: "Analisar") { model.scanLens(root: path) }
                    }
                }
            }
            .sheet(item: Bindable(model).lensReview) { request in
                ReviewSheet(plan: request.plan, onExecute: model.executeDeletion)
            }
    }

    @ViewBuilder private var content: some View {
        @Bindable var model = model
        switch model.lensPhase {
        case .idle:
            ContentUnavailableView {
                Label("Descubra o que ocupa espaço", systemImage: "square.grid.3x3.square")
            } description: {
                Text("Mede cada pasta pelo espaço que ela realmente ocupa no disco.")
            } actions: {
                Button("Analisar pasta pessoal") { model.scanLens(root: NSHomeDirectory()) }
                    .buttonStyle(.borderedProminent)
            }
        case let .scanning(files, path):
            VStack(spacing: 12) {
                ProgressView()
                Text("\(files.formatted()) arquivos").monospacedDigit()
                Text(path.abbreviatingHome)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 480)
                Button("Cancelar") { model.cancelLens() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done:
            if let current = model.lensTrail.last {
                VStack(spacing: 0) {
                    Breadcrumbs()
                    Divider()
                    if let volume = model.lensVolume {
                        DiskIndicator(volume: volume,
                                      selectedBytes: DeletionPlanner.plan(model.lensSelectedNodes).totalBytes)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        Divider()
                    }
                    // One tile is just "100%": the map only earns its space when it compares.
                    if current.children.filter({ Double($0.bytes) >= Double(current.bytes) * 0.01 }).count >= 2 {
                        VStack(alignment: .leading, spacing: 8) {
                            SpaceMapView(node: current, selection: $model.lensSelection) { model.open($0) }
                                .frame(minHeight: 180, idealHeight: 280, maxHeight: 320)
                            AgeLegend()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        Divider()
                    }
                    NodeList(node: current, search: search, selection: $model.lensSelection, onRemove: model.requestLensReview)
                    SelectionBar { model.requestLensReview(model.lensSelectedNodes) }
                }
                .onChange(of: current.path) {
                    model.lensSelection = []
                    search = ""
                }
            }
        }
    }
}

private struct Breadcrumbs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.lensTrail.enumerated()), id: \.element.path) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        Button(index == 0 ? node.path.abbreviatingHome : node.name) { model.goBack(to: node) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(index == model.lensTrail.count - 1 ? .primary : .secondary)
                            .disabled(index == model.lensTrail.count - 1)
                    }
                }
            }
            if let current = model.lensTrail.last {
                Text(formatBytes(current.bytes))
                    .font(.headline)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct NodeList: View {
    @Environment(AppModel.self) private var model
    let node: SpaceNode
    let search: String
    @Binding var selection: Set<String>
    let onRemove: ([SpaceNode]) -> Void
    @AppStorage("sort.lens") private var sort: Sort = .size

    enum Sort: String, CaseIterable {
        case size = "Tamanho", oldest = "Mais antigos", name = "Nome"
    }

    private var sorted: [SpaceNode] {
        let shown = search.isEmpty ? node.children : node.children.filter { $0.name.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .size: return shown
        // Dateless entries (empty folders) go last: nothing to judge them by.
        case .oldest: return shown.sorted { ($0.lastModified ?? .distantFuture) < ($1.lastModified ?? .distantFuture) }
        case .name: return shown.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        if node.children.isEmpty {
            ContentUnavailableView(
                node.isTruncated ? "Conteúdo não detalhado" : "Pasta vazia",
                systemImage: "folder",
                description: Text(node.isTruncated ? "Abra a pasta para medir o que tem dentro." : "")
            )
        } else {
            HStack {
                Text(search.isEmpty ? "\(node.children.count) itens" : "\(sorted.count) de \(node.children.count) itens")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                SortPicker(selection: $sort)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            List(sorted, selection: $selection) { child in
                NodeRow(node: child, parentBytes: node.bytes)
                    .tag(child.path)
            }
            .listStyle(.inset)
            .overlay { if sorted.isEmpty { NoMatches(search: search) } }
            .contextMenu(forSelectionType: String.self) { paths in
                let nodes = node.children.filter { paths.contains($0.path) }
                if nodes.count == 1, let child = nodes.first {
                    if child.isDirectory { Button("Abrir") { model.open(child) } }
                    Button("Pré-visualizar") { model.lensPreview = URL(fileURLWithPath: child.path) }
                    Button("Mostrar no Finder") { Finder.reveal(child.path) }
                    Divider()
                }
                if !nodes.isEmpty {
                    Button(nodes.count == 1 ? "Revisar e remover…" : "Revisar e remover \(nodes.count) itens…",
                           role: .destructive) { onRemove(nodes) }
                }
            } primaryAction: { paths in
                if let child = child(paths) { model.open(child) }
            }
            // Quick Look: Space (like Finder) or "Pré-visualizar"; arrows move through the selection.
            .quickLookPreview(Bindable(model).lensPreview, in: previewURLs)
            .onKeyPress(.space) {
                guard let first = sorted.first(where: { selection.contains($0.path) }) else { return .ignored }
                model.lensPreview = model.lensPreview == nil ? URL(fileURLWithPath: first.path) : nil
                return .handled
            }
            .safeAreaInset(edge: .bottom) {
                if node.isTruncated {
                    Text("Itens menores estão somados no total, mas não listados.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
        }
    }

    /// The selected items in list order, or every item when nothing is selected.
    private var previewURLs: [URL] {
        let chosen = sorted.filter { selection.contains($0.path) }
        return (chosen.isEmpty ? sorted : chosen).map { URL(fileURLWithPath: $0.path) }
    }

    private func child(_ paths: Set<String>) -> SpaceNode? {
        guard let path = paths.first else { return nil }
        return node.children.first { $0.path == path }
    }
}

private struct NodeRow: View {
    let node: SpaceNode
    let parentBytes: Int64

    private var fraction: Double { parentBytes > 0 ? Double(node.bytes) / Double(parentBytes) : 0 }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            Text(node.lastModified?.relativeDescription ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
                .help(node.lastModified.map { "Modificado em \($0.formatted(date: .long, time: .shortened))" } ?? "Sem arquivos")
            ShareBar(fraction: fraction)
                .frame(width: 120)
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
            Text(formatBytes(node.bytes))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(node.isDirectory ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint(node.isDirectory ? "Clique duas vezes para abrir" : "")
    }
}

/// Fixed bottom bar: what is selected and how much it weighs, with the only path to removal.
private struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let onReview: () -> Void

    var body: some View {
        let nodes = model.lensSelectedNodes
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if nodes.isEmpty {
                    Text("Nada selecionado").font(.headline).foregroundStyle(.secondary)
                    Text("Clique para selecionar; ⌘-clique para vários").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(formatBytes(nodes.reduce(0) { $0 + $1.bytes })) selecionados")
                        .font(.headline).monospacedDigit()
                    Text(nodes.count == 1 ? nodes[0].name : "\(nodes.count) itens")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if !nodes.isEmpty {
                Button("Limpar seleção") { model.lensSelection = [] }
                    .buttonStyle(.borderless)
            }
            Button("Revisar e remover…", action: onReview)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(nodes.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}
