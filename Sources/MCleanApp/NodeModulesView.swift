import CleanerCore
import SwiftUI

struct NodeModulesView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var search = ProcessInfo.processInfo.environment["MCLEAN_SEARCH"] ?? ""
    @AppStorage("sort.nodeModules") private var sort: Sort = .size

    enum Sort: String, CaseIterable {
        case size = "Tamanho", idle = "Mais parados", name = "Nome"
    }

    private var visible: [NodeModulesCandidate] {
        let all = (model.nodeCandidates ?? []).filter { search.isEmpty || $0.project.localizedCaseInsensitiveContains(search) }
        switch sort {
        // The model's order: discovery while measuring (rows don't jump as sizes arrive), then by size.
        case .size: return all
        case .idle: return all.sorted { $0.lastActivity < $1.lastActivity }
        case .name: return all.sorted { $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending }
        }
    }

    /// Only what is on screen: a checked folder the search hides is never deleted unseen.
    private var selected: [NodeModulesCandidate] {
        visible.filter { model.nodeSelection.contains($0.path) }
    }

    private var hiddenSelectedCount: Int { model.nodeSelection.count - selected.count }

    private var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.bytes } }

    /// What actually relieves the Mac's own disk; external volumes are reported apart.
    private var selectedInternalBytes: Int64 {
        selected.filter { $0.path.externalVolumeName == nil }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            results
        }
        // Pin to the top: an empty state alone does not fill the height and the header would float.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("node_modules")
        .searchable(text: $search, prompt: "Buscar projeto")
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.findNodeModules() } } label: {
                    Label("Procurar", systemImage: "magnifyingglass")
                }
                .disabled(model.nodeRoots.isEmpty || model.isSearchingNodeModules || !model.nodeMeasuring.isEmpty)
                .help("Procurar de novo")
            }
        }
        .confirmationDialog("Apagar \(selected.count) pastas node_modules?", isPresented: $confirming) {
            Button("Apagar \(formatBytes(selectedBytes))", role: .destructive) {
                Task { await model.deleteNodeModules(Set(selected.map(\.path))) }
            }
        } message: {
            Text("Apagadas de vez. Para recriar, rode npm install ou pnpm install no projeto. Commits não são afetados.")
        }
    }

    /// One compact row: the list below is the point of this screen, not the settings.
    private var header: some View {
        @Bindable var model = model
        return HStack(alignment: .center, spacing: 16) {
            Text("Procurar em").foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.nodeRoots, id: \.self) { root in
                        HStack(spacing: 4) {
                            Text(root.abbreviatingHome).lineLimit(1)
                            Button {
                                model.nodeRoots.removeAll { $0 == root }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remover \(root.abbreviatingHome)")
                        }
                        .font(.callout)
                        .padding(.leading, 10)
                        .padding(.trailing, 6)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                        .help(root)
                    }
                }
            }
            Button {
                if let path = Finder.chooseFolder(prompt: "Adicionar"), !model.nodeRoots.contains(path) {
                    model.nodeRoots.append(path)
                }
            } label: {
                Image(systemName: "plus")
            }
            .help("Adicionar pasta")
            .accessibilityLabel("Adicionar pasta")
            Stepper(value: $model.idleDays, in: 1...365, step: 7) {
                Text("parados há ≥ \(model.idleDays) dias").monospacedDigit()
            }
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(formatBytes(selectedBytes)) em \(selected.count) pastas")
                    .font(.headline)
                    .monospacedDigit()
                Text("\(formatBytes(selectedInternalBytes)) no disco do Mac · \(formatBytes(selectedBytes - selectedInternalBytes)) em discos externos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if hiddenSelectedCount > 0 {
                    Text("\(hiddenSelectedCount) marcadas fora da busca não serão apagadas")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !model.nodeMeasuring.isEmpty {
                    Text("Medindo \(model.nodeMeasuring.count) pastas…").font(.caption).foregroundStyle(.secondary)
                } else if model.nodeHiddenTinyCount > 0 && model.nodeFreedBytes == nil {
                    Text("\(model.nodeHiddenTinyCount) pastas com menos de 1 MB (links de workspace) ocultas")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let freed = model.nodeFreedBytes {
                    Label("\(formatBytes(freed)) liberados (medido no disco)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            Button("Apagar") { confirming = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selected.isEmpty || model.isSearchingNodeModules)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var results: some View {
        if model.isSearchingNodeModules {
            ProgressView("Procurando…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let candidates = model.nodeCandidates {
            if candidates.isEmpty {
                ContentUnavailableView("Nenhum node_modules parado", systemImage: "checkmark.circle",
                                       description: Text("Todos os projetos tiveram atividade recente."))
            } else {
                let rows = visible
                VStack(spacing: 0) {
                    HStack {
                        Text(rows.count == candidates.count ? "\(rows.count) projetos" : "\(rows.count) de \(candidates.count) projetos")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        SortPicker(selection: $sort)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    if rows.isEmpty {
                        NoMatches(search: search)
                    } else {
                        List(rows, id: \.path) { CandidateRow(candidate: $0) }
                            .listStyle(.inset)
                    }
                }
                .safeAreaInset(edge: .bottom) { actionBar }
            }
        } else {
            ContentUnavailableView("Procure node_modules de projetos parados", systemImage: "shippingbox",
                                   description: Text("A atividade vem do último commit, ou do package.json quando não há git."))
        }
    }
}

private struct CandidateRow: View {
    @Environment(AppModel.self) private var model
    let candidate: NodeModulesCandidate

    private var project: String { candidate.project }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle((project as NSString).lastPathComponent, isOn: Binding(
                get: { model.nodeSelection.contains(candidate.path) },
                set: { if $0 { model.nodeSelection.insert(candidate.path) } else { model.nodeSelection.remove(candidate.path) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text((project as NSString).lastPathComponent)
                    if let volume = candidate.path.externalVolumeName {
                        Label(volume, systemImage: "externaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Em disco externo: apagar não libera espaço no Mac")
                    }
                }
                Text(project.abbreviatingHome)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(candidate.lastActivity, format: .relative(presentation: .named))
                .font(.callout)
                .foregroundStyle(.secondary)
            Group {
                if model.nodeMeasuring.contains(candidate.path) {
                    ProgressView().controlSize(.small).accessibilityLabel("Medindo")
                } else {
                    Text(formatBytes(candidate.bytes)).monospacedDigit()
                }
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu { Button("Mostrar no Finder") { Finder.reveal(candidate.path) } }
    }
}

private extension NodeModulesCandidate {
    var project: String { (path as NSString).deletingLastPathComponent }
    var projectName: String { (project as NSString).lastPathComponent }
}
