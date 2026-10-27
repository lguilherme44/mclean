import CleanerCore
import SwiftUI

/// "Offload" for the Mac: the app goes to an external disk and a few-KB stub stays in its place,
/// opening the real app whenever that disk is connected. "Acordar" brings it back.
struct HibernateView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var confirming: AppModel.AppRow?
    @State private var search = ProcessInfo.processInfo.environment["MCLEAN_SEARCH"] ?? ""
    @AppStorage("sort.hibernate") private var sort: Sort = .size

    enum Sort: String, CaseIterable {
        case size = "Tamanho", idle = "Mais parados", name = "Nome"
    }

    private func matches(_ name: String) -> Bool { search.isEmpty || name.localizedCaseInsensitiveContains(search) }

    private var candidates: [AppModel.AppRow] {
        // A stub is what hibernating left behind: it is listed under "Hibernados", never sent away again.
        let all = (model.appRows ?? []).filter {
            !$0.app.isApple && !$0.app.bundleID.hasPrefix(Hibernator.stubPrefix) && matches($0.app.name)
        }
        let bySize: (AppModel.AppRow, AppModel.AppRow) -> Bool = { ($0.appBytes ?? 0) > ($1.appBytes ?? 0) }
        switch sort {
        case .size: return all.sorted(by: bySize)
        // No recorded activity first, then the longest idle; ties go to the biggest, the best ones to send away.
        case .idle: return all.sorted {
            let (a, b) = ($0.lastUsed ?? .distantPast, $1.lastUsed ?? .distantPast)
            return a == b ? bySize($0, $1) : a < b
        }
        case .name: return all.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        }
    }

    private var hibernated: [HibernatedApp] {
        let all = model.hibernated.filter { matches($0.name) }
        switch sort {
        case .size: return all.sorted { $0.bytes > $1.bytes }
        // Hibernated longest ago first.
        case .idle: return all.sorted { $0.date < $1.date }
        case .name: return all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        content
            .navigationTitle("Hibernar apps")
            .searchable(text: $search, prompt: "Buscar app")
            .task { await model.loadHibernation() }
            // After a hibernate/wake the list changes under the selection: never leave a stale one.
            .onChange(of: model.hibernated.map(\.bundleID)) { selection = nil }
            .toolbar {
                ToolbarItem {
                    Button { Task { await model.loadHibernation() } } label: { Label("Atualizar", systemImage: "arrow.clockwise") }
                }
            }
            .confirmationDialog(
                "Hibernar \(confirming?.app.name ?? "")?",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                presenting: confirming
            ) { row in
                Button("Cancelar", role: .cancel) {}
                Button("Hibernar e liberar \(formatBytes(row.appBytes ?? 0))") { Task { await model.hibernate(row) } }
            } message: { _ in
                Text("O app vai para \(model.hibernationTarget ?? "o disco externo") e um atalho de poucos KB fica no lugar. Com o disco conectado ele abre normalmente; sem o disco, avisa. Dá para acordar quando quiser.")
            }
    }

    @ViewBuilder private var content: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: $selection) {
                if !hibernated.isEmpty {
                    Section("Hibernados") {
                        ForEach(hibernated) { entry in HibernatedRow(entry: entry) }
                    }
                }
                Section("Apps instalados") {
                    if model.appRows == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if candidates.isEmpty && !search.isEmpty {
                        Text("Nenhum app com “\(search)”").foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { row in
                        CandidateRow(row: row, problem: model.hibernationProblem(row)).tag(row.id)
                    }
                }
            }
            .listStyle(.inset)
            actionBar
        }
        .overlay {
            if model.isHibernating {
                ProgressView("Copiando e conferindo…").padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var header: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.hibernationVolumes.isEmpty {
                    Label("Conecte um disco externo APFS ou HFS+ para hibernar apps.", systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.orange)
                } else {
                    Text("Destino:")
                    Picker("Destino", selection: $model.hibernationTarget) {
                        ForEach(model.hibernationVolumes, id: \.self) { volume in
                            Text((volume as NSString).lastPathComponent).tag(Optional(volume))
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                Spacer()
                SortPicker(selection: $sort)
            }
            if let message = model.hibernationMessage {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var actionBar: some View {
        let row = candidates.first { $0.id == selection }
        let problem = row.flatMap { model.hibernationProblem($0) }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let row {
                    Text(row.app.name).font(.headline)
                    Text(problem ?? "\(formatBytes(row.appBytes ?? 0)) saem do disco do Mac")
                        .font(.caption).foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                } else {
                    Text("Escolha um app").font(.headline).foregroundStyle(.secondary)
                    Text("Os que precisam ficar em /Applications mostram o motivo").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Hibernar…") { confirming = row }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(row == nil || problem != nil || model.hibernationTarget == nil || model.isHibernating)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct HibernatedRow: View {
    @Environment(AppModel.self) private var model
    let entry: HibernatedApp

    private var online: Bool { FileManager.default.fileExists(atPath: entry.storedPath) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                Text(online ? "No disco \(entry.storedPath.split(separator: "/").dropFirst(1).first ?? "")" : "Disco desconectado: conecte para abrir ou acordar")
                    .font(.caption).foregroundStyle(online ? Color.secondary : Color.orange)
            }
            Spacer()
            Text(formatBytes(entry.bytes)).monospacedDigit().foregroundStyle(.secondary)
            Button("Acordar") { Task { await model.wake(entry) } }
                .disabled(!online || model.isHibernating)
        }
        .padding(.vertical, 3)
    }
}

private struct CandidateRow: View {
    let row: AppModel.AppRow
    let problem: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.path))
                .resizable().frame(width: 28, height: 28)
                .opacity(problem == nil ? 1 : 0.45)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.app.name).foregroundStyle(problem == nil ? .primary : .secondary)
                Text(problem.map { "Não pode: \($0)" } ?? "Última atividade: \(row.lastUsed?.relativeDescription ?? "sem registro")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let bytes = row.appBytes {
                Text(formatBytes(bytes)).monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
