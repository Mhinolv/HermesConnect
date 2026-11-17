import CryptoKit
import Foundation

/// The OpenSSH form of the device public key (`ecdsa-sha2-nistp256`, RFC 5656).
/// It holds public data only.
public struct OpenSSHPublicKey: Sendable, Equatable {
    public static let keyType = "ecdsa-sha2-nistp256"
    public static let curveName = "nistp256"

    /// The SSH wire blob: string(key type), string(curve name), string(0x04 || X || Y).
    public let blob: Data
    /// The comment at the end of the `authorized_keys` line.
    public let comment: String

    public init(publicKey: P256.Signing.PublicKey, comment: String) {
        self.init(x963Point: publicKey.x963Representation, comment: comment)
    }

    /// - Parameter x963Point: the uncompressed point (65 bytes, `0x04 || X || Y`).
    public init(x963Point: Data, comment: String) {
        var blob = Data()
        blob.appendSSHString(Data(Self.keyType.utf8))
        blob.appendSSHString(Data(Self.curveName.utf8))
        blob.appendSSHString(x963Point)
        self.blob = blob
        self.comment = Self.sanitizedComment(comment)
    }

    /// One `authorized_keys` line: `ecdsa-sha2-nistp256 <base64 blob> <comment>`.
    public var line: String {
        let base = "\(Self.keyType) \(blob.base64EncodedString())"
        return comment.isEmpty ? base : "\(base) \(comment)"
    }

    /// The OpenSSH SHA256 fingerprint, as `ssh-keygen -l` prints it (`SHA256:` + unpadded base64).
    public var fingerprint: String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// The default comment: `hermesconnect@<device name>`, with spaces changed to `-`.
    public static func defaultComment(deviceName: String) -> String {
        "hermesconnect@\(deviceName)"
    }

    /// Keep the comment on one line and free of spaces, so the line stays one field per part.
    static func sanitizedComment(_ comment: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@._-"))
        let mapped = comment.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" }
        return String(mapped)
    }
}

extension Data {
    /// Append an SSH `string`: a big-endian uint32 length, then the bytes.
    mutating func appendSSHString(_ bytes: Data) {
        var length = UInt32(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(bytes)
    }
}
