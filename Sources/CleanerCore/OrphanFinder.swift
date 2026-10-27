import CoreServices
import Foundation

/// Data left in the Library by apps that are no longer installed ("leftovers of removed apps").
/// Derived from the disk: a folder named like a bundle id whose app neither is installed nor known to LaunchServices.
public struct OrphanFinder {
    public struct Item: Sendable, Hashable {
        public let path: String
        /// Caches, cookies, web storage, window state: the app would rebuild them anyway.
        public let isRegenerable: Bool
    }

    public struct Group: Sendable, Identifiable {
        public var id: String { bundleID }
        public let bundleID: String
        public let items: [Item]
    }

    let home: String
    let installedIDs: [String]
    let isRegistered: (String) -> Bool

    public init(home: String = NSHomeDirectory(), installedIDs: [String],
                isRegistered: @escaping (String) -> Bool = OrphanFinder.launchServicesKnows) {
        self.home = home
        self.installedIDs = installedIDs.map { $0.lowercased() }
        self.isRegistered = isRegistered
    }

    static let folders: [(name: String, regenerable: Bool)] = [
        ("Caches", true), ("HTTPStorages", true), ("WebKit", true), ("Saved Application State", true),
        ("Containers", false), ("Group Containers", false), ("Application Support", false),
        ("Application Scripts", false), ("Preferences", false),
    ]
    static let idPattern = #"^[a-z0-9-]+(\.[a-z0-9_-]+){2,}$"#

    public func find() -> [Group] {
        var byID: [String: [Item]] = [:]
        let fm = FileManager.default
        for folder in Self.folders {
            let base = "\(home)/Library/\(folder.name)"
            for entry in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
                guard let id = Self.bundleID(fromEntry: entry, folder: folder.name), isOrphan(id) else { continue }
                byID[id, default: []].append(Item(path: "\(base)/\(entry)", isRegenerable: folder.regenerable))
            }
        }
        return byID.map { Group(bundleID: $0.key, items: $0.value) }.sorted { $0.bundleID < $1.bundleID }
    }

    /// `com.x.app.savedState`, `com.x.app.plist`, `com.x.app.ShipIt`, `TEAMID.com.x.app` → `com.x.app`.
    static func bundleID(fromEntry entry: String, folder: String) -> String? {
        var stem = entry.lowercased()
        for suffix in [".savedstate", ".binarycookies", ".plist", ".shipit"] where stem.hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
        }
        if folder == "Group Containers" || folder == "Application Scripts" {
            // `TEAMID.`, then `group.`/`groups.` (e.g. `243LU875E5.groups.com.apple.podcasts`).
            if let range = stem.range(of: #"^[a-z0-9]{10}\."#, options: .regularExpression) { stem.removeSubrange(range) }
            for prefix in ["groups.", "group."] where stem.hasPrefix(prefix) { stem = String(stem.dropFirst(prefix.count)) }
        }
        guard stem.range(of: idPattern, options: .regularExpression) != nil else { return nil }
        return stem
    }

    func isOrphan(_ id: String) -> Bool {
        // Apple ids come behind many prefixes (`group.`, `systemgroup.`, team ids): match anywhere.
        if id.hasPrefix("com.apple.") || id.contains(".com.apple.") { return false }
        // Extensions/helpers of an installed app, or an org folder holding an installed app's id.
        let related = installedIDs.contains { $0 == id || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }
        return !related && !isRegistered(id)
    }

    /// Any app with this id anywhere LaunchServices knows (other disks, /System, Setapp...).
    public static func launchServicesKnows(_ id: String) -> Bool {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL]
        else { return false }
        return !urls.isEmpty
    }
}
