import Foundation

/// Issue #182: the time limits of one connect.
///
/// Each network step has its own limit: the SSH login (`CitadelSSHTransport.connectTimeoutSeconds`, 15 s), the gate
/// `ping` (`ping`), the gate `serve` (`ServeBootstrap.Configuration.serveTimeout`, 150 s) and each HTTP call (15 s).
/// The `total` limit covers the full connect, also a step that does not stop when it is cancelled.
public enum ConnectTimeLimit {
    /// The gate answers `ping` at once. 15 s is the limit of each HTTP call too.
    public static let ping: Duration = .seconds(15)
    /// The gate waits up to 120 s for a first start of Hermes. The login, the `ping`, the health check and the
    /// ownership check get the other 60 s.
    public static let total: Duration = .seconds(180)
    /// A return to the foreground cancels a connect that started this long ago or more, and starts a new one.
    public static let restartAfter: Duration = .seconds(10)
}

/// Issue #182: a wait for a time. Tests give a fake that ends when the test moves its clock.
/// Throws `CancellationError` when the task is cancelled.
public typealias LimitSleep = @Sendable (Duration) async throws -> Void

/// The real `LimitSleep`.
public let systemLimitSleep: LimitSleep = { try await Task.sleep(for: $0) }

/// Issue #182: the end of a wait for a connect.
public enum ConnectWaitOutcome: Sendable, Equatable {
    /// The connect ended, or the app stopped the wait (`ConnectWatch.finish()`).
    case finished
    /// The limit passed first.
    case expired
}

/// Issue #182: waits for one connect up to a limit. The connect runs in its own task and calls `finish()` when it ends.
/// A wait that ends never cancels the connect. The caller does that.
@MainActor
public final class ConnectWatch {
    private var outcome: ConnectWaitOutcome?
    private var waiter: CheckedContinuation<ConnectWaitOutcome, Never>?
    private var timer: Task<Void, Never>?

    public init() {}

    /// Wait until `finish()` runs or `limit` passes on `clock`. A second call gives the first outcome at once.
    public func wait(limit: Duration, clock: any RetryClock) async -> ConnectWaitOutcome {
        if let outcome { return outcome }
        let deadline = clock.now + limit
        timer = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            self?.end(.expired)
        }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                waiter = continuation
            }
        }
    }

    /// The connect ended, or a new connect replaced it. The wait ends with `finished`. Later calls do nothing.
    public func finish() { end(.finished) }

    private func end(_ result: ConnectWaitOutcome) {
        guard outcome == nil else { return }
        outcome = result
        timer?.cancel()
        timer = nil
        waiter?.resume(returning: result)
        waiter = nil
    }
}

extension RetryClock {
    /// Issue #182: a `LimitSleep` on this clock, for the steps that do not run on the main actor.
    public nonisolated var limitSleep: LimitSleep {
        { [self] duration in
            let deadline = await now + duration
            try await sleep(until: deadline)
        }
    }
}

struct DeadlineExceeded: Error {}

/// Runs `operation`. If it takes longer than `limit`, cancels it and throws `DeadlineExceeded`.
/// Issue #182: the throw does not wait for the operation to end. A stalled SSH channel can ignore the cancel.
func withDeadline<T: Sendable>(_ limit: Duration, sleep: @escaping LimitSleep = systemLimitSleep,
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = DeadlineRace<T>()
    let work = Task {
        do {
            race.end(.success(try await operation()))
        } catch {
            race.end(.failure(error))
        }
    }
    let timer = Task {
        do {
            try await sleep(limit)
        } catch {
            return
        }
        race.end(.failure(DeadlineExceeded()))
    }
    defer {
        work.cancel()
        timer.cancel()
    }
    return try await withTaskCancellationHandler {
        try await race.value()
    } onCancel: {
        race.end(.failure(CancellationError()))
    }
}

/// Issue #182: runs `operation`. If `failure` throws first, cancels the operation and throws that error at once.
/// If `failure` returns, the operation continues, and its result counts.
func untilFailure<T: Sendable>(_ failure: @escaping @Sendable () async throws -> Void,
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = DeadlineRace<T>()
    let work = Task {
        do {
            race.end(.success(try await operation()))
        } catch {
            race.end(.failure(error))
        }
    }
    let watcher = Task {
        do {
            try await failure()
        } catch {
            race.end(.failure(error))
        }
    }
    defer {
        work.cancel()
        watcher.cancel()
    }
    return try await withTaskCancellationHandler {
        try await race.value()
    } onCancel: {
        race.end(.failure(CancellationError()))
    }
}

/// The first result of a `withDeadline` or `untilFailure` race. Later results are dropped.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?
    private var waiter: CheckedContinuation<T, any Error>?

    func end(_ value: Result<T, any Error>) {
        let resume: CheckedContinuation<T, any Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            defer { waiter = nil }
            return waiter
        }
        resume?.resume(with: value)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<T, any Error>? = lock.withLock {
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
