import Foundation
import Security

/// The 64-hex session token of one `hermes serve` spawn (docs/hermes-protocol.md 1.6).
/// Issue #173: the app keeps it in the Keychain for each server (`ServeTokenStore`). It goes to the gate on stdin and to Hermes in the
/// `X-Hermes-Session-Token` header. `description` hides it, so a print or a log line cannot leak it.
public struct SessionToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 64 lowercase hex characters.
    let value: String

    init?(hex: String) {
        guard Self.isValid(Data(hex.utf8)) else { return nil }
        value = hex
    }

    /// 32 random bytes from the system CSPRNG, as 64 lowercase hex (`mint_token`).
    public static func mint() -> SessionToken {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "The system random number generator failed.")
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return SessionToken(hex: hex)!
    }

    /// `true` for exactly 64 lowercase hex characters, the gate rule (`server/README.md`).
    public static func isValid(_ bytes: Data) -> Bool {
        bytes.count == 64 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// The gate `serve` stdin: the token with no newline. The gate reads it to EOF.
    var stdinBytes: Data { Data(value.utf8) }

    public var description: String { "SessionToken(<redacted>)" }
    public var debugDescription: String { description }
}

/// A running Hermes server, reachable through a loopback forward on this device.
public struct HermesServe: Sendable {
    /// `http://127.0.0.1:<local port>` and the token. Give it to `GatewayClient` and `HermesRESTClient` (#5).
    public let endpoint: GatewayEndpoint
    public let forward: any LoopbackForward
    /// The server port from `PORT <n>`. A fixed-port gate (version 2 or later) always prints the same port (#29).
    public let remotePort: Int
    /// Keep it for the next connect (issue #173: in the Keychain, `ServeTokenStore`). The gate then reuses the live server.
    public let token: SessionToken
}

/// Starts or reuses `hermes serve` through the gate, then checks it (issue #4).
///
/// 1. Send the token on the gate `serve` stdin. The gate starts or reuses the server and prints `PORT <n>`.
/// 2. Open a local forward to `127.0.0.1:<n>` on the server.
/// 3. `GET /api/health` (fallback `GET /api/status`) until it answers. Issue #181: a reuse token skips this step.
///    The gate prints `PORT <n>` only for a live server or after `HERMES_BACKEND_READY`, and step 4 calls the
///    same server (docs/hermes-protocol.md 7.1 step 6). If step 4 cannot reach Hermes, step 3 runs, then step 4 again.
/// 4. `GET /api/ssh/ownership` with the token. 401, 403 or 404 means that the token is stale.
///    A stale reuse token gets one more try with a new token. The gate then replaces the server.
///    Issue #181: with `socketPrewarm`, the gateway socket opens while this check runs. Nothing goes on that
///    socket before the check passes. A failed check closes it.
///
/// With a pinned port, a `PORT <n>` with another port fails with `gateError("port-changed")` before step 2 (issue #29).
/// Issue #181: `start(on: GateLogin, …)` runs step 1 while the gate `ping` runs. Before step 2 it waits for the
/// `ping`. A failed `ping` gives its own error, as when the `ping` ran first.
public struct ServeBootstrap: Sendable {
    public struct Configuration: Sendable {
        /// The gate waits up to 120 s for the ready line. This deadline covers that wait and the SSH round trip.
        public var serveTimeout: Duration
        public var healthAttempts: Int
        public var healthRetryDelay: Duration

        public init(serveTimeout: Duration = .seconds(150), healthAttempts: Int = 10,
                    healthRetryDelay: Duration = .milliseconds(500)) {
            self.serveTimeout = serveTimeout
            self.healthAttempts = healthAttempts
            self.healthRetryDelay = healthRetryDelay
        }
    }

    /// Gate error codes that can go away when the owner tries again ("Offline", tap to retry).
    /// All other gate codes are a refusal ("Not connected" and the "Hermes Did Not Start" alert).
    public static let retryableGateCodes: Set<String> = ["serve-timeout", "serve-exited", "update-in-progress"]

    /// The code of the error for a `PORT <n>` that differs from the pinned port. The app treats it as a refusal.
    public static let portChangedCode = "port-changed"

    /// Gate version 2 and later serve on one fixed port for each key slot (issue #29), so the app can pin that port.
    /// Version 1 asks the server for a random port at each spawn, so a pin would refuse every new spawn.
    public static func pinsPort(gateVersion: String) -> Bool {
        guard gateVersion.allSatisfy(\.isASCII), let version = Int(gateVersion) else { return false }
        return version >= 2
    }

    private let loader: any HTTPDataLoading
    private let configuration: Configuration
    private let mintToken: @Sendable () -> SessionToken
    private let socketPrewarm: GatewaySocketPrewarm?

    /// - Parameter socketPrewarm: Issue #181: opens the gateway socket while the ownership check runs, or nil.
    ///   The app gives `.shared`, which `PrewarmedGatewayConnector` reads.
    public init(loader: any HTTPDataLoading = URLSessionHTTPLoader(), configuration: Configuration = Configuration(),
                socketPrewarm: GatewaySocketPrewarm? = nil,
                mintToken: @escaping @Sendable () -> SessionToken = { SessionToken.mint() }) {
        self.loader = loader
        self.configuration = configuration
        self.socketPrewarm = socketPrewarm
        self.mintToken = mintToken
    }

    /// - Parameters:
    ///   - reuse: The token of the last connect, or nil. With a token, the gate reuses its live server.
    ///   - pinnedPort: The server port of the last connect to a fixed-port gate, or nil. Another port is refused.
    ///   - timing: Issue #180: the run that records the `serve`, `health` and `ownership` steps, or nil.
    ///     A failure ends the run with the step that failed. A retry with a new token records the steps again.
    /// - Throws: `SSHConnectionError`. `gateError` holds only the gate code.
    public func start(on session: any SSHSession, reuse: SessionToken?, pinnedPort: Int? = nil,
                      timing: ConnectRun? = nil) async throws(SSHConnectionError) -> HermesServe {
        try await start(on: session, reuse: reuse, pin: .fixed(pinnedPort), timing: timing)
    }

    /// Issue #181: the same steps on a `GateLogin`. The gate `serve` runs while the gate `ping` runs.
    /// - Parameters:
    ///   - savedPort: The saved server port of the profile (`ServerProfile.servePort`), or nil.
    ///     It becomes the pin only when the `ping` gives a fixed-port gate (`pinsPort(gateVersion:)`).
    /// - Throws: `SSHConnectionError`. A failed `ping` gives the error of the `ping`, also when the `serve` failed.
    public func start(on login: GateLogin, reuse: SessionToken?, savedPort: Int?,
                      timing: ConnectRun? = nil) async throws(SSHConnectionError) -> HermesServe {
        try await start(on: login.session, reuse: reuse, pin: .fromGate(login, savedPort: savedPort), timing: timing)
    }

    private func start(on session: any SSHSession, reuse: SessionToken?, pin: PortPin,
                       timing: ConnectRun?) async throws(SSHConnectionError) -> HermesServe {
        do throws(SSHConnectionError) {
            do {
                return try await attempt(on: session, token: reuse ?? mintToken(), reused: reuse != nil, pin: pin,
                                         timing: timing)
            } catch .sessionTokenRejected where reuse != nil {
                return try await attempt(on: session, token: mintToken(), reused: false, pin: pin, timing: timing)
            }
        } catch {
            timing?.fail()
            throw error
        }
    }

    /// Where the port pin comes from.
    private enum PortPin: Sendable {
        /// The caller ran the `ping` already.
        case fixed(Int?)
        /// The `ping` runs at the same time as the `serve`.
        case fromGate(GateLogin, savedPort: Int?)

        /// Issue #182: ends when the `ping` ends, and throws its error. `fixed` ends at once.
        var failure: @Sendable () async throws -> Void {
            switch self {
            case .fixed: return {}
            case .fromGate(let login, _): return { _ = try await login.gateVersion() }
            }
        }

        /// The pin. It waits for the `ping` and throws its error.
        func port() async throws(SSHConnectionError) -> Int? {
            switch self {
            case .fixed(let port): return port
            case .fromGate(let login, let savedPort):
                return ServeBootstrap.pinsPort(gateVersion: try await login.gateVersion()) ? savedPort : nil
            }
        }
    }

    /// `PORT <n>` (one line, 1...65535) gives `n`. Other text gives nil.
    public static func parsePort(_ reply: String) -> Int? {
        let line = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.contains("\n"), line.hasPrefix("PORT ") else { return nil }
        let digits = line.dropFirst("PORT ".count)
        guard !digits.isEmpty, digits.count <= 5, digits.allSatisfy(\.isASCII), let port = Int(digits),
              (1...65535).contains(port) else { return nil }
        return port
    }

    /// - Parameter reused: `token` is the token of the last connect. Then the health check runs only as a fallback.
    private func attempt(on session: any SSHSession, token: SessionToken, reused: Bool, pin: PortPin,
                         timing: ConnectRun?) async throws(SSHConnectionError) -> HermesServe {
        let (remotePort, forward): (Int, any LoopbackForward)
        do {
            (remotePort, forward) = try await timing.measure(.serve) {
                try await serve(on: session, token: token, pin: pin)
            }
        } catch {
            throw (error as? SSHConnectionError) ?? .unreachable
        }
        var socketURL: URL?
        do {
            guard let endpoint = try? GatewayEndpoint(port: forward.localPort, token: token.value) else {
                throw SSHConnectionError.forwardFailed
            }
            let client = HermesRESTClient(endpoint: endpoint, loader: loader)
            if !reused {
                try await timing.measure(.health) { try await waitForHealth(client) }
            }
            if let socketPrewarm {
                socketURL = endpoint.webSocketURL
                socketPrewarm.open(endpoint.webSocketURL)
            }
            do {
                try await timing.measure(.ownership) { try await checkOwnership(client) }
            } catch SSHConnectionError.hermesNotReady where reused {
                // Hermes did not answer. Wait for it as a new spawn does, then check again.
                try await timing.measure(.health) { try await waitForHealth(client) }
                try await timing.measure(.ownership) { try await checkOwnership(client) }
            }
            return HermesServe(endpoint: endpoint, forward: forward, remotePort: remotePort, token: token)
        } catch {
            if let socketURL { socketPrewarm?.discard(socketURL) }
            await forward.close()
            throw (error as? SSHConnectionError) ?? .hermesNotReady
        }
    }

    /// The gate `serve`, then the forward to the port that it printed.
    /// With `PortPin.fromGate`, it waits for the `ping` before it reads the reply. A `ping` error comes first.
    private func serve(on session: any SSHSession, token: SessionToken,
                       pin: PortPin) async throws(SSHConnectionError) -> (Int, any LoopbackForward) {
        let reply: String
        do {
            // Issue #182: a failed `ping` ends a `serve` with no reply at once. It does not wait for the `serve` limit.
            reply = try await withDeadline(configuration.serveTimeout) { [pin] in
                try await untilFailure(pin.failure) { try await session.execute(.serve, stdin: token.stdinBytes) }
            }
        } catch {
            _ = try await pin.port()
            throw (error as? SSHConnectionError) ?? (error is DeadlineExceeded ? .hermesNotReady : .unreachable)
        }
        let pinnedPort = try await pin.port()
        guard let remotePort = Self.parsePort(reply) else { throw .unexpectedReply }
        if let pinnedPort, remotePort != pinnedPort { throw .gateError(Self.portChangedCode) }
        do {
            return (remotePort, try await session.openLoopbackForward(remotePort: remotePort))
        } catch {
            throw (error as? SSHConnectionError) ?? .forwardFailed
        }
    }

    private func waitForHealth(_ client: HermesRESTClient) async throws {
        for attempt in 0..<max(configuration.healthAttempts, 1) {
            if attempt > 0 { try await Task.sleep(for: configuration.healthRetryDelay) }
            if (try? await client.health()) != nil { return }
            if (try? await client.status()) != nil { return }
        }
        throw SSHConnectionError.hermesNotReady
    }

    private func checkOwnership(_ client: HermesRESTClient) async throws {
        let proof: SSHOwnershipProof
        do {
            proof = try await client.sshOwnership()
        } catch HermesAPIError.unauthorized, HermesAPIError.notFound, HermesAPIError.http(status: 403) {
            throw SSHConnectionError.sessionTokenRejected
        } catch {
            throw SSHConnectionError.hermesNotReady
        }
        guard proof.isValid else { throw SSHConnectionError.sessionTokenRejected }
    }
}
