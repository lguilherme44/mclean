import CleanerCore
import SwiftUI

/// "Review Items Before Removal": every unit can be unchecked, guarded items show why, and the
/// result (including partial failures) stays on screen instead of vanishing with the sheet.
struct ReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plan: DeletionPlan
    var title = "Revisar antes de mover para a Lixeira"
    /// Shown above the list, e.g. "feche o app antes"; when set, removal is disabled.
    var blockingWarning: String?
    /// Per-path explanation shown under the name (e.g. "encontrado pelo nome").
    var notes: [String: String] = [:]
    let onExecute: (DeletionPlan) -> [DeletionPlanner.Outcome]
    @State private var excluded: Set<String>
    @State private var outcomes: [DeletionPlanner.Outcome]?

    init(plan: DeletionPlan, title: String = "Revisar antes de mover para a Lixeira", blockingWarning: String? = nil,
         notes: [String: String] = [:], initiallyExcluded: Set<String> = [],
         onExecute: @escaping (DeletionPlan) -> [DeletionPlanner.Outcome]) {
        self.plan = plan
        self.title = title
        self.blockingWarning = blockingWarning
        self.notes = notes
        self.onExecute = onExecute
        _excluded = State(initialValue: initiallyExcluded)
    }

    private var chosen: DeletionPlan {
        plan.excluding(excluded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let outcomes {
                result(outcomes)
            } else {
                review
            }
        }
        .frame(width: 560, height: 460)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text("Dá para desfazer pela Lixeira. O espaço só volta quando você esvaziá-la.")
                    .font(.callout).foregroundStyle(.secondary)
                if let blockingWarning {
                    Label(blockingWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange).padding(.top, 4)
                }
            }
            .padding(20)
            Divider()
            List {
                Section {
                    ForEach(plan.units) { unit in
                        Toggle(isOn: Binding(
                            get: { !excluded.contains(unit.path) },
                            set: { if $0 { excluded.remove(unit.path) } else { excluded.insert(unit.path) } }
                        )) {
                            UnitRow(unit: unit, note: notes[unit.path])
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                if !plan.blocked.isEmpty {
                    Section("Não serão removidos") {
                        ForEach(plan.blocked, id: \.unit.path) { item in
                            HStack {
                                Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                                UnitRow(unit: item.unit, note: "Protegido: \(item.reason)")
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Text("\(formatBytes(chosen.totalBytes)) em \(chosen.units.count) itens")
                    .font(.headline).monospacedDigit()
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Mover para a Lixeira", role: .destructive) { outcomes = onExecute(chosen) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(chosen.units.isEmpty || blockingWarning != nil)
            }
            .padding(16)
        }
    }

    private func result(_ outcomes: [DeletionPlanner.Outcome]) -> some View {
        let failed = outcomes.filter { $0.error != nil }
        let moved = outcomes.filter { $0.error == nil }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label(failed.isEmpty ? "Movido para a Lixeira" : "Parte não foi movida",
                      systemImage: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(failed.isEmpty ? Color.green : Color.orange)
                Text("\(moved.count) itens, \(formatBytes(moved.reduce(0) { $0 + $1.unit.bytes })). Esvazie a Lixeira para recuperar o espaço.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            List {
                if !failed.isEmpty {
                    Section("Falharam: feche os apps que usam esses arquivos e tente de novo") {
                        ForEach(failed, id: \.unit.path) { outcome in
                            VStack(alignment: .leading, spacing: 2) {
                                UnitRow(unit: outcome.unit)
                                Text(outcome.error ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Movidos") {
                    ForEach(moved, id: \.unit.path) { UnitRow(unit: $0.unit) }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }
}

struct UnitRow: View {
    let unit: DeletionPlan.Unit
    /// Replaces the parent-folder line (e.g. why the item is protected).
    var note: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: unit.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(unit.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(unit.name).lineLimit(1)
                Text(note ?? ((unit.path as NSString).deletingLastPathComponent).abbreviatingHome)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let date = unit.lastModified {
                Text(date.relativeDescription).font(.caption).foregroundStyle(.secondary)
            }
            Text(formatBytes(unit.bytes)).monospacedDigit().frame(width: 76, alignment: .trailing)
        }
    }
}
