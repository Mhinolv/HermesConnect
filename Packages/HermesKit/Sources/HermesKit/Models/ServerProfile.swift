import Foundation

/// The one Hermes server of the owner.
public struct ServerProfile: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let defaultPort = 22
    public static let defaultUser = "hermes"

    public var version: Int
    public var host: String
    public var port: Int
    public var user: String
    public var displayName: String

    public init(host: String, port: Int = ServerProfile.defaultPort,
                user: String = ServerProfile.defaultUser, displayName: String? = nil) {
        self.version = Self.currentVersion
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.user = user
        self.displayName = displayName ?? self.host
    }

    /// Tolerant decode: a missing field gets its default, so old files still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? Self.defaultUser
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? host
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
