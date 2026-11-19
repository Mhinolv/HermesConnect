import Foundation
import Testing
@testable import HermesKit

/// Issue #145: a fake gateway drops the socket mid-turn. The chat reconnects, resumes the stored id and replays the
/// events from the last `seq` (docs/hermes-protocol.md 4). No network.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ReattachTests {
    static let token = String(repeating: "0f", count: 32)
    static let stored = "20261118_101500_ab12cd"
    static let live = "3f9a1c2e"

    private func ids() -> @Sendable () -> String {
        let counter = ReattachCounter()
        return { counter.next() }
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FakeTimeout(what: "condition")
    }

    /// A client on the first socket, a chat with a delivered prompt, and three events of the reply.
    private func midTurn(_ first: FakeGatewaySocket, _ second: FakeGatewaySocket) async throws
        -> (GatewayClient, ChatViewModel) {
        let client = GatewayClient(endpoint: try GatewayEndpoint(port: 8123, token: Self.token),
                                   connector: FakeGatewayConnector(first, second),
                                   configuration: .init(heartbeatInterval: nil))
        async let ready = client.connect()
        first.pushReady()
        first.reply(to: try await first.waitForRequest("client.capabilities"), result: "{}")
        _ = try await ready

        let vm = ChatViewModel(transport: client, redrawInterval: .milliseconds(1), makeId: ids())
        vm.startEvents()
        let send = vm.send("hello")
        let create = try await first.waitForRequest("session.create")
        first.reply(to: create, result: #"{"session_id":"\#(Self.live)","stored_session_id":"\#(Self.stored)","message_count":0,"messages":[]}"#)
        let submit = try await first.waitForRequest("prompt.submit")
        first.reply(to: submit, result: #"{"status":"streaming","user_row_id":118}"#)
        await send?.value

        first.push(Self.frame(seq: 1, #"{"type":"message.start","payload":{"turn_id":"t1"}}"#))
        first.push(Self.frame(seq: 2, #"{"type":"message.delta","payload":{"text":"Hel","turn_id":"t1","segment":0,"offset":0}}"#))
        first.push(Self.frame(seq: 3, #"{"type":"message.delta","payload":{"text":"lo","turn_id":"t1","segment":0,"offset":3}}"#))
        try await waitFor { vm.messages.last?.text == "Hello" }
        return (client, vm)
    }

    /// One event frame of the live session with its `seq`. `body` is `{"type":…,"payload":…}`.
    static func frame(seq: Int, _ body: String) -> String {
        #"{"jsonrpc":"2.0","method":"event","params":\#(event(seq: seq, body))}"#
    }

    /// The `params` object of an event frame, as `session.events.since` returns it.
    static func event(seq: Int, _ body: String) -> String {
        let inner = body.dropFirst().dropLast()
        return #"{"session_id":"\#(live)","seq":\#(seq),\#(inner)}"#
    }

    private func reconnect(_ client: GatewayClient, _ second: FakeGatewaySocket) async throws {
        async let ready = client.connect()
        second.pushReady()
        second.reply(to: try await second.waitForRequest("client.capabilities"), result: "{}")
        _ = try await ready
    }

    private func submits(_ sockets: FakeGatewaySocket...) -> Int {
        sockets.map { $0.sent.filter { $0["method"]?.stringValue == "prompt.submit" }.count }.reduce(0, +)
    }

    @Test func dropMidTurnReattachesAndReplaysIntoTheSameBubble() async throws {
        let first = FakeGatewaySocket()
        let second = FakeGatewaySocket()
        let (client, vm) = try await midTurn(first, second)
        let bubble = try #require(vm.messages.last)
        #expect(bubble.role == .assistant)

        // The heartbeat drop: the socket closes while Hermes still works on the turn.
        first.serverClose(closeCode: 1006)
        for _ in 0..<1000 {
            if case .disconnected = await client.state { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        // The chat reads the drop from the event stream.
        try await Task.sleep(for: .milliseconds(50))
        // A drop is not a failure. The partial bubble stays, and no "Reply failed" or "Not Delivered" shows.
        #expect(vm.messages.last?.reply == .streaming)
        #expect(vm.messages.first?.delivery == .delivered)
        #expect(vm.isReplyActive)

        try await reconnect(client, second)
        let resume = try await second.waitForRequest("session.resume")
        #expect(resume["params"]?["session_id"]?.stringValue == Self.stored)
        second.reply(to: resume, result: #"{"session_id":"\#(Self.live)","stored_session_id":"\#(Self.stored)","message_count":1,"messages":[],"running":true}"#)

        let since = try await second.waitForRequest("session.events.since")
        #expect(since["params"]?["session_id"]?.stringValue == Self.live)
        #expect(since["params"]?["last_seen"] == .int(3))
        // The ring sends seq 3 again (already shown), then the rest of the turn.
        let events = [
            Self.event(seq: 3, #"{"type":"message.delta","payload":{"text":"lo","turn_id":"t1","segment":0,"offset":3}}"#),
            Self.event(seq: 4, #"{"type":"message.delta","payload":{"text":" there","turn_id":"t1","segment":0,"offset":5}}"#),
            Self.event(seq: 5, #"{"type":"message.complete","payload":{"text":"Hello there","status":"complete"}}"#),
        ].joined(separator: ",")
        second.reply(to: since, result: #"{"events":[\#(events)],"latest_seq":5,"truncated":false,"count":3,"epoch":"0123456789abcdef0123456789abcdef","open_requests":[]}"#)

        let history = try await second.waitForRequest("session.history")
        second.reply(to: history, result: #"{"count":2,"messages":[{"role":"user","text":"hello","row_id":118},{"role":"assistant","text":"Hello there","row_id":119}]}"#)
        second.reply(to: try await second.waitForRequest("approval.pending"), result: #"{"approvals":[]}"#)
        try await waitFor { !vm.isReplyActive && !vm.isUpdating }

        let replies = vm.messages.filter { $0.role == .assistant }
        #expect(replies.count == 1)
        #expect(replies.first?.id == bubble.id)
        #expect(replies.first?.text == "Hello there")
        #expect(replies.first?.reply == .complete)
        #expect(vm.messages.filter { $0.role == .user }.count == 1)
        #expect(vm.messages.first?.delivery == .delivered)
        // The prompt went out one time, on the first socket only.
        #expect(submits(first, second) == 1)
    }
}

/// A chat transport with a scripted resume snapshot, replay and history. No network.
final class FakeReplayTransport: ChatTransport, @unchecked Sendable {
    let events: AsyncStream<GatewayClientEvent>
    let input: AsyncStream<GatewayClientEvent>.Continuation
    private let lock = NSLock()
    private var _submits: [FakeChatTransport.Submit] = []
    private var _replays: [(String, Int)] = []
    private var _histories = 0
    /// The `running` of the resume snapshot.
    var running: Bool? = true
    /// The replay answer. `nil` throws, as an older server does.
    var replay: SessionEventsSinceResult?
    /// Live events that come while the replay call waits.
    var duringReplay: [GatewayClientEvent] = []
    var transcript: [TranscriptMessage] = []

    init() {
        (events, input) = AsyncStream.makeStream(of: GatewayClientEvent.self)
    }

    var submits: [FakeChatTransport.Submit] { lock.withLock { _submits } }
    var replays: [(String, Int)] { lock.withLock { _replays } }
    var histories: Int { lock.withLock { _histories } }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: "st1")
    }

    func resumeSession(storedId: String, source _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: storedId, running: lock.withLock { running })
    }

    func submitPrompt(sessionId: String, text: String, retryBeforeRowId: Int?) async throws -> Int? {
        lock.withLock { _submits.append(.init(sessionId: sessionId, text: text, retryBeforeRowId: retryBeforeRowId)) }
        return 118
    }

    func stopReply(sessionId _: String) async throws -> Bool { true }

    func history(sessionId _: String) async throws -> [TranscriptMessage] {
        lock.withLock {
            _histories += 1
            return transcript
        }
    }

    func eventsSince(sessionId: String, lastSeen: Int) async throws -> SessionEventsSinceResult {
        let (live, result) = lock.withLock {
            _replays.append((sessionId, lastSeen))
            return (duringReplay, replay)
        }
        for item in live { input.yield(item) }
        if !live.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
        guard let result else { throw ChatReplayError.unsupported }
        return result
    }
}

private func replayEvent(_ json: String) throws -> GatewayEvent {
    try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))
}

private func replayResult(_ events: [GatewayEvent], truncated: Bool = false) -> SessionEventsSinceResult {
    SessionEventsSinceResult(events: events, latestSeq: events.compactMap(\.seq).max() ?? 0, truncated: truncated,
                             count: events.count, epoch: "e1", openRequests: [])
}

/// Issue #145: the reattach paths of the chat view model.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ReattachModelTests {
    private func model(_ transport: FakeReplayTransport) -> ChatViewModel {
        let counter = ReattachCounter()
        return ChatViewModel(transport: transport, redrawInterval: .zero, makeId: { counter.next() })
    }

    private func live(_ json: String) throws -> GatewayClientEvent { .event(try replayEvent(json)) }

    /// A delivered prompt "hello" (row 118) and a partial reply "Hel" with `seq` 1 and 2. Deltas have no `offset`,
    /// so only the `seq` check stops a second copy of the text.
    private func midTurn(_ transport: FakeReplayTransport) async throws -> ChatViewModel {
        let vm = model(transport)
        vm.receive(.state(.connected(GatewayReady(replayEpoch: "e1"))))
        await vm.send("hello")?.value
        vm.receive(try live(#"{"type":"message.start","session_id":"s1","seq":1,"payload":{}}"#))
        vm.receive(try live(#"{"type":"message.delta","session_id":"s1","seq":2,"payload":{"text":"Hel"}}"#))
        vm.receive(.state(.disconnected(.heartbeatTimeout)))
        #expect(vm.isReattaching)
        #expect(vm.messages.last?.reply == .streaming)
        return vm
    }

    @Test func replayAppliesEachEventOneTimeAndLiveEventsWait() async throws {
        let transport = FakeReplayTransport()
        let vm = try await midTurn(transport)
        let bubble = try #require(vm.messages.last?.id)
        let prompt = try #require(vm.messages.first?.id)
        #expect(vm.liveReplyProgress(promptId: prompt) == .streaming("Hel"))
        transport.replay = replayResult([
            try replayEvent(#"{"type":"message.delta","session_id":"s1","seq":2,"payload":{"text":"Hel"}}"#),
            try replayEvent(#"{"type":"message.delta","session_id":"s1","seq":3,"payload":{"text":"lo"}}"#),
        ])
        // seq 4 comes live on the new socket before the replay answer. It must apply after seq 3.
        transport.duringReplay = [try live(#"{"type":"message.delta","session_id":"s1","seq":4,"payload":{"text":" there"}}"#)]
        vm.startEvents()
        await vm.open()
        #expect(transport.replays.map(\.1) == [2])
        #expect(vm.messages.last?.id == bubble)
        #expect(vm.messages.last?.text == "Hello there")
        #expect(vm.isReplyActive)
        #expect(!vm.isReattaching)
        // A live copy of an old event changes nothing.
        vm.receive(try live(#"{"type":"message.delta","session_id":"s1","seq":3,"payload":{"text":"lo"}}"#))
        vm.receive(try live(#"{"type":"message.complete","session_id":"s1","seq":5,"payload":{"text":"Hello there","status":"complete"}}"#))
        #expect(vm.messages.map(\.text) == ["hello", "Hello there"])
        #expect(vm.messages.last?.reply == .complete)
        #expect(vm.liveReplyProgress(promptId: prompt) == .done("Hello there"))
        #expect(transport.submits.count == 1)
        vm.stopEvents()
    }

    @Test func turnThatEndedDuringTheDropShowsTheReplyFromTheHistory() async throws {
        let transport = FakeReplayTransport()
        let vm = try await midTurn(transport)
        let bubble = try #require(vm.messages.last?.id)
        transport.running = false
        transport.replay = nil
        transport.transcript = [TranscriptMessage(role: "user", text: "hello", rowId: 118),
                                TranscriptMessage(role: "assistant", text: "Hello there", rowId: 119)]
        await vm.open()
        #expect(vm.messages.map(\.text) == ["hello", "Hello there"])
        #expect(vm.messages.last?.id == bubble)
        #expect(vm.messages.last?.reply == .complete)
        #expect(vm.messages.first?.delivery == .delivered)
        #expect(!vm.isReplyActive)
        #expect(!vm.isReattaching)
        #expect(transport.submits.count == 1)
    }

    @Test func replayThatEndsTheTurnShowsTheFinalReply() async throws {
        let transport = FakeReplayTransport()
        let vm = try await midTurn(transport)
        transport.running = false
        transport.replay = replayResult([
            try replayEvent(#"{"type":"message.complete","session_id":"s1","seq":3,"payload":{"text":"Hello there","status":"complete"}}"#),
        ])
        transport.transcript = [TranscriptMessage(role: "user", text: "hello", rowId: 118),
                                TranscriptMessage(role: "assistant", text: "Hello there", rowId: 119)]
        await vm.open()
        #expect(vm.messages.map(\.text) == ["hello", "Hello there"])
        #expect(vm.messages.last?.reply == .complete)
        #expect(!vm.isReplyActive)
    }

    @Test func noReplayAndNoReplyShowsNotDeliveredAndTryAgainSendsOneTime() async throws {
        let transport = FakeReplayTransport()
        let vm = try await midTurn(transport)
        let prompt = try #require(vm.messages.first?.id)
        transport.running = false
        transport.replay = nil
        transport.transcript = [TranscriptMessage(role: "user", text: "hello", rowId: 118)]
        await vm.open()
        // "Not Delivered" under the prompt. The partial bubble goes.
        #expect(vm.messages.map(\.role) == [.user])
        #expect(vm.messages.first?.delivery == .failed)
        #expect(!vm.isReplyActive)
        #expect(!vm.isReattaching)
        // Hands-Free shows "Not Delivered" for this turn.
        #expect(vm.liveReplyProgress(promptId: prompt) == .failed)

        await vm.retrySend(id: prompt)?.value
        #expect(transport.submits == [.init(sessionId: "s1", text: "hello", retryBeforeRowId: nil),
                                      .init(sessionId: "s1", text: "hello", retryBeforeRowId: 118)])
        #expect(vm.messages.first?.delivery == .delivered)
    }

    @Test func truncatedReplayOfARunningTurnKeepsTheTurn() async throws {
        let transport = FakeReplayTransport()
        let vm = try await midTurn(transport)
        transport.running = true
        transport.replay = replayResult([
            try replayEvent(#"{"type":"message.delta","session_id":"s1","seq":9,"payload":{"text":"lo"}}"#),
        ], truncated: true)
        await vm.open()
        #expect(vm.messages.last?.text == "Hello")
        #expect(vm.messages.last?.reply == .streaming)
        #expect(vm.isReplyActive)
        #expect(!vm.isReattaching)
        #expect(transport.histories == 1)
    }

    @Test func olderServerWithNoRunningFieldKeepsWaiting() async throws {
        let transport = FakeReplayTransport()
        let vm = try await midTurn(transport)
        transport.running = nil
        transport.replay = nil
        transport.transcript = [TranscriptMessage(role: "user", text: "hello", rowId: 118)]
        await vm.open()
        #expect(vm.messages.last?.reply == .streaming)
        #expect(vm.messages.first?.delivery == .delivered)
        #expect(vm.isReplyActive)
    }

    @Test func newReplayEpochSkipsTheReplay() async throws {
        let transport = FakeReplayTransport()
        let vm = try await midTurn(transport)
        vm.receive(.state(.connected(GatewayReady(replayEpoch: "e2"))))
        await vm.open()
        #expect(transport.replays.isEmpty)
        // The snapshot says that the turn runs: the turn stays.
        #expect(vm.isReplyActive)
        #expect(vm.messages.last?.reply == .streaming)
    }

    @Test func dropWhileThePromptStillSendsIsNotAReattach() async throws {
        let transport = FakeReplayTransport()
        let vm = model(transport)
        vm.receive(.state(.disconnected(.heartbeatTimeout)))
        #expect(!vm.isReattaching)
        #expect(!vm.isReplyActive)
    }
}

private final class ReattachCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> String { lock.withLock { value += 1; return "m\(value)" } }
}
