import Foundation

public enum Permissions {
    /// Full Disk Access probe: the system TCC database opens only with it. Without it, the Trash,
    /// Mail and iPhone backups cannot even be listed (EPERM), so their rules measure nothing.
    public static var hasFullDiskAccess: Bool {
        guard let handle = FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") else {
            return false
        }
        try? handle.close()
        return true
    }

    /// Rules whose targets live behind Full Disk Access.
    public static let fullDiskAccessRules: Set<String> = ["trash", "external-trash", "ios-backups", "mail-downloads", "mail-trash"]

    public static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
