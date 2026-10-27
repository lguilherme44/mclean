import Darwin
import Foundation

/// Measures allocated bytes (what deletion can actually free), not logical file size.
///
/// Hard links are counted once per calculator instance: pnpm and uv hard-link the same
/// file into many places, and summing each link would promise space that never comes back.
/// APFS clones (copy-on-write) cannot be detected from `stat` and are still overcounted;
/// that is why `clean` reports the free-space delta measured by the volume, not this estimate.
public final class SizeCalculator {
    private struct Inode: Hashable {
        let device: Int32
        let inode: UInt64
    }

    private var seenLinks = Set<Inode>()
    public private(set) var unreadable = 0

    public init() {}

    public func allocatedSize(of path: String) -> Int64 {
        var total: Int64 = 0
        let cPath = strdup(path)
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            unreadable += 1
            return 0
        }
        defer { fts_close(stream) }
        while let entry = fts_read(stream) {
            switch Int32(entry.pointee.fts_info) {
            case FTS_DNR, FTS_ERR, FTS_NS:
                unreadable += 1
            case FTS_DP:
                continue // directory already counted in pre-order
            default:
                guard let info = entry.pointee.fts_statp?.pointee else { continue }
                if info.st_nlink > 1 && (info.st_mode & S_IFMT) != S_IFDIR {
                    guard seenLinks.insert(Inode(device: info.st_dev, inode: info.st_ino)).inserted else { continue }
                }
                total += Int64(info.st_blocks) * 512
            }
        }
        return total
    }
}
