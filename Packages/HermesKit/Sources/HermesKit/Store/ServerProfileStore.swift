import Foundation

/// Saves the server profile.
public protocol ServerProfileStore: Sendable {
    func load() throws -> ServerProfile?
    func save(_ profile: ServerProfile) throws
    func delete() throws
}

/// The profile as JSON in Application Support (`HermesConnect/server-profile.json`).
public struct FileServerProfileStore: ServerProfileStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The default location in Application Support.
    public static func applicationSupport() throws -> FileServerProfileStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return FileServerProfileStore(fileURL: base.appending(path: "HermesConnect/server-profile.json"))
    }

    public func load() throws -> ServerProfile? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(ServerProfile.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ profile: ServerProfile) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try encoder.encode(profile).write(to: fileURL, options: options)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// A `ServerProfileStore` in memory, for tests and previews.
public final class InMemoryServerProfileStore: ServerProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var profile: ServerProfile?

    public init(_ profile: ServerProfile? = nil) {
        self.profile = profile
    }

    public func load() throws -> ServerProfile? { lock.withLock { profile } }
    public func save(_ profile: ServerProfile) throws { lock.withLock { self.profile = profile } }
    public func delete() throws { lock.withLock { profile = nil } }
}
