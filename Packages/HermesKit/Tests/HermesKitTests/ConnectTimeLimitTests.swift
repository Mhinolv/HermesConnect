import Foundation
import Testing
@testable import HermesKit

/// Issue #182: a `LimitSleep` that ends when the test moves the time.
final class FakeLimitSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Duration = .zero
    private var nextID = 0
    private var sleepers: [(id: Int, deadline: Duration, continuation: CheckedContinuation<Void, any Error>)] = []
    /// Waits that the task cancelled before they were stored.
    private var cancelled: Set<Int> = []

    var count: Int { lock.withLock { sleepers.count } }

    var sleep: LimitSleep {
        { [self] duration in try await self.wait(duration) }
    }

    private func wait(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let stored: Bool = lock.withLock {
                    if cancelled.contains(id) { return false }
                    sleepers.append((id, now + duration, continuation))
                    return true
                }
                if !stored { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let gone = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
                    cancelled.insert(id)
                    return nil
                }
                return sleepers.remove(at: index).continuation
            }
            gone?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            now += duration
            let due = sleepers.filter { $0.deadline <= now }
            sleepers.removeAll { $0.deadline <= now }
            return due.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }
}

/// Issue #182: a retry clock that ends each wait at its deadline when the test moves the time.
@MainActor
final class LimitTestClock: RetryClock {
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

private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not met")
}

/// The result of a task that the test reads when it ends.
private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? { lock.withLock { _value } }
    func set(_ value: T) { lock.withLock { _value = value } }
}

/// Issue #182: each connect step has a time limit. Fakes only: no network, no real waits for the limits.
@Suite(.timeLimit(.minutes(1))) struct ConnectTimeLimitTests {
    private let profile = ServerProfile(host: "vps.example.com", hostKey: .sample)

    /// Regression for #182, criterion 2: a `ping` with no reply waited with no limit.
    @Test func aPingWithNoReplyFailsAtItsTimeLimit() async throws {
        let transport = StallingSSHTransport(stalls: [.ping])
        let sleep = FakeLimitSleep()
        let connector = HostConnector(transport: transport, pingTimeout: .seconds(15), sleep: sleep.sleep)
        let result = Box<Result<String, SSHConnectionError>>()
        let profile = profile
        _ = Task {
            do throws(SSHConnectionError) {
                let connection = try await connector.connect(profile: profile, key: SoftwareKeyFactory.wrap(.init()))
                result.set(.success(connection.gateVersion))
            } catch {
                result.set(.failure(error))
            }
        }
        try await waitUntil { transport.stalled == 1 && sleep.count == 1 }
        sleep.advance(by: .seconds(14))
        try await Task.sleep(for: .milliseconds(20))
        #expect(result.value == nil)
        sleep.advance(by: .seconds(1))
        try await waitUntil { result.value != nil }
        #expect(result.value == .failure(.unreachable))
        // The connection closes, so the stalled channel ends too.
        #expect(transport.inner.record.closedSessions == 1)
        transport.release()
    }

    /// Issue #182 with #181: the `ping` runs at the same time as the `serve`. A `ping` that fails at its limit
    /// ends a `serve` with no reply at once. Before, it waited for the 150 s `serve` limit.
    @Test func aFailedPingEndsAStalledServeAtOnce() async throws {
        let transport = StallingSSHTransport(stalls: [.ping, .serve])
        let sleep = FakeLimitSleep()
        let connector = HostConnector(transport: transport, pingTimeout: .seconds(15), sleep: sleep.sleep)
        let bootstrap = ServeBootstrap(loader: ScriptedHermesHTTP(),
                                       configuration: .init(serveTimeout: .seconds(600)))
        let login = try await connector.login(profile: profile, key: SoftwareKeyFactory.wrap(.init()))
        let result = Box<SSHConnectionError>()
        _ = Task {
            do throws(SSHConnectionError) {
                _ = try await bootstrap.start(on: login, reuse: nil, savedPort: nil)
            } catch {
                result.set(error)
            }
        }
        try await waitUntil { transport.stalled == 2 && sleep.count == 1 }
        sleep.advance(by: .seconds(15))
        try await waitUntil { result.value != nil }
        #expect(result.value == .unreachable)
        await login.session.close()
        transport.release()
    }

    @Test func aServeThatAnswersIsNotEndedByAGoodPing() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let connector = HostConnector(transport: transport, pingTimeout: .seconds(15), sleep: FakeLimitSleep().sleep)
        let bootstrap = ServeBootstrap(loader: ScriptedHermesHTTP(),
                                       configuration: .init(serveTimeout: .seconds(600), healthAttempts: 1,
                                                            healthRetryDelay: .milliseconds(1)))
        let login = try await connector.login(profile: profile, key: SoftwareKeyFactory.wrap(.init()))
        let running = try await bootstrap.start(on: login, reuse: nil, savedPort: nil)
        #expect(running.remotePort == 41_001)
        #expect(try await login.gateVersion() == "1")
    }

    @Test func aPingThatAnswersConnectsAndStopsItsTimer() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let sleep = FakeLimitSleep()
        let connector = HostConnector(transport: transport, pingTimeout: .seconds(15), sleep: sleep.sleep)
        let connection = try await connector.connect(profile: profile, key: SoftwareKeyFactory.wrap(.init()))
        #expect(connection.gateVersion == "1")
        try await waitUntil { sleep.count == 0 }
        #expect(transport.record.closedSessions == 0)
    }

    @Test func theDefaultPingLimitIsFifteenSeconds() {
        #expect(HostConnector(transport: ScriptedSSHTransport(hostKey: .sample)).pingTimeout == .seconds(15))
        #expect(ConnectTimeLimit.ping == .seconds(15))
        // The gate waits up to 120 s for a first start. The total limit leaves 60 s for the other steps.
        #expect(ConnectTimeLimit.total == .seconds(180))
        #expect(ConnectTimeLimit.restartAfter == .seconds(10))
    }

    /// The old deadline waited for the step to end after the cancel. A stalled channel blocked it.
    @Test func aDeadlineDoesNotWaitForAStepThatIgnoresTheCancel() async throws {
        let gate = StallGate()
        let sleep = FakeLimitSleep()
        let result = Box<String>()
        _ = Task {
            do {
                _ = try await withDeadline(.seconds(5), sleep: sleep.sleep) {
                    await gate.wait()
                    return "late"
                }
                result.set("value")
            } catch is DeadlineExceeded {
                result.set("deadline")
            } catch {
                result.set("other")
            }
        }
        try await waitUntil { gate.waiting == 1 && sleep.count == 1 }
        sleep.advance(by: .seconds(5))
        try await waitUntil { result.value != nil }
        #expect(result.value == "deadline")
        #expect(gate.waiting == 1)
        gate.open()
    }

    @Test func aDeadlineGivesTheValueOrTheErrorOfTheStep() async throws {
        let sleep = FakeLimitSleep()
        let value = try await withDeadline(.seconds(5), sleep: sleep.sleep) { 42 }
        #expect(value == 42)
        await #expect(throws: SSHConnectionError.gateError("x")) {
            try await withDeadline(.seconds(5), sleep: sleep.sleep) { () async throws -> Int in
                throw SSHConnectionError.gateError("x")
            }
        }
        try await waitUntil { sleep.count == 0 }
    }

    @Test func aCancelledDeadlineThrowsAtOnce() async throws {
        let gate = StallGate()
        let sleep = FakeLimitSleep()
        let result = Box<String>()
        let task = Task {
            do {
                _ = try await withDeadline(.seconds(5), sleep: sleep.sleep) { await gate.wait() }
                result.set("value")
            } catch is CancellationError {
                result.set("cancelled")
            } catch {
                result.set("other")
            }
        }
        try await waitUntil { gate.waiting == 1 }
        task.cancel()
        try await waitUntil { result.value != nil }
        #expect(result.value == "cancelled")
        gate.open()
    }

    // MARK: ConnectWatch

    @MainActor @Test func aWatchEndsWhenTheConnectEnds() async throws {
        let clock = LimitTestClock()
        let watch = ConnectWatch()
        let outcome = Box<ConnectWaitOutcome>()
        let task = Task { @MainActor in outcome.set(await watch.wait(limit: .seconds(180), clock: clock)) }
        try await waitUntil { clock.sleeperCount == 1 }
        watch.finish()
        await task.value
        #expect(outcome.value == .finished)
        try await waitUntil { clock.sleeperCount == 0 }
    }

    @MainActor @Test func aWatchExpiresAtTheLimitAndNotBefore() async throws {
        let clock = LimitTestClock()
        let watch = ConnectWatch()
        let outcome = Box<ConnectWaitOutcome>()
        let task = Task { @MainActor in outcome.set(await watch.wait(limit: .seconds(180), clock: clock)) }
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(179))
        try await Task.sleep(for: .milliseconds(20))
        #expect(outcome.value == nil)
        clock.advance(by: .seconds(1))
        await task.value
        #expect(outcome.value == .expired)
        // A late end changes nothing. A second wait gives the first outcome.
        watch.finish()
        #expect(await watch.wait(limit: .seconds(1), clock: clock) == .expired)
    }

    @MainActor @Test func aWatchThatFinishedFirstReturnsAtOnce() async {
        let clock = LimitTestClock()
        let watch = ConnectWatch()
        watch.finish()
        #expect(await watch.wait(limit: .seconds(180), clock: clock) == .finished)
        #expect(clock.sleeperCount == 0)
    }
}
