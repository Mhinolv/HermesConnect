import CryptoKit
import Foundation

/// The public host key of the server, in OpenSSH form (`<type> <base64 blob>`).
/// It holds public data only. The app pins the full key, not only the fingerprint.
public struct HostKey: Sendable, Equatable, Hashable, Codable {
    /// The key type, for example `ssh-ed25519` or `ecdsa-sha2-nistp256`.
    public let algorithm: String
    /// The SSH wire blob of the key.
    public let blob: Data

    public init(algorithm: String, blob: Data) {
        self.algorithm = algorithm
        self.blob = blob
    }

    /// Parse `<type> <base64>` (an optional comment after it is ignored).
    /// Returns nil if the text is not a valid key, or if the type inside the blob is not the stated type.
    public init?(openSSH text: String) {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])), !blob.isEmpty,
              Self.blobKeyType(blob) == String(parts[0])
        else { return nil }
        self.init(algorithm: String(parts[0]), blob: blob)
    }

    /// `<type> <base64 blob>`, the form of `known_hosts` and `/etc/ssh/ssh_host_*_key.pub`.
    public var openSSH: String { "\(algorithm) \(blob.base64EncodedString())" }

    /// The OpenSSH SHA256 fingerprint, as `ssh-keygen -l` prints it (`SHA256:` + unpadded base64).
    public var fingerprint: String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// `SHA256:` and the first 12 characters of the hash, for the Settings row.
    public var shortFingerprint: String {
        let hash = fingerprint.dropFirst("SHA256:".count)
        return "SHA256:" + hash.prefix(12)
    }

    /// The key type as `ssh-keygen -l` shows it: `ED25519`, `ECDSA`, `RSA`.
    public var displayType: String {
        switch algorithm {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa": "RSA"
        case let name where name.hasPrefix("ecdsa-sha2-"): "ECDSA"
        default: algorithm.uppercased()
        }
    }

    /// The fingerprint hash in groups of 4 characters, so VoiceOver reads it in short parts.
    public var spokenFingerprint: String {
        let hash = Array(fingerprint.dropFirst("SHA256:".count))
        let groups = stride(from: 0, to: hash.count, by: 4).map { String(hash[$0..<min($0 + 4, hash.count)]) }
        return "SHA256, " + groups.joined(separator: ", ")
    }

    /// The first SSH `string` of the blob: the key type.
    static func blobKeyType(_ blob: Data) -> String? {
        let bytes = [UInt8](blob)
        guard bytes.count >= 4 else { return nil }
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0, bytes.count >= 4 + length else { return nil }
        return String(bytes: bytes[4..<(4 + length)], encoding: .utf8)
    }
}

extension HostKey {
    /// Saved as one OpenSSH string (`<type> <base64>`), the same text as `known_hosts`.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let key = HostKey(openSSH: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Not an OpenSSH public key."))
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(openSSH)
    }
}

extension HostKey: CustomStringConvertible {
    public var description: String { "HostKey(\(algorithm), \(fingerprint))" }
}

/// The result of the comparison of the received host key with the pinned key.
public enum HostKeyVerdict: Sendable, Equatable {
    /// The key is the pinned key. Authentication can continue.
    case trusted
    /// There is no pin. The owner must compare the fingerprint and confirm.
    case unknown(HostKey)
    /// The key is not the pinned key. The app must not connect.
    case changed(saved: HostKey, received: HostKey)

    public static func evaluate(received: HostKey, pinned: HostKey?) -> HostKeyVerdict {
        guard let pinned else { return .unknown(received) }
        return pinned == received ? .trusted : .changed(saved: pinned, received: received)
    }
}
