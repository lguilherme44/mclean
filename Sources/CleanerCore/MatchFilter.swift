import Foundation

/// Content checks a glob cannot express. Both are conservative: when a file cannot be read or
/// the answer depends on something we cannot see (PATH, an unmounted volume), it is NOT junk.
public enum MatchFilter: String, Codable, Sendable {
    /// Preference file that opens but does not parse. Unreadable is not broken: macOS protects
    /// Contacts/Messages/Mail plists with TCC, and they fail `plutil` only for lack of permission.
    case brokenPlist
    /// Launch agent whose absolute `Program` / `ProgramArguments[0]` no longer exists.
    case missingProgram

    func accepts(_ path: String) -> Bool {
        // Apple's plists are TCC-protected (Music, TV, Contacts): opening one can block in open()
        // waiting for a permission prompt, which hung the whole scan on a real Mac. Never judged.
        if (path as NSString).lastPathComponent.lowercased().hasPrefix("com.apple.") { return false }
        guard let data = Self.read(path) else { return false }
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        switch self {
        case .brokenPlist:
            return plist == nil
        case .missingProgram:
            guard let dict = plist as? [String: Any] else { return false }
            let program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
            guard let program, program.hasPrefix("/") else { return false }
            if program.hasPrefix("/Volumes/") {
                let parts = program.split(separator: "/")
                guard parts.count > 1, FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])") else { return false }
            }
            return !FileManager.default.fileExists(atPath: program)
        }
    }

    /// Regular files only (a FIFO blocks open() until a writer shows up), and never longer than
    /// `deadline`: whatever does not open in time is treated as unreadable, i.e. not junk. A read
    /// that outlives the deadline is abandoned on its background thread.
    static func read(_ path: String, deadline: TimeInterval = 1) -> Data? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        final class Result: @unchecked Sendable { var data: Data? }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        // A dedicated thread, not the global queue: the deadline must time the read itself, not
        // the wait for a pool thread (blocked reads elsewhere starve the pool and fake timeouts).
        Thread.detachNewThread {
            // open()+read, the same calls that blocked on a TCC-protected plist.
            if let handle = FileHandle(forReadingAtPath: path) {
                result.data = try? handle.readToEnd()
                try? handle.close()
            }
            done.signal()
        }
        return done.wait(timeout: .now() + deadline) == .success ? result.data : nil
    }
}
