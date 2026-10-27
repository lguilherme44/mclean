import CleanerCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let disk = model.disk { DiskSummary(disk: disk) } else { ProgressView() }
                HistorySection(history: model.history)
                Opportunities()
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Visão geral")
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refreshDisk() } } label: {
                    Label("Atualizar", systemImage: "arrow.clockwise")
                }
                .help("Medir o disco de novo")
            }
        }
    }
}

private struct DiskSummary: View {
    let disk: DiskStatus

    private var freeFraction: Double {
        disk.totalBytes > 0 ? Double(disk.freeBytes) / Double(disk.totalBytes) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Macintosh HD")
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatBytes(disk.freeBytes))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("livres de \(formatBytes(disk.totalBytes))")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            CapacityBar(used: disk.totalBytes - disk.freeBytes, total: disk.totalBytes)
            if freeFraction < 0.1 {
                Label(
                    "Pouco espaço. O macOS precisa de folga para crescer o swap e instalar atualizações.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }
            Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 4) {
                GridRow {
                    Metric(title: "Usado", value: formatBytes(disk.totalBytes - disk.freeBytes))
                    Metric(title: "Swap em uso", value: formatBytes(disk.swapUsedBytes),
                           hint: "Os arquivos de swap ocupam o mesmo disco.")
                    Metric(title: "Snapshots locais", value: "\(disk.localSnapshots.count)",
                           hint: "Snapshots de update e do Time Machine retêm espaço.")
                }
            }
            .padding(.top, 8)
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
        .help(hint ?? "")
    }
}

private struct Opportunities: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Onde recuperar espaço").font(.title2.weight(.semibold))
            switch model.scan {
            case .idle:
                Text("Mede caches, logs, lixo de desenvolvimento e o que mais as regras cobrem. Nada é apagado sem sua confirmação.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Analisar o Mac") { Task { await model.runScan() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            case let .scanning(step):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(step).foregroundStyle(.secondary).lineLimit(1)
                }
            case let .done(results):
                let actionable = results.filter { result in
                    if case .report = result.rule.action { return false }
                    return result.bytes > 0
                }
                // Unmeasurable (e.g. root-only) is shown as such, never dropped as if it were empty.
                let informational = results.filter { result in
                    if case .report = result.rule.action {
                        return result.bytes > 0 || (!result.items.isEmpty && result.unreadableEntries > 0)
                    }
                    return false
                }
                let top = actionable.sorted { $0.bytes > $1.bytes }.prefix(6)
                let largest = top.first?.bytes ?? 1
                VStack(spacing: 0) {
                    ForEach(Array(top), id: \.rule.id) { result in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(result.rule.name)
                                    if !result.runningBlockers.isEmpty {
                                        Text("feche: \(result.runningBlockers.joined(separator: ", "))")
                                            .font(.caption).foregroundStyle(.orange)
                                    } else if result.rule.safety == .review {
                                        Text("revisar").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                ShareBar(fraction: Double(result.bytes) / Double(largest))
                            }
                            Text(formatBytes(result.bytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
                if !informational.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Também ocupando espaço, exige ação sua")
                            .font(.callout.weight(.medium))
                        ForEach(informational.sorted { $0.bytes > $1.bytes }, id: \.rule.id) { result in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.rule.name)
                                    if let note = result.rule.note {
                                        Text(LocalizedStringKey(note)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(result.bytes == 0 && result.unreadableEntries > 0 ? "não medido" : formatBytes(result.bytes))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
                }
                HStack {
                    Text("\(formatBytes(model.selectedBytes)) pré-selecionados com segurança")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Revisar limpeza") { model.page = .cleanup }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
        }
    }
}
