import Darwin
import Foundation

public struct SpaceNode: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let isDirectory: Bool
    public var bytes: Int64
    /// Sorted by size, largest first. Empty for files and for directories below the kept depth.
    public var children: [SpaceNode]
    /// True when this directory has content that was aggregated but not kept as nodes.
    public var isTruncated: Bool
    /// Newest file modification anywhere below (files only: a directory's own mtime changes when
    /// an entry is added or removed, which says nothing about whether its content is in use).
    public var lastModified: Date?

    public init(path: String, isDirectory: Bool, bytes: Int64, children: [SpaceNode], isTruncated: Bool,
                lastModified: Date? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.bytes = bytes
        self.children = children
        self.isTruncated = isTruncated
        self.lastModified = lastModified
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// Space Lens: one physical traversal that aggregates allocated bytes into every directory,
/// keeping nodes only down to `depth` levels so memory stays bounded on a full home scan.
/// Deeper content still counts toward its nearest kept ancestor; drilling past the kept
/// depth means scanning again from that directory.
public enum SpaceLens {
    public struct Progress: Sendable {
        public let files: Int
        public let currentPath: String
    }

    /// Per directory; the long tail of tiny entries is still counted in the parent's bytes.
    public static let maxChildren = 300

    public static func scan(
        root: String, depth: Int = 3, isCancelled: () -> Bool = { false },
        progress: ((Progress) -> Void)? = nil
    ) -> SpaceNode? {
        final class Builder {
            let path: String
            let level: Int
            var bytes: Int64 = 0
            var children: [SpaceNode] = []
            var truncated = false
            var newest: time_t = 0
            init(path: String, level: Int) { self.path = path; self.level = level }
        }

        let cPath = strdup(root)
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(stream) }

        var stack: [Builder] = []
        var seenLinks = Set<[UInt64]>()
        var files = 0
        var result: SpaceNode?

        // A clock-skewed file (extracted archive, wrong camera clock) must not make a whole
        // folder look active, so timestamps more than a day ahead are ignored.
        let latestPlausible = time_t(Date().timeIntervalSince1970) + 86_400

        func date(_ seconds: time_t) -> Date? {
            seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
        }

        func allocated(_ info: stat) -> Int64 {
            if info.st_nlink > 1 && (info.st_mode & S_IFMT) != S_IFDIR {
                guard seenLinks.insert([UInt64(bitPattern: Int64(info.st_dev)), info.st_ino]).inserted else { return 0 }
            }
            return Int64(info.st_blocks) * 512
        }

        while let entry = fts_read(stream) {
            if isCancelled() { return nil }
            let level = Int(entry.pointee.fts_level)
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D:
                let builder = Builder(path: String(cString: entry.pointee.fts_path), level: level)
                if let stat = entry.pointee.fts_statp?.pointee { builder.bytes += allocated(stat) }
                stack.append(builder)
            case FTS_DP, FTS_DNR:
                // An unreadable directory comes back as FTS_DNR *in place of* FTS_DP, after its
                // FTS_D. Close it like any other directory, or the stack drifts and the scan of
                // a home folder (TCC-protected Mail, Safari…) never produces a root.
                let path = String(cString: entry.pointee.fts_path)
                guard let top = stack.last, top.path == path else { continue }
                if info == FTS_DNR { top.truncated = true }
                guard let done = stack.popLast() else { continue }
                var children = done.children.sorted { $0.bytes > $1.bytes }
                if children.count > maxChildren {
                    children.removeSubrange(maxChildren...)
                    done.truncated = true
                }
                let node = SpaceNode(
                    path: done.path, isDirectory: true, bytes: done.bytes,
                    children: children, isTruncated: done.truncated, lastModified: date(done.newest))
                if let parent = stack.last {
                    parent.bytes += node.bytes
                    parent.newest = max(parent.newest, done.newest)
                    if done.level <= depth {
                        parent.children.append(node)
                    } else {
                        parent.truncated = true
                    }
                } else {
                    result = node
                }
            case FTS_ERR, FTS_NS, FTS_DC:
                continue
            default:
                guard let stat = entry.pointee.fts_statp?.pointee else { continue }
                let bytes = allocated(stat)
                let mtime = stat.st_mtimespec.tv_sec
                let modified = mtime > latestPlausible ? 0 : mtime
                files += 1
                if files % 5_000 == 0 {
                    progress?(Progress(files: files, currentPath: String(cString: entry.pointee.fts_path)))
                }
                guard let parent = stack.last else {
                    // Root itself is a file.
                    return SpaceNode(path: root, isDirectory: false, bytes: bytes, children: [], isTruncated: false,
                                     lastModified: date(modified))
                }
                parent.bytes += bytes
                parent.newest = max(parent.newest, modified)
                if level <= depth && bytes > 0 {
                    parent.children.append(SpaceNode(
                        path: String(cString: entry.pointee.fts_path), isDirectory: false, bytes: bytes,
                        children: [], isTruncated: false, lastModified: date(modified)))
                } else if bytes > 0 {
                    parent.truncated = true
                }
            }
        }
        return result
    }
}
