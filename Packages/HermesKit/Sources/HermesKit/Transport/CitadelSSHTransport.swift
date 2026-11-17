import Citadel
import Foundation
import NIOCore
import NIOSSH

/// The real `SSHTransport`: Citadel over SwiftNIO SSH.
///
/// - The host key check runs during the key exchange, before user authentication.
/// - Authentication offers only the device key, once. No password, no keyboard-interactive.
/// - No PTY, no agent forwarding, no remote forwards. Citadel refuses channels that the server opens.
public struct CitadelSSHTransport: SSHTransport {
    public var connectTimeoutSeconds: Int64

    public init(connectTimeoutSeconds: Int64 = 15) {
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    public func connect(to endpoint: SSHEndpoint, key: DeviceKey,
                        checkHostKey: @escaping @Sendable (HostKey) throws -> Void) async throws -> any SSHSession {
        let privateKey: NIOSSHPrivateKey
        do {
            privateKey = try key.sshPrivateKey()
        } catch {
            throw SSHConnectionError.unusableKey
        }
        let checker = HostKeyChecker(check: checkHostKey)
        let authentication = DeviceKeyAuthentication(username: endpoint.user, privateKey: privateKey)
        do {
            let client = try await SSHClient.connect(
                host: endpoint.host,
                port: endpoint.port,
                authenticationMethod: .custom(authentication),
                hostKeyValidator: .custom(checker),
                reconnect: .never,
                connectTimeout: .seconds(connectTimeoutSeconds)
            )
            return CitadelSession(client: client)
        } catch {
            // A host key rejection is the first failure. NIOSSH can wrap it, so use the recorded error.
            if let rejection = checker.rejection { throw rejection }
            if authentication.didOffer { throw SSHConnectionError.authenticationFailed }
            if let error = error as? SSHConnectionError { throw error }
            throw SSHConnectionError.unreachable
        }
    }
}

/// Converts the NIOSSH host key and calls the check. It records the rejection, so `connect` can rethrow it.
private final class HostKeyChecker: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let check: @Sendable (HostKey) throws -> Void
    private let lock = NSLock()
    private var _rejection: (any Error)?

    init(check: @escaping @Sendable (HostKey) throws -> Void) {
        self.check = check
    }

    var rejection: (any Error)? { lock.withLock { _rejection } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            guard let received = HostKey(openSSH: String(openSSHPublicKey: hostKey)) else {
                throw SSHConnectionError.unexpectedReply
            }
            try check(received)
            validationCompletePromise.succeed(())
        } catch {
            lock.withLock { _rejection = error }
            validationCompletePromise.fail(error)
        }
    }
}

/// Offers the device key one time. If the server refuses it, authentication stops.
private final class DeviceKeyAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private let lock = NSLock()
    private var offered = false

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    var didOffer: Bool { lock.withLock { offered } }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        let first = lock.withLock { () -> Bool in
            defer { offered = true }
            return !offered
        }
        guard first, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
            return
        }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username, serviceName: "",
            offer: .privateKey(.init(privateKey: privateKey))
        ))
    }
}

/// One authenticated Citadel connection.
private final class CitadelSession: SSHSession, @unchecked Sendable {
    /// The gate replies with one short line. A larger reply is an error.
    static let maxReplyBytes = 4096

    private let client: SSHClient

    init(client: SSHClient) {
        self.client = client
    }

    func execute(_ command: GateCommand) async throws -> String {
        do {
            let buffer = try await client.executeCommand(command.rawValue, maxResponseSize: Self.maxReplyBytes)
            return String(buffer: buffer)
        } catch let error as TTYSTDError {
            throw SSHConnectionError.gateError(HostConnector.gateErrorCode(fromStderr: String(buffer: error.message)))
        } catch let error as SSHClient.CommandFailed {
            throw SSHConnectionError.gateError("exit \(error.exitCode)")
        } catch {
            throw SSHConnectionError.unreachable
        }
    }

    func close() async {
        try? await client.close()
    }
}
