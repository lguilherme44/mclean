import Charts
import CleanerCore
import SwiftUI

/// Free space over time + cleanups as events on the same axis + the pace/forecast sentence.
/// One series, so the title names it and there is no legend box; cleanups are event rules, never
/// a second y-scale. The cleanup list below is the table view: no value lives only in a tooltip.
struct HistorySection: View {
    let history: History

    private var forecast: Forecast? { Forecast.make(history) }

    private var recentSamples: [History.Sample] {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        return history.samples.filter { $0.date >= cutoff }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Espaço livre nos últimos 30 dias").font(.headline)
            ForecastLine(forecast: forecast, samples: history.samples)
            if recentSamples.count >= 2 {
                FreeSpaceChart(samples: recentSamples, cleanups: history.cleanups.filter {
                    $0.date >= (recentSamples.first?.date ?? .distantPast)
                })
                .frame(height: 200)
                .padding(.top, 10) // room for the cleanup labels above the plot
            } else {
                Text("O mclean mede o disco ao abrir, a cada limpeza e no `mclean status`; o gráfico aparece a partir da segunda medição.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !history.cleanups.isEmpty {
                CleanupLog(cleanups: Array(history.cleanups.suffix(8).reversed()))
            }
        }
    }
}

private struct ForecastLine: View {
    let forecast: Forecast?
    let samples: [History.Sample]

    var body: some View {
        if let forecast {
            let perDay = formatBytes(Int64(abs(forecast.bytesPerDay)))
            if let days = forecast.daysUntilFull {
                let urgent = days < 30
                Label {
                    Text("No ritmo atual (−\(perDay)/dia), o disco enche em **~\(Int(days.rounded())) dias**.")
                } icon: {
                    Image(systemName: urgent ? "exclamationmark.triangle.fill" : "chart.line.downtrend.xyaxis")
                        .foregroundStyle(urgent ? Color.orange : Color.secondary)
                }
                .font(.callout)
            } else {
                Label("Uso estável nos últimos 14 dias (\(forecast.bytesPerDay >= 0 ? "+" : "−")\(perDay)/dia, sem contar limpezas).",
                      systemImage: "checkmark.circle")
                    .font(.callout)
            }
        } else {
            let days = Int(samples.first.map { Date().timeIntervalSince($0.date) / 86_400 } ?? 0)
            let span = days < 1 ? "desde hoje" : days == 1 ? "em 1 dia" : "em \(days) dias"
            let count = samples.count == 1 ? "1 medição" : "\(samples.count) medições"
            Label("Coletando dados: a previsão precisa de 5 medições ao longo de 2 dias (agora: \(count) \(span)).",
                  systemImage: "hourglass")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct FreeSpaceChart: View {
    let samples: [History.Sample]
    let cleanups: [History.Cleanup]
    @State private var hovered: History.Sample?

    private func gb(_ bytes: Int64) -> Double { Double(bytes) / 1_000_000_000 }

    var body: some View {
        Chart {
            ForEach(cleanups, id: \.date) { cleanup in
                RuleMark(x: .value("Limpeza", cleanup.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text(cleanup.freedBytes > 0 ? "+\(formatBytes(cleanup.freedBytes))" : cleanup.source)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
            }
            ForEach(samples, id: \.date) { sample in
                LineMark(x: .value("Data", sample.date), y: .value("Livre (GB)", gb(sample.freeBytes)))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let hovered {
                RuleMark(x: .value("Data", hovered.date))
                    .foregroundStyle(Color.primary.opacity(0.35))
                PointMark(x: .value("Data", hovered.date), y: .value("Livre (GB)", gb(hovered.freeBytes)))
                    .symbolSize(70)
                    .foregroundStyle(Color.accentColor)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatBytes(hovered.freeBytes)).font(.callout.weight(.semibold)).monospacedDigit()
                            Text(hovered.date.formatted(.dateTime.day().month().hour().minute().locale(Locale(identifier: "pt_BR"))))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v)) GB") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, dayStride))) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(Locale(identifier: "pt_BR")))
            }
        }
        .chartYScale(domain: 0...(Double(samples.map(\.freeBytes).max() ?? 0) / 1_000_000_000 * 1.2 + 1))
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case let .active(location) = phase, let plot = proxy.plotFrame else { hovered = nil; return }
                        let x = location.x - geometry[plot].origin.x
                        guard let date: Date = proxy.value(atX: x) else { return }
                        // Snap to the nearest sample: the crosshair finds the X.
                        hovered = samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                    }
            }
        }
        .accessibilityLabel("Espaço livre ao longo do tempo")
    }

    private var dayStride: Int {
        guard let first = samples.first?.date, let last = samples.last?.date else { return 1 }
        return Int((last.timeIntervalSince(first) / 86_400 / 6).rounded(.up))
    }
}

/// "Cleanup Log": what ran, when, and what was really freed (measured, not estimated).
private struct CleanupLog: View {
    let cleanups: [History.Cleanup]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Limpezas recentes").font(.subheadline.weight(.semibold)).padding(.bottom, 6)
            ForEach(Array(cleanups.enumerated()), id: \.offset) { index, cleanup in
                if index > 0 { Divider() }
                DisclosureGroup {
                    Text(cleanup.items.map { $0.abbreviatingHome }.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } label: {
                    HStack {
                        Text(cleanup.date.formatted(.dateTime.day().month().hour().minute().locale(Locale(identifier: "pt_BR"))))
                            .monospacedDigit()
                            .frame(width: 120, alignment: .leading)
                        Text(cleanup.source)
                        Text("· \(cleanup.items.count) \(cleanup.items.count == 1 ? "item" : "itens")")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(cleanup.freedBytes > 0 ? "+\(formatBytes(cleanup.freedBytes))" : "na Lixeira")
                            .monospacedDigit()
                            .foregroundStyle(cleanup.freedBytes > 0 ? .primary : .secondary)
                    }
                    .font(.callout)
                }
                .padding(.vertical, 6)
            }
        }
    }
}
