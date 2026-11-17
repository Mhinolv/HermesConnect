import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import Testing
@testable import HermesKit

/// Issue #18: the SSH algorithm allow-list. The in-process server runs on 127.0.0.1. No real server is used.
@Suite(.serialized) struct SSHAlgorithmPolicyTests {
    // MARK: Offered lists

    @Test func offeredCiphersAreAEADOnly() {
        #expect(!SSHAlgorithmPolicy.offeredCiphers.isEmpty)
        for cipher in SSHAlgorithmPolicy.offeredCiphers {
            #expect(SSHAlgorithmPolicy.isAllowed(cipher: cipher), "\(cipher)")
        }
    }

    @Test func offeredKeyExchangesAreCurve25519OrMLKEMOnly() {
        #expect(!SSHAlgorithmPolicy.offeredKeyExchanges.isEmpty)
        for kex in SSHAlgorithmPolicy.offeredKeyExchanges {
            #expect(SSHAlgorithmPolicy.isAllowed(keyExchange: kex), "\(kex)")
        }
    }

    @Test func refusedAlgorithmsAreNeverOffered() {
        let offered = SSHAlgorithmPolicy.offeredCiphers + SSHAlgorithmPolicy.offeredKeyExchanges
        for name in SSHAlgorithmPolicy.refusedCiphers + SSHAlgorithmPolicy.refusedKeyExchanges {
            #expect(!offered.contains(name), "\(name)")
        }
        for name in offered {
            #expect(!name.contains("sha1"), "\(name)")
            #expect(!name.contains("cbc"), "\(name)")
            #expect(!name.hasPrefix("diffie-hellman-group"), "\(name)")
        }
        let config = SSHAlgorithmPolicy.citadelAlgorithms
        guard case .replace(let ciphers) = config.transportProtectionSchemes,
              case .replace(let kexes) = config.keyExchangeAlgorithms else {
            Issue.record("The policy must replace the NIOSSH lists, not add to them")
            return
        }
        #expect(ciphers.map { $0.cipherName } == SSHAlgorithmPolicy.offeredCiphers)
        #expect(kexes.flatMap { $0.keyExchangeAlgorithmNames.map(String.init) } == SSHAlgorithmPolicy.offeredKeyExchanges)
    }

    /// Records the library gaps of Citadel 0.12.1 / swift-nio-ssh 0.3.7. If this test fails, NIOSSH changed:
    /// for ML-KEM, make `reportedKeyExchange` tell the key exchanges apart, then update this test.
    @Test func libraryGapsAreRecorded() {
        // No mlkem768x25519-sha256 and no chacha20-poly1305 in NIOSSH yet.
        #expect(!SSHAlgorithmPolicy.offersPostQuantum)
        #expect(SSHAlgorithmPolicy.offeredKeyExchanges == ["curve25519-sha256", "curve25519-sha256@libssh.org"])
        #expect(SSHAlgorithmPolicy.offeredCiphers == ["aes256-gcm@openssh.com", "aes128-gcm@openssh.com"])
        #expect(SSHAlgorithmPolicy.reportedKeyExchange == "curve25519-sha256")
        // When NIOSSH adds them, the policy prefers them.
        #expect(SSHAlgorithmPolicy.allowedKeyExchanges.first == SSHAlgorithmPolicy.postQuantumKeyExchange)
        #expect(SSHAlgorithmPolicy.allowedCiphers.first == "chacha20-poly1305@openssh.com")
    }

    @Test func displayTextJoinsCipherAndKeyExchange() {
        let pair = SSHNegotiatedAlgorithms(cipher: "aes256-gcm@openssh.com", keyExchange: "curve25519-sha256")
        #expect(pair.displayText == "aes256-gcm@openssh.com · curve25519-sha256")
    }

    // MARK: Negotiation with an in-process server

    private let deviceKey = SoftwareKeyFactory.wrap(P256.Signing.PrivateKey())

    private struct Server {
        let server: SSHServer
        let port: Int
        let hostKey: HostKey
        let auth: CitadelTransportTests.RecordingAuthDelegate
    }

    private func startServer(algorithms: SSHAlgorithms = SSHAlgorithms()) async throws -> Server {
        let accepted = HostKey(algorithm: OpenSSHPublicKey.keyType, blob: deviceKey.openSSH(comment: "").blob)
        let auth = CitadelTransportTests.RecordingAuthDelegate(accepted: accepted)
        let serverKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let hostKey = try #require(HostKey(openSSH: String(openSSHPublicKey: serverKey.publicKey)))
        var lastError: (any Error)?
        for _ in 0..<10 {
            let port = Int.random(in: 41000...59000)
            do {
                let server = try await SSHServer.host(host: "127.0.0.1", port: port, hostKeys: [serverKey],
                                                      algorithms: algorithms, authenticationDelegate: auth)
                return Server(server: server, port: port, hostKey: hostKey, auth: auth)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SSHConnectionError.unreachable
    }

    private func connect(_ server: Server) async throws -> any SSHSession {
        let endpoint = SSHEndpoint(host: "127.0.0.1", port: server.port, user: "hermes")
        let pinned = server.hostKey
        return try await CitadelSSHTransport(connectTimeoutSeconds: 5).connect(to: endpoint, key: deviceKey) { received in
            if received != pinned { throw SSHConnectionError.hostKeyChanged(saved: pinned, received: received) }
        }
    }

    @Test func connectionReportsTheNegotiatedCipherAndKeyExchange() async throws {
        let server = try await startServer()
        let session = try await connect(server)
        let algorithms = await session.negotiatedAlgorithms()
        #expect(algorithms == SSHNegotiatedAlgorithms(cipher: "aes256-gcm@openssh.com", keyExchange: "curve25519-sha256"))
        await session.close()
        try await server.server.close()
    }

    @Test func serverWithOnlyAES128GCMNegotiatesAES128GCM() async throws {
        var algorithms = SSHAlgorithms()
        algorithms.transportProtectionSchemes = .replace(with: SSHAlgorithmPolicy.cipherTypes.filter {
            $0.cipherName == "aes128-gcm@openssh.com"
        })
        let server = try await startServer(algorithms: algorithms)
        let session = try await connect(server)
        #expect(await session.negotiatedAlgorithms()?.cipher == "aes128-gcm@openssh.com")
        await session.close()
        try await server.server.close()
    }

    @Test func serverWithOnlyCTRCipherIsRefused() async throws {
        var algorithms = SSHAlgorithms()
        algorithms.transportProtectionSchemes = .replace(with: [AES128CTR.self])
        let server = try await startServer(algorithms: algorithms)
        await #expect(throws: SSHConnectionError.noAllowedAlgorithms) { try await connect(server) }
        #expect(server.auth.requests.isEmpty)
        try await server.server.close()
    }

    @Test func serverWithOnlyDiffieHellmanGroup14SHA1IsRefused() async throws {
        var algorithms = SSHAlgorithms()
        algorithms.keyExchangeAlgorithms = .replace(with: [DiffieHellmanGroup14Sha1.self])
        let server = try await startServer(algorithms: algorithms)
        await #expect(throws: SSHConnectionError.noAllowedAlgorithms) { try await connect(server) }
        #expect(server.auth.requests.isEmpty)
        // The server registered the weak types in the global NIOSSH registry. The client still does not offer them.
        #expect(!SSHAlgorithmPolicy.offeredKeyExchanges.contains("diffie-hellman-group14-sha1"))
        try await server.server.close()
    }
}
