import Foundation
import Testing
@testable import HermesKit

/// A clock that moves 10 ms at each read. The step times of a test are then exact.
private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Duration.zero

    func now() -> Duration {
        lock.withLock {
            defer { time += .milliseconds(10) }
            return time
        }
    }
}

/// Collects the lines of one log category.
private final class LineCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    private var id: UUID?
    let category = "connect-test-\(UUID().uuidString)"

    var lines: [String] { lock.withLock { _lines } }
    /// The last line that starts with "connect done" or "connect failed".
    var summary: String? { lines.last { $0.hasPrefix("connect done") || $0.hasPrefix("connect failed") } }

    init() {
        let category = category
        id = HermesLog.addObserver { [weak self] entry in
            guard entry.category == category, entry.level >= .info else { return }
            self?.lock.withLock { self?._lines.append(entry.message) }
        }
    }

    func stop() { if let id { HermesLog.removeObserver(id) } }
}

private let token = String(repeating: "0f", count: 32)

/// Issue #180: the time of each connect step.
@Suite(.timeLimit(.minutes(1))) struct ConnectTimelineTests {
    private let fast = ServeBootstrap.Configuration(serveTimeout: .seconds(5), healthAttempts: 3,
                                                    healthRetryDelay: .milliseconds(1))
    private let profile = ServerProfile(host: "vps.example.com", hostKey: .sample)

    private func timeline(_ capture: LineCapture) -> ConnectTimeline {
        let clock = StepClock()
        return ConnectTimeline(now: { clock.now() }, log: HermesLog(category: capture.category))
    }

    /// The server steps of a connect: login, ping, serve, health, ownership.
    private func serverSteps(_ transport: ScriptedSSHTransport, http: FakeHermesHTTP = FakeHermesHTTP(),
                             reuse: SessionToken? = nil,
                             timing: ConnectRun) async throws(SSHConnectionError) -> HermesServe {
        let key = SoftwareKeyFactory.wrap(.init())
        let gate = try await HostConnector(transport: transport).connect(profile: profile, key: key, timing: timing)
        return try await ServeBootstrap(loader: http, configuration: fast)
            .start(on: gate.session, reuse: reuse, timing: timing)
    }

    @Test func aConnectLogsOneLineWithTheTimeOfEachStep() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let timeline = timeline(capture)
        let run = timeline.begin()
        _ = try await serverSteps(ScriptedSSHTransport(hostKey: .sample), timing: run)
        #expect(capture.summary == nil, "the connect waits for the socket and the list")
        #expect(timeline.current === run)
        run.start(.socketReady)
        run.finish(.socketReady, ok: true)
        run.start(.firstListRefresh)
        run.finish(.firstListRefresh, ok: true)

        #expect(capture.summary == "connect done in 140 ms: ssh-login 10 ms, ping 10 ms, serve 10 ms, health 10 ms, "
            + "ownership 10 ms, socket-ready 10 ms, first-list-refresh 10 ms")
        #expect(capture.lines.filter { $0.hasPrefix("connect step ") }.count == 7, "one line for each step")
        #expect(capture.lines.first == "connect step ssh-login: 10 ms")
        #expect(timeline.current == nil, "the run ended")
    }

    @Test func theAppStepsCanEndInAnyOrder() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let run = timeline(capture).begin()
        _ = try await serverSteps(ScriptedSSHTransport(hostKey: .sample), timing: run)
        run.start(.socketReady)
        run.start(.firstListRefresh)
        run.finish(.firstListRefresh, ok: true)
        #expect(capture.summary == nil)
        run.finish(.socketReady, ok: true)
        #expect(capture.summary?.hasPrefix("connect done in 140 ms: ") == true)
        #expect(capture.summary?.hasSuffix("first-list-refresh 10 ms, socket-ready 30 ms") == true)
    }

    @Test func aFailedServeLogsTheStepThatFailedAndItsTime() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let transport = ScriptedSSHTransport(hostKey: .sample)
        transport.serveFailure = .gateError("hermes-not-found")
        let timeline = timeline(capture)
        let run = timeline.begin()
        await #expect(throws: SSHConnectionError.gateError("hermes-not-found")) {
            _ = try await serverSteps(transport, timing: run)
        }
        #expect(capture.summary == "connect failed at serve (10 ms), total 70 ms: ssh-login 10 ms, ping 10 ms, "
            + "serve 10 ms failed")
        #expect(capture.lines.contains("connect step serve: failed after 10 ms"))
        #expect(timeline.current == nil)
    }

    @Test func anUnknownHostKeyFailsTheLoginStep() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let run = timeline(capture).begin()
        let unpinned = ServerProfile(host: "vps.example.com")
        await #expect(throws: SSHConnectionError.hostKeyUnknown(.sample)) {
            _ = try await HostConnector(transport: ScriptedSSHTransport(hostKey: .sample))
                .connect(profile: unpinned, key: SoftwareKeyFactory.wrap(.init()), timing: run)
        }
        #expect(capture.summary == "connect failed at ssh-login (10 ms), total 30 ms: ssh-login 10 ms failed")
    }

    @Test func aBadPongFailsThePingStep() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let run = timeline(capture).begin()
        let transport = ScriptedSSHTransport(hostKey: .sample, pingReply: .success("HELLO\n"))
        await #expect(throws: SSHConnectionError.unexpectedReply) {
            _ = try await serverSteps(transport, timing: run)
        }
        #expect(capture.summary == "connect failed at ping (10 ms), total 50 ms: ssh-login 10 ms, ping 10 ms failed")
    }

    @Test func aFailedHealthCheckFailsTheHealthStep() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let run = timeline(capture).begin()
        let http = FakeHermesHTTP(routes: [:])
        await #expect(throws: SSHConnectionError.hermesNotReady) {
            _ = try await serverSteps(ScriptedSSHTransport(hostKey: .sample), http: http, timing: run)
        }
        #expect(capture.summary?.hasPrefix("connect failed at health (10 ms), total 90 ms: ") == true)
    }

    /// A stale reuse token gets a new token. The second try records its steps again, and the connect goes on.
    /// Issue #181: the reuse try has no health step. The new token gets one.
    @Test func aTokenRetryRecordsTheServeStepsAgain() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let run = timeline(capture).begin()
        let http = FakeHermesHTTP()
        let stale = SessionToken.mint()
        let staleValue = stale.value
        http.ownershipStatus = { $0 == staleValue ? 401 : 200 }
        _ = try await serverSteps(ScriptedSSHTransport(hostKey: .sample), http: http, reuse: stale, timing: run)
        #expect(capture.summary == nil, "a retry that works is not a failed connect")
        run.start(.socketReady)
        run.finish(.socketReady, ok: true)
        run.start(.firstListRefresh)
        run.finish(.firstListRefresh, ok: true)
        #expect(capture.summary == "connect done in 180 ms: ssh-login 10 ms, ping 10 ms, serve 10 ms, "
            + "ownership 10 ms failed, serve 10 ms, health 10 ms, ownership 10 ms, socket-ready 10 ms, "
            + "first-list-refresh 10 ms")
    }

    @Test func aFailedSocketLogsTheSocketStep() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let run = timeline(capture).begin()
        _ = try await serverSteps(ScriptedSSHTransport(hostKey: .sample), timing: run)
        run.start(.socketReady)
        run.finish(.socketReady, ok: false)
        #expect(capture.summary?.hasPrefix("connect failed at socket-ready (10 ms), total 120 ms: ") == true)
    }

    @Test func anAppStepRunsOnlyAfterTheServerIsReadyAndOneTime() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let run = timeline(capture).begin()
        run.start(.socketReady)
        run.finish(.socketReady, ok: true)
        #expect(run.recorded.isEmpty, "no app step before ownership")

        _ = try await serverSteps(ScriptedSSHTransport(hostKey: .sample), timing: run)
        run.start(.socketReady)
        run.finish(.socketReady, ok: true)
        run.start(.socketReady)
        run.finish(.socketReady, ok: false)
        #expect(run.recorded.filter { $0.step == .socketReady }.count == 1, "a reconnect is not a new step")
        #expect(capture.summary == nil)
    }

    @Test func aNewConnectDropsTheOldRunWithNoSummary() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let timeline = timeline(capture)
        let old = timeline.begin()
        _ = try await serverSteps(ScriptedSSHTransport(hostKey: .sample), timing: old)
        old.start(.socketReady)
        let new = timeline.begin()
        #expect(timeline.current === new)
        old.finish(.socketReady, ok: true)
        old.fail()
        #expect(capture.summary == nil)
        #expect(!old.recorded.contains { $0.step == .socketReady })
    }

    @Test func noRunMeansNoTiming() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let timeline = timeline(capture)
        #expect(timeline.current == nil)
        let key = SoftwareKeyFactory.wrap(.init())
        _ = try await HostConnector(transport: ScriptedSSHTransport(hostKey: .sample)).connect(profile: profile, key: key)
        #expect(capture.lines.isEmpty)
    }

    @Test func millisecondsRoundDown() {
        #expect(ConnectRun.milliseconds(.microseconds(1999)) == 1)
        #expect(ConnectRun.milliseconds(.seconds(2)) == 2000)
        #expect(ConnectRun.milliseconds(.zero) == 0)
        #expect(ConnectRun.milliseconds(.milliseconds(-5)) == 0)
    }

    /// The lines hold step names and durations only: no host, user, token, key or fingerprint.
    @Test func theLinesHoldNoHostTokenOrKey() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let run = timeline(capture).begin()
        let served = try await serverSteps(ScriptedSSHTransport(hostKey: .sample), timing: run)
        run.start(.socketReady)
        run.finish(.socketReady, ok: false)
        let secrets = ["vps.example.com", "hermes", served.token.value, HostKey.sample.fingerprint,
                       String(served.remotePort), String(served.forward.localPort)]
        #expect(!capture.lines.isEmpty)
        for line in capture.lines {
            for secret in secrets { #expect(!line.contains(secret), "\(line)") }
        }
        let allowed = Set(ConnectStep.allCases.map(\.rawValue))
        for line in capture.lines where line.hasPrefix("connect step ") {
            let name = line.dropFirst("connect step ".count).prefix { $0 != ":" }
            #expect(allowed.contains(String(name)))
        }
    }
}

// MARK: - App steps in the chat link and the session list

/// Builds clients on scripted sockets. No network.
private final class SocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [FakeGatewaySocket] = []
    var sockets: [FakeGatewaySocket] { lock.withLock { _sockets } }

    func make(_ endpoint: GatewayEndpoint) -> GatewayClient {
        let socket = FakeGatewaySocket()
        lock.withLock { _sockets.append(socket) }
        return GatewayClient(endpoint: endpoint, connector: FakeGatewayConnector(socket),
                             configuration: .init(heartbeatInterval: nil, readyTimeout: .seconds(5)))
    }

    func socket(_ index: Int) async throws -> FakeGatewaySocket {
        for _ in 0..<500 {
            if sockets.count > index { return sockets[index] }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FakeTimeout(what: "socket \(index)")
    }
}

@MainActor
private func waitFor(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw FakeTimeout(what: "condition")
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ConnectTimelineAppStepTests {
    private let fast = ServeBootstrap.Configuration(serveTimeout: .seconds(5), healthAttempts: 3,
                                                    healthRetryDelay: .milliseconds(1))

    private func readyRun(_ timeline: ConnectTimeline) async throws -> ConnectRun {
        let run = timeline.begin()
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let gate = try await HostConnector(transport: transport)
            .connect(profile: ServerProfile(host: "vps.example.com", hostKey: .sample),
                     key: SoftwareKeyFactory.wrap(.init()), timing: run)
        _ = try await ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
            .start(on: gate.session, reuse: nil, timing: run)
        return run
    }

    @Test func theChatLinkAndTheListEndTheConnect() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let clock = StepClock()
        let timeline = ConnectTimeline(now: { clock.now() }, log: HermesLog(category: capture.category))
        let run = try await readyRun(timeline)

        let factory = SocketFactory()
        let link = LiveChatTransport(makeClient: factory.make, timeline: timeline)
        link.setEndpoint(try GatewayEndpoint(port: 8123, token: token))
        let socket = try await factory.socket(0)
        socket.pushReady()
        socket.reply(to: try await socket.waitForRequest("client.capabilities"), result: "{}")
        try await waitFor { link.status == .ready }
        #expect(run.recorded.last?.step == .socketReady)
        #expect(run.recorded.last?.ok == true)

        let list = SessionListModel(transport: FakeSessionsTransport(), chatTransport: FakeChatTransport(),
                                    cache: InMemorySessionCacheStore(), timeline: timeline)
        list.receive(.state(.connected(GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef"))))
        try await waitFor { capture.summary != nil }
        #expect(capture.summary?.hasPrefix("connect done in ") == true)
        #expect(capture.summary?.hasSuffix(", socket-ready 10 ms, first-list-refresh 10 ms") == true)
        #expect(timeline.current == nil)
    }

    @Test func aFailedListLoadFailsTheConnect() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let clock = StepClock()
        let timeline = ConnectTimeline(now: { clock.now() }, log: HermesLog(category: capture.category))
        let run = try await readyRun(timeline)
        run.start(.socketReady)
        run.finish(.socketReady, ok: true)

        let sessions = FakeSessionsTransport()
        sessions.fail = true
        let list = SessionListModel(transport: sessions, chatTransport: FakeChatTransport(),
                                    cache: InMemorySessionCacheStore(), timeline: timeline)
        list.receive(.state(.connected(GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef"))))
        try await waitFor { capture.summary != nil }
        #expect(capture.summary?.hasPrefix("connect failed at first-list-refresh (10 ms), ") == true)
    }

    @Test func aListLoadWithNoConnectRecordsNothing() async throws {
        let capture = LineCapture()
        defer { capture.stop() }
        let timeline = ConnectTimeline(log: HermesLog(category: capture.category))
        let sessions = FakeSessionsTransport()
        let list = SessionListModel(transport: sessions, chatTransport: FakeChatTransport(),
                                    cache: InMemorySessionCacheStore(), timeline: timeline)
        list.receive(.state(.connected(GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef"))))
        try await waitFor { sessions.fetches == 1 }
        await list.refresh()
        #expect(capture.lines.isEmpty)
    }
}
