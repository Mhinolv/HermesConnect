import Foundation

/// Saves the server list (issue #66).
public protocol ServerListStore: Sendable {
    /// The saved list. No file: an empty list.
    func load() throws -> ServerList
    func save(_ list: ServerList) throws
}

/// The server list as JSON in Application Support (`HermesConnect/servers.json`).
///
/// Migration (issue #66): when `servers.json` is missing and the old single profile file
/// (`server-profile.json`) is there, `load` makes a list with that profile as the only and active server.
/// The profile keeps its host key pin, its port pin and its algorithms, so the owner sees no new prompt.
/// It gets the fixed id `ServerProfile.legacyID`. The old file stays, so an older build still connects with no
/// new setup (owner rule: never reset the connection). `servers.json` wins when both files are there.
///
/// While the old file is there, each save also writes the legacy server (`ServerProfile.legacyID`) to it when
/// its host, port, user, name, pin or port pin changed. So an older build gets the same pin. A removed legacy
/// server leaves the old file as it is.
public struct FileServerListStore: ServerListStore {
    public let fileURL: URL
    /// The single profile file of builds before issue #66.
    public let legacyURL: URL

    public init(fileURL: URL, legacyURL: URL) {
        self.fileURL = fileURL
        self.legacyURL = legacyURL
    }

    /// The default location in Application Support.
    public static func applicationSupport() throws -> FileServerListStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return FileServerListStore(fileURL: base.appending(path: "HermesConnect/servers.json"),
                                   legacyURL: base.appending(path: "HermesConnect/server-profile.json"))
    }

    public func load() throws -> ServerList {
        let manager = FileManager.default
        if manager.fileExists(atPath: fileURL.path) {
            return try JSONDecoder().decode(ServerList.self, from: Data(contentsOf: fileURL))
        }
        guard let legacy = try FileServerProfileStore(fileURL: legacyURL).load() else { return ServerList() }
        var profile = legacy
        profile.version = ServerProfile.currentVersion
        let list = ServerList(servers: [profile], activeID: profile.id)
        // The old file stays as it is. If the write fails, the next load migrates again with the same id.
        try? write(list)
        return list
    }

    public func save(_ list: ServerList) throws {
        try write(list)
        mirrorLegacy(list)
    }

    private func write(_ list: ServerList) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: fileURL, options: ProtectedStorage.writeOptions)
    }

    /// Keep the old file in step with the legacy server, for an older build. A failure here never fails the save.
    private func mirrorLegacy(_ list: ServerList) {
        let legacyFile = FileServerProfileStore(fileURL: legacyURL)
        guard let server = list.server(id: ServerProfile.legacyID),
              let old = try? legacyFile.load(), Self.connectionFieldsDiffer(old, server) else { return }
        try? legacyFile.save(server)
    }

    /// The fields that an older build uses to connect. The id, the version and the algorithms do not count.
    static func connectionFieldsDiffer(_ a: ServerProfile, _ b: ServerProfile) -> Bool {
        a.host != b.host || a.port != b.port || a.user != b.user || a.displayName != b.displayName
            || a.hostKey != b.hostKey || a.servePort != b.servePort
    }
}

/// The single profile file of builds before issue #66 (`server-profile.json`). Only the migration reads it.
public struct FileServerProfileStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> ServerProfile? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(ServerProfile.self, from: Data(contentsOf: fileURL))
    }

    /// Tests use this to make a file of an old build.
    public func save(_ profile: ServerProfile) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: fileURL, options: ProtectedStorage.writeOptions)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// A `ServerListStore` in memory, for tests and previews.
public final class InMemoryServerListStore: ServerListStore, @unchecked Sendable {
    private let lock = NSLock()
    private var list: ServerList
    /// Tests set this to make each save fail.
    public var failsSaves = false

    public init(_ list: ServerList = ServerList()) {
        self.list = list
    }

    /// One server, or none.
    public convenience init(profile: ServerProfile?) {
        self.init(ServerList(servers: profile.map { [$0] } ?? []))
    }

    public struct SaveFailure: Error {}

    public func load() throws -> ServerList { lock.withLock { list } }
    public func save(_ list: ServerList) throws {
        try lock.withLock {
            if failsSaves { throw SaveFailure() }
            self.list = list
        }
    }
}
