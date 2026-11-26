import Foundation
import Network
import Observation

/// Issue #178: a sign that the link to the server can be dead while the app is open.
public enum LinkTrigger: Sendable, Equatable {
    /// The chat socket closed after it was ready (`LiveChatTransport.onDrop`).
    case linkDropped
    /// The SSH connection closed (`SSHSession.onClose`, the Citadel `onDisconnect` hook).
    case sessionClosed
    /// The network path of the device changed (`NetworkPathMonitoring`).
    case pathChanged
}

/// Issue #178: what the supervisor did for one trigger.
public enum LinkCheckOutcome: Sendable, Equatable {
    /// The app is in the background, or the connection is not in a state to recover (for example the trust sheet).
    case skipped
    /// The link answered the probe. It stays open.
    case kept
    /// The supervisor started a reconnect. `succeeded` is `false` when the connect failed ("Offline").
    case reconnected(succeeded: Bool)
}

/// Issue #178: the network path, reduced to the values that can break the SSH link.
public struct LinkPath: Sendable, Equatable {
    public var isSatisfied: Bool
    /// The interface types in use, for example `["wifi"]` or `["cellular"]`.
    public var interfaces: [String]
    /// The gateways of the path. A move to another Wi-Fi network changes them.
    public var gateways: [String]

    public init(isSatisfied: Bool, interfaces: [String] = [], gateways: [String] = []) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
        self.gateways = gateways
    }
}

/// Issue #178: tells a real path change from the first report and from repeats.
public struct LinkPathFilter: Sendable {
    private var last: LinkPath?

    public init() {}

    /// Returns `true` when `path` differs from the last path. The first path is not a change.
    public mutating func isChange(_ path: LinkPath) -> Bool {
        defer { last = path }
        guard let last else { return false }
        return last != path
    }
}

/// Issue #178: reports changes of the network path. `SystemPathMonitor` is the real one. Tests use a fake.
@MainActor
public protocol NetworkPathMonitoring: AnyObject {
    /// Start to report. `onChange` runs on the main actor for each real change, not for the first path.
    /// Issue #179: it gets the new path, so a retry runs at once when the network comes back.
    func start(_ onChange: @escaping @MainActor (LinkPath) -> Void)
    func stop()
}

/// Issue #178: `NWPathMonitor` on its own queue. It reports only real changes (`LinkPathFilter`).
@MainActor
public final class SystemPathMonitor: NetworkPathMonitoring {
    private var monitor: NWPathMonitor?

    public init() {}

    public func start(_ onChange: @escaping @MainActor (LinkPath) -> Void) {
        stop()
        let monitor = NWPathMonitor()
        let filter = FilterBox()
        monitor.pathUpdateHandler = { path in
            let linkPath = Self.linkPath(path)
            guard filter.isChange(linkPath) else { return }
            Task { @MainActor in onChange(linkPath) }
        }
        monitor.start(queue: DispatchQueue(label: "HermesKit.SystemPathMonitor"))
        self.monitor = monitor
    }

    public func stop() {
        monitor?.cancel()
        monitor = nil
    }

    nonisolated static func linkPath(_ path: NWPath) -> LinkPath {
        let types: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"), (.other, "other"),
        ]
        return LinkPath(isSatisfied: path.status == .satisfied,
                        interfaces: types.filter { path.usesInterfaceType($0.0) }.map(\.1),
                        gateways: path.gateways.map { "\($0)" })
    }

    /// The filter of the monitor queue. Only that queue uses it.
    private final class FilterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var filter = LinkPathFilter()
        func isChange(_ path: LinkPath) -> Bool { lock.withLock { filter.isChange(path) } }
    }
}

/// Issue #179: the wait before the next connect try. 2 s after the first failure, then double, to a limit of 30 s.
public struct ConnectBackoff: Sendable, Equatable {
    public static let first: Duration = .seconds(2)
    public static let limit: Duration = .seconds(30)

    /// The failed tries since the last reset.
    public private(set) var failures = 0

    public init() {}

    /// The wait after `failures` failed tries (1 or more): 2, 4, 8, 16, 30, 30… seconds.
    public static func delay(afterFailures failures: Int) -> Duration {
        guard failures > 1 else { return first }
        // 2 s doubled 4 times is 32 s, over the limit. Stop the doubling there, so the value cannot overflow.
        let doublings = min(failures - 1, 4)
        return min(first * (1 << doublings), limit)
    }

    /// Count one failed try. Returns the wait before the next try.
    public mutating func recordFailure() -> Duration {
        failures += 1
        return Self.delay(afterFailures: failures)
    }

    public mutating func reset() { failures = 0 }

    /// The whole seconds that the subtitle shows ("Retry in 4 s"). Never less than 1 while the wait runs.
    public static func secondsLeft(until deadline: ContinuousClock.Instant, now: ContinuousClock.Instant) -> Int {
        let left = deadline - now
        guard left > .zero else { return 1 }
        let parts = left.components
        let whole = Int(parts.seconds) + (parts.attoseconds > 0 ? 1 : 0)
        return max(1, whole)
    }
}

/// Issue #179: the time source of the retry wait. `SystemRetryClock` is the real one. Tests move a fake clock.
@MainActor
public protocol RetryClock: AnyObject, Sendable {
    var now: ContinuousClock.Instant { get }
    /// Wait until `deadline`. Throws `CancellationError` when the task is cancelled.
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

@MainActor
public final class SystemRetryClock: RetryClock {
    public init() {}

    public var now: ContinuousClock.Instant { .now }

    public func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await Task.sleep(until: deadline, clock: .continuous)
    }
}

/// Issue #178: finds a dead link while the app is open and starts one reconnect.
///
/// - A chat socket drop or an SSH close reconnects at once. The link is down, so a probe has no use.
/// - A network path change tests the link with the #176 probe. A link that answers stays open.
/// - Triggers that come during a check join that check. A drop during a probe that passed runs one more check.
/// - Nothing happens in the background, or when the connection is not ready to recover (`Hooks.canRecover`).
///
/// Issue #179: a failed connect tries again after a wait (`ConnectBackoff`: 2 s, then double, to 30 s).
/// - The app reports each failed try: a connect with a network error (`connectFailed()`), or a chat socket
///   that did not open after a good connect (`chatSocketFailed()`). The state is then "Offline" with a countdown.
/// - A link that drops again less than `stableAfter` after a try of the supervisor counts as a failed try too.
///   So a link that drops again and again backs off. It does not reconnect in a tight loop.
/// - The wait resets when the link stays ready for `stableAfter`, on a tap (`retryNow()`), and in the background.
/// - A network path that comes back during the wait tries at once.
/// - A refused key, a changed host key and the trust sheet are never reported, so they never retry.
@MainActor @Observable
public final class LinkSupervisor {
    public struct Hooks {
        /// `true` while the app has a connected server and nothing waits for the owner
        /// (no trust sheet, no changed host key, no connect in progress).
        public var canRecover: @MainActor () -> Bool
        /// `true` while the chat link is ready, so a probe can test it.
        public var linkIsReady: @MainActor () -> Bool
        /// The #176 probe: one heartbeat call with a time limit.
        public var probe: @MainActor () async -> Bool
        /// Close the link, then connect again. Returns `true` when the connect succeeded.
        public var reconnect: @MainActor () async -> Bool
        /// Issue #179: `true` while the state is "Offline" after a network failure, and nothing waits for the owner.
        public var canRetry: @MainActor () -> Bool
        /// Issue #179: one connect try. A failure comes back through `connectFailed()` or `chatSocketFailed()`.
        public var retry: @MainActor () async -> Void
        /// Issue #179: close a link that failed after a good connect, and show "Offline". It reports nothing.
        public var abandon: @MainActor () async -> Void

        public init(canRecover: @escaping @MainActor () -> Bool,
                    linkIsReady: @escaping @MainActor () -> Bool,
                    probe: @escaping @MainActor () async -> Bool,
                    reconnect: @escaping @MainActor () async -> Bool,
                    canRetry: @escaping @MainActor () -> Bool = { false },
                    retry: @escaping @MainActor () async -> Void = {},
                    abandon: @escaping @MainActor () async -> Void = {}) {
            self.canRecover = canRecover
            self.linkIsReady = linkIsReady
            self.probe = probe
            self.reconnect = reconnect
            self.canRetry = canRetry
            self.retry = retry
            self.abandon = abandon
        }
    }

    /// Issue #179: a link must stay ready this long after a try. A drop before that is a failed try.
    public static let stableAfter: Duration = .seconds(30)

    /// `true` from the start of a reconnect until it ends. The subtitle shows "Reconnecting…" for it.
    public private(set) var isReconnecting = false
    /// The outcome of the last check (for tests and for #179).
    public private(set) var lastOutcome: LinkCheckOutcome?
    /// Issue #179: when the next try starts. Nil when no try waits. The subtitle shows "Offline · Retry in N s".
    public private(set) var retryAt: ContinuousClock.Instant?

    @ObservationIgnored private let hooks: Hooks
    @ObservationIgnored private let monitor: (any NetworkPathMonitoring)?
    @ObservationIgnored private let clock: any RetryClock
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var running: Task<LinkCheckOutcome, Never>?
    /// A trigger came during the running check. The strongest one wins (a drop beats a path change).
    @ObservationIgnored private var queued: LinkTrigger?
    /// Issue #179: the failed tries since the last reset.
    @ObservationIgnored public private(set) var backoff = ConnectBackoff()
    /// Issue #179: the task that waits for `retryAt`. Nil while no try waits.
    @ObservationIgnored private var waitTask: Task<Void, Never>?
    /// Issue #179: counts schedules. A wait or a try of an older schedule does nothing.
    @ObservationIgnored private var generation = 0
    /// Issue #179: the end of the last reconnect or retry of the supervisor.
    @ObservationIgnored private var lastTryEnd: ContinuousClock.Instant?
    /// Issue #179: when the chat link was last ready. Nil after a failure or a drop.
    @ObservationIgnored private var readyAt: ContinuousClock.Instant?

    /// `foreground`: `false` when the app can launch in the background. The app then calls `setForeground`.
    public init(hooks: Hooks, monitor: (any NetworkPathMonitoring)? = nil, foreground: Bool = true,
                clock: any RetryClock = SystemRetryClock()) {
        self.hooks = hooks
        self.monitor = monitor
        self.clock = clock
        isForeground = foreground
    }

    /// Start to watch the network path.
    public func start() {
        monitor?.start { [weak self] path in self?.networkChanged(path) }
    }

    public func stop() {
        monitor?.stop()
        running?.cancel()
        running = nil
        queued = nil
        cancelWait()
    }

    /// The app calls this when the scene goes to the background (`false`) or is active again (`true`).
    /// The #176 foreground check handles the return. The supervisor only acts while the app is open.
    /// Issue #179: the background stops the retries and resets the wait. A try that runs is not stopped.
    public func setForeground(_ foreground: Bool) {
        isForeground = foreground
        guard !foreground else { return }
        queued = nil
        cancelWait()
        backoff.reset()
    }

    /// Report one trigger. It does nothing in the background or when the connection cannot recover.
    public func report(_ trigger: LinkTrigger) {
        guard isForeground, hooks.canRecover() else { return }
        if running != nil {
            queued = Self.stronger(queued, trigger)
            return
        }
        // Issue #179: a try waits already (a drop that came soon after a try). This trigger joins it.
        guard retryAt == nil else { return }
        if trigger != .pathChanged {
            let flapped = droppedSoonAfterATry()
            readyAt = nil
            if flapped {
                // The link came back from a try and died again. Count a failed try and wait.
                fail(abandon: true)
                return
            }
            // The link was stable, or no try ran: reconnect at once, as #178 does.
            backoff.reset()
        }
        running = Task { [weak self] in
            guard let self else { return .skipped }
            return await self.drain(trigger)
        }
    }

    /// Run one check for `trigger` and wait for it. Tests use it. The app uses `report(_:)`.
    @discardableResult
    public func check(_ trigger: LinkTrigger) async -> LinkCheckOutcome {
        report(trigger)
        guard let running else { return .skipped }
        return await running.value
    }

    // MARK: Retry with backoff (issue #179)

    /// The app connect failed with a network error or a time limit ("Offline"). Try again after the wait.
    /// The app does not call it for a refused key, a changed host key or the trust sheet.
    public func connectFailed() {
        guard isForeground else { return }
        fail(abandon: false)
    }

    /// SSH and serve connected, but the chat socket did not open. That is a failed try, not "Reconnecting…".
    /// Close the link ("Offline"), then try again after the wait.
    public func chatSocketFailed() {
        guard isForeground, hooks.canRecover() else { return }
        fail(abandon: true)
    }

    /// The chat link is ready. If it stays ready for `stableAfter`, the next failure starts at 2 s again.
    public func linkReady() {
        readyAt = clock.now
    }

    /// The owner tapped "Offline". Reset the wait and try at once.
    public func retryNow() {
        cancelWait()
        backoff.reset()
        readyAt = nil
        let mine = generation
        Task { [weak self] in await self?.runTry(mine, checks: false) }
    }

    /// Issue #179: a satisfied path during the wait tries at once. Else it is a #178 path change.
    public func networkChanged(_ path: LinkPath) {
        guard retryAt != nil else {
            report(.pathChanged)
            return
        }
        guard path.isSatisfied, isForeground else { return }
        cancelWait()
        let mine = generation
        Task { [weak self] in await self?.runTry(mine, checks: true) }
    }

    /// `true` when the link dropped less than `stableAfter` after the last try of the supervisor,
    /// and did not stay ready for `stableAfter`.
    private func droppedSoonAfterATry() -> Bool {
        let now = clock.now
        if let readyAt, now - readyAt >= Self.stableAfter { return false }
        guard let lastTryEnd else { return false }
        return now - lastTryEnd < Self.stableAfter
    }

    /// Count one failed try, show "Offline" if `abandon`, and start the wait for the next try.
    private func fail(abandon: Bool) {
        if let readyAt, clock.now - readyAt >= Self.stableAfter { backoff.reset() }
        readyAt = nil
        let wait = backoff.recordFailure()
        cancelWait()
        let mine = generation
        let deadline = clock.now + wait
        retryAt = deadline
        if abandon { Task { await hooks.abandon() } }
        waitTask = Task { [weak self, clock] in
            do { try await clock.sleep(until: deadline) } catch { return }
            await self?.waitEnded(mine)
        }
    }

    private func waitEnded(_ mine: Int) async {
        guard mine == generation else { return }
        waitTask = nil
        retryAt = nil
        await runTry(mine, checks: true)
    }

    /// One try. `checks`: an automatic try runs only in the foreground and in a state that can retry.
    private func runTry(_ mine: Int, checks: Bool) async {
        guard mine == generation else { return }
        if checks {
            guard isForeground, hooks.canRetry() else {
                // The owner, a switch or Settings changed the state during the wait. The chain of tries ends.
                backoff.reset()
                return
            }
        }
        await hooks.retry()
        lastTryEnd = clock.now
    }

    /// Stop the wait. A wait or a try of an older schedule then does nothing.
    private func cancelWait() {
        generation += 1
        waitTask?.cancel()
        waitTask = nil
        retryAt = nil
    }

    // MARK: Check (issue #178)

    /// What one check does: test the link first only after a path change on a ready link.
    public enum Step: Sendable, Equatable {
        case probe
        case reconnect
    }

    public static func step(for trigger: LinkTrigger, linkIsReady: Bool) -> Step {
        switch trigger {
        case .linkDropped, .sessionClosed: .reconnect
        case .pathChanged: linkIsReady ? .probe : .reconnect
        }
    }

    private func drain(_ first: LinkTrigger) async -> LinkCheckOutcome {
        var trigger = first
        var outcome = LinkCheckOutcome.skipped
        while true {
            outcome = await runOnce(trigger)
            lastOutcome = outcome
            // A reconnect makes a new link, so the triggers of the old link do not count.
            guard outcome == .kept, let next = queued else { break }
            queued = nil
            trigger = next
        }
        queued = nil
        running = nil
        return outcome
    }

    private func runOnce(_ trigger: LinkTrigger) async -> LinkCheckOutcome {
        guard !Task.isCancelled, isForeground, hooks.canRecover() else { return .skipped }
        if Self.step(for: trigger, linkIsReady: hooks.linkIsReady()) == .probe {
            if await hooks.probe() { return .kept }
            // The owner, a switch or the foreground check can act during the probe. They win.
            guard !Task.isCancelled, isForeground, hooks.canRecover() else { return .skipped }
        }
        isReconnecting = true
        defer {
            isReconnecting = false
            lastTryEnd = clock.now
        }
        return .reconnected(succeeded: await hooks.reconnect())
    }

    private static func stronger(_ a: LinkTrigger?, _ b: LinkTrigger) -> LinkTrigger {
        guard let a else { return b }
        return a == .pathChanged ? b : a
    }
}
