import Foundation
import Testing
@testable import HermesKit

/// A session whose `ping` waits until the `serve` started. A `ping` that runs first fails after 2 s.
/// Each exec can also take a fixed time. No network.
private final class OverlapSession: SSHSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    private var serveStarted = false
    let pong: String
    let port: Int
    let waitsForServe: Bool
    let execTime: Duration

    init(pong: String = "PONG 3\n", port: Int = 47_100, waitsForServe: Bool = true, execTime: Duration = .zero) {
        self.pong = pong
        self.port = port
        self.waitsForServe = waitsForServe
        self.execTime = execTime
    }

    var events: [String] { lock.withLock { _events } }
    private func note(_ event: String) { lock.withLock { _events.append(event) } }

    func execute(_ command: GateCommand, stdin: Data?) async throws -> String {
        switch command {
        case .ping:
            note("ping start")
            if waitsForServe {
                for _ in 0..<1000 where !lock.withLock({ serveStarted }) {
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard lock.withLock({ serveStarted }) else { throw SSHConnectionError.gateError("ping-first") }
            }
            try await Task.sleep(for: execTime)
            note("ping end")
            return pong
        case .serve:
            note("serve start")
            lock.withLock { serveStarted = true }
            try await Task.sleep(for: execTime)
            note("serve end")
            return "PORT \(port)\n"
        case .location:
            return "OK\n"
        }
    }

    func openLoopbackForward(remotePort: Int) async throws -> any LoopbackForward {
        note("forward \(remotePort)")
        return Forward()
    }

    func close() async { note("close") }

    private struct Forward: LoopbackForward {
        var localPort: Int { 50_123 }
        func close() async {}
    }
}

private struct OverlapTransport: SSHTransport {
    let session: OverlapSession
    func connect(to endpoint: SSHEndpoint, key: DeviceKey,
                 checkHostKey: @escaping @Sendable (HostKey) throws -> Void) async throws -> any SSHSession {
        try checkHostKey(.sample)
        return session
    }
}

/// Counts the sockets that the prewarm opens. Optional: the ownership check waits for the first one.
private final class CountingConnector: GatewayWebSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [FakeGatewaySocket] = []
    private var _urls: [URL] = []
    var sockets: [FakeGatewaySocket] { lock.withLock { _sockets } }
    var urls: [URL] { lock.withLock { _urls } }

    func connect(to url: URL) async throws -> any GatewayWebSocket {
        let socket = FakeGatewaySocket()
        lock.withLock {
            _sockets.append(socket)
            _urls.append(url)
        }
        return socket
    }
}

/// Issue #181: fewer steps in the connect sequence.
@Suite(.timeLimit(.minutes(1))) struct FewerConnectStepsTests {
    private let fast = ServeBootstrap.Configuration(serveTimeout: .seconds(5), healthAttempts: 3,
                                                    healthRetryDelay: .milliseconds(1))
    private let profile = ServerProfile(host: "vps.example.com", hostKey: .sample)
    private let key = SoftwareKeyFactory.wrap(.init())

    private func login(_ transport: any SSHTransport, timing: ConnectRun? = nil) async throws -> GateLogin {
        try await HostConnector(transport: transport).login(profile: profile, key: key, timing: timing)
    }

    // MARK: No health call on a reuse

    @Test func aReuseTokenMakesNoHealthCall() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let http = FakeHermesHTTP()
        let bootstrap = ServeBootstrap(loader: http, configuration: fast)
        let first = try await bootstrap.start(on: try await login(transport), reuse: nil, savedPort: nil)
        #expect(http.paths == ["/api/health", "/api/ssh/ownership"], "a new token waits for health")

        let second = try await bootstrap.start(on: try await login(transport), reuse: first.token, savedPort: nil)
        #expect(second.token == first.token)
        #expect(http.paths == ["/api/health", "/api/ssh/ownership", "/api/ssh/ownership"])
        #expect(transport.record.reuses == 1)
    }

    @Test func aReuseOnTheOldPathMakesNoHealthCallToo() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let http = FakeHermesHTTP()
        let bootstrap = ServeBootstrap(loader: http, configuration: fast)
        let gate = try await HostConnector(transport: transport).connect(profile: profile, key: key)
        let first = try await bootstrap.start(on: gate.session, reuse: nil)
        _ = try await bootstrap.start(on: gate.session, reuse: first.token)
        #expect(http.paths.filter { $0 == "/api/health" }.count == 1)
    }

    /// The ownership check of a reuse cannot reach Hermes. The health wait runs, then the check runs again.
    @Test func aReuseThatCannotReachHermesWaitsForHealth() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let http = FakeHermesHTTP()
        let bootstrap = ServeBootstrap(loader: http, configuration: fast)
        let first = try await bootstrap.start(on: try await login(transport), reuse: nil, savedPort: nil)
        let calls = Counter()
        http.ownershipStatus = { _ in calls.next() == 1 ? 503 : 200 }

        let second = try await bootstrap.start(on: try await login(transport), reuse: first.token, savedPort: nil)
        #expect(second.token == first.token, "no new token for a server that was slow")
        #expect(http.paths.suffix(3) == ["/api/ssh/ownership", "/api/health", "/api/ssh/ownership"])
    }

    @Test func aReuseThatHermesNeverAnswersIsNotReady() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let http = FakeHermesHTTP(routes: [:])
        let token = SessionToken.mint()
        await #expect(throws: SSHConnectionError.hermesNotReady) {
            try await ServeBootstrap(loader: http, configuration: fast)
                .start(on: try await login(transport), reuse: token, savedPort: nil)
        }
        #expect(transport.record.closedForwards == 1)
    }

    // MARK: The ping runs at the same time as the serve

    /// Before #181 the `serve` started after the `ping` ended. This session fails a `ping` that runs first.
    @Test func thePingDoesNotDelayTheServe() async throws {
        let session = OverlapSession()
        let served = try await ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
            .start(on: try await login(OverlapTransport(session: session)), reuse: nil, savedPort: 47_100)
        #expect(served.remotePort == 47_100)
        let events = session.events
        let serveStart = try #require(events.firstIndex(of: "serve start"))
        let pingEnd = try #require(events.firstIndex(of: "ping end"))
        #expect(serveStart < pingEnd, "the serve started while the ping ran: \(events)")
        #expect(events.last == "forward 47100", "the forward opens after the ping: \(events)")
    }

    @Test func theTimingLogShowsAShorterConnect() async throws {
        let step = Duration.milliseconds(150)
        let clock = ContinuousClock()

        let oldSession = OverlapSession(waitsForServe: false, execTime: step)
        let oldStart = clock.now
        let gate = try await HostConnector(transport: OverlapTransport(session: oldSession))
            .connect(profile: profile, key: key, timing: ConnectTimeline().begin())
        _ = try await ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
            .start(on: gate.session, reuse: nil, timing: nil)
        let before = clock.now - oldStart

        let newSession = OverlapSession(waitsForServe: false, execTime: step)
        let run = ConnectTimeline().begin()
        let newStart = clock.now
        _ = try await ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
            .start(on: try await login(OverlapTransport(session: newSession), timing: run), reuse: nil,
                   savedPort: nil, timing: run)
        let after = clock.now - newStart

        #expect(before >= step * 2)
        #expect(after < before - step / 2, "before \(before), after \(after)")
        let steps = run.recorded.map(\.step)
        #expect(Set(steps) == [.sshLogin, .ping, .serve, .health, .ownership], "every step stays in the log")
        #expect(run.recorded.allSatisfy { $0.ok })
    }

    // MARK: The gate checks give the same errors

    @Test(arguments: [
        (Result<String, SSHConnectionError>.success("hello"), SSHConnectionError.unexpectedReply),
        (.success("PONG \n"), .unexpectedReply),
        (.failure(.gateError("not-allowed")), .gateError("not-allowed")),
    ])
    func aBadPingGivesTheSameErrorAndOpensNoForward(reply: Result<String, SSHConnectionError>,
                                                    expected: SSHConnectionError) async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample, pingReply: reply)
        let run = ConnectTimeline().begin()
        let gate = try await login(transport, timing: run)
        await #expect(throws: expected) {
            try await ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
                .start(on: gate, reuse: nil, savedPort: nil, timing: run)
        }
        #expect(transport.record.forwardPorts.isEmpty)
        #expect(run.hasEnded)
        #expect(run.recorded.contains { $0.step == .ping && !$0.ok })
    }

    @Test func aBadPingWinsOverAFailedServe() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample, pingReply: .failure(.gateError("not-allowed")))
        transport.serveFailure = .gateError("serve-exited")
        await #expect(throws: SSHConnectionError.gateError("not-allowed")) {
            try await ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
                .start(on: try await login(transport), reuse: nil, savedPort: nil)
        }
    }

    @Test func aFailedServeWithAGoodPingKeepsItsError() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        transport.serveFailure = .gateError("serve-exited")
        await #expect(throws: SSHConnectionError.gateError("serve-exited")) {
            try await ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
                .start(on: try await login(transport), reuse: nil, savedPort: nil)
        }
    }

    /// A version 1 gate gets no port pin. A version 2 or later gate refuses another port and opens no forward.
    @Test func onlyAFixedPortGatePinsTheSavedPort() async throws {
        let old = ScriptedSSHTransport(hostKey: .sample, pingReply: .success("PONG 1\n"))
        let served = try await ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
            .start(on: try await login(old), reuse: nil, savedPort: 47_100)
        #expect(served.remotePort == 41_001)

        let fixed = ScriptedSSHTransport(hostKey: .sample, pingReply: .success("PONG 3\n"))
        await #expect(throws: SSHConnectionError.gateError(ServeBootstrap.portChangedCode)) {
            try await ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
                .start(on: try await login(fixed), reuse: nil, savedPort: 47_100)
        }
        #expect(fixed.record.forwardPorts.isEmpty)
        let same = try await ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
            .start(on: try await login(fixed), reuse: nil, savedPort: 41_002)
        #expect(same.remotePort == 41_002)
    }

    @Test func theOldConnectStillRunsThePingFirst() async throws {
        let session = OverlapSession(waitsForServe: false)
        let gate = try await HostConnector(transport: OverlapTransport(session: session))
            .connect(profile: profile, key: key)
        #expect(gate.gateVersion == "3")
        #expect(session.events == ["ping start", "ping end"])
    }

    // MARK: The socket opens while the ownership check runs

    @Test func theSocketOpensWhileTheOwnershipCheckRuns() async throws {
        let connector = CountingConnector()
        let prewarm = GatewaySocketPrewarm(connector: connector)
        let http = FakeHermesHTTP()
        // The ownership answer waits until the socket opened. Without the prewarm the check never passes.
        http.ownershipStatus = { _ in
            for _ in 0..<1000 where connector.sockets.isEmpty { usleep(2000) }
            return connector.sockets.isEmpty ? 401 : 200
        }
        let served = try await ServeBootstrap(loader: http, configuration: fast, socketPrewarm: prewarm)
            .start(on: try await login(ScriptedSSHTransport(hostKey: .sample)), reuse: nil, savedPort: nil)
        #expect(connector.urls == [served.endpoint.webSocketURL])
        #expect(prewarm.waitingCount == 1)

        let socket = try #require(connector.sockets.first)
        #expect(socket.sent.isEmpty, "no frame before the chat link takes the socket")
        let taken = try await PrewarmedGatewayConnector(prewarm: prewarm, fallback: FakeGatewayConnector())
            .connect(to: served.endpoint.webSocketURL)
        #expect(taken as? FakeGatewaySocket === socket)
        #expect(prewarm.waitingCount == 0)
        #expect(socket.closedCode == nil)
    }

    @Test func aFailedOwnershipCheckClosesTheSocket() async throws {
        let connector = CountingConnector()
        let prewarm = GatewaySocketPrewarm(connector: connector)
        let http = FakeHermesHTTP()
        http.set("/api/ssh/ownership", status: 401)
        await #expect(throws: SSHConnectionError.sessionTokenRejected) {
            try await ServeBootstrap(loader: http, configuration: fast, socketPrewarm: prewarm)
                .start(on: try await login(ScriptedSSHTransport(hostKey: .sample)), reuse: nil, savedPort: nil)
        }
        #expect(prewarm.waitingCount == 0)
        // The socket can open after the discard. Then it closes when it opens.
        try await waitUntil { connector.sockets.count == 1 && connector.sockets[0].closedCode == 1000 }
    }

    /// A stale reuse token: the socket of the old token closes. The socket of the new token waits.
    @Test func aTokenRetryKeepsOnlyTheSocketOfTheNewToken() async throws {
        let connector = CountingConnector()
        let prewarm = GatewaySocketPrewarm(connector: connector)
        let http = FakeHermesHTTP()
        let stale = SessionToken.mint()
        let staleValue = stale.value
        http.ownershipStatus = { $0 == staleValue ? 401 : 200 }
        let served = try await ServeBootstrap(loader: http, configuration: fast, socketPrewarm: prewarm)
            .start(on: try await login(ScriptedSSHTransport(hostKey: .sample)), reuse: stale, savedPort: nil)
        #expect(served.token != stale)
        try await waitUntil { connector.urls.count == 2 }
        let newIndex = try #require(connector.urls.firstIndex(of: served.endpoint.webSocketURL))
        let oldSocket = connector.sockets[1 - newIndex]
        try await waitUntil { oldSocket.closedCode == 1000 }
        #expect(connector.sockets[newIndex].closedCode == nil)
        #expect(prewarm.waitingCount == 1)
    }

    @Test func aSocketThatNobodyTakesCloses() async throws {
        let connector = CountingConnector()
        let prewarm = GatewaySocketPrewarm(connector: connector, lifetime: .milliseconds(20))
        let url = try GatewayEndpoint(port: 50_000, token: String(repeating: "ab", count: 32)).webSocketURL
        prewarm.open(url)
        try await waitUntil { connector.sockets.first?.closedCode == 1000 }
        #expect(prewarm.waitingCount == 0)
        let fallback = FakeGatewayConnector(FakeGatewaySocket())
        _ = try await PrewarmedGatewayConnector(prewarm: prewarm, fallback: fallback).connect(to: url)
        #expect(fallback.urls == [url], "an expired socket is not used")
    }

    @Test func anotherURLGetsANewSocket() async throws {
        let connector = CountingConnector()
        let prewarm = GatewaySocketPrewarm(connector: connector)
        let token = String(repeating: "ab", count: 32)
        prewarm.open(try GatewayEndpoint(port: 50_000, token: token).webSocketURL)
        let other = try GatewayEndpoint(port: 50_001, token: token).webSocketURL
        let fallback = FakeGatewayConnector(FakeGatewaySocket())
        _ = try await PrewarmedGatewayConnector(prewarm: prewarm, fallback: fallback).connect(to: other)
        #expect(fallback.urls == [other])
        #expect(prewarm.waitingCount == 1)
    }

    @Test func withNoPrewarmNoSocketOpens() async throws {
        let http = FakeHermesHTTP()
        _ = try await ServeBootstrap(loader: http, configuration: fast)
            .start(on: try await login(ScriptedSSHTransport(hostKey: .sample)), reuse: nil, savedPort: nil)
        #expect(GatewaySocketPrewarm.shared.waitingCount == 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FakeTimeout(what: "condition")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
