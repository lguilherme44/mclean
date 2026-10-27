import Foundation

/// An app moved to another disk, with a stub left in its place.
public struct HibernatedApp: Codable, Sendable, Equatable, Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let originalPath: String
    public let storedPath: String
    public let bytes: Int64
    public let date: Date
}

public enum HibernationError: Error, CustomStringConvertible {
    case notEligible(String)
    case copyNotVerified(String)
    case diskMissing(String)
    case notOurStub(String)
    case runningFromDisk(String)

    public var description: String {
        switch self {
        case let .notEligible(reason): "não pode hibernar: \(reason)"
        case let .copyNotVerified(reason): "a cópia não conferiu (\(reason)); nada foi apagado"
        case let .diskMissing(path): "o disco com \(path) não está conectado"
        case let .notOurStub(path): "\(path) não é o app-fantasma do mclean; nada foi alterado"
        case let .runningFromDisk(name): "\(name) está aberto a partir do disco externo: feche o app antes de acordá-lo"
        }
    }
}

/// "Offload app" for the Mac: the real bundle goes to another disk and a few-KB stub with the same
/// name and icon stays in the app folder, opening the real app when that disk is connected.
/// The original is only deleted after the copy verifies (signature + same files and bytes).
public struct Hibernator {
    public static let stubPrefix = "dev.lellis.mclean.stub."

    let registryURL: URL
    let appFolders: [String]
    /// Injected so tests can simulate a copy that loses data.
    /// Injected so tests can simulate macOS refusing a delete.
    public var remove: (String) throws -> Void = { try FileManager.default.removeItem(atPath: $0) }
    public var copy: (String, String) throws -> Void = { from, to in
        let result = try ProcessRunner.run(["/usr/bin/ditto", from, to])
        guard result.status == 0 else { throw HibernationError.copyNotVerified("ditto: \(result.output)") }
    }

    public init(registryURL: URL = Hibernator.defaultRegistryURL, appFolders: [String] = AppInventory.defaultFolders) {
        self.registryURL = registryURL
        self.appFolders = appFolders
    }

    public static var defaultRegistryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MClean/hibernated.json")
    }

    // MARK: Eligibility

    /// nil = can hibernate. Each reason is something macOS or the app requires to stay put.
    public func ineligibility(of app: InstalledApp, isRunning: Bool) -> String? {
        if let reason = UninstallPlanner.appGuard(app, appFolders: appFolders) { return reason }
        let contents = app.path + "/Contents"
        let fm = FileManager.default
        if fm.fileExists(atPath: contents + "/_MASReceipt") {
            return "é da App Store (as atualizações exigem /Applications)"
        }
        if let items = try? fm.contentsOfDirectory(atPath: contents + "/Library/SystemExtensions"), !items.isEmpty {
            return "tem extensão de sistema/VPN (o macOS exige /Applications)"
        }
        if let items = try? fm.contentsOfDirectory(atPath: contents + "/Library/LaunchServices"), !items.isEmpty {
            return "instala um helper privilegiado"
        }
        if access(app.path, W_OK) != 0 || access((app.path as NSString).deletingLastPathComponent, W_OK) != 0 {
            return "sem permissão de escrita (precisa de senha de administrador)"
        }
        // Transient reason last: a permanent one must not hide behind "close it first".
        if isRunning { return "está aberto" }
        return nil
    }

    /// Apps run from APFS or HFS+ only: exFAT/FAT lose permissions and signatures.
    public static func volumeCanHoldApps(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let type = withUnsafeBytes(of: info.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return type == "apfs" || type == "hfs"
    }

    // MARK: Hibernate / wake

    public func hibernate(_ app: InstalledApp, to folder: String, isRunning: Bool = false) throws -> HibernatedApp {
        if let reason = ineligibility(of: app, isRunning: isRunning) { throw HibernationError.notEligible(reason) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // A copy left by an earlier run must not block this one, and is never overwritten.
        let bundleName = ((app.path as NSString).lastPathComponent as NSString).deletingPathExtension
        var stored = (folder as NSString).appendingPathComponent(bundleName + ".app")
        var suffix = 2
        while fm.fileExists(atPath: stored) {
            stored = (folder as NSString).appendingPathComponent("\(bundleName) (\(suffix)).app")
            suffix += 1
        }

        try copy(app.path, stored)
        if let problem = Self.mismatch(original: app.path, copy: stored) {
            try? fm.removeItem(atPath: stored)
            throw HibernationError.copyNotVerified(problem)
        }
        let bytes = SizeCalculator().allocatedSize(of: app.path)
        let iconData = Self.iconData(of: app.path)

        do {
            try fm.removeItem(atPath: app.path)
        } catch {
            // Partial delete: put the verified copy back before reporting.
            _ = try? ProcessRunner.run(["/usr/bin/ditto", stored, app.path])
            throw error
        }
        do {
            try Self.writeStub(at: app.path, name: app.name, bundleID: app.bundleID, target: stored, icon: iconData)
        } catch {
            try? fm.removeItem(atPath: app.path)
            _ = try? ProcessRunner.run(["/usr/bin/ditto", stored, app.path])
            try? fm.removeItem(atPath: stored)
            throw error
        }
        let entry = HibernatedApp(bundleID: app.bundleID, name: app.name, originalPath: app.path,
                                  storedPath: stored, bytes: bytes, date: Date())
        try save(list().filter { $0.bundleID != app.bundleID } + [entry])
        return entry
    }

    /// Returns the disk copy it could NOT delete (the app is back either way), so callers can say so.
    @discardableResult
    public func wake(_ entry: HibernatedApp, isRunning: Bool = false) throws -> String? {
        if isRunning { throw HibernationError.runningFromDisk(entry.name) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: entry.storedPath) else { throw HibernationError.diskMissing(entry.storedPath) }
        let info = NSDictionary(contentsOfFile: entry.originalPath + "/Contents/Info.plist") as? [String: Any]
        let id = info?["CFBundleIdentifier"] as? String ?? ""
        let restoring = entry.originalPath + ".mclean-restaurando"
        if fm.fileExists(atPath: entry.originalPath) && !id.hasPrefix(Self.stubPrefix) {
            throw HibernationError.notOurStub(entry.originalPath)
        }
        try? fm.removeItem(atPath: restoring)
        try copy(entry.storedPath, restoring)
        if let problem = Self.mismatch(original: entry.storedPath, copy: restoring) {
            try? fm.removeItem(atPath: restoring)
            throw HibernationError.copyNotVerified(problem)
        }
        if fm.fileExists(atPath: entry.originalPath) { try fm.removeItem(atPath: entry.originalPath) }
        try fm.moveItem(atPath: restoring, toPath: entry.originalPath)
        var leftover: String?
        do { try remove(entry.storedPath) } catch { leftover = entry.storedPath }
        try save(list().filter { $0.bundleID != entry.bundleID })
        return leftover
    }

    public func list() -> [HibernatedApp] {
        guard let data = try? Data(contentsOf: registryURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HibernatedApp].self, from: data)) ?? []
    }

    func save(_ entries: [HibernatedApp]) throws {
        try FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: registryURL, options: .atomic)
    }

    // MARK: Verification

    public static func signatureIsValid(_ path: String) -> Bool {
        (try? ProcessRunner.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", path]))?.status == 0
    }

    /// nil when the copy matches: same files with the same sizes, and a signature that verifies
    /// whenever the original's does.
    static func mismatch(original: String, copy: String) -> String? {
        let a = inventory(original), b = inventory(copy)
        if a.count != b.count { return "\(a.count) arquivos no original, \(b.count) na cópia" }
        if let different = a.first(where: { b[$0.key] != $0.value }) { return "\(different.key) diferente" }
        if signatureIsValid(original) && !signatureIsValid(copy) { return "assinatura da cópia inválida" }
        return nil
    }

    static func inventory(_ root: String) -> [String: Int64] {
        var files: [String: Int64] = [:]
        guard let walker = FileManager.default.enumerator(atPath: root) else { return files }
        while let relative = walker.nextObject() as? String {
            guard let attributes = walker.fileAttributes, attributes[.type] as? FileAttributeType != .typeDirectory else { continue }
            files[relative] = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        return files
    }

    // MARK: Stub

    static func iconData(of app: String) -> Data? {
        let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") as? [String: Any]
        guard var icon = info?["CFBundleIconFile"] as? String else { return nil }
        if !icon.hasSuffix(".icns") { icon += ".icns" }
        return FileManager.default.contents(atPath: app + "/Contents/Resources/" + icon)
    }

    static func writeStub(at path: String, name: String, bundleID: String, target: String, icon: Data?) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: path + "/Contents/Resources", withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": stubPrefix + bundleID, "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleExecutable": "stub", "CFBundlePackageType": "APPL", "LSUIElement": true,
            "MCleanHibernatedTarget": target, "MCleanOriginalBundleID": bundleID,
        ]
        if let icon {
            try icon.write(to: URL(fileURLWithPath: path + "/Contents/Resources/AppIcon.icns"))
            info["CFBundleIconFile"] = "AppIcon"
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        let volume = (target as NSString).pathComponents.dropFirst(2).first ?? "externo"
        let shellTarget = "'" + target.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let message = "\(name) está hibernado no disco \(volume). Conecte o disco para abrir, ou acorde o app no MClean."
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        let script = """
        #!/bin/sh
        # mclean: \(name) hibernado. Abre o app real se o disco estiver conectado.
        TARGET=\(shellTarget)
        if [ -d "$TARGET" ]; then exec /usr/bin/open "$TARGET" --args "$@"; fi
        /usr/bin/osascript -e 'display alert "\(message)"'

        """
        let executable = path + "/Contents/MacOS/stub"
        try Data(script.utf8).write(to: URL(fileURLWithPath: executable))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
        _ = try? ProcessRunner.run(["/usr/bin/codesign", "--force", "--sign", "-", path])
    }
}

extension Hibernator {
    /// External disks that can hold apps (APFS/HFS+, writable, not the boot volume).
    public static func candidateVolumes() -> [String] {
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey, .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsRootFileSystem == false, values?.volumeIsReadOnly == false,
                  url.path.hasPrefix("/Volumes/"), volumeCanHoldApps(url.path) else { return nil }
            return url.path
        }
    }

    public static func storeFolder(onVolume volume: String) -> String { volume + "/MClean Hibernados" }
}
