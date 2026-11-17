import Foundation

/// Issue #68: the last `commands.catalog` of each server, for the slash suggestions while offline.
/// It keeps only the command names, aliases and descriptions. It holds no secrets and no message text.
public protocol SlashCatalogCacheStore: Sendable {
    func load(server: String) -> [SlashCatalogEntry]?
    func save(_ entries: [SlashCatalogEntry], server: String)
    /// Issue #84: "Remove Server" drops the catalog of that server.
    func remove(server: String)
}

extension SlashCatalogCacheStore {
    public func remove(server _: String) {}
}

/// The key of a server in the cache: `user@host:port`, host in lower case. Issue #66 (more than one server)
/// gives each server its own key, so each server keeps its own catalog.
public enum SlashCatalogServerKey {
    public static func make(_ profile: ServerProfile) -> String {
        "\(profile.user)@\(profile.host.lowercased()):\(profile.port)"
    }
}

/// The JSON body of `slash-commands.json`. A missing key or a bad entry is dropped, so older and newer files
/// still load.
struct SlashCatalogCacheBody: Codable, Equatable {
    static let formatVersion = 1
    /// More servers than this: the file keeps the ones saved last.
    static let maxServers = 8

    var version: Int
    var servers: [String: [SlashCatalogEntry]]
    /// The server keys, the one saved last at the end.
    var order: [String]

    init(servers: [String: [SlashCatalogEntry]] = [:], order: [String] = []) {
        version = Self.formatVersion
        self.servers = servers
        self.order = order
    }

    private enum CodingKeys: String, CodingKey { case version, servers, order }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? Self.formatVersion
        let servers = (try? container.decodeIfPresent([String: LossyArray<SlashCatalogEntry>].self,
                                                      forKey: .servers)) ?? [:]
        self.servers = servers.mapValues(\.items)
        let order = (try? container.decodeIfPresent([String].self, forKey: .order)) ?? []
        self.order = order.filter { servers[$0] != nil }
        for key in self.servers.keys.sorted() where !self.order.contains(key) { self.order.insert(key, at: 0) }
    }

    mutating func put(_ entries: [SlashCatalogEntry], server: String) {
        servers[server] = entries
        order.removeAll { $0 == server }
        order.append(server)
        while order.count > Self.maxServers {
            servers[order.removeFirst()] = nil
        }
    }
}

/// `slash-commands.json` in the cache folder, with the same `ProtectedStorage` rules.
/// Issue #84: the file stays in `HermesConnect/Cache/`, not in a server folder. It is keyed by server already,
/// and an older build still reads it.
public final class FileSlashCatalogCacheStore: SlashCatalogCacheStore, @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var prepared = false

    public init(directory: URL) {
        self.directory = directory
    }

    /// The default location: `HermesConnect/Cache/slash-commands.json` in Application Support.
    public static func applicationSupport() throws -> FileSlashCatalogCacheStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return FileSlashCatalogCacheStore(directory: base.appending(path: "HermesConnect/Cache",
                                                                   directoryHint: .isDirectory))
    }

    var fileURL: URL { directory.appending(path: "slash-commands.json") }

    public func load(server: String) -> [SlashCatalogEntry]? { lock.withLock { read().servers[server] } }

    public func save(_ entries: [SlashCatalogEntry], server: String) {
        lock.withLock {
            var body = read()
            guard body.servers[server] != entries || body.order.last != server else { return }
            body.put(entries, server: server)
            write(body)
        }
    }

    public func remove(server: String) {
        lock.withLock {
            var body = read()
            guard body.servers[server] != nil else { return }
            body.servers[server] = nil
            body.order.removeAll { $0 == server }
            write(body)
        }
    }

    /// Called with the lock held. A missing or broken file is an empty cache.
    private func read() -> SlashCatalogCacheBody {
        guard let data = try? Data(contentsOf: fileURL),
              let body = try? JSONDecoder().decode(SlashCatalogCacheBody.self, from: data) else {
            return SlashCatalogCacheBody()
        }
        return body
    }

    /// Called with the lock held. The cache is optional: a failed write is dropped.
    private func write(_ body: SlashCatalogCacheBody) {
        do {
            if !prepared {
                try ProtectedStorage.prepare(directory: directory)
                prepared = true
            }
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try JSONEncoder().encode(body).write(to: fileURL, options: ProtectedStorage.writeOptions)
        } catch {
            // The next save tries again.
        }
    }
}

/// A cache in memory, for tests, previews and the DEBUG demo.
public final class InMemorySlashCatalogCacheStore: SlashCatalogCacheStore, @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [String: [SlashCatalogEntry]]

    public init(servers: [String: [SlashCatalogEntry]] = [:]) {
        self.servers = servers
    }

    public func load(server: String) -> [SlashCatalogEntry]? { lock.withLock { servers[server] } }
    public func save(_ entries: [SlashCatalogEntry], server: String) { lock.withLock { servers[server] = entries } }
    public func remove(server: String) { _ = lock.withLock { servers.removeValue(forKey: server) } }
}
