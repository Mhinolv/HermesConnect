import Foundation
import Synchronization
@testable import HermesKit

/// A scripted in-memory WebSocket. No network.
final class FakeGatewaySocket: GatewayWebSocket, @unchecked Sendable {
    private let state = Mutex(State())
    private let inbox: AsyncThrowingStream<GatewayWebSocketMessage, any Error>
    private let inboxContinuation: AsyncThrowingStream<GatewayWebSocketMessage, any Error>.Continuation
    // Only the client receive loop uses the iterator, one call at a time.
    private var iterator: AsyncThrowingStream<GatewayWebSocketMessage, any Error>.Iterator

    private struct State {
        var sent: [JSONValue] = []
        var closedCode: Int?
        var failSends = false
    }

    init() {
        (inbox, inboxContinuation) = AsyncThrowingStream.makeStream(of: GatewayWebSocketMessage.self)
        iterator = inbox.makeAsyncIterator()
    }

    // MARK: GatewayWebSocket

    func send(_ text: String) async throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        try state.withLock { state in
            if state.failSends || state.closedCode != nil { throw GatewayWebSocketClosed(closeCode: 1006) }
            state.sent.append(value)
        }
    }

    func receive() async throws -> GatewayWebSocketMessage {
        guard let message = try await iterator.next() else { throw GatewayWebSocketClosed(closeCode: 1000) }
        return message
    }

    func close(code: Int) {
        state.withLock { $0.closedCode = code }
        inboxContinuation.finish(throwing: GatewayWebSocketClosed(closeCode: code))
    }

    // MARK: Server side

    var closedCode: Int? { state.withLock { $0.closedCode } }
    var sent: [JSONValue] { state.withLock { $0.sent } }

    func push(_ json: String) {
        inboxContinuation.yield(.text(json))
    }

    /// Issue #97: a binary frame, for example `speak-stream` PCM.
    func pushBinary(_ data: Data) {
        inboxContinuation.yield(.data(data))
    }

    func pushReady(heartbeat: Bool? = true, epoch: String = "0123456789abcdef0123456789abcdef") {
        let heartbeatField = heartbeat.map { ",\"heartbeat\":\($0)" } ?? ""
        push("""
        {"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{\
        "skin":{"name":"default"},"change_events":true\(heartbeatField),"replay_epoch":"\(epoch)"}}}
        """)
    }

    func serverClose(closeCode: Int? = nil, httpStatus: Int? = nil) {
        inboxContinuation.finish(throwing: GatewayWebSocketClosed(closeCode: closeCode, httpStatus: httpStatus))
    }

    func failSends() {
        state.withLock { $0.failSends = true }
    }

    /// Waits until the client sent `count` frames with this method. Returns the last one.
    @discardableResult
    func waitForRequest(_ method: String, count: Int = 1) async throws -> JSONValue {
        let frames = try await waitForSent(count: count) { $0["method"]?.stringValue == method }
        return frames[count - 1]
    }

    /// Waits until the client sent `count` frames that match.
    func waitForSent(count: Int = 1, timeout: Duration = .seconds(5),
                     _ match: (JSONValue) -> Bool) async throws -> [JSONValue] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let frames = sent.filter(match)
            if frames.count >= count { return frames }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FakeTimeout(what: "sent frame")
    }

    /// Answers a sent request with a result.
    func reply(to request: JSONValue, result: String) {
        push(#"{"jsonrpc":"2.0","id":\#(Self.idJSON(request)),"result":\#(result)}"#)
    }

    func replyError(to request: JSONValue, code: Int, message: String) {
        push(#"{"jsonrpc":"2.0","id":\#(Self.idJSON(request)),"error":{"code":\#(code),"message":"\#(message)"}}"#)
    }

    private static func idJSON(_ request: JSONValue) -> String {
        switch request["id"] {
        case .int(let id): String(id)
        case .string(let id): "\"\(id)\""
        default: "null"
        }
    }
}

struct FakeTimeout: Error { var what: String }

/// Hands out scripted sockets in order and records the URLs.
final class FakeGatewayConnector: GatewayWebSocketConnecting, @unchecked Sendable {
    private let state: Mutex<(sockets: [FakeGatewaySocket], urls: [URL], error: GatewayWebSocketClosed?)>

    init(_ sockets: FakeGatewaySocket..., error: GatewayWebSocketClosed? = nil) {
        state = Mutex((sockets, [], error))
    }

    var urls: [URL] { state.withLock { $0.urls } }

    func connect(to url: URL) async throws -> any GatewayWebSocket {
        try state.withLock { state in
            state.urls.append(url)
            if let error = state.error { throw error }
            guard !state.sockets.isEmpty else { throw GatewayWebSocketClosed(urlErrorCode: -1004) }
            return state.sockets.removeFirst()
        }
    }
}

/// A clock that moves only when the test moves it.
final class ManualClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    var now: ContinuousClock.Instant { instant.withLock { $0 } }

    func advance(by duration: Duration) {
        instant.withLock { $0 = $0 + duration }
    }
}

/// Reads `GatewayClient.events` with a timeout per item.
final class EventReader: @unchecked Sendable {
    private var iterator: AsyncStream<GatewayClientEvent>.Iterator

    init(_ client: GatewayClient) {
        iterator = client.events.makeAsyncIterator()
    }

    /// The next item that is not a state change.
    func nextEvent() async throws -> GatewayClientEvent {
        while true {
            let item = try await next()
            if case .state = item { continue }
            return item
        }
    }

    /// The next state change.
    func nextState() async throws -> GatewayConnectionState {
        while true {
            if case .state(let state) = try await next() { return state }
        }
    }

    func next() async throws -> GatewayClientEvent {
        guard let item = await iterator.next() else { throw FakeTimeout(what: "events stream ended") }
        return item
    }
}
