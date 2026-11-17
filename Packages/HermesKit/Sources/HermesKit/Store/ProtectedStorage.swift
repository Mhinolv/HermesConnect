import Foundation

/// Data Protection and backup rules for the local copies of messages and attachments (issue #18).
///
/// - Files use `completeUntilFirstUserAuthentication`: the files are encrypted until the first unlock after a
///   restart. Background catch-up still works after that first unlock.
/// - Folders are excluded from iCloud and Finder backup: the server holds the real transcript.
/// - The protection class changes only the key that encrypts the file, not its bytes, so files saved
///   before this change load as before.
public enum ProtectedStorage {
    public static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    /// The options for each write of a protected file.
    public static var writeOptions: Data.WritingOptions {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        return options
    }

    /// Make `directory` if it is missing, exclude it from backup, and give it and every file in it the protection
    /// class. Files from builds before issue #18 get the class here. Safe to call more than once.
    /// - Parameter setProtection: Gives one item the protection class. Tests pass a recorder, because the
    ///   Simulator has no Data Protection (it reads the attribute as nil).
    public static func prepare(directory: URL,
                               setProtection: (URL) throws -> Void = ProtectedStorage.setProtection) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        #if os(iOS)
        try? setProtection(directory)
        if let items = manager.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in items { try? setProtection(url) }
        }
        #endif
    }

    /// Gives `url` the protection class `protection`.
    public static func setProtection(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
    }

    /// True when `url` is excluded from backup.
    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }
}
