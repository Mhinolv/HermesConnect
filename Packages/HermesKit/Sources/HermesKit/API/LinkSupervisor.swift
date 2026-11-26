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
    func start(_ onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// Issue #178: `NWPathMonitor` on its own queue. It reports only real changes (`LinkPathFilter`).
@MainActor
public final class SystemPathMonitor: NetworkPathMonitoring {
    private var monitor: NWPathMonitor?

    public init() {}

    public func start(_ onChange: @escaping @MainActor () -> Void) {
        stop()
        let monitor = NWPathMonitor()
        let filter = FilterBox()
        monitor.pathUpdateHandler = { path in
            guard filter.isChange(Self.linkPath(path)) else { return }
            Task { @MainActor in onChange() }
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

/// Issue #178: finds a dead link while the app is open and starts one reconnect.
///
/// - A chat socket drop or an SSH close reconnects at once. The link is down, so a probe has no use.
/// - A network path change tests the link with the #176 probe. A link that answers stays open.
/// - Triggers that come during a check join that check. A drop during a probe that passed runs one more check.
/// - Nothing happens in the background, or when the connection is not ready to recover (`Hooks.canRecover`).
///
/// Seam for #179 (backoff retry) and #182 (connect time limits): `Hooks.reconnect` returns the result, and
/// `check(_:)` returns the outcome. A retry policy can act on `.reconnected(succeeded: false)`.
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

        public init(canRecover: @escaping @MainActor () -> Bool,
                    linkIsReady: @escaping @MainActor () -> Bool,
                    probe: @escaping @MainActor () async -> Bool,
                    reconnect: @escaping @MainActor () async -> Bool) {
            self.canRecover = canRecover
            self.linkIsReady = linkIsReady
            self.probe = probe
            self.reconnect = reconnect
        }
    }

    /// `true` from the start of a reconnect until it ends. The subtitle shows "Reconnecting…" for it.
    public private(set) var isReconnecting = false
    /// The outcome of the last check (for tests and for #179).
    public private(set) var lastOutcome: LinkCheckOutcome?

    @ObservationIgnored private let hooks: Hooks
    @ObservationIgnored private let monitor: (any NetworkPathMonitoring)?
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var running: Task<LinkCheckOutcome, Never>?
    /// A trigger came during the running check. The strongest one wins (a drop beats a path change).
    @ObservationIgnored private var queued: LinkTrigger?

    /// `foreground`: `false` when the app can launch in the background. The app then calls `setForeground`.
    public init(hooks: Hooks, monitor: (any NetworkPathMonitoring)? = nil, foreground: Bool = true) {
        self.hooks = hooks
        self.monitor = monitor
        isForeground = foreground
    }

    /// Start to watch the network path.
    public func start() {
        monitor?.start { [weak self] in self?.report(.pathChanged) }
    }

    public func stop() {
        monitor?.stop()
        running?.cancel()
        running = nil
        queued = nil
    }

    /// The app calls this when the scene goes to the background (`false`) or is active again (`true`).
    /// The #176 foreground check handles the return. The supervisor only acts while the app is open.
    public func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if !foreground { queued = nil }
    }

    /// Report one trigger. It does nothing in the background or when the connection cannot recover.
    public func report(_ trigger: LinkTrigger) {
        guard isForeground, hooks.canRecover() else { return }
        if running != nil {
            queued = Self.stronger(queued, trigger)
            return
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
        defer { isReconnecting = false }
        return .reconnected(succeeded: await hooks.reconnect())
    }

    private static func stronger(_ a: LinkTrigger?, _ b: LinkTrigger) -> LinkTrigger {
        guard let a else { return b }
        return a == .pathChanged ? b : a
    }
}
