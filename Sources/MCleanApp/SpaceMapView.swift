import AppKit
import CleanerCore
import SwiftUI

/// Ordinal age ramp (one hue, older = further from the surface), validated with the dataviz
/// validator: light `--ordinal` PASS on #fcfcfb, dark PASS on #1a1a19. Label ink per step picked
/// by APCA (black only where it out-scores white).
extension AgeBand {
    var title: String {
        switch self {
        case .underMonth: "< 1 mês"
        case .months1to6: "1–6 meses"
        case .months6to12: "6–12 meses"
        case .years1to2: "1–2 anos"
        case .over2Years: "> 2 anos"
        }
    }

    func fill(_ scheme: ColorScheme) -> Color {
        let light: [UInt32] = [0x86B6EF, 0x5598E7, 0x2A78D6, 0x1C5CAB, 0x0D366B]
        let dark: [UInt32] = [0x184F95, 0x256ABF, 0x3987E5, 0x6DA7EC, 0xB7D3F6]
        return Color(hex: (scheme == .dark ? dark : light)[rawValue])
    }

    func ink(_ scheme: ColorScheme) -> Color {
        let blackOnLight: Set<AgeBand> = [.underMonth]
        let blackOnDark: Set<AgeBand> = [.years1to2, .over2Years]
        return (scheme == .dark ? blackOnDark : blackOnLight).contains(self) ? Color(hex: 0x0B0B0B) : .white
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension Date {
    var relativeDescription: String {
        formatted(.relative(presentation: .named).locale(Locale(identifier: "pt_BR")))
    }
}

/// Treemap of one folder: area = allocated size, color = how long its content has been untouched.
struct SpaceMapView: View {
    let node: SpaceNode
    @Binding var selection: Set<String>
    let onOpen: (SpaceNode) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovered: Treemap.Entry?
    @State private var pointer: CGPoint = .zero

    var body: some View {
        GeometryReader { proxy in
            let entries = Treemap.layout(node.children, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(entries, id: \.rect.debugDescription) { entry in
                    tile(entry)
                }
                if let hovered {
                    // Kept inside the map: flips to the left/top of the pointer near the edges.
                    tooltip(for: hovered)
                        .fixedSize()
                        .offset(x: pointer.x + 240 > proxy.size.width ? max(pointer.x - 234, 0) : pointer.x + 14,
                                y: pointer.y + 80 > proxy.size.height ? max(pointer.y - 74, 0) : pointer.y + 14)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(location):
                    pointer = location
                    hovered = entries.first { $0.rect.contains(location) }
                case .ended:
                    hovered = nil
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mapa de espaço de \(node.name)")
    }

    private func child(_ entry: Treemap.Entry) -> SpaceNode? {
        guard case let .node(path) = entry.tile else { return nil }
        return node.children.first { $0.path == path }
    }

    private func band(_ entry: Treemap.Entry) -> AgeBand? {
        child(entry)?.lastModified.map { AgeBand(lastModified: $0) }
    }

    @ViewBuilder private func tile(_ entry: Treemap.Entry) -> some View {
        let child = child(entry)
        let band = band(entry)
        // Neutral gray for "other items" and dateless entries: no age to encode.
        let fill = band?.fill(scheme) ?? Color(hex: scheme == .dark ? 0x4A4A47 : 0xC9C9C6)
        let ink = band?.ink(scheme) ?? (scheme == .dark ? .white : Color(hex: 0x0B0B0B))
        let isSelected = child.map { selection.contains($0.path) } ?? false
        // 1 pt inset on each side = the 2 pt surface gap between adjacent fills.
        let rect = entry.rect.insetBy(dx: 1, dy: 1)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(fill)
            if isSelected {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary, lineWidth: 2)
            }
            if rect.width > 64, rect.height > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label(entry, child)).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(formatBytes(entry.bytes)).font(.caption2).monospacedDigit()
                }
                .foregroundStyle(ink)
                .padding(6)
            }
        }
        .frame(width: max(rect.width, 0), height: max(rect.height, 0))
        .offset(x: rect.minX, y: rect.minY)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let child, child.isDirectory { onOpen(child) } }
        .onTapGesture {
            guard let path = child?.path else { return }
            // ⌘-click toggles, like the list; a plain click selects only this tile.
            if NSEvent.modifierFlags.contains(.command) {
                if selection.contains(path) { selection.remove(path) } else { selection.insert(path) }
            } else {
                selection = [path]
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label(entry, child))
        .accessibilityValue("\(formatBytes(entry.bytes))" + (child?.lastModified.map { ", modificado \($0.relativeDescription)" } ?? ""))
        .accessibilityAddTraits(.isButton)
    }

    private func label(_ entry: Treemap.Entry, _ child: SpaceNode?) -> String {
        if case let .other(count) = entry.tile { return "Outros itens (\(count))" }
        return child?.name ?? ""
    }

    private func tooltip(for entry: Treemap.Entry) -> some View {
        let child = child(entry)
        return VStack(alignment: .leading, spacing: 3) {
            Text(label(entry, child)).font(.callout.weight(.semibold)).lineLimit(1)
            Text("Tamanho: \(formatBytes(entry.bytes))").monospacedDigit()
            if let date = child?.lastModified {
                Text("Modificado: \(date.relativeDescription)")
            } else if case .other = entry.tile {
                Text("Itens pequenos somados")
            }
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .padding(8)
        .frame(maxWidth: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 3, y: 1)
    }
}

/// Legend for the age colors; identity never rides on color alone.
struct AgeLegend: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 14) {
            Text("Última modificação:").foregroundStyle(.secondary)
            ForEach(AgeBand.allCases, id: \.self) { band in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(band.fill(scheme)).frame(width: 12, height: 12)
                    Text(band.title)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

/// "X of Y used" for the scanned folder's volume, with the selection and purgeable space split
/// out. Purgeable is drawn as a texture of the used tone: it is used space macOS gives back by
/// itself, so it reads as "used, but soft" instead of as another category of color.
struct DiskIndicator: View {
    let volume: AppModel.LensVolume
    let selectedBytes: Int64

    private var breakdown: DiskBreakdown {
        DiskBreakdown(total: volume.status.totalBytes, free: volume.status.freeBytes,
                      purgeable: volume.status.purgeableBytes, selected: selectedBytes)
    }

    private static let used = Color.primary.opacity(0.42)
    private static let track = Color.primary.opacity(0.08)

    var body: some View {
        let b = breakdown
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(volume.name).font(.callout.weight(.semibold))
                Text("\(formatBytes(b.otherUsed + b.selected + b.purgeable)) usados de \(formatBytes(b.total))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if b.selected > 0 {
                    Text("Livre depois de esvaziar a Lixeira: \(formatBytes(b.freeAfterRemoval))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            GeometryReader { proxy in
                let total = max(Double(b.total), 1)
                let gaps: CGFloat = 2 * 3
                let width = max(proxy.size.width - gaps, 0)
                let w = { (bytes: Int64) in width * CGFloat(Double(bytes) / total) }
                HStack(spacing: 2) {
                    segment(Self.used, w(b.otherUsed))
                    segment(Color.accentColor, w(b.selected))
                    StripeFill(color: Self.used).frame(width: w(b.purgeable))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    segment(Self.track, w(b.free))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            HStack(spacing: 14) {
                legend(AnyView(Self.used), "Usado", b.otherUsed)
                if b.selected > 0 { legend(AnyView(Color.accentColor), "Selecionado", b.selected) }
                if b.purgeable > 0 {
                    legend(AnyView(StripeFill(color: Self.used)), "Liberável pelo macOS", b.purgeable)
                        .help("Espaço que o macOS recupera sozinho quando precisa: snapshots locais e caches do sistema.")
                }
                legend(AnyView(Self.track), "Livre", b.free)
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
    }

    private func segment(_ color: Color, _ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: max(width, 0))
    }

    private func legend(_ swatch: AnyView, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 5) {
            swatch.frame(width: 12, height: 12).clipShape(RoundedRectangle(cornerRadius: 2))
            Text(title)
            Text(formatBytes(bytes)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// 45° hatch, the texture used where color alone must not carry the meaning.
struct StripeFill: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 4
            }
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
    }
}
