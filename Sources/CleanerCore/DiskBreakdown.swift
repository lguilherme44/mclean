import Foundation

/// How a volume's capacity splits for the Space Lens indicator. `free` is what `df` shows;
/// `purgeable` is space macOS reclaims on its own (snapshots, system caches) and is neither free
/// nor really used. The selection is part of the used space.
public struct DiskBreakdown: Equatable, Sendable {
    public let otherUsed: Int64
    public let selected: Int64
    public let purgeable: Int64
    public let free: Int64

    public var total: Int64 { otherUsed + selected + purgeable + free }
    /// `free` once the selection is trashed AND the Trash is emptied.
    public var freeAfterRemoval: Int64 { free + selected }

    public init(total: Int64, free: Int64, purgeable: Int64, selected: Int64) {
        let free = min(max(free, 0), total)
        let purgeable = min(max(purgeable, 0), total - free)
        let used = total - free - purgeable
        self.selected = min(max(selected, 0), used)
        otherUsed = used - self.selected
        self.purgeable = purgeable
        self.free = free
    }
}
