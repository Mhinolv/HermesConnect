import CryptoKit
import Foundation
import NIOSSH

/// Where the private key of the device lives.
public enum DeviceKeyKind: String, Sendable, Codable, Equatable {
    /// A Secure Enclave key. The private key cannot leave the hardware.
    case secureEnclave
    /// A software key in the Keychain. Used only when the Secure Enclave is not available (Simulator).
    case software

    public var displayName: String {
        switch self {
        case .secureEnclave: "ECDSA P-256 (Secure Enclave)"
        case .software: "Simulator key (not hardware-backed)"
        }
    }
}

/// Signs data with the private key of the device. Issue #3 gives this to the SSH client.
public protocol DeviceKeySigner: Sendable {
    /// Sign `data` with ECDSA P-256 over SHA-256 (the `ecdsa-sha2-nistp256` signature).
    func sign(_ data: Data) throws -> P256.Signing.ECDSASignature
}

/// The SSH key of this device: the public key and a signer for the private key.
/// The private key bytes are never exposed.
public struct DeviceKey: Sendable {
    public let kind: DeviceKeyKind
    public let publicKey: P256.Signing.PublicKey
    private let signer: any DeviceKeySigner

    public init(kind: DeviceKeyKind, publicKey: P256.Signing.PublicKey, signer: any DeviceKeySigner) {
        self.kind = kind
        self.publicKey = publicKey
        self.signer = signer
    }

    public func sign(_ data: Data) throws -> P256.Signing.ECDSASignature {
        try signer.sign(data)
    }

    public func openSSH(comment: String) -> OpenSSHPublicKey {
        OpenSSHPublicKey(publicKey: publicKey, comment: comment)
    }

    /// The key object for NIOSSH user authentication (issue #3). The Secure Enclave key stays in the hardware.
    /// A signer that is not one of the HermesKit key sources cannot be used for SSH.
    func sshPrivateKey() throws -> NIOSSHPrivateKey {
        guard let source = signer as? any SSHPrivateKeySource else { throw DeviceKeyError.unsupportedSigner }
        return try source.sshPrivateKey()
    }
}

/// A signer that can give NIOSSH a key object. Only the HermesKit key sources conform.
protocol SSHPrivateKeySource {
    func sshPrivateKey() throws -> NIOSSHPrivateKey
}

extension DeviceKey: CustomStringConvertible, CustomDebugStringConvertible {
    /// Show only public data, so a log or a debugger print cannot show the private key.
    public var description: String {
        "DeviceKey(\(kind.rawValue), \(openSSH(comment: "").fingerprint))"
    }

    public var debugDescription: String { description }
}

/// Makes and restores device keys. The stored representation is opaque:
/// for the Secure Enclave it is a wrapped handle that only this device can use.
public protocol DeviceKeyFactory: Sendable {
    var kind: DeviceKeyKind { get }
    func makeKey() throws -> (key: DeviceKey, storedRepresentation: Data)
    func restoreKey(from storedRepresentation: Data) throws -> DeviceKey
}

/// Secure Enclave P-256 keys with `.privateKeyUsage` and `AfterFirstUnlockThisDeviceOnly` (research.md D1).
/// No per-use user presence, so background work can sign.
public struct SecureEnclaveKeyFactory: DeviceKeyFactory {
    public init() {}

    public var kind: DeviceKeyKind { .secureEnclave }

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public func makeKey() throws -> (key: DeviceKey, storedRepresentation: Data) {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error
        ) else {
            throw DeviceKeyError.accessControl
        }
        let privateKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        return (Self.wrap(privateKey), privateKey.dataRepresentation)
    }

    public func restoreKey(from storedRepresentation: Data) throws -> DeviceKey {
        Self.wrap(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: storedRepresentation))
    }

    private static func wrap(_ privateKey: SecureEnclave.P256.Signing.PrivateKey) -> DeviceKey {
        DeviceKey(kind: .secureEnclave, publicKey: privateKey.publicKey,
                  signer: SecureEnclaveSigner(representation: privateKey.dataRepresentation))
    }
}

/// Software P-256 keys. Only for devices with no Secure Enclave (the Simulator) and for tests.
public struct SoftwareKeyFactory: DeviceKeyFactory {
    public init() {}

    public var kind: DeviceKeyKind { .software }

    public func makeKey() throws -> (key: DeviceKey, storedRepresentation: Data) {
        let privateKey = P256.Signing.PrivateKey()
        return (Self.wrap(privateKey), privateKey.rawRepresentation)
    }

    public func restoreKey(from storedRepresentation: Data) throws -> DeviceKey {
        do {
            return Self.wrap(try P256.Signing.PrivateKey(rawRepresentation: storedRepresentation))
        } catch {
            throw DeviceKeyError.corruptKey
        }
    }

    static func wrap(_ privateKey: P256.Signing.PrivateKey) -> DeviceKey {
        DeviceKey(kind: .software, publicKey: privateKey.publicKey,
                  signer: SoftwareSigner(raw: privateKey.rawRepresentation))
    }
}

/// Holds the wrapped Secure Enclave handle, not key material. The hardware does the signing.
private struct SecureEnclaveSigner: DeviceKeySigner, SSHPrivateKeySource {
    let representation: Data

    func sign(_ data: Data) throws -> P256.Signing.ECDSASignature {
        try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: representation).signature(for: data)
    }

    /// NIOSSH signs through the Secure Enclave handle (`ecdsa-sha2-nistp256`).
    func sshPrivateKey() throws -> NIOSSHPrivateKey {
        NIOSSHPrivateKey(secureEnclaveP256Key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: representation))
    }
}

private struct SoftwareSigner: DeviceKeySigner, SSHPrivateKeySource {
    let raw: Data

    func sign(_ data: Data) throws -> P256.Signing.ECDSASignature {
        try P256.Signing.PrivateKey(rawRepresentation: raw).signature(for: data)
    }

    func sshPrivateKey() throws -> NIOSSHPrivateKey {
        NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: raw))
    }
}

public enum DeviceKeyError: Error, Equatable, CustomStringConvertible {
    case accessControl
    case corruptKey
    case keychain(OSStatus)
    case kindMismatch
    case unsupportedSigner

    public var description: String {
        switch self {
        case .accessControl: "Could not set the key access control."
        case .corruptKey: "The stored key is not valid."
        case .keychain(let status): "Keychain error \(status)."
        case .kindMismatch: "The stored key was made by a different key source."
        case .unsupportedSigner: "This key source cannot sign SSH requests."
        }
    }
}
