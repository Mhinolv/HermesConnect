import Foundation
import Testing
@testable import HermesKit

private let token = String(repeating: "0f", count: 32)

/// A path monitor with no `NWPathMonitor`. The test calls `change()`.
@MainActor
private final class FakePathMonitor: NetworkPathMonitoring {
    private var onChange: (@MainActor (LinkPath) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0

    func start(_ onChange: @escaping @MainActor (LinkPath) -> Void) {
        starts += 1
        self.onChange = onChange
    }

    func stop() {
        stops += 1
        onChange = nil
    }

    func change(_ path: LinkPath = LinkPath(isSatisfied: true, interfaces: ["cellular"])) { onChange?(path) }
}

/// Issue #179: a clock that moves only when the test moves it. A sleep ends when `advance` passes its deadline.
@MainActor
private final class FakeRetryClock: RetryClock {
    private(set) var now = ContinuousClock.now
    private var sleepers: [(id: Int, deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextID = 0
    var sleeperCount: Int { sleepers.count }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        guard deadline > now else { return }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { sleepers.append((id, deadline, $0)) }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func advance(by duration: Duration) {
        now = now + duration
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        due.forEach { $0.continuation.resume() }
    }

    private func cancel(_ id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// The app side of the supervisor: a connection state, a probe and a reconnect, all scripted.
@MainActor
private final class FakeApp {
    var canRecover = true
    var linkIsReady = true
    var probeAnswer = true
    var reconnectSucceeds = true
    /// Issue #179: the state is "Offline" after a network failure.
    var canRetry = true
    /// Issue #179: runs in each retry, for example to report one more failure.
    var onRetry: (@MainActor () -> Void)?
    private(set) var retries = 0
    private(set) var abandons = 0
    /// A reconnect waits until the test opens this gate (nil: no wait).
    var reconnectGate: CheckedContinuation<Void, Never>?
    var holdsReconnect = false
    private(set) var probes = 0
    private(set) var reconnects = 0
    private(set) var reconnectTimes: [ContinuousClock.Instant] = []

    var hooks: LinkSupervisor.Hooks {
        LinkSupervisor.Hooks(
            canRecover: { [unowned self] in canRecover },
            linkIsReady: { [unowned self] in linkIsReady },
            probe: { [unowned self] in
                probes += 1
                return probeAnswer
            },
            reconnect: { [unowned self] in
                reconnects += 1
                reconnectTimes.append(.now)
                if holdsReconnect { await withCheckedContinuation { reconnectGate = $0 } }
                return reconnectSucceeds
            },
            canRetry: { [unowned self] in canRetry },
            retry: { [unowned self] in
                retries += 1
                onRetry?()
            },
            abandon: { [unowned self] in abandons += 1 })
    }

    func openReconnect() {
        reconnectGate?.resume()
        reconnectGate = nil
    }
}

/// Builds clients on scripted sockets. No network.
private final class ClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [FakeGatewaySocket] = []
    var sockets: [FakeGatewaySocket] { lock.withLock { _sockets } }

    func make(_ endpoint: GatewayEndpoint) -> GatewayClient {
        let socket = FakeGatewaySocket()
        lock.withLock { _sockets.append(socket) }
        return GatewayClient(endpoint: endpoint, connector: FakeGatewayConnector(socket),
                             configuration: .init(heartbeatInterval: nil, readyTimeout: .seconds(5)))
    }

    func handshake(_ index: Int) async throws -> FakeGatewaySocket {
        for _ in 0..<500 where sockets.count <= index { try await Task.sleep(for: .milliseconds(2)) }
        guard sockets.count > index else { throw FakeTimeout(what: "socket \(index)") }
        let socket = sockets[index]
        socket.pushReady()
        socket.reply(to: try await socket.waitForRequest("client.capabilities"), result: "{}")
        return socket
    }
}

@MainActor
private func waitFor(_ limit: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
    let end = ContinuousClock.now + limit
    while ContinuousClock.now < end {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw FakeTimeout(what: "condition")
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LinkSupervisorTests {
    /// Regression for #178: a socket drop in the foreground left the link `.notConnected`, and nothing reconnected.
    /// Now the transport reports the drop, and the supervisor starts a reconnect in 5 s or less.
    @Test func socketDropInTheForegroundReconnectsInFiveSeconds() async throws {
        let factory = ClientFactory()
        let transport = LiveChatTransport(makeClient: factory.make)
        let app = FakeApp()
        let supervisor = LinkSupervisor(hooks: app.hooks)
        transport.onDrop = { supervisor.report(.linkDropped) }
        transport.setEndpoint(try GatewayEndpoint(port: 8123, token: token))
        let socket = try await factory.handshake(0)
        try await waitFor { transport.status == .ready }

        let dropped = ContinuousClock.now
        socket.serverClose(closeCode: 1006)
        try await waitFor { transport.status == .notConnected }
        try await waitFor { app.reconnects == 1 }
        #expect(try #require(app.reconnectTimes.first) - dropped <= .seconds(5))
        // A drop is a dead link: no probe first.
        #expect(app.probes == 0)
    }

    /// A stale token renews the session (#6). It is not a drop for the supervisor.
    @Test func staleTokenIsNotADrop() async throws {
        let factory = ClientFactory()
        let transport = LiveChatTransport(makeClient: factory.make)
        var drops = 0
        transport.onDrop = { drops += 1 }
        transport.onStaleToken = {}
        transport.setEndpoint(try GatewayEndpoint(port: 8123, token: token))
        let socket = try await factory.handshake(0)
        try await waitFor { transport.status == .ready }
        socket.serverClose(closeCode: 4401)
        try await waitFor { transport.status == .reconnecting }
        #expect(drops == 0)
    }

    /// The app closes the link (a reconnect, a switch). That is not a drop.
    @Test func closeOfTheAppSideIsNotADrop() async throws {
        let factory = ClientFactory()
        let transport = LiveChatTransport(makeClient: factory.make)
        var drops = 0
        transport.onDrop = { drops += 1 }
        transport.setEndpoint(try GatewayEndpoint(port: 8123, token: token))
        _ = try await factory.handshake(0)
        try await waitFor { transport.status == .ready }
        transport.setEndpoint(nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.status == .notConnected)
        #expect(drops == 0)
    }

    @Test func networkPathChangeProbesAtOnce() async throws {
        let app = FakeApp()
        let monitor = FakePathMonitor()
        let supervisor = LinkSupervisor(hooks: app.hooks, monitor: monitor)
        supervisor.start()
        #expect(monitor.starts == 1)
        monitor.change()
        try await waitFor(.seconds(1)) { app.probes == 1 }
        #expect(app.reconnects == 0)
        #expect(supervisor.lastOutcome == .kept)
        supervisor.stop()
        #expect(monitor.stops == 1)
    }

    @Test func linkThatAnswersTheProbeStaysOpen() async {
        let app = FakeApp()
        let supervisor = LinkSupervisor(hooks: app.hooks)
        #expect(await supervisor.check(.pathChanged) == .kept)
        #expect(app.probes == 1)
        #expect(app.reconnects == 0)
        #expect(!supervisor.isReconnecting)
    }

    @Test func probeThatFailsReconnects() async {
        let app = FakeApp()
        app.probeAnswer = false
        let supervisor = LinkSupervisor(hooks: app.hooks)
        #expect(await supervisor.check(.pathChanged) == .reconnected(succeeded: true))
        #expect(app.probes == 1)
        #expect(app.reconnects == 1)
    }

    /// A path change on a link that is not ready reconnects with no probe.
    @Test func pathChangeOnADownLinkReconnects() async {
        let app = FakeApp()
        app.linkIsReady = false
        let supervisor = LinkSupervisor(hooks: app.hooks)
        #expect(await supervisor.check(.pathChanged) == .reconnected(succeeded: true))
        #expect(app.probes == 0)
    }

    @Test func sshCloseReconnectsWithNoProbe() async {
        let app = FakeApp()
        let supervisor = LinkSupervisor(hooks: app.hooks)
        #expect(await supervisor.check(.sessionClosed) == .reconnected(succeeded: true))
        #expect(app.probes == 0)
        #expect(app.reconnects == 1)
    }

    /// The trust sheet, a changed host key, a connect in progress: `canRecover` is false. Nothing reconnects.
    @Test func statesThatWaitForTheOwnerDoNotReconnect() async {
        let app = FakeApp()
        app.canRecover = false
        let supervisor = LinkSupervisor(hooks: app.hooks)
        for trigger in [LinkTrigger.linkDropped, .sessionClosed, .pathChanged] {
            #expect(await supervisor.check(trigger) == .skipped)
        }
        #expect(app.probes == 0)
        #expect(app.reconnects == 0)
    }

    /// The owner tapped "Cancel" or a switch started during the probe. The supervisor does not reconnect.
    @Test func stateChangeDuringTheProbeWins() async {
        let app = FakeApp()
        app.probeAnswer = false
        let supervisor = LinkSupervisor(hooks: LinkSupervisor.Hooks(
            canRecover: { app.canRecover }, linkIsReady: { true },
            probe: { app.canRecover = false; return false },
            reconnect: { Issue.record("no reconnect"); return true }))
        #expect(await supervisor.check(.pathChanged) == .skipped)
    }

    @Test func backgroundDoesNothing() async {
        let app = FakeApp()
        let supervisor = LinkSupervisor(hooks: app.hooks)
        supervisor.setForeground(false)
        #expect(await supervisor.check(.linkDropped) == .skipped)
        supervisor.setForeground(true)
        #expect(await supervisor.check(.linkDropped) == .reconnected(succeeded: true))
        #expect(app.reconnects == 1)
    }

    /// One drop gives a socket close, an SSH close and a path change. They make one reconnect.
    @Test func triggersDuringAReconnectJoinIt() async throws {
        let app = FakeApp()
        app.holdsReconnect = true
        let supervisor = LinkSupervisor(hooks: app.hooks)
        supervisor.report(.linkDropped)
        try await waitFor(.seconds(1)) { app.reconnects == 1 && supervisor.isReconnecting }
        supervisor.report(.sessionClosed)
        supervisor.report(.pathChanged)
        app.openReconnect()
        try await waitFor(.seconds(1)) { !supervisor.isReconnecting }
        try await Task.sleep(for: .milliseconds(30))
        #expect(app.reconnects == 1)
        #expect(supervisor.lastOutcome == .reconnected(succeeded: true))
    }

    /// A drop during a probe that passed is still a dead link. One more check runs.
    @Test func dropDuringAPassedProbeReconnects() async throws {
        let app = FakeApp()
        var gate: CheckedContinuation<Void, Never>?
        let supervisor = LinkSupervisor(hooks: LinkSupervisor.Hooks(
            canRecover: { true }, linkIsReady: { app.linkIsReady },
            probe: { await withCheckedContinuation { gate = $0 }; return true },
            reconnect: { app.reconnectSucceeds }))
        supervisor.report(.pathChanged)
        try await waitFor(.seconds(1)) { gate != nil }
        app.linkIsReady = false
        supervisor.report(.linkDropped)
        gate?.resume()
        try await waitFor(.seconds(1)) { supervisor.lastOutcome == .reconnected(succeeded: true) }
    }

    /// A failed reconnect ends the check. #179 adds the retry.
    @Test func failedReconnectIsReportedForTheRetryIssue() async {
        let app = FakeApp()
        app.reconnectSucceeds = false
        let supervisor = LinkSupervisor(hooks: app.hooks)
        #expect(await supervisor.check(.linkDropped) == .reconnected(succeeded: false))
        #expect(!supervisor.isReconnecting)
    }

    @Test func pathFilterIgnoresTheFirstPathAndRepeats() {
        var filter = LinkPathFilter()
        let wifi = LinkPath(isSatisfied: true, interfaces: ["wifi"], gateways: ["192.168.1.1:0"])
        let paths = [wifi, wifi, LinkPath(isSatisfied: true, interfaces: ["cellular"]), LinkPath(isSatisfied: false),
                     LinkPath(isSatisfied: true, interfaces: ["wifi"], gateways: ["10.0.0.1:0"])]
        let changes = paths.map { filter.isChange($0) }
        #expect(changes == [false, false, true, true, true])
    }

    @Test func stepTable() {
        #expect(LinkSupervisor.step(for: .linkDropped, linkIsReady: true) == .reconnect)
        #expect(LinkSupervisor.step(for: .sessionClosed, linkIsReady: true) == .reconnect)
        #expect(LinkSupervisor.step(for: .pathChanged, linkIsReady: true) == .probe)
        #expect(LinkSupervisor.step(for: .pathChanged, linkIsReady: false) == .reconnect)
    }
}

/// A socket connector that refuses every connect (TCP "connection refused").
private struct RefusingConnector: GatewayWebSocketConnecting {
    func connect(to url: URL) async throws -> any GatewayWebSocket {
        throw GatewayWebSocketClosed(urlErrorCode: -1004)
    }
}

/// Issue #179: retry a failed connect with backoff. A fake clock, a fake app and fake sockets. No network.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LinkRetryTests {
    private func make(_ app: FakeApp, monitor: FakePathMonitor? = nil) -> (LinkSupervisor, FakeRetryClock) {
        let clock = FakeRetryClock()
        return (LinkSupervisor(hooks: app.hooks, monitor: monitor, clock: clock), clock)
    }

    /// The wait that `retryAt` shows now.
    private func wait(_ supervisor: LinkSupervisor, _ clock: FakeRetryClock) -> Duration? {
        supervisor.retryAt.map { $0 - clock.now }
    }

    @Test func backoffDoublesToALimitOfThirtySeconds() {
        var backoff = ConnectBackoff()
        let waits = (0..<7).map { _ in backoff.recordFailure() }
        #expect(waits == [2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
        #expect(ConnectBackoff.delay(afterFailures: 0) == .seconds(2))
        #expect(ConnectBackoff.delay(afterFailures: 1_000_000) == .seconds(30))
        backoff.reset()
        #expect(backoff.recordFailure() == .seconds(2))
    }

    @Test func countdownShowsWholeSecondsRoundedUp() {
        let now = ContinuousClock.now
        #expect(ConnectBackoff.secondsLeft(until: now + .seconds(4), now: now) == 4)
        #expect(ConnectBackoff.secondsLeft(until: now + .milliseconds(3_001), now: now) == 4)
        #expect(ConnectBackoff.secondsLeft(until: now + .milliseconds(2_999), now: now) == 3)
        #expect(ConnectBackoff.secondsLeft(until: now + .milliseconds(10), now: now) == 1)
        // The try starts at the deadline. The text never says "0 s".
        #expect(ConnectBackoff.secondsLeft(until: now, now: now) == 1)
        #expect(ConnectBackoff.secondsLeft(until: now - .seconds(1), now: now) == 1)
    }

    /// Criterion 1: after a network failure, the app tries again in 2 s with no tap.
    @Test func networkFailureTriesAgainInTwoSeconds() async throws {
        let app = FakeApp()
        let (supervisor, clock) = make(app)
        supervisor.connectFailed()
        #expect(wait(supervisor, clock) == .seconds(2))
        try await waitFor(.seconds(1)) { clock.sleeperCount == 1 }
        clock.advance(by: .milliseconds(1_999))
        try await Task.sleep(for: .milliseconds(20))
        #expect(app.retries == 0)
        clock.advance(by: .milliseconds(1))
        try await waitFor(.seconds(1)) { app.retries == 1 }
        #expect(supervisor.retryAt == nil)
        // A connect failure is already "Offline". The supervisor does not close anything.
        #expect(app.abandons == 0)
    }

    /// Criterion 2: the wait doubles after each failure, to a limit of 30 s.
    @Test func waitDoublesAfterEachFailedTry() async throws {
        let app = FakeApp()
        let (supervisor, clock) = make(app)
        app.onRetry = { supervisor.connectFailed() }
        supervisor.connectFailed()
        var waits: [Duration] = []
        for tries in 1...6 {
            let next = try #require(wait(supervisor, clock))
            waits.append(next)
            try await waitFor(.seconds(1)) { clock.sleeperCount == 1 }
            clock.advance(by: next)
            try await waitFor(.seconds(1)) { app.retries == tries }
        }
        #expect(waits == [2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
        #expect(supervisor.backoff.failures == 7)
    }

    /// Criterion 4: the retries stop when the app goes to the background.
    @Test func retriesStopInTheBackground() async throws {
        let app = FakeApp()
        let (supervisor, clock) = make(app)
        supervisor.connectFailed()
        try await waitFor(.seconds(1)) { clock.sleeperCount == 1 }
        supervisor.setForeground(false)
        #expect(supervisor.retryAt == nil)
        try await waitFor(.seconds(1)) { clock.sleeperCount == 0 }
        clock.advance(by: .seconds(60))
        // A failure in the background does not start a wait either.
        supervisor.connectFailed()
        supervisor.chatSocketFailed()
        try await Task.sleep(for: .milliseconds(20))
        #expect(supervisor.retryAt == nil)
        #expect(app.retries == 0)
        // Back in the foreground the wait starts at 2 s again.
        supervisor.setForeground(true)
        supervisor.connectFailed()
        #expect(wait(supervisor, clock) == .seconds(2))
    }

    /// Criterion 5: a tap on "Offline" retries at once and resets the wait.
    @Test func tapRetriesAtOnceAndResetsTheWait() async throws {
        let app = FakeApp()
        let (supervisor, clock) = make(app)
        for _ in 0..<3 { supervisor.connectFailed() }
        #expect(wait(supervisor, clock) == .seconds(8))
        app.onRetry = { supervisor.connectFailed() }
        supervisor.retryNow()
        try await waitFor(.seconds(1)) { app.retries == 1 }
        #expect(wait(supervisor, clock) == .seconds(2))
    }

    /// A tap tries also when no wait runs ("Offline ↻" after a cancelled trust sheet).
    @Test func tapWithNoWaitTries() async throws {
        let app = FakeApp()
        app.canRetry = false
        let (supervisor, _) = make(app)
        supervisor.retryNow()
        try await waitFor(.seconds(1)) { app.retries == 1 }
        #expect(supervisor.retryAt == nil)
    }

    /// Scope: retry at once when the network comes back. A path that is not satisfied waits.
    @Test func networkThatComesBackTriesAtOnce() async throws {
        let app = FakeApp()
        let monitor = FakePathMonitor()
        let (supervisor, clock) = make(app, monitor: monitor)
        supervisor.start()
        supervisor.connectFailed()
        supervisor.connectFailed()
        monitor.change(LinkPath(isSatisfied: false))
        try await Task.sleep(for: .milliseconds(20))
        #expect(app.retries == 0)
        #expect(wait(supervisor, clock) == .seconds(4))
        monitor.change(LinkPath(isSatisfied: true, interfaces: ["wifi"]))
        try await waitFor(.seconds(1)) { app.retries == 1 }
        #expect(supervisor.retryAt == nil)
        // Not a #178 path check: the link is down, so no probe and no reconnect.
        #expect(app.probes == 0)
        #expect(app.reconnects == 0)
        // The wait does not reset: a failure of that try waits 8 s.
        supervisor.connectFailed()
        #expect(wait(supervisor, clock) == .seconds(8))
    }

    /// The owner, a switch or Settings changed the state during the wait. No try runs, and the chain ends.
    @Test func stateThatCannotRetryEndsTheChain() async throws {
        let app = FakeApp()
        let (supervisor, clock) = make(app)
        supervisor.connectFailed()
        supervisor.connectFailed()
        app.canRetry = false
        try await waitFor(.seconds(1)) { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(4))
        try await waitFor(.seconds(1)) { supervisor.retryAt == nil }
        try await Task.sleep(for: .milliseconds(20))
        #expect(app.retries == 0)
        #expect(supervisor.backoff.failures == 0)
    }

    /// QA #211 risk 1: a link that drops again and again backs off. It does not reconnect in a tight loop.
    @Test func linkThatDropsAgainAndAgainBacksOff() async throws {
        let app = FakeApp()
        let (supervisor, clock) = make(app)
        // The first drop of a link reconnects at once (#178).
        #expect(await supervisor.check(.linkDropped) == .reconnected(succeeded: true))
        #expect(app.reconnects == 1)
        var waits: [Duration] = []
        for tries in 1...5 {
            // The new link is ready, then drops again soon.
            supervisor.linkReady()
            clock.advance(by: .seconds(1))
            supervisor.report(.linkDropped)
            supervisor.report(.sessionClosed)
            let next = try #require(wait(supervisor, clock))
            waits.append(next)
            #expect(app.reconnects == 1)
            try await waitFor(.seconds(1)) { app.abandons == tries && clock.sleeperCount == 1 }
            clock.advance(by: next)
            try await waitFor(.seconds(1)) { app.retries == tries }
        }
        #expect(waits == [2, 4, 8, 16, 30].map { Duration.seconds($0) })
        #expect(app.reconnects == 1)
    }

    /// A link that stays ready for `stableAfter` resets the wait. Its next drop reconnects at once.
    @Test func stableLinkResetsTheWait() async throws {
        let app = FakeApp()
        let (supervisor, clock) = make(app)
        app.onRetry = { supervisor.connectFailed() }
        supervisor.connectFailed()
        supervisor.connectFailed()
        try await waitFor(.seconds(1)) { clock.sleeperCount == 1 }
        app.onRetry = nil
        clock.advance(by: .seconds(4))
        try await waitFor(.seconds(1)) { app.retries == 1 }
        #expect(supervisor.backoff.failures == 2)
        supervisor.linkReady()
        clock.advance(by: LinkSupervisor.stableAfter)
        #expect(await supervisor.check(.linkDropped) == .reconnected(succeeded: true))
        #expect(supervisor.backoff.failures == 0)
        // A failure of that reconnect waits 2 s.
        supervisor.connectFailed()
        #expect(wait(supervisor, clock) == .seconds(2))
    }

    /// A ready link that fails later (a path probe, then a reconnect that fails) starts at 2 s, also after old failures.
    @Test func failureAfterAStableLinkStartsAtTwoSeconds() async throws {
        let app = FakeApp()
        let (supervisor, clock) = make(app)
        for _ in 0..<4 { supervisor.connectFailed() }
        supervisor.retryNow()
        try await waitFor(.seconds(1)) { app.retries == 1 }
        supervisor.linkReady()
        clock.advance(by: .seconds(120))
        supervisor.connectFailed()
        #expect(wait(supervisor, clock) == .seconds(2))
    }

    /// QA #211 risk 2: SSH connected, but the chat socket did not open. That is a failed try: the supervisor
    /// closes the link ("Offline", not "Reconnecting…") and retries after the wait.
    @Test func chatSocketThatDoesNotOpenIsAFailedTry() async throws {
        let app = FakeApp()
        let (supervisor, clock) = make(app)
        let transport = LiveChatTransport(makeClient: {
            GatewayClient(endpoint: $0, connector: RefusingConnector(),
                          configuration: .init(heartbeatInterval: nil, readyTimeout: .seconds(1)))
        })
        var readies = 0
        transport.onReady = { readies += 1 }
        transport.onConnectFailed = { supervisor.chatSocketFailed() }
        transport.setEndpoint(try GatewayEndpoint(port: 8123, token: token))
        try await waitFor { app.abandons == 1 }
        #expect(transport.status == .notConnected)
        #expect(wait(supervisor, clock) == .seconds(2))
        #expect(readies == 0)
        try await waitFor(.seconds(1)) { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(2))
        try await waitFor(.seconds(1)) { app.retries == 1 }
        #expect(app.reconnects == 0)
    }

    /// A socket that opens reports `onReady`, not a failure.
    @Test func socketThatOpensReportsReady() async throws {
        let factory = ClientFactory()
        let transport = LiveChatTransport(makeClient: factory.make)
        var readies = 0
        var failures = 0
        transport.onReady = { readies += 1 }
        transport.onConnectFailed = { failures += 1 }
        transport.setEndpoint(try GatewayEndpoint(port: 8123, token: token))
        _ = try await factory.handshake(0)
        try await waitFor { transport.status == .ready }
        #expect(readies == 1)
        #expect(failures == 0)
    }

    /// A chat socket failure while the connection cannot recover (trust sheet, a switch) starts no wait.
    @Test func chatSocketFailureThatCannotRecoverDoesNothing() {
        let app = FakeApp()
        app.canRecover = false
        let (supervisor, _) = make(app)
        supervisor.chatSocketFailed()
        #expect(supervisor.retryAt == nil)
        #expect(supervisor.backoff.failures == 0)
    }

    /// `stop()` ends the wait.
    @Test func stopEndsTheWait() async throws {
        let app = FakeApp()
        let (supervisor, clock) = make(app)
        supervisor.connectFailed()
        supervisor.stop()
        #expect(supervisor.retryAt == nil)
        clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(20))
        #expect(app.retries == 0)
    }
}
