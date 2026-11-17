import Foundation

/// JSON-RPC 2.0 client for the Hermes gateway on `/api/ws` (docs/hermes-protocol.md 3).
///
/// - `connect()` opens the socket, waits for `gateway.ready`, sends `client.capabilities`
///   with `server_requests: true`, then starts the 15 s heartbeat.
/// - `events` gives connection states, typed events and server requests, in order.
/// - A drop is an `.state(.disconnected(reason))` item. The client does not reconnect.
///   #15 calls `connect()` again. The `events` stream stays open across connections.
/// - The client never logs the token or message text.
public actor GatewayClient {
    public struct Configuration: Sendable {
        /// Time between heartbeats. `nil` turns off the timer (tests call `heartbeatTick()`).
        public var heartbeatInterval: Duration?
        /// No inbound frame for this time means that the connection is dead.
        public var silenceDeadline: Duration
        /// This many unanswered heartbeats in a row mean that the connection is dead.
        public var maxUnansweredPings: Int
        public var readyTimeout: Duration
        public var requestTimeout: Duration

        public init(heartbeatInterval: Duration? = .seconds(15), silenceDeadline: Duration = .seconds(45),
                    maxUnansweredPings: Int = 3, readyTimeout: Duration = .seconds(20),
                    requestTimeout: Duration = .seconds(120)) {
            self.heartbeatInterval = heartbeatInterval
            self.silenceDeadline = silenceDeadline
            self.maxUnansweredPings = maxUnansweredPings
            self.readyTimeout = readyTimeout
            self.requestTimeout = requestTimeout
        }
    }

    public nonisolated let events: AsyncStream<GatewayClientEvent>
    public nonisolated let endpoint: GatewayEndpoint
    private let continuation: AsyncStream<GatewayClientEvent>.Continuation
    private let connector: any GatewayWebSocketConnecting
    private let configuration: Configuration
    private let now: @Sendable () -> ContinuousClock.Instant

    public private(set) var state: GatewayConnectionState = .idle
    /// The method that the heartbeat uses. It is `gateway.ping` when `gateway.ready.heartbeat` is `true`.
    public private(set) var heartbeatMethod: GatewayHeartbeatMethod = .gatewayPing

    private var socket: (any GatewayWebSocket)?
    /// Goes up on each connect and each drop. Work of an old socket checks it and stops.
    private var generation = 0
    private var lastDisconnectReason: GatewayDisconnectReason = .clientClosed
    private var nextRequestId = 1
    private var pending: [JSONRPCID: PendingCall] = [:]
    private var heartbeatIds: Set<JSONRPCID> = []
    private var unansweredPings = 0
    private var lastInbound: ContinuousClock.Instant
    private var readyWaiter: CheckedContinuation<GatewayReady, any Error>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var readyTimeoutTask: Task<Void, Never>?

    private struct PendingCall {
        var method: String
        var continuation: CheckedContinuation<Data, any Error>?
        /// A result that came in before the caller started to wait.
        var early: Result<Data, any Error>?
        var timeout: Task<Void, Never>?
    }

    public init(endpoint: GatewayEndpoint,
                connector: any GatewayWebSocketConnecting = URLSessionGatewayConnector(),
                configuration: Configuration = Configuration(),
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.endpoint = endpoint
        self.connector = connector
        self.configuration = configuration
        self.now = now
        self.lastInbound = now()
        (events, continuation) = AsyncStream.makeStream(of: GatewayClientEvent.self, bufferingPolicy: .unbounded)
    }

    deinit {
        continuation.finish()
    }

    // MARK: Connection

    /// Opens the socket and does the handshake (docs/hermes-protocol.md 3.2).
    /// Throws `GatewayError.disconnected(reason)` when the socket closes first, for example
    /// `.unauthorized` on HTTP 401 or close code 4401.
    @discardableResult
    public func connect() async throws -> GatewayReady {
        switch state {
        case .connecting, .connected: throw GatewayError.alreadyConnected
        case .idle, .disconnected: break
        }
        generation += 1
        let gen = generation
        setState(.connecting)

        let socket: any GatewayWebSocket
        do {
            socket = try await connector.connect(to: endpoint.webSocketURL)
        } catch {
            if gen == generation { finishConnection(Self.reason(for: error)) }
            throw GatewayError.disconnected(lastDisconnectReason)
        }
        guard gen == generation else {
            socket.close(code: 1000)
            throw GatewayError.disconnected(lastDisconnectReason)
        }
        self.socket = socket
        lastInbound = now()
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket, generation: gen) }

        let ready = try await waitForReady(generation: gen)
        heartbeatMethod = ready.heartbeat == true ? .gatewayPing : .legacyPing

        // Without this the server fails every approval and clarify request at once
        // (`tui_gateway/methods_voice.py:522-541`).
        do {
            _ = try await call("client.capabilities", params: ClientCapabilitiesParams(serverRequests: true),
                               as: JSONValue.self)
        } catch GatewayError.rpc {
            // An old server without the method. Chat still works.
        }
        guard gen == generation else { throw GatewayError.disconnected(lastDisconnectReason) }
        setState(.connected(ready))
        startHeartbeat()
        return ready
    }

    /// Closes the socket. Pending calls fail with `.disconnected(.clientClosed)`.
    public func disconnect() {
        switch state {
        case .connecting, .connected: finishConnection(.clientClosed)
        case .idle, .disconnected: break
        }
    }

    // MARK: Requests

    /// Sends a request and decodes its `result` as `Output`.
    /// Throws `GatewayError.rpc` for an error answer.
    public func call<Params: Encodable & Sendable, Output: Decodable & Sendable>(
        _ method: String, params: Params, as resultType: Output.Type = Output.self
    ) async throws -> Output {
        guard let socket else { throw GatewayError.notConnected }
        let id = JSONRPCID.int(nextRequestId)
        nextRequestId += 1
        let text = try Self.encode(RequestFrame(id: id, method: method, params: params))
        pending[id] = PendingCall(method: method)
        let timeout = configuration.requestTimeout
        pending[id]?.timeout = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.resolve(id, with: .failure(GatewayError.timeout(method: method)))
        }
        do {
            try await socket.send(text)
        } catch {
            resolve(id, with: .failure(GatewayError.disconnected(Self.reason(for: error))))
        }
        let data = try await waitForResponse(id)
        return try Self.decodeResult(data, method: method, as: Output.self)
    }

    /// Answers a server request on its id (docs/hermes-protocol.md 3.11).
    public func respond<Answer: Encodable & Sendable>(to id: JSONRPCID, result: Answer) async throws {
        try await sendFrame(ResponseFrame(id: id, result: result))
    }

    /// Answers a server request with an error. An error answer to `approval` is a withdrawal,
    /// not a deny (`tui_gateway/server.py:717-728`).
    public func reject(_ id: JSONRPCID, code: Int = -32601, message: String = "not supported") async throws {
        try await sendFrame(ErrorResponseFrame(id: id, error: RPCErrorObject(code: code, message: message)))
    }

    /// Sends one heartbeat call and waits for its answer. Returns `true` for `{"ok":true}` or `{"pong":true}`.
    @discardableResult
    public func ping(using method: GatewayHeartbeatMethod? = nil) async throws -> Bool {
        let result = try await call((method ?? heartbeatMethod).rawValue, params: EmptyParams(), as: PingResult.self)
        return result.ok == true || result.pong == true
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        unansweredPings = 0
        guard let interval = configuration.heartbeatInterval else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.heartbeatTick()
            }
        }
    }

    /// Heartbeats sent since the last answer (for tests).
    var unansweredPingCount: Int { unansweredPings }

    /// One heartbeat step: drop the connection when it is dead, else send one ping.
    /// The timer calls it every `heartbeatInterval`. Tests call it directly.
    func heartbeatTick() async {
        guard case .connected = state, let socket else { return }
        if unansweredPings >= configuration.maxUnansweredPings
            || now() - lastInbound >= configuration.silenceDeadline {
            finishConnection(.heartbeatTimeout)
            return
        }
        let id = JSONRPCID.string("heartbeat-\(nextRequestId)")
        nextRequestId += 1
        heartbeatIds.insert(id)
        unansweredPings += 1
        let gen = generation
        do {
            try await socket.send(Self.encode(RequestFrame(id: id, method: heartbeatMethod.rawValue,
                                                           params: EmptyParams())))
        } catch {
            if gen == generation { finishConnection(Self.reason(for: error)) }
        }
    }

    // MARK: Inbound

    private func receiveLoop(_ socket: any GatewayWebSocket, generation gen: Int) async {
        while true {
            let message: GatewayWebSocketMessage
            do {
                message = try await socket.receive()
            } catch {
                if gen == generation { finishConnection(Self.reason(for: error)) }
                return
            }
            guard gen == generation else { return }
            handle(message)
        }
    }

    private func handle(_ message: GatewayWebSocketMessage) {
        let data = switch message {
        case .text(let text): Data(text.utf8)
        case .data(let data): data
        }
        lastInbound = now()
        let decoder = JSONDecoder()
        guard let head = try? decoder.decode(FrameHead.self, from: data) else { return }

        if head.method == "event" {
            guard let event = (try? decoder.decode(EventFrame.self, from: data))?.params else { return }
            if case .gatewayReady(let ready) = event.kind {
                guard let waiter = readyWaiter else { return }
                readyWaiter = nil
                readyTimeoutTask?.cancel()
                waiter.resume(returning: ready)
                return
            }
            continuation.yield(.event(event))
        } else if let method = head.method {
            // A server request has an id. A frame with another method and no id is not in the protocol.
            guard let id = head.id else { return }
            handleServerRequest(id: id, method: method, data: data)
        } else if let id = head.id {
            if heartbeatIds.contains(id) {
                heartbeatIds.removeAll()
                unansweredPings = 0
                return
            }
            resolve(id, with: .success(data))
        }
        // Else: an error frame with no id (`-32700` parse error, `tui_gateway/ws.py:701-706`). Ignore it.
    }

    private func handleServerRequest(id: JSONRPCID, method: String, data: Data) {
        let params = (try? JSONDecoder().decode(ServerRequestFrame.self, from: data))?.params ?? .object([:])
        guard GatewayServerRequest.supportedMethods.contains(method) else {
            sendLater(ErrorResponseFrame(id: id, error: RPCErrorObject(code: -32601, message: "not supported")))
            return
        }
        guard let request = try? GatewayServerRequest(id: id, method: method, params: params) else {
            sendLater(ErrorResponseFrame(id: id, error: RPCErrorObject(code: -32602, message: "invalid params")))
            return
        }
        continuation.yield(.serverRequest(request))
    }

    // MARK: Plumbing

    private func waitForReady(generation gen: Int) async throws -> GatewayReady {
        let timeout = configuration.readyTimeout
        return try await withCheckedThrowingContinuation { continuation in
            readyWaiter = continuation
            readyTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.readyTimedOut(generation: gen)
            }
        }
    }

    private func readyTimedOut(generation gen: Int) {
        guard gen == generation, readyWaiter != nil else { return }
        finishConnection(.readyTimeout)
    }

    private func waitForResponse(_ id: JSONRPCID) async throws -> Data {
        guard let call = pending[id] else { throw GatewayError.disconnected(lastDisconnectReason) }
        if let early = call.early {
            pending[id] = nil
            return try early.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id]?.continuation = continuation
        }
    }

    private func resolve(_ id: JSONRPCID, with result: Result<Data, any Error>) {
        guard var call = pending[id] else { return }
        call.timeout?.cancel()
        call.timeout = nil
        if let waiter = call.continuation {
            pending[id] = nil
            waiter.resume(with: result)
        } else {
            call.early = result
            pending[id] = call
        }
    }

    private func finishConnection(_ reason: GatewayDisconnectReason) {
        generation += 1
        lastDisconnectReason = reason
        socket?.close(code: reason == .clientClosed ? 1000 : 1001)
        socket = nil
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        readyWaiter?.resume(throwing: GatewayError.disconnected(reason))
        readyWaiter = nil
        let calls = pending
        pending = [:]
        for call in calls.values {
            call.timeout?.cancel()
            call.continuation?.resume(throwing: GatewayError.disconnected(reason))
        }
        heartbeatIds.removeAll()
        unansweredPings = 0
        setState(.disconnected(reason))
    }

    private func setState(_ newState: GatewayConnectionState) {
        state = newState
        continuation.yield(.state(newState))
    }

    private func sendFrame<Frame: Encodable>(_ frame: Frame) async throws {
        guard let socket else { throw GatewayError.notConnected }
        let text = try Self.encode(frame)
        do {
            try await socket.send(text)
        } catch {
            throw GatewayError.disconnected(Self.reason(for: error))
        }
    }

    /// Sends a frame without a wait. A failure shows up as a drop in the receive loop.
    private func sendLater<Frame: Encodable>(_ frame: Frame) {
        guard let socket, let text = try? Self.encode(frame) else { return }
        Task { try? await socket.send(text) }
    }

    private static func reason(for error: any Error) -> GatewayDisconnectReason {
        if let closed = error as? GatewayWebSocketClosed { return GatewayDisconnectReason(closed) }
        if case GatewayError.disconnected(let reason)? = error as? GatewayError { return reason }
        if let urlError = error as? URLError { return .transportFailed(code: urlError.code.rawValue) }
        return .transportFailed(code: nil)
    }

    private static func encode<Frame: Encodable>(_ frame: Frame) throws -> String {
        String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
    }

    static func decodeResult<Output: Decodable>(_ data: Data, method: String, as _: Output.Type) throws -> Output {
        let decoder = JSONDecoder()
        if let error = (try? decoder.decode(ErrorAnswerFrame.self, from: data))?.error {
            throw GatewayError.rpc(code: error.code, message: error.message)
        }
        guard let frame = try? decoder.decode(ResultFrame<Output>.self, from: data) else {
            throw GatewayError.invalidResponse(method: method)
        }
        return frame.result
    }
}

// MARK: Typed methods (docs/hermes-protocol.md 8)

extension GatewayClient {
    /// `session.create` (`methods_session.py:479-481`).
    public func createSession(_ params: SessionCreateParams = SessionCreateParams()) async throws -> SessionCreateResult {
        try await call("session.create", params: params)
    }

    /// `session.resume` with a stored id (`methods_session.py:1044-1074`).
    public func resumeSession(_ params: SessionResumeParams) async throws -> LiveSessionSnapshot {
        try await call("session.resume", params: params)
    }

    /// `session.activate` with a live id, after a reconnect (`methods_session.py:1152-1164`).
    public func activateSession(_ params: SessionActivateParams) async throws -> LiveSessionSnapshot {
        try await call("session.activate", params: params)
    }

    /// `session.list` (`methods_session.py:536-560`). For pages, use `HermesRESTClient.sessions`.
    public func listSessions(_ params: SessionListParams = SessionListParams()) async throws -> [SessionListRow] {
        try await call("session.list", params: params, as: SessionListResult.self).sessions
    }

    /// `session.history` with a live id (`methods_session.py:1978-1997`).
    public func sessionHistory(sessionId: String) async throws -> SessionHistoryResult {
        try await call("session.history", params: SessionIdParams(sessionId: sessionId))
    }

    /// `prompt.submit` (`methods_prompt.py:820-974`). The reply comes as events.
    public func submitPrompt(_ params: PromptSubmitParams) async throws -> PromptSubmitResult {
        try await call("prompt.submit", params: params)
    }

    /// `session.interrupt` (`methods_session_interrupt.py:70-100`).
    public func interrupt(sessionId: String) async throws -> SessionInterruptResult {
        try await call("session.interrupt", params: SessionIdParams(sessionId: sessionId))
    }

    /// `session.events.since` for replay after a reconnect (`methods_session.py:2309-2323`).
    public func eventsSince(sessionId: String, lastSeen: Int) async throws -> SessionEventsSinceResult {
        try await call("session.events.since", params: SessionEventsSinceParams(sessionId: sessionId, lastSeen: lastSeen))
    }

    /// Answers an `approval` server request (docs/hermes-protocol.md 3.11).
    public func answerApproval(_ request: GatewayServerRequest, choice: ApprovalChoice, all: Bool? = nil) async throws {
        try await respond(to: request.id, result: ApprovalAnswer(choice: choice, all: all))
    }
}

// MARK: Wire frames

struct EmptyParams: Encodable, Sendable {}

struct ClientCapabilitiesParams: Encodable, Sendable {
    var serverRequests: Bool
    private enum CodingKeys: String, CodingKey { case serverRequests = "server_requests" }
}

struct PingResult: Decodable, Sendable {
    var ok: Bool?
    var pong: Bool?
}

struct RPCErrorObject: Codable, Sendable {
    var code: Int
    var message: String
}

private struct RequestFrame<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: JSONRPCID
    let method: String
    let params: Params
}

private struct ResponseFrame<Answer: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: JSONRPCID
    let result: Answer
}

private struct ErrorResponseFrame: Encodable {
    let jsonrpc = "2.0"
    let id: JSONRPCID
    let error: RPCErrorObject
}

private struct FrameHead: Decodable {
    var id: JSONRPCID?
    var method: String?
}

private struct EventFrame: Decodable {
    var params: GatewayEvent
}

private struct ServerRequestFrame: Decodable {
    var params: JSONValue?
}

private struct ErrorAnswerFrame: Decodable {
    var error: RPCErrorObject?
}

private struct ResultFrame<Output: Decodable>: Decodable {
    var result: Output
}
