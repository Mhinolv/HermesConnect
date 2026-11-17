import Foundation

/// Gives each reader its own event stream (issue #7). An `AsyncStream` has one reader only, and it ends
/// when its reader task is cancelled. The session list and each chat screen read the events at the same
/// time, and a chat screen that closes must not end the events of the others.
public final class GatewayEventBroadcast: Sendable {
    private let state = Locked<[UUID: AsyncStream<GatewayClientEvent>.Continuation]>([:])

    public init() {}

    /// A new stream that gets every event from now on. It ends when its reader stops.
    public func subscribe() -> AsyncStream<GatewayClientEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayClientEvent.self)
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0[id] = nil }
        }
        state.withLock { $0[id] = continuation }
        return stream
    }

    public func yield(_ item: GatewayClientEvent) {
        for continuation in state.withLock({ Array($0.values) }) {
            continuation.yield(item)
        }
    }

    /// The number of open streams (tests).
    public var readerCount: Int { state.withLock { $0.count } }
}

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
