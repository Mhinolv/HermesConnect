import Citadel
import NIOCore
import NIOSSH

/// The SSH algorithms that the app offers (issue #18): AEAD ciphers and curve25519 key exchange only.
///
/// The app offers no SHA-1, no CBC or CTR cipher, no HMAC, no NIST curve and no `diffie-hellman-group*`.
/// A server that offers only those fails the key exchange with `SSHConnectionError.noAllowedAlgorithms`.
///
/// Library gaps (Citadel 0.12.1, swift-nio-ssh 0.3.7). The tests in `SSHAlgorithmPolicyTests` record them:
/// - NIOSSH has no `mlkem768x25519-sha256` (post-quantum hybrid) and no `chacha20-poly1305@openssh.com`.
///   The policy lists both first. When NIOSSH adds them, the filter offers them with no code change.
/// - The NIOSSH algorithm types are internal, so the policy cannot name them. It filters the bundled
///   NIOSSH lists by their wire names.
/// - NIOSSH does not record which key exchange name it chose. The only allowed key exchange type answers to
///   `curve25519-sha256` and its older alias `curve25519-sha256@libssh.org` (the same algorithm), so the app
///   reports `curve25519-sha256`.
public enum SSHAlgorithmPolicy {
    public static let postQuantumKeyExchange = "mlkem768x25519-sha256"

    /// Allowed key exchange names, most preferred first.
    public static let allowedKeyExchanges = [postQuantumKeyExchange, "curve25519-sha256", "curve25519-sha256@libssh.org"]

    /// Allowed cipher names, most preferred first. All are AEAD: the MAC is part of the cipher.
    public static let allowedCiphers = ["chacha20-poly1305@openssh.com", "aes256-gcm@openssh.com", "aes128-gcm@openssh.com"]

    /// Names that the app must never offer. Tests check the offered lists against them.
    public static let refusedKeyExchanges = [
        "diffie-hellman-group1-sha1", "diffie-hellman-group14-sha1", "diffie-hellman-group14-sha256",
        "diffie-hellman-group-exchange-sha1", "diffie-hellman-group-exchange-sha256",
    ]
    public static let refusedCiphers = [
        "aes128-cbc", "aes192-cbc", "aes256-cbc", "3des-cbc", "blowfish-cbc", "cast128-cbc",
        "rijndael-cbc@lysator.liu.se", "aes128-ctr", "aes192-ctr", "aes256-ctr", "arcfour",
    ]

    public static func isAllowed(cipher: String) -> Bool { allowedCiphers.contains(cipher) }
    public static func isAllowed(keyExchange: String) -> Bool { allowedKeyExchanges.contains(keyExchange) }

    /// The key exchange types that the app offers, in the order of `allowedKeyExchanges`.
    static var keyExchangeTypes: [NIOSSHKeyExchangeAlgorithmProtocol.Type] {
        allowed(bundled.keyExchangeAlgorithms, names: { $0.keyExchangeAlgorithmNames.map(String.init) },
                order: allowedKeyExchanges)
    }

    /// The cipher types that the app offers, in the order of `allowedCiphers`.
    static var cipherTypes: [NIOSSHTransportProtection.Type] {
        allowed(bundled.transportProtectionSchemes, names: { [$0.cipherName] }, order: allowedCiphers)
    }

    /// The key exchange names that the app sends in its `SSH_MSG_KEXINIT`.
    public static var offeredKeyExchanges: [String] {
        keyExchangeTypes.flatMap { $0.keyExchangeAlgorithmNames.map(String.init) }
    }

    /// The cipher names that the app sends in its `SSH_MSG_KEXINIT`.
    public static var offeredCiphers: [String] { cipherTypes.map { $0.cipherName } }

    /// True when the bundled NIOSSH offers the post-quantum key exchange.
    public static var offersPostQuantum: Bool { offeredKeyExchanges.contains(postQuantumKeyExchange) }

    /// The name that the app reports for the key exchange of a connection that succeeded.
    /// With one allowed key exchange type, that type is the one that ran.
    static var reportedKeyExchange: String? {
        let types = keyExchangeTypes
        guard types.count == 1 else { return nil }
        return types[0].keyExchangeAlgorithmNames.first.map(String.init)
    }

    /// The lists for Citadel. `replace` keeps the NIOSSH defaults out: only these types go into the client config.
    static var citadelAlgorithms: SSHAlgorithms {
        var algorithms = SSHAlgorithms()
        algorithms.keyExchangeAlgorithms = .replace(with: keyExchangeTypes)
        algorithms.transportProtectionSchemes = .replace(with: cipherTypes)
        return algorithms
    }

    /// Keeps the types whose names are all allowed, sorted by the position of their first name in `order`.
    private static func allowed<T>(_ types: [T], names: (T) -> [String], order: [String]) -> [T] {
        types
            .filter { type in
                let typeNames = names(type)
                return !typeNames.isEmpty && typeNames.allSatisfy(order.contains)
            }
            .sorted { first, second in
                let a = names(first).compactMap(order.firstIndex).min() ?? order.count
                let b = names(second).compactMap(order.firstIndex).min() ?? order.count
                return a < b
            }
    }

    /// A client configuration with the NIOSSH defaults, read for its default lists only. It never connects.
    private static var bundled: SSHClientConfiguration {
        SSHClientConfiguration(userAuthDelegate: NoDelegate(), serverAuthDelegate: NoDelegate())
    }

    private struct NoDelegate: NIOSSHClientUserAuthenticationDelegate, NIOSSHClientServerAuthenticationDelegate {
        func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
            nextChallengePromise.succeed(nil)
        }

        func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
            validationCompletePromise.fail(SSHConnectionError.unexpectedReply)
        }
    }
}

/// The cipher and key exchange of the last connection that succeeded. Settings shows them (issue #18).
public struct SSHNegotiatedAlgorithms: Codable, Sendable, Equatable {
    public var cipher: String
    public var keyExchange: String

    public init(cipher: String, keyExchange: String) {
        self.cipher = cipher
        self.keyExchange = keyExchange
    }

    /// `<cipher> · <kex>`, for the Settings row.
    public var displayText: String { "\(cipher) · \(keyExchange)" }
}
