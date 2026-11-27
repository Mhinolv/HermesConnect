import Foundation

/// Issue #182: a wait that a test opens. It ignores a cancel, as a stalled SSH channel can. For tests only.
public final class StallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var _waiting = 0

    /// The tasks that wait now.
    public var waiting: Int { lock.withLock { _waiting } }

    public init() {}

    public func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                _waiting += 1
                return false
            }
            if now { continuation.resume() }
        }
    }

    public func open() {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            _waiting = 0
            defer { waiters.removeAll() }
            return waiters
        }
        due.forEach { $0.resume() }
    }
}

/// Issue #182: a fake SSH transport whose gate commands get no reply. For tests only, as `ScriptedSSHTransport`.
/// A stalled command ends when its session closes (with `unreachable`) or when the test calls `release()`.
/// It ignores a cancel.
public final class StallingSSHTransport: SSHTransport, @unchecked Sendable {
    public let inner: ScriptedSSHTransport
    private let lock = NSLock()
    private var _stalls: Set<GateCommand>
    private var _stallsLeft: Int
    private var gates: [StallGate] = []

    /// - Parameters:
    ///   - stalls: The commands that get no reply.
    ///   - times: How many commands stall. Later commands answer at once.
    public init(stalls: Set<GateCommand>, times: Int = .max, hostKey: HostKey = .sample) {
        inner = ScriptedSSHTransport(hostKey: hostKey)
        _stalls = stalls
        _stallsLeft = times
    }

    /// The commands that wait for a reply now.
    public var stalled: Int { lock.withLock { gates }.reduce(0) { $0 + $1.waiting } }

    /// Answer every stalled command now, and stop all stalls.
    public func release() {
        let open = lock.withLock { () -> [StallGate] in
            _stalls = []
            return gates
        }
        open.forEach { $0.open() }
    }

    fileprivate func takeStall(_ command: GateCommand) -> Bool {
        lock.withLock {
            guard _stalls.contains(command), _stallsLeft > 0 else { return false }
            _stallsLeft -= 1
            return true
        }
    }

    public func connect(to endpoint: SSHEndpoint, key: DeviceKey,
                 checkHostKey: @escaping @Sendable (HostKey) throws -> Void) async throws -> any SSHSession {
        let session = try await inner.connect(to: endpoint, key: key, checkHostKey: checkHostKey)
        let gate = StallGate()
        lock.withLock { gates.append(gate) }
        return Session(inner: session, transport: self, gate: gate, closed: ClosedFlag())
    }

    final class ClosedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isClosed: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private struct Session: SSHSession {
        let inner: any SSHSession
        let transport: StallingSSHTransport
        let gate: StallGate
        let closed: ClosedFlag

        func execute(_ command: GateCommand, stdin: Data?) async throws -> String {
            if transport.takeStall(command) {
                await gate.wait()
                if closed.isClosed { throw SSHConnectionError.unreachable }
            }
            return try await inner.execute(command, stdin: stdin)
        }

        func openLoopbackForward(remotePort: Int) async throws -> any LoopbackForward {
            try await inner.openLoopbackForward(remotePort: remotePort)
        }

        func negotiatedAlgorithms() async -> SSHNegotiatedAlgorithms? { await inner.negotiatedAlgorithms() }

        func onClose(_ handler: @escaping @Sendable () -> Void) { inner.onClose(handler) }

        func close() async {
            closed.set()
            gate.open()
            await inner.close()
        }
    }
}
