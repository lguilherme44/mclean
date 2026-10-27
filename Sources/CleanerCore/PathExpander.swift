import Darwin
import Foundation

public enum PathExpander {
    /// Expands `~` and globs (braces included) into existing paths, sorted and deduplicated.
    /// `$UID` = the current user id (per-user folders such as `/Volumes/*/.Trashes/501`).
    public static func substitutingTokens(_ pattern: String) -> String {
        pattern.replacingOccurrences(of: "$UID", with: String(getuid()))
    }

    public static func expand(_ pattern: String, home: String = NSHomeDirectory()) -> [String] {
        let pattern = substitutingTokens(pattern)
        let expanded = pattern.hasPrefix("~") ? home + pattern.dropFirst() : pattern
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(expanded, GLOB_BRACE | GLOB_NOSORT, nil, &result) == 0 else { return [] }
        var paths: [String] = []
        for i in 0..<Int(result.gl_pathc) {
            if let cString = result.gl_pathv[i] { paths.append(String(cString: cString)) }
        }
        return Array(Set(paths)).sorted()
    }

    /// Paths for a rule after excludes and the age filter.
    public static func matches(for rule: Rule, home: String = NSHomeDirectory(), now: Date = Date()) -> [String] {
        let excludes = rule.exclude.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        let cutoff = rule.minAgeDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let all = Set(rule.paths.flatMap { expand($0, home: home) })
        var kept: Set<String> = []
        if let link = rule.keepActiveLink {
            let expanded = link.hasPrefix("~") ? home + link.dropFirst() : link
            guard let target = realPath(expanded) else { return [] }
            kept.formUnion(all.filter { SafetyGuard.isSameOrDescendant(target, of: realPath($0) ?? $0) })
        }
        if let newest = rule.keepNewest {
            let byVersion = all.sorted {
                ($0 as NSString).lastPathComponent.compare(($1 as NSString).lastPathComponent, options: .numeric)
                    == .orderedDescending
            }
            kept.formUnion(byVersion.prefix(newest))
        }
        if let recent = rule.keepMostRecent {
            let byDate = all.sorted { (modificationDate($0) ?? .distantPast) > (modificationDate($1) ?? .distantPast) }
            kept.formUnion(byDate.prefix(recent))
        }
        return all.subtracting(kept).filter { path in
            if excludes.contains(where: { fnmatch($0, path, 0) == 0 }) { return false }
            if let cutoff, let modified = modificationDate(path), modified > cutoff { return false }
            if let filter = rule.filter, !filter.accepts(path) { return false }
            return true
        }.sorted()
    }

    /// nil when the path (or a symlink in it) does not resolve.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func modificationDate(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }
}
