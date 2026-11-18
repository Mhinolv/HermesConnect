import Foundation
import Testing
@testable import HermesKit

/// A chat transport with approval calls. No network.
final class FakeApprovalTransport: ChatTransport, ServerRequestTransport, @unchecked Sendable {
    struct Answer: Equatable {
        var id: JSONRPCID
        var choice: ApprovalChoice
    }

    struct Respond: Equatable {
        var sessionId: String
        var choice: ApprovalChoice
        var requestId: String?
    }

    let events: AsyncStream<GatewayClientEvent>
    let input: AsyncStream<GatewayClientEvent>.Continuation
    private let lock = NSLock()
    private var _answers: [Answer] = []
    private var _responds: [Respond] = []
    private var _acks: [String] = []
    private var _rejects: [(JSONRPCID, Int)] = []
    var failAnswer = false
    var failRespond = false
    var resolved = 1
    var resumeRef = ChatSessionRef(liveId: "s2", storedId: "st1")
    var pending: [ApprovalRequest] = []
    var transcript: [TranscriptMessage] = []

    init() {
        (events, input) = AsyncStream.makeStream(of: GatewayClientEvent.self)
    }

    var answers: [Answer] { lock.withLock { _answers } }
    var responds: [Respond] { lock.withLock { _responds } }
    var acks: [String] { lock.withLock { _acks } }
    var rejects: [(JSONRPCID, Int)] { lock.withLock { _rejects } }

    struct Failure: Error {}

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: "st1")
    }

    func resumeSession(storedId _: String, source _: String) async throws -> ChatSessionRef {
        lock.withLock { resumeRef }
    }

    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? { 1 }
    func stopReply(sessionId _: String) async throws -> Bool { true }
    func history(sessionId _: String) async throws -> [TranscriptMessage] { lock.withLock { transcript } }

    func answerApproval(requestId: JSONRPCID, choice: ApprovalChoice) async throws {
        lock.withLock { _answers.append(Answer(id: requestId, choice: choice)) }
        if lock.withLock({ failAnswer }) { throw Failure() }
    }

    func rejectServerRequest(_ id: JSONRPCID, code: Int, message _: String) async throws {
        lock.withLock { _rejects.append((id, code)) }
    }

    func respondApproval(sessionId: String, choice: ApprovalChoice, requestId: String?) async throws -> Int {
        lock.withLock { _responds.append(Respond(sessionId: sessionId, choice: choice, requestId: requestId)) }
        if lock.withLock({ failRespond }) { throw Failure() }
        return lock.withLock { resolved }
    }

    func acknowledgeApproval(sessionId _: String, requestId: String) async throws {
        lock.withLock { _acks.append(requestId) }
    }

    func pendingApprovals(sessionId _: String) async throws -> [ApprovalRequest] { lock.withLock { pending } }

    struct ValueSent: Equatable {
        var id: JSONRPCID
        var value: String
    }

    struct ClarifySent: Equatable {
        var id: JSONRPCID
        var answers: [String: String?]?
        var outcome: String
    }

    private var _values: [ValueSent] = []
    private var _clarifies: [ClarifySent] = []
    var failValue = false
    var values: [ValueSent] { lock.withLock { _values } }
    var clarifies: [ClarifySent] { lock.withLock { _clarifies } }

    func answerValue(requestId: JSONRPCID, value: String) async throws {
        lock.withLock { _values.append(ValueSent(id: requestId, value: value)) }
        if lock.withLock({ failValue }) { throw Failure() }
    }

    func answerClarify(requestId: JSONRPCID, answers: [String: String?]?, outcome: String) async throws {
        lock.withLock { _clarifies.append(ClarifySent(id: requestId, answers: answers, outcome: outcome)) }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ApprovalTests {
    static let command = "CMD-5d1e gcal events update --id 42"

    private func model(_ transport: FakeApprovalTransport, live: String = "s1") -> ChatViewModel {
        ChatViewModel(transport: transport, session: ChatSessionRef(liveId: live, storedId: "st1"), title: "Plans",
                      redrawInterval: .seconds(60))
    }

    private func approval(id: String = "srq-1", session: String = "s1", requestId: String = "a1",
                          choices: [String] = ["once", "session", "always", "deny"]) throws -> GatewayClientEvent {
        let params: JSONValue = .object([
            "session_id": .string(session), "request_id": .string(requestId), "command": .string(Self.command),
            "description": .string("Update a calendar event"), "choices": .array(choices.map(JSONValue.string)),
        ])
        return .serverRequest(try GatewayServerRequest(id: .string(id), method: "approval", params: params))
    }

    private func event(_ json: String) throws -> GatewayClientEvent {
        .event(try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8)))
    }

    private func card(_ vm: ChatViewModel) -> ChatApprovalCard? { vm.messages.compactMap(\.approval).first }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FakeTimeout(what: "condition")
    }

    @Test func cardShowsDescriptionAndServerChoicesWithDenyLast() async throws {
        let transport = FakeApprovalTransport()
        let vm = model(transport)
        var alerts: [ApprovalAlert] = []
        vm.onApprovalRequest = { alerts.append($0) }
        vm.receive(try approval(choices: ["deny", "once", "session"]))
        let shown = try #require(card(vm))
        #expect(ChatApprovalCard.title == "Hermes asks for approval")
        #expect(shown.bodyText == "Update a calendar event")
        #expect(shown.commandText == Self.command)
        #expect(shown.choices == [.once, .session, .deny])
        #expect(shown.choices.map(ChatApprovalCard.buttonTitle) == ["Allow Once", "Allow for This Chat", "Deny"])
        #expect(vm.hasWaitingApproval)
        #expect(vm.approvalAlert != nil)
        #expect(alerts.map(\.storedSessionId) == ["st1"])
        #expect(alerts.first?.title == "Plans")
        try await waitUntil { transport.acks == ["a1"] }
    }

    @Test func requestOfAnotherSessionShowsNoCard() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try approval(session: "other"))
        #expect(vm.messages.isEmpty)
    }

    @Test func tapSendsTheChoiceOnTheRequestIdAndShowsTheResult() async throws {
        let transport = FakeApprovalTransport()
        let vm = model(transport)
        vm.receive(try approval())
        let id = try #require(vm.messages.first?.id)
        #expect(vm.answerApproval(id: id, choice: .always) != nil)
        #expect(card(vm)?.resultText == "Sending…")
        try await waitUntil { card(vm)?.state == .answered(.always) }
        #expect(transport.answers == [.init(id: .string("srq-1"), choice: .always)])
        #expect(transport.responds.isEmpty)
        #expect(card(vm)?.resultText == "Always allowed")
        #expect(!vm.hasWaitingApproval)
        // A second tap does nothing.
        #expect(vm.answerApproval(id: id, choice: .deny) == nil)
    }

    @Test func choiceThatTheServerDidNotOfferIsRefused() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try approval(choices: ["once", "deny"]))
        let id = try #require(vm.messages.first?.id)
        #expect(vm.answerApproval(id: id, choice: .always) == nil)
        #expect(card(vm)?.state == .waiting)
    }

    @Test func failedAnswerFallsBackToApprovalRespond() async throws {
        let transport = FakeApprovalTransport()
        transport.failAnswer = true
        let vm = model(transport)
        vm.receive(try approval())
        let id = try #require(vm.messages.first?.id)
        await vm.answerApproval(id: id, choice: .once)?.value
        #expect(transport.responds == [.init(sessionId: "s1", choice: .once, requestId: "a1")])
        #expect(card(vm)?.resultText == "Allowed once")
    }

    @Test func answerThatCannotGoShowsTheButtonsAgain() async throws {
        let transport = FakeApprovalTransport()
        transport.failAnswer = true
        transport.failRespond = true
        let vm = model(transport)
        vm.receive(try approval())
        let id = try #require(vm.messages.first?.id)
        await vm.answerApproval(id: id, choice: .once)?.value
        #expect(card(vm)?.state == .waiting)
    }

    @Test func respondThatResolvesNothingShowsExpired() async throws {
        let transport = FakeApprovalTransport()
        transport.resolved = 0
        transport.resumeRef = ChatSessionRef(liveId: "s2", storedId: "st1", openRequests: [],
                                             pendingApproval: ApprovalRequest(sessionId: "s2", requestId: "a7"))
        let vm = ChatViewModel(transport: transport, storedSessionId: "st1", redrawInterval: .seconds(60))
        await vm.open()
        let id = try #require(vm.messages.first { $0.approval != nil }?.id)
        await vm.answerApproval(id: id, choice: .deny)?.value
        #expect(transport.responds == [.init(sessionId: "s2", choice: .deny, requestId: "a7")])
        #expect(card(vm)?.resultText == "This request expired")
    }

    @Test func openShowsOpenRequestsAndPendingApprovalOnce() async throws {
        let transport = FakeApprovalTransport()
        let open = try GatewayServerRequest(id: .string("srq-9"), method: "approval", params: .object([
            "session_id": .string("s2"), "request_id": .string("a1"), "command": .string(Self.command),
            "choices": .array([.string("once"), .string("deny")]),
        ]))
        let clarify = try GatewayServerRequest(id: .string("srq-10"), method: "clarify",
                                               params: .object(["session_id": .string("s2"), "questions": .array([])]))
        transport.resumeRef = ChatSessionRef(liveId: "s2", storedId: "st1", openRequests: [open, clarify],
                                             pendingApproval: ApprovalRequest(sessionId: "s2", requestId: "a1",
                                                                              command: Self.command))
        transport.pending = [ApprovalRequest(sessionId: "s2", requestId: "a1"),
                             ApprovalRequest(sessionId: "s2", requestId: "a2", description: "Send mail")]
        let vm = ChatViewModel(transport: transport, storedSessionId: "st1", redrawInterval: .seconds(60))
        var alerts = 0
        vm.onApprovalRequest = { _ in alerts += 1 }
        await vm.open()
        let cards = vm.messages.compactMap(\.approval)
        #expect(cards.map(\.requestId) == ["a1", "a2"])
        #expect(cards.first?.serverRequestId == .string("srq-9"))
        #expect(cards.last?.serverRequestId == nil)
        #expect(alerts == 0, "a replay posts no notification")
        // Issue #117: a clarify with no question that the owner can answer ends at once with no answers.
        try await waitUntil { !transport.clarifies.isEmpty }
        #expect(transport.clarifies == [.init(id: .string("srq-10"), answers: nil, outcome: "submitted")])
        #expect(transport.rejects.isEmpty)

        let second = try #require(vm.messages.first { $0.approval?.requestId == "a2" }?.id)
        await vm.answerApproval(id: second, choice: .once)?.value
        #expect(transport.responds == [.init(sessionId: "s2", choice: .once, requestId: "a2")])
    }

    @Test func replayOfTheSameRequestUpdatesTheCard() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try approval(id: "srq-1"))
        vm.receive(try approval(id: "srq-2"))
        #expect(vm.messages.count == 1)
        #expect(card(vm)?.serverRequestId == .string("srq-2"))
    }

    @Test func resumeExpiresACardThatTheServerNoLongerLists() async throws {
        let transport = FakeApprovalTransport()
        transport.resumeRef = ChatSessionRef(liveId: "s1", storedId: "st1", openRequests: [])
        let vm = model(transport)
        vm.receive(try approval())
        vm.receive(.state(.disconnected(.heartbeatTimeout)))
        await vm.open()
        #expect(card(vm)?.state == .expired)
    }

    @Test func requestCancelTimeoutExpiresOtherReasonsRemove() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try approval(id: "srq-1", requestId: "a1"))
        vm.receive(try approval(id: "srq-2", requestId: "a2"))
        vm.receive(try event(#"{"type":"request.cancel","session_id":"s1","payload":{"id":"srq-1","method":"approval","reason":"timeout"}}"#))
        vm.receive(try event(#"{"type":"request.cancel","session_id":"s1","payload":{"id":"srq-2","method":"approval","reason":"resolved"}}"#))
        let cards = vm.messages.compactMap(\.approval)
        #expect(cards.map(\.requestId) == ["a1"])
        #expect(cards.first?.resultText == "This request expired")
        #expect(!vm.hasWaitingApproval)
    }

    @Test func answeredCardKeepsItsResultAfterRequestCancel() async throws {
        let transport = FakeApprovalTransport()
        let vm = model(transport)
        vm.receive(try approval())
        let id = try #require(vm.messages.first?.id)
        await vm.answerApproval(id: id, choice: .once)?.value
        vm.receive(try event(#"{"type":"request.cancel","session_id":"s1","payload":{"id":"srq-1","method":"approval","reason":"resolved"}}"#))
        #expect(card(vm)?.resultText == "Allowed once")
    }

    @Test func approvalCancelledShowsDenied() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try approval(id: "srq-1", requestId: "a1"))
        vm.receive(try approval(id: "srq-2", requestId: "a2"))
        vm.receive(try event(#"{"type":"approval.cancelled","session_id":"s1","payload":{"session_id":"s1","stored_session_id":"st1","reason":"interrupted","cancelled_count":1,"request_ids":["a2"]}}"#))
        let cards = vm.messages.compactMap(\.approval)
        #expect(cards.map(\.state) == [.waiting, .cancelled])
        #expect(cards.last?.resultText == "Denied")
    }

    @Test func cardStaysOutOfTheCacheAndKeepsItsPlaceInAHistoryMerge() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try approval())
        #expect(SessionCache.cacheable(vm.messages).isEmpty)
        var thread = ChatThread(messages: vm.messages)
        let row = ChatMessage(id: "h1", role: .assistant, text: "Done", date: .distantPast, reply: .complete)
        thread.replaceHistory([row])
        #expect(thread.messages.map(\.id) == ["h1", vm.messages[0].id])
        #expect(!QuoteReply.canQuote(vm.messages[0]))
        let reacted = thread.react(.heart, id: vm.messages[0].id)
        #expect(!reacted)
    }

    @Test func approvalLogsHaveNoCommandText() async throws {
        let capture = LogPrivacyTests.Capture()
        let observer = HermesLog.addObserver { capture.record($0) }
        defer { HermesLog.removeObserver(observer) }
        let transport = FakeApprovalTransport()
        let vm = model(transport)
        vm.receive(try approval())
        let id = try #require(vm.messages.first?.id)
        await vm.answerApproval(id: id, choice: .once)?.value
        vm.receive(.serverRequest(try GatewayServerRequest(id: .string("srq-4"), method: "sudo", params: .object([
            "session_id": .string("s1"), "command": .string(Self.command),
        ]))))
        #expect(capture.entries.contains { $0.message.hasPrefix("approval shown") })
        #expect(capture.leaks(of: [Self.command, "Update a calendar event"]).isEmpty)
    }

    @Test func accessibilityLabelReadsTitleThenDescription() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try approval())
        let row = try #require(ChatTimeline.rows(for: vm.messages).first)
        #expect(ChatTimeline.accessibilityLabel(for: row).hasPrefix("Hermes asks for approval, Update a calendar event"))
    }
}
