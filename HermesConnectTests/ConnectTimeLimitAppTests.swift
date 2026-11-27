import Foundation
import HermesKit
import Testing
@testable import HermesConnect

/// Issue #182: a retry clock that ends each wait at its deadline when the test moves the time.
@MainActor
final class AppLimitClock: RetryClock {
    private(set) var now = ContinuousClock.now
    private var nextID = 0
    private var sleepers: [(id: Int, deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, any Error>)] = []
    var sleeperCount: Int { sleepers.count }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        guard deadline > now else { return }
        nextID += 1
        let id = nextID
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

/// Issue #182: a stalled connect ends in a known time, and a new try can start. Fakes only: no network,
/// no SSH, and a fake clock for the limits.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ConnectTimeLimitAppTests {
    @MainActor private final class Setup {
        let model: AppModel
        let transport: StallingSSHTransport
        let clock: AppLimitClock
        var failures = 0
        var connectEnded = false

        init(model: AppModel, transport: StallingSSHTransport, clock: AppLimitClock) {
            self.model = model
            self.transport = transport
            self.clock = clock
        }
    }

    private func makeModel(stalls: Set<GateCommand>, times: Int = .max) async -> Setup {
        let keyStore = KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: SoftwareKeyFactory())
        let store = InMemoryServerListStore(profile: ServerProfile(host: "vps.example.com", hostKey: .sample))
        let transport = StallingSSHTransport(stalls: stalls, times: times)
        // The real `serve` limit (a real wait) never ends during a test. The fake clock gives the total limit.
        let serve = ServeBootstrap(loader: ScriptedHermesHTTP(),
                                   configuration: .init(serveTimeout: .seconds(600), healthAttempts: 1,
                                                        healthRetryDelay: .milliseconds(1)))
        let clock = AppLimitClock()
        let model = AppModel(keyStore: keyStore, serverStore: store,
                             defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                             deviceName: "Test iPhone", transport: transport, serve: serve, clock: clock)
        await model.ensureKey()
        let setup = Setup(model: model, transport: transport, clock: clock)
        model.onConnectFailed = { [weak setup] in setup?.failures += 1 }
        return setup
    }

    /// Start a connect that the test does not wait for. `connectEnded` turns true when `connect()` returns.
    private func startConnect(_ setup: Setup) -> Task<Void, Never> {
        Task { @MainActor in
            await setup.model.connect()
            setup.connectEnded = true
        }
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition not met")
    }

    /// Regression for #182: a stalled `serve` kept "Starting Hermes…" with no end, and `connect()` never returned.
    /// Now the total limit ends it with "Offline", and a new try connects.
    @Test func stalledConnectEndsOfflineAtTheTimeLimit() async throws {
        let setup = await makeModel(stalls: [.serve], times: 1)
        defer { setup.transport.release() }
        _ = startConnect(setup)
        try await waitFor { setup.transport.stalled == 1 && setup.model.connection == .startingHermes }
        try await waitFor { setup.clock.sleeperCount == 1 }
        setup.clock.advance(by: .seconds(179))
        try await Task.sleep(for: .milliseconds(20))
        #expect(setup.model.connection == .startingHermes)
        #expect(!setup.connectEnded)
        setup.clock.advance(by: .seconds(1))
        try await waitFor { setup.model.connection == .offline(.unreachable) && setup.connectEnded }
        #expect(setup.failures == 1)
        #expect(setup.model.hermesEndpoint == nil)
        #expect(setup.model.canRetryConnect)
        // The stalled link is closed. A new try starts and connects.
        #expect(setup.transport.inner.record.closedSessions == 1)
        await setup.model.connect()
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(setup.transport.inner.record.connectAttempts == 2)
    }

    /// Issue #182, criterion 2: a `ping` with no reply ends at the 15 s step limit, before the total limit.
    @Test func stalledPingEndsOfflineAtItsTimeLimit() async throws {
        let setup = await makeModel(stalls: [.ping], times: 1)
        defer { setup.transport.release() }
        _ = startConnect(setup)
        // Two waits: the total limit and the `ping` limit.
        try await waitFor { setup.transport.stalled == 1 && setup.clock.sleeperCount == 2 }
        setup.clock.advance(by: .seconds(14))
        try await Task.sleep(for: .milliseconds(20))
        // Issue #181: the `serve` runs while the `ping` waits, so the state is "Starting Hermes".
        #expect(setup.model.connection == .startingHermes)
        setup.clock.advance(by: .seconds(1))
        try await waitFor { setup.model.connection == .offline(.unreachable) && setup.connectEnded }
        #expect(setup.failures == 1)
        #expect(setup.transport.inner.record.closedSessions == 1)
    }

    /// Issue #182, criterion 4: a first start of Hermes that takes 120 s still connects.
    @Test func slowFirstStartStillSucceeds() async throws {
        let setup = await makeModel(stalls: [.serve], times: 1)
        _ = startConnect(setup)
        try await waitFor { setup.transport.stalled == 1 && setup.clock.sleeperCount == 1 }
        setup.clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(20))
        #expect(setup.model.connection == .startingHermes)
        setup.transport.release()
        try await waitFor { setup.model.connection == .connected(gateVersion: "1") && setup.connectEnded }
        // The total limit stopped. A later time does not end the link.
        try await waitFor { setup.clock.sleeperCount == 0 }
        setup.clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(20))
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(setup.failures == 0)
    }

    /// Issue #182, criterion 3: back in the foreground, a connect older than 10 s is cancelled and started again.
    /// The old connect never shows "Offline" or "Connected".
    @Test func foregroundReturnRestartsAnOldConnect() async throws {
        let setup = await makeModel(stalls: [.serve], times: 2)
        defer { setup.transport.release() }
        _ = startConnect(setup)
        try await waitFor { setup.transport.stalled == 1 && setup.model.connection == .startingHermes }
        setup.clock.advance(by: .seconds(11))
        let restart = Task { @MainActor in
            await setup.model.reconnectOnForeground(link: nil, away: 60)
        }
        // The old connect ends at once. The new connect waits on its own `serve`.
        try await waitFor {
            setup.transport.inner.record.connectAttempts == 2 && setup.transport.stalled == 1
                && setup.model.connection == .startingHermes && setup.connectEnded
        }
        #expect(setup.transport.inner.record.closedSessions == 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(setup.model.connection == .startingHermes)
        #expect(setup.failures == 0)
        setup.transport.release()
        await restart.value
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(setup.failures == 0)
        #expect(setup.transport.inner.record.closedSessions == 1)
    }

    /// A connect younger than 10 s continues on a return to the foreground.
    @Test func foregroundReturnKeepsAYoungConnect() async throws {
        let setup = await makeModel(stalls: [.serve], times: 1)
        defer { setup.transport.release() }
        _ = startConnect(setup)
        try await waitFor { setup.transport.stalled == 1 && setup.model.connection == .startingHermes }
        setup.clock.advance(by: .seconds(9))
        await setup.model.reconnectOnForeground(link: nil, away: 60)
        #expect(setup.transport.inner.record.connectAttempts == 1)
        #expect(setup.model.connection == .startingHermes)
        setup.transport.release()
        try await waitFor { setup.model.connection == .connected(gateVersion: "1") && setup.connectEnded }
    }

    @Test func onlyAConnectOlderThanTenSecondsRestarts() {
        let action = AppModel.foregroundAction
        #expect(action(.connecting, nil, 60, nil) == .none)
        #expect(action(.connecting, nil, 60, .milliseconds(9_999)) == .none)
        #expect(action(.connecting, nil, 60, .seconds(10)) == .restart)
        #expect(action(.startingHermes, nil, 60, .seconds(60)) == .restart)
        #expect(action(.notStarted(.authenticationFailed), nil, 60, .seconds(60)) == .none)
        #expect(action(.hostKeyChanged(saved: .sample, received: .otherSample), nil, 60, .seconds(60)) == .none)
        #expect(action(.offline(.unreachable), nil, 60, nil) == .connect)
    }

    /// Issue #182 with #179: a timed-out connect is a failed try. "Offline · Retry in 2 s ↻", then a retry.
    @Test func aTimedOutConnectRetriesWithBackoff() async throws {
        let setup = await makeModel(stalls: [.serve], times: 1)
        defer { setup.transport.release() }
        let supervisor = ChatLaunch.makeSupervisor(model: setup.model, link: LiveChatTransport(),
                                                   monitor: FakeAppPathMonitor(), clock: setup.clock)
        supervisor.setForeground(true)
        _ = startConnect(setup)
        try await waitFor { setup.transport.stalled == 1 && setup.clock.sleeperCount == 1 }
        setup.clock.advance(by: .seconds(180))
        try await waitFor { setup.model.connection == .offline(.unreachable) && supervisor.retryAt != nil }
        #expect(supervisor.retryAt.map { $0 - setup.clock.now } == .seconds(2))
        try await waitFor { setup.clock.sleeperCount == 1 }
        setup.clock.advance(by: .seconds(2))
        try await waitFor { setup.model.connection == .connected(gateVersion: "1") }
        #expect(setup.transport.inner.record.connectAttempts == 2)
        supervisor.stop()
    }
}
