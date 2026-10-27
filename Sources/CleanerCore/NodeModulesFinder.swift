import Darwin
import Foundation

public struct NodeModulesCandidate: Codable, Sendable {
    public let path: String
    public let bytes: Int64
    /// Last commit (git) or `package.json` modification, whichever is known.
    public let lastActivity: Date

    public init(path: String, bytes: Int64, lastActivity: Date) {
        self.path = path
        self.bytes = bytes
        self.lastActivity = lastActivity
    }
}

/// Finds top-level `node_modules` (never nested ones) in projects idle for `idleDays`.
/// Measured on this machine: worktrees were 70% `node_modules`, and removing them from idle
/// projects frees space without losing any commit.
public enum NodeModulesFinder {
    /// Sizing dominates (discovery of 79 dirs: <1 s; sizing 28 GB on an external SSD: ~100 s
    /// sequentially), so candidates are measured in parallel. Each one gets its own calculator:
    /// hard links are deduplicated inside a `node_modules`, not across projects.
    public static func find(roots: [String], idleDays: Int, now: Date = Date()) -> [NodeModulesCandidate] {
        let idle = discover(roots: roots, idleDays: idleDays, now: now)
        let sizes = Slots(count: idle.count)
        DispatchQueue.concurrentPerform(iterations: idle.count) { index in
            sizes.set(index, measure(idle[index].path))
        }
        return idle.enumerated()
            .map { NodeModulesCandidate(path: $1.path, bytes: sizes.get($0), lastActivity: $1.lastActivity) }
            .sorted { $0.bytes > $1.bytes }
    }

    /// The cheap half: which `node_modules` belong to idle projects. Measured on 1,738
    /// node_modules: one `git log` process each took 155 s; a `stat` per repository takes ~1 s.
    public static func discover(roots: [String], idleDays: Int, now: Date = Date()) -> [(path: String, lastActivity: Date)] {
        let cutoff = now.addingTimeInterval(-Double(idleDays) * 86_400)
        let perRoot = Buckets(count: roots.count)
        // Roots are walked in parallel; each one owns its bucket and activity cache.
        DispatchQueue.concurrentPerform(iterations: roots.count) { index in
            var activity = ActivityCache()
            perRoot.set(index, directories(under: roots[index]).compactMap { dir in
                let project = (dir as NSString).deletingLastPathComponent
                guard let last = activity.lastActivity(of: project), last < cutoff else { return nil }
                return (dir, last)
            })
        }
        return (0..<roots.count).flatMap(perRoot.get)
    }

    private final class Buckets: @unchecked Sendable {
        private var values: [[(path: String, lastActivity: Date)]]
        private let lock = NSLock()
        init(count: Int) { values = Array(repeating: [], count: count) }
        func set(_ index: Int, _ items: [(path: String, lastActivity: Date)]) { lock.withLock { values[index] = items } }
        func get(_ index: Int) -> [(path: String, lastActivity: Date)] { lock.withLock { values[index] } }
    }

    /// The expensive half. Hard links are deduplicated within one `node_modules`.
    public static func measure(_ path: String) -> Int64 {
        SizeCalculator().allocatedSize(of: path)
    }

    /// Fixed-size results written from `concurrentPerform`: each index is touched by exactly one
    /// iteration, so the slots never race even though the buffer is shared.
    private final class Slots: @unchecked Sendable {
        private let buffer: UnsafeMutableBufferPointer<Int64>
        init(count: Int) {
            buffer = .allocate(capacity: count)
            buffer.initialize(repeating: 0)
        }
        deinit { buffer.deallocate() }
        func set(_ index: Int, _ value: Int64) { buffer[index] = value }
        func get(_ index: Int) -> Int64 { buffer[index] }
    }

    /// Build output and tool caches hold node_modules that are not projects of their own.
    static let prunedNames: Set<String> = [
        ".git", ".Trash", "Library", ".output", ".next", ".nuxt", "dist", "build", ".turbo",
        ".venv", "venv", "target", "Pods", "DerivedData", ".pnpm-store",
    ]

    static func directories(under root: String) -> [String] {
        var found: [String] = []
        let cPath = strdup(root)
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        // FTS_NOSTAT: directory type comes from readdir, so files are never stat'ed.
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV | FTS_NOSTAT, nil) else { return [] }
        defer { fts_close(stream) }
        while let entry = fts_read(stream) {
            guard Int32(entry.pointee.fts_info) == FTS_D else { continue }
            let path = String(cString: entry.pointee.fts_path)
            let name = (path as NSString).lastPathComponent
            if name == "node_modules" {
                found.append(path)
                fts_set(stream, entry, FTS_SKIP)
            } else if entry.pointee.fts_level > 0 && prunedNames.contains(name) {
                fts_set(stream, entry, FTS_SKIP)
            }
        }
        return found
    }

    /// Last activity of a project: when git last moved HEAD (commit, checkout, reset), read from
    /// the mtime of `<gitdir>/logs/HEAD`; without git, the `package.json` mtime.
    struct ActivityCache {
        private var byGitDir: [String: Date?] = [:]

        mutating func lastActivity(of project: String) -> Date? {
            if let gitDir = Self.gitDir(containing: project) {
                if let cached = byGitDir[gitDir] { return cached }
                let date = PathExpander.modificationDate(gitDir + "/logs/HEAD")
                    ?? PathExpander.modificationDate(gitDir + "/HEAD")
                byGitDir[gitDir] = date
                return date
            }
            return PathExpander.modificationDate((project as NSString).appendingPathComponent("package.json"))
        }

        /// Walks up to the enclosing repository. In a worktree `.git` is a file `gitdir: <path>`.
        static func gitDir(containing start: String) -> String? {
            var dir = start
            while dir != "/" && !dir.isEmpty {
                let dotGit = dir + "/.git"
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                    if isDirectory.boolValue { return dotGit }
                    guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    return target.hasPrefix("/") ? target : ((dir as NSString).appendingPathComponent(target) as NSString).standardizingPath
                }
                dir = (dir as NSString).deletingLastPathComponent
            }
            return nil
        }
    }}
