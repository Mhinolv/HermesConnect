import Foundation
import Testing
@testable import HermesKit

private let token = String(repeating: "0f", count: 32)

/// A path monitor with no `NWPathMonitor`. The test calls `change()`.
@MainActor
private final class FakePathMonitor: NetworkPathMonitoring {
    private var onChange: (@MainActor () -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0

    func start(_ onChange: @escaping @MainActor () -> Void) {
        starts += 1
        self.onChange = onChange
    }

    func stop() {
        stops += 1
        onChange = nil
    }

    func change() { onChange?() }
}

/// The app side of the supervisor: a connection state, a probe and a reconnect, all scripted.
@MainActor
private final class FakeApp {
    var canRecover = true
    var linkIsReady = true
    var probeAnswer = true
    var reconnectSucceeds = true
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
            })
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
