import Darwin
import Foundation

public struct DiskStatus: Codable, Sendable {
    public let freeBytes: Int64
    public let totalBytes: Int64
    /// Reclaimed by macOS on demand (local snapshots, system caches): not counted in `freeBytes`.
    public let purgeableBytes: Int64
    public let swapUsedBytes: Int64
    public let localSnapshots: [String]

    public static func current(volume: String = "/") -> DiskStatus {
        let values = try? URL(fileURLWithPath: volume)
            .resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey])
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? Int64(swap.xsu_used) : 0
        let snapshots = (try? ProcessRunner.run(["/usr/bin/tmutil", "listlocalsnapshots", volume]))?.output
            .split(separator: "\n").map(String.init).filter { $0.hasPrefix("com.apple") } ?? []
        let free = Int64(values?.volumeAvailableCapacity ?? 0)
        return DiskStatus(
            freeBytes: free,
            totalBytes: Int64(values?.volumeTotalCapacity ?? 0),
            purgeableBytes: max(0, (values?.volumeAvailableCapacityForImportantUsage ?? free) - free),
            swapUsedBytes: swapUsed,
            localSnapshots: snapshots
        )
    }
}
