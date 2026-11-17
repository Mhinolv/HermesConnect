import Foundation

/// Issue #66: the Hermes servers of the owner, in the order added, and the active server.
/// One server is connected at a time (owner decision 2026-11-17). All servers use the one device key.
/// Each server keeps its own pinned host key.
public struct ServerList: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public enum Failure: Error, Equatable {
        /// A saved server has the same host, port and user.
        case duplicate
        /// No saved server has this id.
        case notFound
    }

    /// What an update did.
    public enum Change: Equatable {
        /// Only the name or other fields changed. The pin stays.
        case sameServer
        /// The host, port or user changed. The pin, the port pin and the algorithms are cleared.
        case newServer
    }

    public var version: Int
    public private(set) var servers: [ServerProfile]
    public private(set) var activeID: UUID?

    public init(servers: [ServerProfile] = [], activeID: UUID? = nil) {
        version = Self.currentVersion
        self.servers = servers
        self.activeID = activeID ?? servers.first?.id
    }

    /// Tolerant decode: a missing field gets its default. A bad server entry is dropped, so the others still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        let entries = (try? container.decodeIfPresent([Lenient].self, forKey: .servers)) ?? []
        var seen = Set<UUID>()
        servers = entries.compactMap(\.profile).filter { seen.insert($0.id).inserted }
        activeID = (try? container.decodeIfPresent(UUID.self, forKey: .activeID)) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case version, servers, activeID
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(servers, forKey: .servers)
        try container.encodeIfPresent(activeID, forKey: .activeID)
    }

    private struct Lenient: Decodable {
        let profile: ServerProfile?
        init(from decoder: any Decoder) throws {
            profile = try? ServerProfile(from: decoder)
        }
    }

    public var isEmpty: Bool { servers.isEmpty }

    /// The connected server. An id that names no server falls back to the first server.
    public var active: ServerProfile? {
        servers.first { $0.id == activeID } ?? servers.first
    }

    public func server(id: UUID) -> ServerProfile? {
        servers.first { $0.id == id }
    }

    /// True when a saved server other than `excluding` has the same host, port and user as `profile`.
    public func containsServer(like profile: ServerProfile, excluding: UUID? = nil) -> Bool {
        servers.contains { $0.id != excluding && !$0.isDifferentServer(from: profile) }
    }

    /// Add a server at the end and make it the active server (orchestrator decision: Add Server switches).
    public mutating func add(_ profile: ServerProfile) throws(Failure) {
        guard !containsServer(like: profile), server(id: profile.id) == nil else { throw .duplicate }
        servers.append(profile)
        activeID = profile.id
    }

    /// Replace the server with the same id. A different host, port or user loses the pin: a new server
    /// needs a new pin. It also loses the port pin and the algorithms, because they belong to the old server.
    @discardableResult
    public mutating func update(_ profile: ServerProfile) throws(Failure) -> Change {
        guard let index = servers.firstIndex(where: { $0.id == profile.id }) else { throw .notFound }
        guard !containsServer(like: profile, excluding: profile.id) else { throw .duplicate }
        var profile = profile
        let change: Change = profile.isDifferentServer(from: servers[index]) ? .newServer : .sameServer
        if change == .newServer {
            profile.hostKey = nil
            profile.servePort = nil
            profile.lastAlgorithms = nil
        }
        servers[index] = profile
        return change
    }

    /// Change one field of a server, for example the pin after the trust sheet. No duplicate check.
    public mutating func modify(id: UUID, _ change: (inout ServerProfile) -> Void) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        change(&servers[index])
    }

    /// Change each server. Reset Device Key clears the port pin of every server: a new key gets a new slot.
    public mutating func modifyAll(_ change: (inout ServerProfile) -> Void) {
        for index in servers.indices { change(&servers[index]) }
    }

    /// Remove a server and its pin. If it was the active server, the first server that stays becomes active.
    public mutating func remove(id: UUID) {
        let wasActive = active?.id == id
        servers.removeAll { $0.id == id }
        if wasActive || servers.isEmpty { activeID = servers.first?.id }
    }

    /// #83 calls this to switch. It does nothing for an unknown id.
    public mutating func activate(id: UUID) {
        guard server(id: id) != nil else { return }
        activeID = id
    }
}
