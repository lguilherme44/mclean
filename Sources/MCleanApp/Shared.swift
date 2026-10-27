import AppKit
import CleanerCore
import SwiftUI

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
}

enum Category: String, CaseIterable {
    case system, dev, ai, xcode, report

    var title: String {
        switch self {
        case .system: "Sistema"
        case .dev: "Desenvolvimento"
        case .ai: "Ferramentas de IA"
        case .xcode: "Xcode"
        case .report: "Só informativo"
        }
    }
}

/// Used/free capacity bar. Turns orange below 15% free and red below 5%, the point where
/// macOS starts failing to grow swap and refusing updates.
struct CapacityBar: View {
    let used: Int64
    let total: Int64

    private var freeFraction: Double { total > 0 ? Double(total - used) / Double(total) : 0 }

    private var tint: Color {
        switch freeFraction {
        case ..<0.05: .red
        case ..<0.15: .orange
        default: .accentColor
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(1 - freeFraction, 0), 1))
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("Uso do disco")
        .accessibilityValue("\(Int((1 - freeFraction) * 100)) por cento usado")
    }
}

/// Horizontal share bar for list rows.
struct ShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(proxy.size.width * min(fraction, 1), fraction > 0 ? 2 : 0))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

enum Finder {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @MainActor
    static func chooseFolder(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

extension String {
    /// Name of the external volume holding this path, or nil for the Mac's own disk.
    /// The startup volume's data is firmlinked at `/`, so anything under `/Volumes/` is elsewhere.
    var externalVolumeName: String? {
        guard hasPrefix("/Volumes/") else { return nil }
        return split(separator: "/").dropFirst().first.map(String.init)
    }

    /// `/Users/me/wk/app` → `~/wk/app`, for display only.
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}

/// Without Full Disk Access some rules cannot even list their folders; say so instead of showing
/// them as "nothing found", and send the user straight to the right Settings pane.
struct FullDiskAccessBanner: View {
    let blocked: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Sem Acesso Total ao Disco").font(.headline)
                Text("O macOS bloqueia a leitura \(blocked.formatted(.list(type: .and).locale(Locale(identifier: "pt_BR")))), então essas categorias não foram medidas. Ative o MClean em Ajustes → Privacidade e Segurança → Acesso Total ao Disco e volte para o app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Abrir Ajustes") { NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.3)))
    }
}
