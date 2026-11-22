import Foundation
import Security

/// Issue #173: keeps the `hermes serve` session token of each server, so a relaunch sends the same token.
/// The gate then reuses the live server, and a running turn continues. One item for each server profile id.
/// The real store is the Keychain. Tests use `InMemoryServeTokenStore`.
public protocol ServeTokenStore: Sendable {
    /// Returns the token of the server, or nil if there is no token.
    func loadToken(for server: UUID) throws -> SessionToken?
    /// Adds the token of the server. Replaces an old token.
    func saveToken(_ token: SessionToken, for server: UUID) throws
    func deleteToken(for server: UUID) throws
    /// Reset Device Key: a new key gets a new slot on each server, so no old token is of use.
    func deleteAllTokens() throws
}

extension SessionToken {
    /// Issue #173: the bytes of the stored item. They are the 64 hex characters, as on the gate stdin.
    var storedBytes: Data { Data(value.utf8) }

    /// Issue #173: a token from a stored item. Nil when the bytes are not 64 lowercase hex characters.
    /// It is public for app tests that compare the gate stdin with a stored token. The bytes stay internal.
    public init?(storedBytes: Data) {
        guard Self.isValid(storedBytes), let hex = String(data: storedBytes, encoding: .utf8) else { return nil }
        self.init(hex: hex)
    }
}

/// Issue #173: the tokens in the Keychain, with the protection of the SSH key (owner decision 2026-11-21).
/// Each item is a generic password, `AfterFirstUnlockThisDeviceOnly`, not synchronizable, so it is not in a backup.
/// The account is the server profile id. Nothing here writes the token to a log, a file or UserDefaults.
public struct KeychainServeTokenStore: ServeTokenStore {
    public static let defaultService = "io.mhinoverse.hermesconnect.serve-token"

    private let service: String

    public init(service: String = KeychainServeTokenStore.defaultService) {
        self.service = service
    }

    private func item(for server: UUID) -> KeychainSecretStore {
        KeychainSecretStore(service: service, account: server.uuidString)
    }

    public func loadToken(for server: UUID) throws -> SessionToken? {
        guard let stored = try item(for: server).read() else { return nil }
        guard let token = SessionToken(storedBytes: stored.data) else {
            // A damaged item is of no use. Delete it, so the next connect mints a new token.
            try item(for: server).delete()
            return nil
        }
        return token
    }

    public func saveToken(_ token: SessionToken, for server: UUID) throws {
        try item(for: server).write(token.storedBytes, label: "serve-token")
    }

    public func deleteToken(for server: UUID) throws {
        try item(for: server).delete()
    }

    public func deleteAllTokens() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceKeyError.keychain(status)
        }
    }
}

/// A `ServeTokenStore` in memory, for tests and previews. It keeps the stored bytes, like the Keychain store.
public final class InMemoryServeTokenStore: ServeTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: Data] = [:]

    public init() {}

    /// The ids of the servers that have a token.
    public var servers: Set<UUID> { lock.withLock { Set(items.keys) } }

    public func loadToken(for server: UUID) throws -> SessionToken? {
        lock.withLock { items[server] }.flatMap { SessionToken(storedBytes: $0) }
    }

    public func saveToken(_ token: SessionToken, for server: UUID) throws {
        lock.withLock { items[server] = token.storedBytes }
    }

    public func deleteToken(for server: UUID) throws {
        _ = lock.withLock { items.removeValue(forKey: server) }
    }

    public func deleteAllTokens() throws {
        lock.withLock { items.removeAll() }
    }
}
