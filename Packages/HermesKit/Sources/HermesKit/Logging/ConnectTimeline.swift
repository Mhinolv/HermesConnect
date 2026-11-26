import Foundation
import os

/// Issue #180: one step of a connect, in the order of the connect.
public enum ConnectStep: String, Sendable, CaseIterable {
    /// The TCP connect, the key exchange, the host key check and the authentication.
    case sshLogin = "ssh-login"
    /// The gate `ping`.
    case ping
    /// The gate `serve` and the open of the loopback forward.
    case serve
    /// `GET /api/health` (fallback `GET /api/status`) until Hermes answers.
    case health
    /// `GET /api/ssh/ownership` with the session token.
    case ownership
    /// The gateway WebSocket of the chat link, until it is ready.
    case socketReady = "socket-ready"
    /// The first `session.list` after the socket connected.
    case firstListRefresh = "first-list-refresh"

    /// The app steps run after the server steps. Each app step runs one time for each connect.
    var isAppStep: Bool { self == .socketReady || self == .firstListRefresh }

    var signpostName: StaticString {
        switch self {
        case .sshLogin: "ssh-login"
        case .ping: "ping"
        case .serve: "serve"
        case .health: "health"
        case .ownership: "ownership"
        case .socketReady: "socket-ready"
        case .firstListRefresh: "first-list-refresh"
        }
    }
}

/// Issue #180: records how long each step of a connect takes.
///
/// - Each step gets one `OSSignposter` interval (subsystem `HermesConnect`, category `connect`) and one info log line.
/// - The end of a connect logs one line with the time of each step in milliseconds.
///   A failed connect logs the step that failed and its time.
/// - The log lines hold step names and durations only. They never hold a host, a key, a token or message text.
///
/// `AppModel.connect()` calls `begin()`. The server steps get the run as a parameter. The chat link and the
/// session list read `current` for the app steps.
public final class ConnectTimeline: @unchecked Sendable {
    /// The timeline of the app.
    public static let shared = ConnectTimeline()

    private let lock = NSLock()
    private let now: @Sendable () -> Duration
    private let log: HermesLog
    private let signposter: OSSignposter
    private var latest: ConnectRun?

    /// - Parameters:
    ///   - now: A monotonic clock. Tests give a fake clock.
    ///   - log: The log of the step lines and the summary line.
    public init(now: @escaping @Sendable () -> Duration = { ConnectTimeline.uptime() },
                log: HermesLog = HermesLog(category: "connect")) {
        self.now = now
        self.log = log
        signposter = OSSignposter(subsystem: HermesLog.subsystem, category: log.category)
    }

    /// Start the timing of a new connect. A run of an older connect that did not end stops with no summary line.
    @discardableResult
    public func begin() -> ConnectRun {
        let run = ConnectRun(now: now, log: log, signposter: signposter)
        let old = lock.withLock { () -> ConnectRun? in
            defer { latest = run }
            return latest
        }
        old?.abandon()
        return run
    }

    /// The run of the last connect while it did not end, or nil.
    public var current: ConnectRun? {
        let run = lock.withLock { latest }
        return run?.hasEnded == false ? run : nil
    }

    private static let origin = ContinuousClock.now

    /// The time since the first use of this clock. It does not stop when the device sleeps.
    public static func uptime() -> Duration { ContinuousClock.now - origin }
}

/// Issue #180: the step times of one connect. It is safe to use from any thread.
public final class ConnectRun: @unchecked Sendable {
    struct Entry: Equatable {
        var step: ConnectStep
        var duration: Duration
        var ok: Bool
    }

    private struct Open {
        var start: Duration
        var signpost: OSSignpostIntervalState
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Duration
    private let log: HermesLog
    private let signposter: OSSignposter
    private let started: Duration
    private let signpost: OSSignpostIntervalState
    private var entries: [Entry] = []
    private var open: [ConnectStep: Open] = [:]
    private var startedAppSteps: Set<ConnectStep> = []
    private var ended = false

    init(now: @escaping @Sendable () -> Duration, log: HermesLog, signposter: OSSignposter) {
        self.now = now
        self.log = log
        self.signposter = signposter
        started = now()
        signpost = signposter.beginInterval("connect", id: signposter.makeSignpostID())
    }

    var hasEnded: Bool { lock.withLock { ended } }

    /// The recorded steps, in the order that they ended. For tests.
    var recorded: [Entry] { lock.withLock { entries } }

    /// Run `operation` as `step`. A thrown error records the step as failed, then the error goes on.
    public func measure<T>(_ step: ConnectStep, _ operation: () async throws -> T) async rethrows -> T {
        start(step)
        do {
            let value = try await operation()
            finish(step, ok: true)
            return value
        } catch {
            finish(step, ok: false)
            throw error
        }
    }

    /// Start `step`. Nothing happens when the run ended or the step runs already.
    /// An app step starts only after the server steps ended well, and only one time for each run.
    public func start(_ step: ConnectStep) {
        let time = now()
        let accepted = lock.withLock { () -> Bool in
            guard !ended, open[step] == nil else { return false }
            if step.isAppStep {
                guard !startedAppSteps.contains(step), entries.last(where: { $0.step == .ownership })?.ok == true
                else { return false }
                startedAppSteps.insert(step)
            }
            return true
        }
        guard accepted else { return }
        let state = signposter.beginInterval(step.signpostName, id: signposter.makeSignpostID())
        lock.withLock { open[step] = Open(start: time, signpost: state) }
    }

    /// End `step`. Nothing happens when the step did not start.
    /// A failed app step, or both app steps done, ends the run with the summary line.
    public func finish(_ step: ConnectStep, ok: Bool) {
        let time = now()
        enum Outcome { case none, step, done, failed }
        let result = lock.withLock { () -> (Open, Entry, Outcome)? in
            guard !ended, let item = open.removeValue(forKey: step) else { return nil }
            let entry = Entry(step: step, duration: time - item.start, ok: ok)
            entries.append(entry)
            var outcome = Outcome.step
            if step.isAppStep {
                if !ok {
                    outcome = .failed
                } else if Set(entries.filter { $0.ok && $0.step.isAppStep }.map(\.step)).count == 2 {
                    outcome = .done
                }
            }
            if outcome == .done || outcome == .failed { ended = true }
            return (item, entry, outcome)
        }
        guard let (item, entry, outcome) = result else { return }
        signposter.endInterval(step.signpostName, item.signpost)
        log.info(Self.stepLine(entry))
        switch outcome {
        case .done: endRun(at: time, failed: false, failedStep: nil)
        case .failed: endRun(at: time, failed: true, failedStep: entry)
        case .none, .step: break
        }
    }

    /// The connect failed in a server step. Log the summary with the last failed step.
    /// Nothing happens when the run ended already.
    public func fail() {
        let time = now()
        let result = lock.withLock { () -> (Bool, Entry?) in
            guard !ended else { return (false, nil) }
            ended = true
            return (true, entries.last { !$0.ok })
        }
        guard result.0 else { return }
        endRun(at: time, failed: true, failedStep: result.1)
    }

    /// A new connect started before this run ended. The open intervals end, and no summary line goes to the log.
    func abandon() {
        let items = lock.withLock { () -> [(ConnectStep, Open)]? in
            guard !ended else { return nil }
            ended = true
            defer { open.removeAll() }
            return open.map { ($0.key, $0.value) }
        }
        guard let items else { return }
        for (step, item) in items { signposter.endInterval(step.signpostName, item.signpost) }
        signposter.endInterval("connect", signpost)
    }

    private func endRun(at time: Duration, failed: Bool, failedStep: Entry?) {
        let (steps, stillOpen) = lock.withLock { () -> ([Entry], [(ConnectStep, Open)]) in
            defer { open.removeAll() }
            return (entries, open.map { ($0.key, $0.value) })
        }
        for (step, item) in stillOpen { signposter.endInterval(step.signpostName, item.signpost) }
        signposter.endInterval("connect", signpost)
        log.info(Self.summaryLine(steps, total: time - started, failed: failed, failedStep: failedStep))
    }

    // MARK: Text

    /// Whole milliseconds, rounded down. A negative time gives 0.
    static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return max(0, Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000))
    }

    static func stepLine(_ entry: Entry) -> String {
        let ms = milliseconds(entry.duration)
        return entry.ok ? "connect step \(entry.step.rawValue): \(ms) ms"
            : "connect step \(entry.step.rawValue): failed after \(ms) ms"
    }

    /// `connect done in 640 ms: ssh-login 120 ms, ping 15 ms, …` or
    /// `connect failed at serve (1365 ms), total 1500 ms: ssh-login 120 ms, ping 15 ms, serve 1365 ms failed`.
    /// A failure with no failed step gives `connect failed, total 1500 ms: …`.
    static func summaryLine(_ entries: [Entry], total: Duration, failed: Bool, failedStep: Entry?) -> String {
        let steps = entries.map { "\($0.step.rawValue) \(milliseconds($0.duration)) ms\($0.ok ? "" : " failed")" }
            .joined(separator: ", ")
        let detail = steps.isEmpty ? "" : ": \(steps)"
        let totalMs = milliseconds(total)
        guard failed else { return "connect done in \(totalMs) ms\(detail)" }
        guard let failedStep else { return "connect failed, total \(totalMs) ms\(detail)" }
        let at = "\(failedStep.step.rawValue) (\(milliseconds(failedStep.duration)) ms)"
        return "connect failed at \(at), total \(totalMs) ms\(detail)"
    }
}

extension Optional where Wrapped == ConnectRun {
    /// Run `operation` as `step` of the run, or with no timing when there is no run.
    func measure<T>(_ step: ConnectStep, _ operation: () async throws -> T) async rethrows -> T {
        guard let run = self else { return try await operation() }
        return try await run.measure(step, operation)
    }
}
