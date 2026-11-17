import Foundation

/// The server address and the SSH user.
public struct SSHEndpoint: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var user: String

    public init(host: String, port: Int, user: String) {
        self.host = host
        self.port = port
        self.user = user
    }

    public init(profile: ServerProfile) {
        self.init(host: profile.host, port: profile.port, user: profile.user)
    }
}

/// A command that the server gate accepts (`server/README.md`). The gate refuses all other commands.
/// Issue #4 adds `serve`, issue #13 adds `location`.
public enum GateCommand: String, Sendable, CaseIterable {
    case ping
}

/// One open SSH connection. It has no PTY, no agent forwarding and no remote forwards.
public protocol SSHSession: Sendable {
    /// Run one gate command on an exec channel and return its standard output.
    func execute(_ command: GateCommand) async throws -> String
    func close() async
}

/// Opens SSH connections. `CitadelSSHTransport` is the real one. Tests use `ScriptedSSHTransport`.
public protocol SSHTransport: Sendable {
    /// Open a connection to `endpoint` and authenticate with `key`.
    ///
    /// The transport calls `checkHostKey` with the server host key during the key exchange,
    /// before user authentication. If `checkHostKey` throws, the transport closes the connection,
    /// does not authenticate, and throws that same error.
    func connect(to endpoint: SSHEndpoint, key: DeviceKey,
                 checkHostKey: @escaping @Sendable (HostKey) throws -> Void) async throws -> any SSHSession
}

/// Why a connection failed. The text never contains key material or command output other than the gate error code.
public enum SSHConnectionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// There is no pinned host key. The owner must confirm the fingerprint first.
    case hostKeyUnknown(HostKey)
    /// The server sent a key that is not the pinned key. The app did not authenticate.
    case hostKeyChanged(saved: HostKey, received: HostKey)
    /// The server did not accept the device key.
    case authenticationFailed
    /// No connection to the server (DNS, TCP, timeout, closed connection).
    case unreachable
    /// The gate refused the command or failed (`ERROR <code>` on stderr, or a non-zero exit).
    case gateError(String)
    /// The gate answered with text that the app does not understand.
    case unexpectedReply
    /// The device key cannot be used for SSH.
    case unusableKey

    public var description: String {
        switch self {
        case .hostKeyUnknown(let key): "The server host key is not trusted yet (\(key.fingerprint))."
        case .hostKeyChanged(let saved, let received):
            "The server host key changed. Saved \(saved.fingerprint), received \(received.fingerprint)."
        case .authenticationFailed: "The server did not accept the key of this iPhone."
        case .unreachable: "The server is not reachable."
        case .gateError(let code): "The server gate returned an error: \(code)."
        case .unexpectedReply: "The server gate sent an unexpected reply."
        case .unusableKey: "The device key cannot be used for SSH."
        }
    }
}

/// A connection that passed the host key check, authentication and the gate `ping`.
public struct GateConnection: Sendable {
    public let session: any SSHSession
    /// The gate version from `PONG <version>`.
    public let gateVersion: String
}

/// Connects to the one server of the owner with the pinned host key (issue #3).
public struct HostConnector: Sendable {
    public let transport: any SSHTransport

    public init(transport: any SSHTransport) {
        self.transport = transport
    }

    /// Connect, check the host key against `profile.hostKey`, authenticate, then run the gate `ping`.
    /// - Throws: `SSHConnectionError`. `hostKeyUnknown` and `hostKeyChanged` come before authentication.
    public func connect(profile: ServerProfile, key: DeviceKey) async throws(SSHConnectionError) -> GateConnection {
        let pinned = profile.hostKey
        let session: any SSHSession
        do {
            session = try await transport.connect(to: SSHEndpoint(profile: profile), key: key) { received in
                switch HostKeyVerdict.evaluate(received: received, pinned: pinned) {
                case .trusted: return
                case .unknown(let key): throw SSHConnectionError.hostKeyUnknown(key)
                case .changed(let saved, let received):
                    throw SSHConnectionError.hostKeyChanged(saved: saved, received: received)
                }
            }
        } catch let error as SSHConnectionError {
            throw error
        } catch {
            throw .unreachable
        }
        do {
            let reply = try await session.execute(.ping)
            guard let version = Self.parsePong(reply) else { throw SSHConnectionError.unexpectedReply }
            return GateConnection(session: session, gateVersion: version)
        } catch {
            await session.close()
            throw (error as? SSHConnectionError) ?? .unreachable
        }
    }

    /// `PONG <version>` (one line) gives `<version>`. Other text gives nil.
    public static func parsePong(_ reply: String) -> String? {
        let line = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.contains("\n"), line.hasPrefix("PONG ") else { return nil }
        let version = line.dropFirst("PONG ".count).trimmingCharacters(in: .whitespaces)
        return version.isEmpty ? nil : version
    }

    /// The gate error code from stderr (`ERROR not-allowed` gives `not-allowed`).
    /// Only the code is kept, so no other server text reaches the UI or a log.
    public static func gateErrorCode(fromStderr text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard line.hasPrefix("ERROR ") else { return "unknown" }
        let rest = line.dropFirst("ERROR ".count)
        let code = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        return code.isEmpty ? "unknown" : String(code)
    }
}

// MARK: - Test and preview transport

/// A fake `SSHTransport` that never opens a socket. For tests and previews.
/// It calls the host key check like the real transport, and it records what happened.
public final class ScriptedSSHTransport: SSHTransport, @unchecked Sendable {
    public struct Record: Sendable, Equatable {
        public var connectAttempts = 0
        /// Connections that passed the host key check and reached authentication.
        public var authentications = 0
        public var commands: [GateCommand] = []
        public var closedSessions = 0
    }

    private let lock = NSLock()
    private var _hostKey: HostKey
    private var _pingReply: Result<String, SSHConnectionError>
    private var _connectFailure: SSHConnectionError?
    private var _record = Record()

    public init(hostKey: HostKey, pingReply: Result<String, SSHConnectionError> = .success("PONG 1\n"),
                connectFailure: SSHConnectionError? = nil) {
        _hostKey = hostKey
        _pingReply = pingReply
        _connectFailure = connectFailure
    }

    /// The key that the fake server sends. Change it to simulate a changed host key.
    public var hostKey: HostKey {
        get { lock.withLock { _hostKey } }
        set { lock.withLock { _hostKey = newValue } }
    }

    /// The error that authentication or the network gives, or nil for success.
    public var connectFailure: SSHConnectionError? {
        get { lock.withLock { _connectFailure } }
        set { lock.withLock { _connectFailure = newValue } }
    }

    public var pingReply: Result<String, SSHConnectionError> {
        get { lock.withLock { _pingReply } }
        set { lock.withLock { _pingReply = newValue } }
    }

    public var record: Record { lock.withLock { _record } }

    public func connect(to endpoint: SSHEndpoint, key: DeviceKey,
                        checkHostKey: @escaping @Sendable (HostKey) throws -> Void) async throws -> any SSHSession {
        let hostKey = lock.withLock { () -> HostKey in
            _record.connectAttempts += 1
            return _hostKey
        }
        if connectFailure == .unreachable { throw SSHConnectionError.unreachable }
        try checkHostKey(hostKey)
        lock.withLock { _record.authentications += 1 }
        if let failure = connectFailure { throw failure }
        return Session(transport: self)
    }

    fileprivate func run(_ command: GateCommand) throws -> String {
        let reply = lock.withLock { () -> Result<String, SSHConnectionError> in
            _record.commands.append(command)
            return _pingReply
        }
        return try reply.get()
    }

    fileprivate func didClose() {
        lock.withLock { _record.closedSessions += 1 }
    }

    private struct Session: SSHSession {
        let transport: ScriptedSSHTransport

        func execute(_ command: GateCommand) async throws -> String {
            try transport.run(command)
        }

        func close() async {
            transport.didClose()
        }
    }
}

extension HostKey {
    /// A fixed Ed25519 host key for tests and previews. It is public data, not a real server key.
    public static let sample = HostKey(algorithm: "ssh-ed25519", blob: sampleBlob(fill: 0x2A))
    /// A second key, to simulate a changed host key.
    public static let otherSample = HostKey(algorithm: "ssh-ed25519", blob: sampleBlob(fill: 0x7E))

    private static func sampleBlob(fill: UInt8) -> Data {
        var blob = Data()
        blob.appendSSHString(Data("ssh-ed25519".utf8))
        blob.appendSSHString(Data(repeating: fill, count: 32))
        return blob
    }
}
