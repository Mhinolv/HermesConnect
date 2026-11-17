import Foundation

/// The one Hermes server of the owner.
public struct ServerProfile: Codable, Sendable, Equatable {
    /// Version 3 (issue #18) adds `servePort` and `lastAlgorithms`.
    public static let currentVersion = 3
    public static let defaultPort = 22
    public static let defaultUser = "hermes"

    public var version: Int
    public var host: String
    public var port: Int
    public var user: String
    public var displayName: String
    /// The pinned host key (issue #3). Nil until the owner trusts the server on the first connect.
    public var hostKey: HostKey?
    /// The server port of the last `serve` of a fixed-port gate (issue #29). The next `serve` must print it.
    /// Only Reset Device Key clears it: a new key gets a new slot. A new server is a new profile without it.
    public var servePort: Int?
    /// The cipher and key exchange of the last connection that succeeded (issue #18).
    public var lastAlgorithms: SSHNegotiatedAlgorithms?

    public init(host: String, port: Int = ServerProfile.defaultPort,
                user: String = ServerProfile.defaultUser, displayName: String? = nil, hostKey: HostKey? = nil,
                servePort: Int? = nil, lastAlgorithms: SSHNegotiatedAlgorithms? = nil) {
        self.version = Self.currentVersion
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.user = user
        self.displayName = displayName ?? self.host
        self.hostKey = hostKey
        self.servePort = servePort
        self.lastAlgorithms = lastAlgorithms
    }

    /// Tolerant decode: a missing field gets its default, so old files still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? Self.defaultUser
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? host
        // Version 1 files have no pin. A pin that does not parse counts as no pin, so the owner must trust again.
        hostKey = (try? container.decodeIfPresent(HostKey.self, forKey: .hostKey)) ?? nil
        // Version 2 files have neither. A value that does not parse counts as none.
        servePort = ((try? container.decodeIfPresent(Int.self, forKey: .servePort)) ?? nil).flatMap {
            Self.isValidPort($0) ? $0 : nil
        }
        lastAlgorithms = (try? container.decodeIfPresent(SSHNegotiatedAlgorithms.self, forKey: .lastAlgorithms)) ?? nil
    }

    /// True when `other` names a different server (host, port or user). A new server needs a new pin.
    public func isDifferentServer(from other: ServerProfile) -> Bool {
        host.caseInsensitiveCompare(other.host) != .orderedSame || port != other.port || user != other.user
    }

    public var isValid: Bool {
        Self.isValidHost(host) && Self.isValidPort(port) && !user.isEmpty
    }

    /// A host name or an IP address: not empty, no spaces, no user part, no scheme.
    public static func isValidHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "@/\\?#"))
        return trimmed.rangeOfCharacter(from: forbidden) == nil
    }

    public static func isValidPort(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }
}
