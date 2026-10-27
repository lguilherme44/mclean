import CoreGraphics
import Foundation

/// Squarified treemap (Bruls, Huizing & van Wijk): rows of tiles whose aspect ratio stays close
/// to 1, so areas can be compared by eye. Pure geometry, no UI: the app only draws the rects.
public enum Treemap {
    public enum Tile: Equatable, Sendable {
        case node(path: String)
        /// The long tail folded into one tile ("Outros itens").
        case other(count: Int)
    }

    public struct Entry: Equatable, Sendable {
        public let tile: Tile
        public let bytes: Int64
        public let rect: CGRect
    }

    /// Children below `minFraction` of the parent, or past `maxTiles`, become one "other" tile.
    public static func layout(
        _ children: [SpaceNode], in bounds: CGRect, minFraction: Double = 0.01, maxTiles: Int = 40
    ) -> [Entry] {
        let total = children.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let sorted = children.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        var tiles: [(Tile, Int64)] = []
        var folded: [SpaceNode] = []
        for child in sorted {
            if tiles.count < maxTiles - 1, Double(child.bytes) / Double(total) >= minFraction {
                tiles.append((.node(path: child.path), child.bytes))
            } else {
                folded.append(child)
            }
        }
        // A single leftover is shown as itself: "Other items (1)" would only hide its name.
        if folded.count == 1 {
            tiles.append((.node(path: folded[0].path), folded[0].bytes))
        } else if !folded.isEmpty {
            tiles.append((.other(count: folded.count), folded.reduce(0) { $0 + $1.bytes }))
        }
        let rects = squarify(tiles.map { Double($0.1) }, in: bounds)
        return zip(tiles, rects).map { Entry(tile: $0.0, bytes: $0.1, rect: $1) }
    }

    /// Rects for `values` (any order; the result keeps it), filling `bounds` exactly.
    public static func squarify(_ values: [Double], in bounds: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0 else { return values.map { _ in .zero } }
        let scale = Double(bounds.width * bounds.height) / total
        let order = values.indices.sorted { values[$0] > values[$1] }
        var result = [CGRect](repeating: .zero, count: values.count)
        var free = bounds
        var row: [Int] = []

        func worst(_ indices: [Int], side: Double) -> Double {
            let areas = indices.map { values[$0] * scale }
            let sum = areas.reduce(0, +)
            guard sum > 0, let maxA = areas.max(), let minA = areas.min(), minA > 0 else { return .infinity }
            return max(side * side * maxA / (sum * sum), (sum * sum) / (side * side * minA))
        }

        func place(_ indices: [Int]) {
            let sum = indices.reduce(0) { $0 + values[$1] * scale }
            guard sum > 0 else { return }
            if free.width >= free.height {
                // Column on the left, tiles stacked top to bottom.
                let width = CGFloat(sum) / free.height
                var y = free.minY
                for index in indices {
                    let height = CGFloat(values[index] * scale) / width
                    result[index] = CGRect(x: free.minX, y: y, width: width, height: height)
                    y += height
                }
                free = CGRect(x: free.minX + width, y: free.minY, width: max(0, free.width - width), height: free.height)
            } else {
                let height = CGFloat(sum) / free.width
                var x = free.minX
                for index in indices {
                    let width = CGFloat(values[index] * scale) / height
                    result[index] = CGRect(x: x, y: free.minY, width: width, height: height)
                    x += width
                }
                free = CGRect(x: free.minX, y: free.minY + height, width: free.width, height: max(0, free.height - height))
            }
        }

        for index in order where values[index] > 0 {
            let side = Double(min(free.width, free.height))
            if row.isEmpty || worst(row + [index], side: side) <= worst(row, side: side) {
                row.append(index)
            } else {
                place(row)
                row = [index]
            }
        }
        if !row.isEmpty { place(row) }
        return result
    }
}

/// How long a file or folder has been untouched, in the bands the Space Lens map colors by.
public enum AgeBand: Int, CaseIterable, Sendable, Comparable {
    case underMonth, months1to6, months6to12, years1to2, over2Years

    public init(lastModified: Date, now: Date = Date()) {
        let days = now.timeIntervalSince(lastModified) / 86_400
        switch days {
        case ..<30: self = .underMonth
        case ..<182: self = .months1to6
        case ..<365: self = .months6to12
        case ..<730: self = .years1to2
        default: self = .over2Years
        }
    }

    public static func < (lhs: AgeBand, rhs: AgeBand) -> Bool { lhs.rawValue < rhs.rawValue }
}
