import Foundation

/// What a multi-selection in Space Lens really removes. Selecting `proj` and `proj/build` must not
/// count `build` twice nor try to trash it after its parent is gone, and items the guard refuses
/// are shown with their reason instead of disappearing from the review.
public struct DeletionPlan: Sendable {
    public struct Unit: Sendable, Identifiable, Hashable {
        public var id: String { path }
        public let path: String
        public let bytes: Int64
        public let isDirectory: Bool
        public let lastModified: Date?

        public var name: String { (path as NSString).lastPathComponent }

        public init(path: String, bytes: Int64, isDirectory: Bool, lastModified: Date?) {
            self.path = path
            self.bytes = bytes
            self.isDirectory = isDirectory
            self.lastModified = lastModified
        }
    }

    public struct Blocked: Sendable {
        public let unit: Unit
        public let reason: String

        public init(unit: Unit, reason: String) {
            self.unit = unit
            self.reason = reason
        }
    }

    public let units: [Unit]
    public let blocked: [Blocked]

    public init(units: [Unit], blocked: [Blocked]) {
        self.units = units
        self.blocked = blocked
    }

    public var totalBytes: Int64 { units.reduce(0) { $0 + $1.bytes } }

    /// The same plan with some units unchecked in the review.
    public func excluding(_ paths: Set<String>) -> DeletionPlan {
        DeletionPlan(units: units.filter { !paths.contains($0.path) }, blocked: blocked)
    }
}

public enum DeletionPlanner {
    public struct Outcome: Sendable {
        public let unit: DeletionPlan.Unit
        public let error: String?
    }

    public static func plan(_ nodes: [SpaceNode], guardrail: SafetyGuard = SafetyGuard()) -> DeletionPlan {
        // Shortest path first, so an ancestor is always kept before any of its descendants is seen.
        var kept: [SpaceNode] = []
        for node in nodes.sorted(by: { $0.path.count < $1.path.count }) {
            if kept.contains(where: { SafetyGuard.isSameOrDescendant(node.path, of: $0.path) }) { continue }
            kept.append(node)
        }
        var units: [DeletionPlan.Unit] = []
        var blocked: [DeletionPlan.Blocked] = []
        for node in kept.sorted(by: { $0.bytes > $1.bytes }) {
            let unit = DeletionPlan.Unit(
                path: node.path, bytes: node.bytes, isDirectory: node.isDirectory, lastModified: node.lastModified)
            if case let .denied(reason) = guardrail.checkTrash(node.path) {
                blocked.append(.init(unit: unit, reason: reason))
            } else {
                units.append(unit)
            }
        }
        return DeletionPlan(units: units, blocked: blocked)
    }

    /// Trashes every unit, continuing past failures (a file in use must not keep the rest selected).
    public static func execute(
        _ plan: DeletionPlan,
        trash: (String) throws -> Void = { try FileManager.default.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil) }
    ) -> [Outcome] {
        plan.units.map { unit in
            do {
                try trash(unit.path)
                return Outcome(unit: unit, error: nil)
            } catch {
                return Outcome(unit: unit, error: (error as NSError).localizedFailureReason ?? error.localizedDescription)
            }
        }
    }
}
