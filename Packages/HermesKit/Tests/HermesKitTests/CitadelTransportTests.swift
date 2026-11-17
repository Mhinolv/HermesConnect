import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import Testing
@testable import HermesKit

/// The real Citadel transport against an in-process SSH server on 127.0.0.1. No real server is used.
@Suite(.serialized) struct CitadelTransportTests {
    /// Records each user authentication request. Accepts only `accepted`.
    final class RecordingAuthDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey
        private let lock = NSLock()
        private var _requests: [HostKey] = []
        let accepted: HostKey?

        init(accepted: HostKey?) { self.accepted = accepted }

        var requests: [HostKey] { lock.withLock { _requests } }

        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            guard case .publicKey(let offer) = request.request,
                  let key = HostKey(openSSH: String(openSSHPublicKey: offer.publicKey)) else {
                responsePromise.succeed(.failure)
                return
            }
            lock.withLock { _requests.append(key) }
            responsePromise.succeed(key == accepted && request.username == "hermes" ? .success : .failure)
        }
    }

    struct Server {
        let server: SSHServer
        let port: Int
        let hostKey: HostKey
    }

    private let deviceKey = SoftwareKeyFactory.wrap(P256.Signing.PrivateKey())

    private var deviceKeyAsHostKey: HostKey {
        HostKey(algorithm: OpenSSHPublicKey.keyType, blob: deviceKey.openSSH(comment: "").blob)
    }

    private func startServer(auth: RecordingAuthDelegate) async throws -> Server {
        let serverKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let hostKey = try #require(HostKey(openSSH: String(openSSHPublicKey: serverKey.publicKey)))
        var lastError: (any Error)?
        for _ in 0..<10 {
            let port = Int.random(in: 41000...59000)
            do {
                let server = try await SSHServer.host(host: "127.0.0.1", port: port, hostKeys: [serverKey],
                                                      authenticationDelegate: auth)
                return Server(server: server, port: port, hostKey: hostKey)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SSHConnectionError.unreachable
    }

    private func connect(_ server: Server, pin: HostKey?) async -> Result<any SSHSession, SSHConnectionError> {
        let profile = ServerProfile(host: "127.0.0.1", port: server.port, hostKey: pin)
        let transport = CitadelSSHTransport(connectTimeoutSeconds: 5)
        do {
            let session = try await transport.connect(to: SSHEndpoint(profile: profile), key: deviceKey) { received in
                if case .changed(let saved, let received) = HostKeyVerdict.evaluate(received: received, pinned: pin) {
                    throw SSHConnectionError.hostKeyChanged(saved: saved, received: received)
                }
                if pin == nil { throw SSHConnectionError.hostKeyUnknown(received) }
            }
            return .success(session)
        } catch let error as SSHConnectionError {
            return .failure(error)
        } catch {
            Issue.record("Unexpected error type: \(type(of: error))")
            return .failure(.unreachable)
        }
    }

    @Test func unknownHostKeyStopsBeforeAuthentication() async throws {
        let auth = RecordingAuthDelegate(accepted: deviceKeyAsHostKey)
        let server = try await startServer(auth: auth)
        let result = await connect(server, pin: nil)
        #expect(throws: SSHConnectionError.hostKeyUnknown(server.hostKey)) { try result.get() }
        #expect(auth.requests.isEmpty)
        try await server.server.close()
    }

    @Test func changedHostKeyStopsBeforeAuthentication() async throws {
        let auth = RecordingAuthDelegate(accepted: deviceKeyAsHostKey)
        let server = try await startServer(auth: auth)
        let result = await connect(server, pin: .sample)
        #expect(throws: SSHConnectionError.hostKeyChanged(saved: .sample, received: server.hostKey)) { try result.get() }
        #expect(auth.requests.isEmpty)
        try await server.server.close()
    }

    @Test func pinnedHostKeyAuthenticatesWithTheDeviceKey() async throws {
        let auth = RecordingAuthDelegate(accepted: deviceKeyAsHostKey)
        let server = try await startServer(auth: auth)
        let session = try await connect(server, pin: server.hostKey).get()
        #expect(auth.requests == [deviceKeyAsHostKey])
        await session.close()
        try await server.server.close()
    }

    @Test func refusedDeviceKeyIsAnAuthenticationFailure() async throws {
        let auth = RecordingAuthDelegate(accepted: nil)
        let server = try await startServer(auth: auth)
        let result = await connect(server, pin: server.hostKey)
        #expect(throws: SSHConnectionError.authenticationFailed) { try result.get() }
        #expect(auth.requests.count == 1)
        try await server.server.close()
    }
}
