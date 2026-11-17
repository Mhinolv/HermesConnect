import Foundation
import Security

/// Keeps one secret item. The real store is the Keychain. Tests use `InMemorySecretStore`.
public protocol SecretStore: Sendable {
    /// Returns the item, or nil if there is no item.
    func read() throws -> (data: Data, label: String)?
    /// Adds the item. Replaces an old item.
    func write(_ data: Data, label: String) throws
    func delete() throws
}

/// The device key: create once, then load it on each launch. Reset deletes it and makes a new one.
public protocol DeviceKeyStore: Sendable {
    func loadKey() throws -> DeviceKey?
    func createKey() throws -> DeviceKey
    func deleteKey() throws
}

extension DeviceKeyStore {
    /// Load the key, or create it if there is no key.
    public func loadOrCreateKey() throws -> DeviceKey {
        if let key = try loadKey() { return key }
        return try createKey()
    }

    /// Delete the old key and create a new one. The server rejects this device until the new key is installed.
    public func resetKey() throws -> DeviceKey {
        try deleteKey()
        return try createKey()
    }
}

/// Stores the key representation in a `SecretStore`. The item label records the key kind.
public struct KeychainDeviceKeyStore: DeviceKeyStore {
    private let secrets: any SecretStore
    private let factory: any DeviceKeyFactory

    public init(secrets: any SecretStore, factory: any DeviceKeyFactory) {
        self.secrets = secrets
        self.factory = factory
    }

    /// The store for the app: the Keychain, and the Secure Enclave when the device has one.
    public static func system() -> KeychainDeviceKeyStore {
        let factory: any DeviceKeyFactory = SecureEnclaveKeyFactory.isAvailable
            ? SecureEnclaveKeyFactory() : SoftwareKeyFactory()
        return KeychainDeviceKeyStore(secrets: KeychainSecretStore(), factory: factory)
    }

    public var kind: DeviceKeyKind { factory.kind }

    public func loadKey() throws -> DeviceKey? {
        guard let item = try secrets.read() else { return nil }
        guard item.label == factory.kind.rawValue else { throw DeviceKeyError.kindMismatch }
        return try factory.restoreKey(from: item.data)
    }

    public func createKey() throws -> DeviceKey {
        let made = try factory.makeKey()
        try secrets.write(made.storedRepresentation, label: factory.kind.rawValue)
        return made.key
    }

    public func deleteKey() throws {
        try secrets.delete()
    }
}

/// A generic password item, this device only, `AfterFirstUnlockThisDeviceOnly`, not synced.
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "io.mhinoverse.hermesconnect.device-key"

    private let service: String
    private let account: String

    public init(service: String = KeychainSecretStore.defaultService, account: String = "ssh-device-key") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    public func read() throws -> (data: Data, label: String)? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let attributes = result as? [CFString: Any],
              let data = attributes[kSecValueData] as? Data
        else { throw DeviceKeyError.keychain(status) }
        return (data, attributes[kSecAttrLabel] as? String ?? "")
    }

    public func write(_ data: Data, label: String) throws {
        try delete()
        var query = baseQuery
        query[kSecValueData] = data
        query[kSecAttrLabel] = label
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceKeyError.keychain(status)
        }
    }
}

/// A `SecretStore` in memory, for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var item: (data: Data, label: String)?

    public init() {}

    public func read() throws -> (data: Data, label: String)? {
        lock.withLock { item }
    }

    public func write(_ data: Data, label: String) throws {
        lock.withLock { item = (data, label) }
    }

    public func delete() throws {
        lock.withLock { item = nil }
    }
}
