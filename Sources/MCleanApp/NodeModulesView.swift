import CleanerCore
import SwiftUI

struct NodeModulesView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    private var selected: [NodeModulesCandidate] {
        (model.nodeCandidates ?? []).filter { model.nodeSelection.contains($0.path) }
    }

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
        .navigationTitle("node_modules")
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.findNodeModules() } } label: {
                    Label("Procurar", systemImage: "magnifyingglass")
                }
                .disabled(model.nodeRoots.isEmpty || model.isSearchingNodeModules || !model.nodeMeasuring.isEmpty)
                .help("Procurar de novo")
            }
        }
        .confirmationDialog("Apagar \(model.nodeSelection.count) pastas node_modules?", isPresented: $confirming) {
            Button("Apagar \(formatBytes(selectedBytes))", role: .destructive) {
                Task { await model.deleteSelectedNodeModules() }
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
                Text("\(formatBytes(selectedBytes)) em \(model.nodeSelection.count) pastas")
                    .font(.headline)
                    .monospacedDigit()
                Text("\(formatBytes(selectedInternalBytes)) no disco do Mac · \(formatBytes(selectedBytes - selectedInternalBytes)) em discos externos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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
                .disabled(model.nodeSelection.isEmpty || model.isSearchingNodeModules)
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
                List(candidates, id: \.path) { CandidateRow(candidate: $0) }
                    .listStyle(.inset)
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

    private var project: String { (candidate.path as NSString).deletingLastPathComponent }

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
