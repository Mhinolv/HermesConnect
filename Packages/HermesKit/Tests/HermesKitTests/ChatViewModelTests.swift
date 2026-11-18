import Foundation
import Testing
@testable import HermesKit

/// A chat transport with scripted answers. No network.
final class FakeChatTransport: ChatTransport, @unchecked Sendable {
    struct Submit: Equatable {
        var sessionId: String
        var text: String
        var retryBeforeRowId: Int?
    }

    let events: AsyncStream<GatewayClientEvent>
    let input: AsyncStream<GatewayClientEvent>.Continuation
    private let lock = NSLock()
    private var _starts: [(String, String)] = []
    private var _submits: [Submit] = []
    private var _stops: [String] = []
    var failStart = false
    var failSubmit = false
    var rowId: Int? = 118

    init() {
        (events, input) = AsyncStream.makeStream(of: GatewayClientEvent.self)
    }

    var starts: [(String, String)] { lock.withLock { _starts } }
    var submits: [Submit] { lock.withLock { _submits } }
    var stops: [String] { lock.withLock { _stops } }

    struct Failure: Error {}

    func startSession(source: String, idempotencyKey: String) async throws -> ChatSessionRef {
        lock.withLock { _starts.append((source, idempotencyKey)) }
        try await Task.sleep(for: .milliseconds(10))
        if lock.withLock({ failStart }) { throw Failure() }
        return ChatSessionRef(liveId: "s1", storedId: "20261116_101500_ab12cd")
    }

    private var _resumes: [String] = []
    var resumes: [String] { lock.withLock { _resumes } }

    /// Thrown by `resumeSession` when set (for example `GatewayError.rpc(code: 4007, ...)`).
    var resumeError: (any Error)?

    func resumeSession(storedId: String, source: String) async throws -> ChatSessionRef {
        lock.withLock { _resumes.append(storedId) }
        if lock.withLock({ failStart }) { throw Failure() }
        if let error = lock.withLock({ resumeError }) { throw error }
        return ChatSessionRef(liveId: "s2", storedId: storedId)
    }

    func submitPrompt(sessionId: String, text: String, retryBeforeRowId: Int?) async throws -> Int? {
        lock.withLock { _submits.append(Submit(sessionId: sessionId, text: text, retryBeforeRowId: retryBeforeRowId)) }
        if lock.withLock({ failSubmit }) { throw Failure() }
        return lock.withLock { rowId }
    }

    func stopReply(sessionId: String) async throws -> Bool {
        lock.withLock { _stops.append(sessionId) }
        return true
    }

    private var _histories: [String] = []
    var histories: [String] { lock.withLock { _histories } }
    var transcript: [TranscriptMessage] = []
    var failHistory = false

    func history(sessionId: String) async throws -> [TranscriptMessage] {
        lock.withLock { _histories.append(sessionId) }
        if lock.withLock({ failHistory }) { throw Failure() }
        return lock.withLock { transcript }
    }
}

private func event(_ json: String) throws -> GatewayClientEvent {
    .event(try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8)))
}

private func ids() -> @Sendable () -> String {
    let counter = Counter()
    return { counter.next() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> String { lock.withLock { value += 1; return "m\(value)" } }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ChatViewModelTests {
    private func model(_ transport: FakeChatTransport, redraw: Duration = .seconds(60)) -> ChatViewModel {
        ChatViewModel(transport: transport, redrawInterval: redraw, makeId: ids())
    }

    @Test func sendShowsBubbleAtOnceThenDelivers() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport)
        let task = vm.send("hello")
        #expect(vm.messages.map(\.text) == ["hello"])
        #expect(vm.messages[0].delivery == .sending)
        await task?.value
        #expect(vm.messages[0].delivery == .delivered)
        #expect(vm.messages[0].userRowId == 118)
        #expect(vm.isReplyActive)
        #expect(transport.starts.map(\.0) == ["ios"])
        #expect(transport.submits == [.init(sessionId: "s1", text: "hello", retryBeforeRowId: nil)])
    }

    /// Issue #67: a slash command runs as a command (`SlashCommandTests`), never as prompt text.
    @Test func slashTextIsNotSentAsAPromptAndBlankTextIsNotSent() async {
        let transport = FakeChatTransport()
        let vm = model(transport)
        #expect(vm.send("  \n ") == nil)
        await vm.send("/model gpt")?.value
        #expect(transport.submits.isEmpty)
    }

    @Test func twoQuickSendsShareOneSessionCreate() async {
        let transport = FakeChatTransport()
        let vm = model(transport)
        let first = vm.send("one")
        let second = vm.send("two")
        await first?.value
        await second?.value
        #expect(transport.starts.count == 1)
        #expect(transport.submits.count == 2)
    }

    @Test func failedSendShowsNotDeliveredThenRetryAndDelete() async {
        let transport = FakeChatTransport()
        transport.failSubmit = true
        let vm = model(transport)
        await vm.send("hello")?.value
        #expect(vm.messages[0].delivery == .failed)
        #expect(!vm.isReplyActive)
        #expect(ChatTimeline.rows(for: vm.messages).first?.footnote == .notDelivered)

        transport.failSubmit = false
        let retry = vm.retrySend(id: vm.messages[0].id)
        #expect(vm.messages[0].delivery == .sending)
        await retry?.value
        #expect(vm.messages[0].delivery == .delivered)
        #expect(transport.submits.count == 2)

        transport.failSubmit = true
        await vm.send("second")?.value
        let failed = vm.messages[1].id
        vm.delete(id: failed)
        #expect(vm.messages.map(\.text) == ["hello"])
    }

    @Test func sessionCreateFailureFailsTheSend() async {
        let transport = FakeChatTransport()
        transport.failStart = true
        let vm = model(transport)
        await vm.send("hello")?.value
        #expect(vm.messages[0].delivery == .failed)
        #expect(transport.submits.isEmpty)
        transport.failStart = false
        await vm.retrySend(id: vm.messages[0].id)?.value
        #expect(transport.starts.count == 2)
        #expect(vm.messages[0].delivery == .delivered)
    }

    @Test func deltasAreThrottledButNoTextIsLost() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport)
        await vm.send("hello")?.value
        vm.receive(try event(#"{"type":"message.start","session_id":"s1","payload":{"turn_id":"t1"}}"#))
        #expect(vm.turn == .typing)
        var offset = 0
        for word in ["Hel", "lo", ", ", "world"] {
            vm.receive(try event(#"{"type":"message.delta","session_id":"s1","payload":{"text":"\#(word)","offset":\#(offset)}}"#))
            offset += word.utf16.count
        }
        // The first delta makes the bubble now. Later deltas wait for the next redraw.
        #expect(vm.messages.last?.text == "Hel")
        #expect(vm.pendingThread.messages.last?.text == "Hello, world")
        vm.redrawNow()
        #expect(vm.messages.last?.text == "Hello, world")
        #expect(vm.turn == .streaming)
    }

    @Test func throttledRedrawHappensWithinTheInterval() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport, redraw: .milliseconds(20))
        await vm.send("hello")?.value
        vm.receive(try event(#"{"type":"message.delta","session_id":"s1","payload":{"text":"A","offset":0}}"#))
        vm.receive(try event(#"{"type":"message.delta","session_id":"s1","payload":{"text":"B","offset":1}}"#))
        #expect(vm.messages.last?.text == "A")
        try await Task.sleep(for: .milliseconds(200))
        #expect(vm.messages.last?.text == "AB")
    }

    @Test func completeRedrawsAtOnceAndAnnounces() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport)
        await vm.send("hello")?.value
        vm.receive(try event(#"{"type":"message.delta","session_id":"s1","payload":{"text":"Hi","offset":0}}"#))
        vm.receive(try event(#"{"type":"tool.start","session_id":"s1","payload":{"tool_id":"1","name":"web_search"}}"#))
        #expect(vm.statusLine == "Using web_search…")
        vm.receive(try event(#"{"type":"message.delta","session_id":"s1","payload":{"text":" there","offset":2}}"#))
        vm.receive(try event(#"{"type":"message.complete","session_id":"s1","payload":{"text":"Hi there.","status":"complete"}}"#))
        #expect(vm.messages.last?.text == "Hi there.")
        #expect(vm.messages.last?.reply == .complete)
        #expect(vm.statusLine == nil)
        #expect(!vm.isReplyActive)
        #expect(vm.completedReplyId == vm.messages.last?.id)
    }

    /// Issue #120: the Voice tab reads `runningTool`. The reply keeps its tools after `message.complete`.
    @Test func runningToolFollowsTheToolEventsAndTheReplyKeepsTheTools() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport)
        await vm.send("hello")?.value
        vm.receive(try event(#"{"type":"message.start","session_id":"s1","payload":{}}"#))
        vm.receive(try event(#"{"type":"tool.start","session_id":"s1","payload":{"tool_id":"1","name":"web_search"}}"#))
        #expect(vm.runningTool == "web_search")
        vm.receive(try event(#"{"type":"tool.complete","session_id":"s1","payload":{"tool_id":"1","name":"web_search","duration_s":0.4,"summary":"Searched"}}"#))
        #expect(vm.runningTool == nil)
        vm.receive(try event(#"{"type":"message.complete","session_id":"s1","payload":{"text":"Done.","status":"complete"}}"#))
        #expect(vm.messages.last?.tools == [ChatToolCall(id: "1", name: "web_search", summary: "Searched", duration: 0.4)])
    }

    @Test func eventsOfOtherSessionsAreIgnored() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport)
        vm.receive(try event(#"{"type":"message.start","session_id":"s1","payload":{}}"#))
        #expect(vm.turn == .idle)
        await vm.send("hello")?.value
        vm.receive(try event(#"{"type":"message.delta","session_id":"other","payload":{"text":"x"}}"#))
        vm.receive(try event(#"{"type":"message.delta","payload":{"text":"x"}}"#))
        #expect(vm.messages.count == 1)
    }

    @Test func sessionTitleUsesTheStoredId() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport)
        await vm.send("hello")?.value
        vm.receive(try event(#"{"type":"session.title","session_id":"s1","payload":{"session_id":"other","title":"No"}}"#))
        #expect(vm.title == nil)
        vm.receive(try event(#"{"type":"session.title","session_id":"s1","payload":{"session_id":"20261116_101500_ab12cd","title":"Trip plan"}}"#))
        #expect(vm.title == "Trip plan")
    }

    @Test func stopCallsInterrupt() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport)
        #expect(vm.stop() == nil)
        await vm.send("hello")?.value
        await vm.stop()?.value
        #expect(transport.stops == ["s1"])
        vm.receive(try event(#"{"type":"message.complete","session_id":"s1","payload":{"text":"Par","status":"interrupted"}}"#))
        #expect(vm.messages.last?.reply == .interrupted)
        #expect(!vm.isReplyActive)
    }

    @Test func replyRetryRegeneratesFromThePromptRow() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport)
        await vm.send("hello")?.value
        vm.receive(try event(#"{"type":"message.delta","session_id":"s1","payload":{"text":"Part","offset":0}}"#))
        vm.receive(try event(#"{"type":"message.complete","session_id":"s1","payload":{"text":"","status":"error","error":"overloaded"}}"#))
        let failed = try #require(vm.messages.last)
        #expect(failed.text == "Part")
        #expect(failed.reply == .failed(message: "overloaded"))

        await vm.retryReply(id: failed.id)?.value
        #expect(vm.messages.map(\.role) == [.user])
        #expect(transport.submits.last == .init(sessionId: "s1", text: "hello", retryBeforeRowId: 118))
        #expect(vm.isReplyActive)
    }

    @Test func disconnectFailsTheActiveReply() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport)
        await vm.send("hello")?.value
        vm.receive(.state(.disconnected(.heartbeatTimeout)))
        #expect(vm.messages.last?.reply == .failed(message: nil))
        #expect(!vm.isReplyActive)
    }

    @Test func sendAfterADropResumesTheStoredSession() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport)
        await vm.send("one")?.value
        vm.receive(try event(#"{"type":"message.complete","session_id":"s1","payload":{"text":"ok","status":"complete"}}"#))
        vm.receive(.state(.disconnected(.heartbeatTimeout)))
        await vm.send("two")?.value
        #expect(transport.starts.count == 1)
        #expect(transport.resumes == ["20261116_101500_ab12cd"])
        #expect(transport.submits.last == .init(sessionId: "s2", text: "two", retryBeforeRowId: nil))
        // Events of the new live id reach the thread.
        vm.receive(try event(#"{"type":"message.start","session_id":"s2","payload":{}}"#))
        #expect(vm.turn == .typing)
    }

    @Test func dropBeforeASessionCreatesOnTheNextSend() async {
        let transport = FakeChatTransport()
        let vm = model(transport)
        vm.receive(.state(.disconnected(.heartbeatTimeout)))
        await vm.send("one")?.value
        #expect(transport.starts.count == 1)
        #expect(transport.resumes.isEmpty)
    }

    @Test func runReadsTheEventStream() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport)
        let runner = Task { await vm.run() }
        await vm.send("hello")?.value
        transport.input.yield(try event(#"{"type":"message.start","session_id":"s1","payload":{}}"#))
        for _ in 0..<100 where vm.turn != .typing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(vm.turn == .typing)
        runner.cancel()
        transport.input.finish()
        await runner.value
    }
}

/// `GatewayClient` as a `ChatTransport`, on a fake socket.
@Suite(.timeLimit(.minutes(1))) struct GatewayChatTransportTests {
    private func connected() async throws -> (GatewayClient, FakeGatewaySocket) {
        let socket = FakeGatewaySocket()
        let client = GatewayClient(endpoint: try GatewayEndpoint(port: 8123, token: String(repeating: "0f", count: 32)),
                                   connector: FakeGatewayConnector(socket), configuration: .init(heartbeatInterval: nil))
        async let ready = client.connect()
        socket.pushReady()
        socket.reply(to: try await socket.waitForRequest("client.capabilities"), result: "{}")
        _ = try await ready
        return (client, socket)
    }

    @Test func startSessionSendsSourceIOS() async throws {
        let (client, socket) = try await connected()
        let transport: any ChatTransport = client
        async let ref = transport.startSession(source: ChatSource.iOS, idempotencyKey: "k1")
        let request = try await socket.waitForRequest("session.create")
        #expect(request["params"] == ["source": "ios", "idempotency_key": "k1"])
        socket.reply(to: request, result: #"{"session_id":"3f9a1c2e","stored_session_id":"20261116_101500_ab12cd","message_count":0,"messages":[]}"#)
        #expect(try await ref == ChatSessionRef(liveId: "3f9a1c2e", storedId: "20261116_101500_ab12cd"))
    }

    @Test func submitAndRetryParams() async throws {
        let (client, socket) = try await connected()
        let transport: any ChatTransport = client
        async let row = transport.submitPrompt(sessionId: "S", text: "hello", retryBeforeRowId: nil)
        let first = try await socket.waitForRequest("prompt.submit")
        #expect(first["params"] == ["session_id": "S", "text": "hello"])
        socket.reply(to: first, result: #"{"status":"streaming","user_row_id":118}"#)
        #expect(try await row == 118)

        async let again = transport.submitPrompt(sessionId: "S", text: "hello", retryBeforeRowId: 118)
        let second = try await socket.waitForRequest("prompt.submit", count: 2)
        #expect(second["params"] == ["session_id": "S", "text": "hello", "truncate_before_row_id": 118,
                                     "confirm_truncate": true])
        socket.reply(to: second, result: #"{"status":"streaming"}"#)
        #expect(try await again == nil)
    }

    @Test func stopReplyCallsInterrupt() async throws {
        let (client, socket) = try await connected()
        let transport: any ChatTransport = client
        async let stopped = transport.stopReply(sessionId: "S")
        let request = try await socket.waitForRequest("session.interrupt")
        #expect(request["params"] == ["session_id": "S"])
        socket.reply(to: request, result: #"{"status":"interrupted"}"#)
        #expect(try await stopped)
    }
}
