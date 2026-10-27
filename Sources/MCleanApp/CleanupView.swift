import CleanerCore
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var showingReport = false

    var body: some View {
        content
            .navigationTitle("Limpeza")
            .toolbar {
                ToolbarItemGroup {
                    Button { Task { await model.runScan() } } label: {
                        Label("Analisar de novo", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isScanning || model.isCleaning)
                    .help("Medir tudo de novo (⌘R)")
                }
            }
            .confirmationDialog(
                "Limpar \(model.selection.count) categorias?",
                isPresented: $confirming
            ) {
                Button("Cancelar", role: .cancel) {}
                Button("Limpar \(formatBytes(model.selectedBytes))", role: .destructive) {
                    Task {
                        await model.clean()
                        showingReport = true
                    }
                }
            } message: {
                Text("Caches e logs são apagados de vez, sem passar pela Lixeira; os apps os recriam quando precisarem. Itens com comando (ex.: npm cache clean) rodam a ferramenta.")
            }
            .sheet(isPresented: $showingReport) {
                if let report = model.lastReport { CleanReportView(report: report) }
            }
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(formatBytes(model.selectedBytes)) selecionados")
                    .font(.headline)
                    .monospacedDigit()
                Text("\(model.selection.count) categorias · o ganho real é medido no disco depois")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Limpar") { confirming = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.selection.isEmpty || model.isScanning || model.isCleaning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var content: some View {
        switch model.scan {
        case .idle:
            ContentUnavailableView {
                Label("Nada analisado ainda", systemImage: "sparkles")
            } description: {
                Text("A análise só mede. Você escolhe o que apagar.")
            } actions: {
                Button("Analisar o Mac") { Task { await model.runScan() } }
                    .buttonStyle(.borderedProminent)
            }
        case let .scanning(step):
            VStack(spacing: 12) {
                ProgressView()
                Text(step).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .done(results):
            RuleList(results: results)
                .disabled(model.isCleaning)
                .safeAreaInset(edge: .bottom) { actionBar }
                .overlay {
                    if model.isCleaning {
                        ProgressView("Limpando…")
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
        }
    }
}

private struct RuleList: View {
    @Environment(AppModel.self) private var model
    let results: [RuleResult]

    var body: some View {
        let unmeasurable = model.hasFullDiskAccess ? [] : results.filter {
            Permissions.fullDiskAccessRules.contains($0.rule.id) && $0.bytes == 0
        }
        let found = results.filter {
            $0.bytes > 0 || $0.rule.paths.isEmpty || $0.timedOut || (!$0.items.isEmpty && $0.unreadableEntries > 0)
        }
        let emptyCount = results.count - found.count - unmeasurable.count
        List {
            if !unmeasurable.isEmpty {
                // Fixed order, proper nouns, and the contraction the sentence needs ("leitura DA Lixeira").
                let labels = [("trash", "da Lixeira"), ("external-trash", "das lixeiras dos discos externos"),
                              ("ios-backups", "dos backups do iPhone"), ("mail-downloads", "dos anexos do Mail"),
                              ("mail-trash", "da lixeira do Mail")]
                FullDiskAccessBanner(blocked: labels.filter { label in unmeasurable.contains { $0.rule.id == label.0 } }.map(\.1))
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 4)
            }
            ForEach(Category.allCases, id: \.self) { category in
                let rows = found.filter { $0.rule.category == category.rawValue }.sorted { $0.bytes > $1.bytes }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows, id: \.rule.id) { RuleRow(result: $0) }
                    } header: {
                        HStack {
                            Text(category.title)
                            Spacer()
                            Text(formatBytes(rows.reduce(0) { $0 + $1.bytes })).monospacedDigit()
                        }
                    }
                }
            }
            if emptyCount > 0 {
                Text("\(emptyCount) regras não encontraram nada para limpar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }
}

private struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let result: RuleResult

    /// Height of one line of body text, so the checkbox centers on the title's first line.
    @ScaledMetric(relativeTo: .body) private var titleLineHeight: CGFloat = 17

    private var isReport: Bool {
        if case .report = result.rule.action { return true }
        return false
    }

    private var isOn: Binding<Bool> {
        Binding(
            get: { model.selection.contains(result.rule.id) },
            set: { on in
                if on { model.selection.insert(result.rule.id) } else { model.selection.remove(result.rule.id) }
            }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isReport {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: titleLineHeight)
                    .accessibilityHidden(true)
            } else {
                Toggle(result.rule.name, isOn: isOn)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!AppModel.isSelectable(result))
                    .frame(height: titleLineHeight)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(result.rule.name)
                    if result.rule.safety == .review && !isReport {
                        Text("revisar")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .help("Fora da seleção automática: confira antes de marcar.")
                    }
                }
                detail
            }
            Spacer(minLength: 12)
            Text(result.rule.paths.isEmpty ? "—" : (result.timedOut || (result.bytes == 0 && result.unreadableEntries > 0)) ? "não medido" : formatBytes(result.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(result.rule.paths.isEmpty ? "O tamanho só é conhecido depois de rodar o comando." : "")
        }
        .padding(.vertical, 3)
        .contextMenu {
            if let first = result.items.first {
                Button("Mostrar no Finder") { Finder.reveal(first.path) }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if result.timedOut {
            Text("Não medido: a análise passou do tempo. Se o macOS mostrou um pedido de permissão, responda e analise de novo.")
                .font(.callout)
                .foregroundStyle(.orange)
        } else if !result.runningBlockers.isEmpty {
            Text("Feche antes: \(result.runningBlockers.joined(separator: ", "))")
                .font(.callout)
                .foregroundStyle(.orange)
        } else if let tool = result.missingTool {
            Text("\(tool) não está instalado no PATH")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let note = result.rule.note {
            Text(LocalizedStringKey(note))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(note)
        }
        if result.unreadableEntries > 0 {
            Text("\(result.unreadableEntries) itens sem permissão de leitura: tamanho mínimo")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct CleanReportView: View {
    @Environment(\.dismiss) private var dismiss
    let report: CleanReport

    private var measured: Int64 { report.measuredFreedBytes.values.reduce(0, +) }
    private var estimated: Int64 {
        report.outcomes.filter { $0.status == .cleaned || $0.status == .partial }.reduce(0) { $0 + $1.estimatedBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Limpeza concluída").font(.title2.weight(.semibold))
                Text("\(formatBytes(measured)) liberados")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Medido no disco. A estimativa era \(formatBytes(estimated)); a diferença vem de arquivos que os apps recriaram ou que estavam em uso.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List(report.outcomes, id: \.ruleID) { outcome in
                HStack(alignment: .firstTextBaseline) {
                    StatusIcon(status: outcome.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.ruleID)
                        Text(outcome.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Text(formatBytes(outcome.estimatedBytes)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct StatusIcon: View {
    let status: CleanOutcome.Status

    var body: some View {
        switch status {
        case .cleaned, .wouldClean:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Limpo")
        case .partial:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityLabel("Parcial")
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Falhou")
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("Pulado")
        }
    }
}
