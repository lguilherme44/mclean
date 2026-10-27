import Foundation

/// Last line of defense: no path reaches `removeItem` without passing `check`.
/// Rules are data and can be edited by hand, so the guard must not trust them.
public struct SafetyGuard: Sendable {
    public let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = Self.canonical(home)
    }

    /// Directories whose *children* a rule may target, but which are never targets themselves.
    var protectedExact: Set<String> {
        let h = home
        return [
            "/", "/Users", "/Library", "/Applications", "/System", "/Volumes", "/private", "/private/var",
            "/private/var/folders", h, "\(h)/Library", "\(h)/Library/Caches", "\(h)/Library/Logs",
            "\(h)/Library/Application Support", "\(h)/Library/Containers", "\(h)/Library/Group Containers",
            "\(h)/Library/Developer", "\(h)/Library/Developer/Xcode", "\(h)/.cache", "\(h)/.Trash",
            "\(h)/Documents", "\(h)/Desktop", "\(h)/Downloads", "\(h)/Pictures", "\(h)/Movies", "\(h)/Music",
            "\(h)/.config", "\(h)/.local",
        ]
    }

    /// Subtrees that hold user data or credentials; nothing under them is ever deleted.
    var neverTouch: [String] {
        let h = home
        return [
            "/System", "/usr", "/bin", "/sbin", "/Applications", "\(h)/Documents", "\(h)/Desktop",
            "\(h)/Pictures", "\(h)/Movies", "\(h)/Music", "\(h)/.ssh", "\(h)/.gnupg",
            "\(h)/Library/Keychains", "\(h)/Library/Mobile Documents", "\(h)/Library/Mail",
            "\(h)/Library/Messages", "\(h)/Library/Photos", "\(h)/.claude",
        ]
    }

    /// Roots under which deletion is allowed at all.
    var allowedRoots: [String] {
        [home, "/private/var/folders", "/Library/Caches", "/Library/Logs", "/Library/Developer/CoreSimulator/Caches"]
    }

    public enum Verdict: Equatable, Sendable {
        case allowed
        case denied(String)
    }

    public func check(_ path: String) -> Verdict {
        let resolved = Self.resolveParent(of: path)
        if protectedExact.contains(resolved) { return .denied("diretório protegido") }
        if neverTouch.contains(where: { Self.isSameOrDescendant(resolved, of: $0) }) {
            return .denied("área de dados do usuário")
        }
        if protectedExact.contains(where: { Self.isSameOrDescendant($0, of: resolved) }) {
            return .denied("contém diretório protegido")
        }
        if Self.isInsideMyVolumeTrash(resolved) { return .allowed }
        guard allowedRoots.contains(where: { Self.isSameOrDescendant(resolved, of: $0) }) else {
            return .denied("fora das raízes permitidas")
        }
        return .allowed
    }

    /// An item inside `/Volumes/<disk>/.Trashes/<my uid>/`: already deleted by me on that disk.
    /// The trash folder itself and other users' trashes stay out.
    static func isInsideMyVolumeTrash(_ resolved: String) -> Bool {
        let parts = (resolved as NSString).pathComponents
        return parts.count >= 6 && parts[1] == "Volumes" && parts[3] == ".Trashes" && parts[4] == String(getuid())
            && !parts[5...].contains("..")
    }

    /// For items the user picked by hand (Space Lens) and that go to the Trash, which is
    /// reversible: anything under home except the structural directories and credential stores.
    public func checkTrash(_ path: String) -> Verdict {
        let resolved = Self.resolveParent(of: path)
        guard Self.isSameOrDescendant(resolved, of: home) else { return .denied("fora da pasta pessoal") }
        if protectedExact.contains(where: { Self.isSameOrDescendant($0, of: resolved) }) {
            return .denied("diretório estrutural")
        }
        let credentials = ["\(home)/Library/Keychains", "\(home)/.ssh", "\(home)/.gnupg", "\(home)/Library/Mobile Documents"]
        if credentials.contains(where: { Self.isSameOrDescendant(resolved, of: $0) }) {
            return .denied("credenciais ou iCloud")
        }
        return .allowed
    }

    /// Directories where every entry is live configuration: a rule may only sweep them through a
    /// content filter (`MatchFilter`), never by glob alone.
    public static func requiresFilter(pattern: String, home: String = NSHomeDirectory()) -> Bool {
        let expanded = pattern.hasPrefix("~") ? home + pattern.dropFirst() : pattern
        return ["\(home)/Library/Preferences", "\(home)/Library/LaunchAgents"].contains {
            isSameOrDescendant(expanded, of: $0)
        }
    }

    /// Patterns whose literal prefix is a broad parent would sweep up unrelated data (`~/*`, `~/Library/*`).
    public static func isTooBroad(pattern: String, home: String = NSHomeDirectory()) -> Bool {
        // The only sweep allowed under /Volumes: my own trash on each disk (guarded by `check`).
        if pattern.hasPrefix("/Volumes/*/.Trashes/$UID/") { return false }
        let expanded = pattern.hasPrefix("~") ? home + pattern.dropFirst() : pattern
        let components = (expanded as NSString).pathComponents
        var literal: [String] = []
        for component in components {
            if component.contains(where: { "*?[{".contains($0) }) { break }
            literal.append(component)
        }
        if literal.count == components.count { return false } // no glob: exact path, guard decides
        let prefix = (NSString.path(withComponents: literal) as NSString).standardizingPath
        let broad: Set<String> = [
            "/", "/Users", "/Library", "/Volumes", home, "\(home)/Library",
            "\(home)/Library/Application Support", "\(home)/Library/Containers",
            "\(home)/Library/Group Containers", "\(home)/Documents", "\(home)/Desktop",
        ]
        return broad.contains(prefix)
    }

    /// Resolves symlinks in the parent chain but keeps the last component, so a symlinked
    /// cache entry is judged by where it lives, and deleting it removes the link, not its target.
    static func resolveParent(of path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        let parent = (standardized as NSString).deletingLastPathComponent
        let name = (standardized as NSString).lastPathComponent
        let resolvedParent = canonical(parent)
        return resolvedParent == "/" ? "/" + name : resolvedParent + "/" + name
    }

    /// `resolvingSymlinksInPath` strips `/private` from `/private/var/...`; put it back so
    /// every path the guard compares lives in the same namespace.
    static func canonical(_ path: String) -> String {
        let resolved = ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        for prefix in ["/var", "/tmp", "/etc"] where resolved == prefix || resolved.hasPrefix(prefix + "/") {
            return "/private" + resolved
        }
        return resolved
    }

    static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}
