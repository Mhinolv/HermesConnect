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
    private let forwards = OpenForwards()

    init(client: SSHClient) {
        self.client = client
    }

    func execute(_ command: GateCommand, stdin: Data?) async throws -> String {
        guard let stdin else { return try await execute(command) }
        return try await execute(command, sending: stdin)
    }

    /// No stdin: the #3 path.
    private func execute(_ command: GateCommand) async throws -> String {
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

    /// Write `stdin` on the exec channel, then EOF. The bytes never go into the command line.
    private func execute(_ command: GateCommand, sending stdin: Data) async throws -> String {
        var stdout = ByteBuffer()
        var stderr = ByteBuffer()
        // The result of the read loop. `withExec` closes the channel at the end and throws
        // `alreadyClosed` when the server closed it first, so the loop does not throw through it.
        var outcome: Result<Void, SSHConnectionError>?
        do {
            try await client.withExec(command.rawValue) { inbound, outbound in
                try await outbound.write(ByteBuffer(bytes: stdin))
                try await Self.sendEOF(outbound)
                do {
                    for try await output in inbound {
                        switch output {
                        case .stdout(let chunk):
                            guard stdout.readableBytes + chunk.readableBytes <= Self.maxReplyBytes else {
                                throw SSHConnectionError.unexpectedReply
                            }
                            stdout.writeImmutableBuffer(chunk)
                        case .stderr(let chunk):
                            // Keep only the start: the gate code is on the first line.
                            if stderr.readableBytes < Self.maxReplyBytes { stderr.writeImmutableBuffer(chunk) }
                        }
                    }
                    outcome = .success(())
                } catch let error as SSHClient.CommandFailed {
                    let text = String(buffer: stderr)
                    outcome = .failure(.gateError(text.hasPrefix("ERROR ")
                        ? HostConnector.gateErrorCode(fromStderr: text) : "exit \(error.exitCode)"))
                } catch let error as SSHConnectionError {
                    outcome = .failure(error)
                } catch {
                    outcome = .failure(.unreachable)
                }
            }
        } catch let error as SSHConnectionError {
            throw error
        } catch ChannelError.alreadyClosed where outcome != nil {
            // The server closed the channel after its reply. That is the normal end.
        } catch {
            throw SSHConnectionError.unreachable
        }
        guard let outcome else { throw SSHConnectionError.unreachable }
        try outcome.get()
        let errorText = String(buffer: stderr)
        if stdout.readableBytes == 0, errorText.hasPrefix("ERROR ") {
            throw SSHConnectionError.gateError(HostConnector.gateErrorCode(fromStderr: errorText))
        }
        return String(buffer: stdout)
    }

    /// Citadel 0.12 has no public call to close stdin. `TTYStdinWriter` keeps its channel in an
    /// internal property, so read it by reflection and half-close the channel. NIOSSH sends `SSH_MSG_CHANNEL_EOF`.
    static func sendEOF(_ writer: TTYStdinWriter) async throws {
        guard let channel = Mirror(reflecting: writer).descendant("channel") as? any Channel else {
            throw SSHConnectionError.unexpectedReply
        }
        try await channel.close(mode: .output)
    }

    func openLoopbackForward(remotePort: Int) async throws -> any LoopbackForward {
        guard (1...65535).contains(remotePort) else { throw SSHConnectionError.forwardFailed }
        do {
            let forward = try await CitadelLoopbackForward.open(client: client, remotePort: remotePort)
            forwards.add(forward)
            return forward
        } catch {
            throw SSHConnectionError.forwardFailed
        }
    }

    func close() async {
        for forward in forwards.takeAll() { await forward.close() }
        try? await client.close()
    }
}

/// The forwards of one session. `close()` stops them before the SSH connection closes.
private final class OpenForwards: @unchecked Sendable {
    private let lock = NSLock()
    private var forwards: [CitadelLoopbackForward] = []

    func add(_ forward: CitadelLoopbackForward) { lock.withLock { forwards.append(forward) } }

    func takeAll() -> [CitadelLoopbackForward] {
        lock.withLock {
            defer { forwards.removeAll() }
            return forwards
        }
    }
}
