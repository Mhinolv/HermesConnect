import CryptoKit
import Foundation
import Testing
@testable import HermesKit

@Suite struct HostConnectorTests {
    private let key = SoftwareKeyFactory.wrap(P256.Signing.PrivateKey())

    private func connect(_ transport: ScriptedSSHTransport, pin: HostKey?) async -> Result<GateConnection, SSHConnectionError> {
        let profile = ServerProfile(host: "vps.example.com", hostKey: pin)
        do {
            return .success(try await HostConnector(transport: transport).connect(profile: profile, key: key))
        } catch {
            return .failure(error)
        }
    }

    @Test func firstConnectStopsBeforeAuthenticationAndShowsTheKey() async {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let result = await connect(transport, pin: nil)
        #expect(throws: SSHConnectionError.hostKeyUnknown(.sample)) { try result.get() }
        #expect(transport.record.connectAttempts == 1)
        #expect(transport.record.authentications == 0)
        #expect(transport.record.commands.isEmpty)
    }

    @Test func pinnedKeyConnectsAndPings() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample, pingReply: .success("PONG 1\n"))
        let connection = try await connect(transport, pin: .sample).get()
        #expect(connection.gateVersion == "1")
        #expect(connection.algorithms == SSHNegotiatedAlgorithms(cipher: "aes256-gcm@openssh.com",
                                                                 keyExchange: "curve25519-sha256"))
        #expect(transport.record.authentications == 1)
        #expect(transport.record.commands == [.ping])
    }

    @Test func changedKeyBlocksBeforeAuthentication() async {
        let transport = ScriptedSSHTransport(hostKey: .otherSample)
        let result = await connect(transport, pin: .sample)
        #expect(throws: SSHConnectionError.hostKeyChanged(saved: .sample, received: .otherSample)) { try result.get() }
        #expect(transport.record.authentications == 0)
        #expect(transport.record.commands.isEmpty)
    }

    @Test(arguments: [SSHConnectionError.authenticationFailed, .unreachable])
    func connectFailuresPassThrough(failure: SSHConnectionError) async {
        let transport = ScriptedSSHTransport(hostKey: .sample, connectFailure: failure)
        let result = await connect(transport, pin: .sample)
        #expect(throws: failure) { try result.get() }
        #expect(transport.record.commands.isEmpty)
    }

    @Test(arguments: [
        (Result<String, SSHConnectionError>.success("hello"), SSHConnectionError.unexpectedReply),
        (.success("PONG \n"), .unexpectedReply),
        (.success("PONG 1\nextra"), .unexpectedReply),
        (.failure(.gateError("not-allowed")), .gateError("not-allowed")),
    ])
    func badPingClosesTheSession(reply: Result<String, SSHConnectionError>, expected: SSHConnectionError) async {
        let transport = ScriptedSSHTransport(hostKey: .sample, pingReply: reply)
        let result = await connect(transport, pin: .sample)
        #expect(throws: expected) { try result.get() }
        #expect(transport.record.closedSessions == 1)
    }

    @Test func parsePong() {
        #expect(HostConnector.parsePong("PONG 1\n") == "1")
        #expect(HostConnector.parsePong("PONG 1.2.3") == "1.2.3")
        #expect(HostConnector.parsePong("PING 1") == nil)
        #expect(HostConnector.parsePong("") == nil)
    }

    @Test func gateErrorKeepsOnlyTheCode() {
        #expect(HostConnector.gateErrorCode(fromStderr: "ERROR not-allowed\n") == "not-allowed")
        #expect(HostConnector.gateErrorCode(fromStderr: "ERROR bad-token: secret text here") == "bad-token")
        #expect(HostConnector.gateErrorCode(fromStderr: "Traceback (most recent call last)") == "unknown")
    }

    @Test func errorTextHasNoKeyMaterial() {
        let text = SSHConnectionError.hostKeyChanged(saved: .sample, received: .otherSample).description
        #expect(text.contains(HostKey.sample.fingerprint))
        #expect(!text.contains(HostKey.sample.blob.base64EncodedString()))
    }
}

@Suite struct DeviceKeySSHTests {
    @Test func softwareKeyGivesAnSSHKey() throws {
        let key = SoftwareKeyFactory.wrap(P256.Signing.PrivateKey())
        _ = try key.sshPrivateKey()
    }

    @Test func foreignSignerIsRefused() {
        struct Foreign: DeviceKeySigner {
            func sign(_ data: Data) throws -> P256.Signing.ECDSASignature {
                try P256.Signing.PrivateKey().signature(for: data)
            }
        }
        let key = DeviceKey(kind: .software, publicKey: P256.Signing.PrivateKey().publicKey, signer: Foreign())
        #expect(throws: DeviceKeyError.unsupportedSigner) { try key.sshPrivateKey() }
    }
}
