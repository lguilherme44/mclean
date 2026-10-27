import Foundation

public struct InstalledApp: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let bundleID: String
    public let name: String
    public let version: String?

    public init(path: String, bundleID: String, name: String, version: String?) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
        self.version = version
    }

    /// Apple's apps live on the sealed system volume or are reinstalled by the OS: never offered.
    public var isApple: Bool { bundleID.hasPrefix("com.apple.") }
}

public enum AppInventory {
    public static var defaultFolders: [String] { ["/Applications", NSHomeDirectory() + "/Applications"] }

    /// `*.app` directly in each folder, plus one level of plain subfolders (`/Applications/Setapp`,
    /// `/Applications/Utilities`). Apps without a bundle id are skipped: leftovers are found by it.
    public static func installed(in folders: [String] = defaultFolders) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        let fm = FileManager.default
        func visit(_ folder: String, depth: Int) {
            for entry in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = (folder as NSString).appendingPathComponent(entry)
                if entry.hasSuffix(".app") {
                    if let app = read(path) { apps.append(app) }
                } else if depth == 0, (try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory {
                    visit(path, depth: 1)
                }
            }
        }
        for folder in folders { visit(folder, depth: 0) }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func read(_ path: String) -> InstalledApp? {
        guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return InstalledApp(path: path, bundleID: bundleID, name: name,
                            version: info["CFBundleShortVersionString"] as? String)
    }
}

public enum LeftoverMatch: String, Sendable, Hashable {
    /// Folder or file named after the bundle id (or an extension of it): certain.
    case bundleID
    /// Launch agent that declares the app (`AssociatedBundleIdentifiers`) or is labeled with its id.
    case launchAgent
    /// Folder whose name contains every word of the app's name: likely, never pre-selected.
    case name
}

public struct Leftover: Sendable, Hashable {
    public let path: String
    public let match: LeftoverMatch
}

/// Where an app leaves data in the user's Library
/// (bundle-id directories, word match on the app name, `AssociatedBundleIdentifiers`).
public struct LeftoverFinder {
    let home: String

    public init(home: String = NSHomeDirectory()) { self.home = home }

    static let bundleIDFolders = [
        "Application Support", "Caches", "Containers", "Group Containers", "Preferences", "Preferences/ByHost",
        "Saved Application State", "HTTPStorages", "WebKit", "Cookies", "Logs", "Application Scripts",
    ]
    /// Name matching only where apps create human-named folders.
    static let nameFolders = ["Application Support", "Caches", "Logs"]
    static let suffixes = [".savedState", ".binarycookies", ".plist"]

    /// `installed`: every app on the Mac, so a folder matched by name is not offered when a more
    /// specific installed app (more name words) also matches it.
    public func leftovers(of app: InstalledApp, installed: [InstalledApp] = []) -> [Leftover] {
        let fm = FileManager.default
        var found: [Leftover] = []
        var seen = Set<String>()
        func add(_ path: String, _ match: LeftoverMatch) {
            if seen.insert(path).inserted { found.append(Leftover(path: path, match: match)) }
        }
        let id = app.bundleID.lowercased()

        for folder in Self.bundleIDFolders {
            let base = "\(home)/Library/\(folder)"
            for entry in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
                var stem = entry.lowercased()
                for suffix in Self.suffixes where stem.hasSuffix(suffix) { stem = String(stem.dropLast(suffix.count)) }
                // Exact id, an extension/helper of it (`id.share-extension`, ByHost `id.<uuid>`), or a
                // group container prefixed by the team id / `group.`.
                let isOurs = stem == id || stem.hasPrefix(id + ".")
                    || (folder == "Group Containers" && stem.hasSuffix("." + id))
                if isOurs { add("\(base)/\(entry)", .bundleID) }
            }
        }

        let agents = "\(home)/Library/LaunchAgents"
        for entry in (try? fm.contentsOfDirectory(atPath: agents)) ?? [] where entry.hasSuffix(".plist") {
            let path = "\(agents)/\(entry)"
            let label = String(entry.dropLast(".plist".count)).lowercased()
            if label == id || label.hasPrefix(id + ".") { add(path, .launchAgent); continue }
            guard let data = fm.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            let associated = plist["AssociatedBundleIdentifiers"]
            let ids = (associated as? [String]) ?? (associated as? String).map { [$0] } ?? []
            if ids.contains(where: { $0.lowercased() == id }) { add(path, .launchAgent) }
        }

        if !app.isApple {
            for folder in Self.nameFolders {
                let base = "\(home)/Library/\(folder)"
                let appWordCount = Self.words(app.name).count
                for entry in (try? fm.contentsOfDirectory(atPath: base)) ?? []
                where Self.nameMatches(resource: entry, appName: app.name) {
                    let ownedByOther = installed.contains { other in
                        other.bundleID != app.bundleID && Self.words(other.name).count > appWordCount
                            && Self.nameMatches(resource: entry, appName: other.name)
                    }
                    if !ownedByOther { add("\(base)/\(entry)", .name) }
                }
            }
        }
        return found
    }

    static let separators = CharacterSet(charactersIn: " -_.")

    /// Every word of the app name must be a word of the resource ("Super Notes Helper" yes,
    /// "Notes" no). A resource that is the app name plus a version ("Super Notes 3") belongs to
    /// another version that may be installed, so it does not match. Names under 4 letters ("Arc",
    /// "Go") are too generic to match by name at all.
    public static func nameMatches(resource: String, appName: String) -> Bool {
        let appWords = words(appName)
        guard appWords.joined().count >= 4 else { return false }
        let resourceLower = resource.lowercased()
        let nameLower = appName.lowercased()
        if resourceLower.hasPrefix(nameLower) {
            let rest = resourceLower.dropFirst(nameLower.count).trimmingCharacters(in: separators)
            if !rest.isEmpty, rest.range(of: #"^v?\d+(\.\d+)*$"#, options: .regularExpression) != nil { return false }
        }
        let resourceWords = Set(words(resource))
        return appWords.allSatisfy(resourceWords.contains)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
    }
}

public enum UninstallPlanner {
    /// The app bundle goes to the Trash only when it is a third-party `.app` directly inside one of
    /// the app folders (one level of subfolder allowed, e.g. Setapp). Leftovers use the Trash guard.
    public static func plan(
        app: InstalledApp, leftovers: [Leftover], appFolders: [String] = AppInventory.defaultFolders,
        guardrail: SafetyGuard = SafetyGuard(),
        size: (String) -> Int64 = { SizeCalculator().allocatedSize(of: $0) }
    ) -> DeletionPlan {
        func unit(_ path: String) -> DeletionPlan.Unit {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return DeletionPlan.Unit(path: path, bytes: size(path), isDirectory: isDirectory.boolValue,
                                     lastModified: PathExpander.modificationDate(path))
        }
        var units: [DeletionPlan.Unit] = []
        var blocked: [DeletionPlan.Blocked] = []
        if let reason = appGuard(app, appFolders: appFolders) {
            blocked.append(.init(unit: unit(app.path), reason: reason))
        } else {
            units.append(unit(app.path))
        }
        for leftover in leftovers {
            if case let .denied(reason) = guardrail.checkTrash(leftover.path) {
                blocked.append(.init(unit: unit(leftover.path), reason: reason))
            } else {
                units.append(unit(leftover.path))
            }
        }
        return DeletionPlan(units: units, blocked: blocked)
    }

    static func appGuard(_ app: InstalledApp, appFolders: [String]) -> String? {
        if app.isApple { return "app da Apple" }
        guard app.path.hasSuffix(".app") else { return "não é um app" }
        let parent = (app.path as NSString).deletingLastPathComponent
        let grandparent = (parent as NSString).deletingLastPathComponent
        guard appFolders.contains(parent) || (appFolders.contains(grandparent) && !parent.hasSuffix(".app")) else {
            return "fora das pastas de aplicativos"
        }
        return nil
    }
}

extension AppInventory {
    /// When the app was last opened, from Spotlight; nil if never opened or not indexed.
    public static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

extension AppInventory {
    /// Spotlight's "last used" is missing for many apps, so the newest modification of the app's
    /// own data folders (matched by bundle id, not by name) also counts as activity.
    public static func lastActivity(spotlight: Date?, leftovers: [Leftover]) -> Date? {
        let dates = leftovers.filter { $0.match != .name }.compactMap { PathExpander.modificationDate($0.path) }
        return ([spotlight].compactMap { $0 } + dates).max()
    }
}

extension AppInventory {
    /// Bundle ids of helpers shipped inside an app (login items, XPC services, extensions): they
    /// write their own Library folders and must not look orphaned while the app is installed.
    public static func embeddedBundleIDs(in appPath: String) -> [String] {
        var ids: [String] = []
        for sub in ["Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/XPCServices",
                    "Contents/PlugIns", "Contents/Helpers"] {
            let base = (appPath as NSString).appendingPathComponent(sub)
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] {
                let plist = "\(base)/\(entry)/Contents/Info.plist"
                if let info = NSDictionary(contentsOfFile: plist), let id = info["CFBundleIdentifier"] as? String {
                    ids.append(id)
                }
            }
        }
        return ids.sorted()
    }
}
