import Foundation
import Testing
@testable import HermesKit

/// Issue #117: the secret, password and question cards. A fake transport: no network.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct PromptTests {
    static let value = "VALUE-3c9e hunter2"
    static let prompt = "PROMPT-81af Paste the API token for the weather skill"
    static let envVar = "WEATHER_API_KEY"
    static let command = "CMD-77b0 sudo apt-get install ffmpeg"

    private func model(_ transport: FakeApprovalTransport, live: String = "s1") -> ChatViewModel {
        ChatViewModel(transport: transport, session: ChatSessionRef(liveId: live, storedId: "st1"), title: "Plans",
                      redrawInterval: .seconds(60))
    }

    private func request(_ json: String) throws -> GatewayServerRequest {
        let frame = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try GatewayServerRequest(id: .string(try #require(frame["id"]?.stringValue)),
                                        method: try #require(frame["method"]?.stringValue),
                                        params: try #require(frame["params"]))
    }

    private func secret(id: String = "srq-1", session: String = "s1") throws -> GatewayClientEvent {
        .serverRequest(try request(#"""
        {"id":"\#(id)","method":"secret","params":{"session_id":"\#(session)","env_var":"\#(Self.envVar)","prompt":"\#(Self.prompt)","metadata":{"skill":"weather"}}}
        """#))
    }

    private func sudo(id: String = "srq-2") throws -> GatewayClientEvent {
        .serverRequest(try request(#"""
        {"id":"\#(id)","method":"sudo","params":{"session_id":"s1","command":"\#(Self.command)"}}
        """#))
    }

    private func clarify(id: String = "srq-3", answers: String = "null") throws -> GatewayClientEvent {
        .serverRequest(try request(#"""
        {"id":"\#(id)","method":"clarify","params":{"session_id":"s1","questions":[
          {"qid":"q1","question":"Which city?","choices":["Austin","Boston",""],"multi_select":false},
          {"qid":"q2","question":"Which days?","choices":["Mon","Tue","Wed"],"multi_select":true},
          {"qid":"q3","question":"Anything else?"}],"answers":\#(answers)}}
        """#))
    }

    private func event(_ json: String) throws -> GatewayClientEvent {
        .event(try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8)))
    }

    private func card(_ vm: ChatViewModel) -> ChatPromptCard? { vm.messages.compactMap(\.prompt).first }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out")
    }

    @Test func secretShowsACardWithThePromptAndTheEnvVar() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try secret())
        let card = try #require(card(vm))
        #expect(card.title == "Hermes asks for a secret")
        #expect(card.bodyText == Self.prompt)
        #expect(card.detailText == Self.envVar)
        #expect(card.isSecure)
        #expect(card.isWaiting)
        #expect(card.serverRequestId == .string("srq-1"))
        #expect(vm.promptAlertId == vm.messages.first?.id)
        let row = try #require(ChatTimeline.rows(for: vm.messages).first)
        #expect(ChatTimeline.accessibilityLabel(for: row).hasPrefix("Hermes asks for a secret, \(Self.prompt)"))
    }

    @Test func sendAnswersTheValueOnTheRequestIdAndKeepsNoCopy() async throws {
        let transport = FakeApprovalTransport()
        let vm = model(transport)
        vm.receive(try secret())
        let id = try #require(vm.messages.first?.id)
        await vm.answerPrompt(id: id, value: Self.value)?.value
        #expect(transport.values == [.init(id: .string("srq-1"), value: Self.value)])
        #expect(card(vm)?.state == .sent)
        #expect(card(vm)?.resultText == "Sent")
        #expect(!String(describing: vm.messages).contains(Self.value))
        #expect(SessionCache.cacheable(vm.messages).isEmpty)
        // A second Send does nothing: the card is not waiting.
        #expect(vm.answerPrompt(id: id, value: Self.value) == nil)
        #expect(transport.values.count == 1)
    }

    @Test func emptyValueSendsNothing() throws {
        let transport = FakeApprovalTransport()
        let vm = model(transport)
        vm.receive(try secret())
        let id = try #require(vm.messages.first?.id)
        #expect(vm.answerPrompt(id: id, value: "") == nil)
        #expect(card(vm)?.isWaiting == true)
    }

    @Test(arguments: ["secret", "sudo"])
    func cancelAnswersWithAnErrorAndShowsCancelled(method: String) async throws {
        let transport = FakeApprovalTransport()
        let vm = model(transport)
        vm.receive(method == "secret" ? try secret() : try sudo(id: "srq-1"))
        let id = try #require(vm.messages.first?.id)
        await vm.cancelPrompt(id: id)?.value
        #expect(transport.rejects.map(\.0) == [.string("srq-1")])
        #expect(transport.rejects.first?.1 == ChatPromptCard.cancelErrorCode)
        #expect(transport.values.isEmpty)
        #expect(card(vm)?.resultText == "Cancelled")
    }

    @Test func sudoWorksTheSameWay() async throws {
        let transport = FakeApprovalTransport()
        let vm = model(transport)
        vm.receive(try sudo())
        let card = try #require(card(vm))
        #expect(card.title == "Hermes asks for a password")
        #expect(card.detailText == Self.command)
        #expect(card.fieldPlaceholder == "Password")
        let id = try #require(vm.messages.first?.id)
        await vm.answerPrompt(id: id, value: Self.value)?.value
        #expect(transport.values == [.init(id: .string("srq-2"), value: Self.value)])
        #expect(self.card(vm)?.resultText == "Sent")
    }

    @Test func failedSendShowsTheFieldAgainWithNotSent() async throws {
        let transport = FakeApprovalTransport()
        transport.failValue = true
        let vm = model(transport)
        vm.receive(try secret())
        let id = try #require(vm.messages.first?.id)
        await vm.answerPrompt(id: id, value: Self.value)?.value
        #expect(card(vm)?.isWaiting == true)
        #expect(card(vm)?.resultText == "Not sent. Try again.")
        #expect(!String(describing: vm.messages).contains(Self.value))
        transport.failValue = false
        await vm.answerPrompt(id: id, value: Self.value)?.value
        #expect(card(vm)?.resultText == "Sent")
    }

    @Test func clarifySendsEveryAnswerWithMultiSelectAsAJSONList() async throws {
        let transport = FakeApprovalTransport()
        let vm = model(transport)
        vm.receive(try clarify())
        let card = try #require(card(vm))
        #expect(card.title == "Hermes asks a question")
        #expect(!card.isSecure)
        #expect(card.openQuestions.map(\.qid) == ["q1", "q2", "q3"])
        #expect(card.openQuestions[0].choices == ["Austin", "Boston"], "a blank choice is dropped")
        #expect(card.openQuestions[2].multiSelect == false)
        let id = try #require(vm.messages.first?.id)
        // A missing answer sends nothing.
        #expect(vm.answerClarify(id: id, typed: ["q1": "Austin"]) == nil)
        let days = card.openQuestions[1].answer(for: ["Mon", "Wed"])
        #expect(days == #"["Mon","Wed"]"#)
        await vm.answerClarify(id: id, typed: ["q1": "Austin", "q2": days, "q3": " No "])?.value
        #expect(transport.clarifies == [.init(id: .string("srq-3"), answers: ["q1": "Austin", "q2": days, "q3": "No"],
                                              outcome: "submitted")])
        #expect(self.card(vm)?.resultText == "Sent")
    }

    @Test func clarifyReplayKeepsTheLockedAnswers() async throws {
        let transport = FakeApprovalTransport()
        let vm = model(transport)
        vm.receive(try clarify(answers: #"{"q1":"Boston","q2":null}"#))
        let card = try #require(card(vm))
        #expect(card.openQuestions.map(\.qid) == ["q3"])
        let id = try #require(vm.messages.first?.id)
        await vm.answerClarify(id: id, typed: ["q3": "Yes"])?.value
        let expected: [String: String?] = ["q1": "Boston", "q2": nil, "q3": "Yes"]
        #expect(transport.clarifies.first?.answers == expected)
    }

    @Test func clarifyCancelSendsNoAnswers() async throws {
        let transport = FakeApprovalTransport()
        let vm = model(transport)
        vm.receive(try clarify())
        let id = try #require(vm.messages.first?.id)
        await vm.cancelPrompt(id: id)?.value
        #expect(transport.clarifies == [.init(id: .string("srq-3"), answers: nil, outcome: "cancelled")])
        #expect(transport.rejects.isEmpty)
        #expect(card(vm)?.resultText == "Cancelled")
    }

    @Test func requestCancelTimeoutExpiresOtherReasonsRemove() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try secret(id: "srq-1"))
        vm.receive(try sudo(id: "srq-2"))
        vm.receive(try event(#"{"type":"request.cancel","session_id":"s1","payload":{"id":"srq-1","method":"secret","reason":"timeout"}}"#))
        vm.receive(try event(#"{"type":"request.cancel","session_id":"s1","payload":{"id":"srq-2","method":"sudo","reason":"interrupted"}}"#))
        let cards = vm.messages.compactMap(\.prompt)
        #expect(cards.map(\.serverRequestId) == [.string("srq-1")])
        #expect(cards.first?.resultText == "This request expired")
    }

    @Test func sentCardKeepsSentAfterRequestCancel() async throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try secret())
        let id = try #require(vm.messages.first?.id)
        await vm.answerPrompt(id: id, value: Self.value)?.value
        vm.receive(try event(#"{"type":"request.cancel","session_id":"s1","payload":{"id":"srq-1","method":"secret","reason":"resolved"}}"#))
        #expect(card(vm)?.resultText == "Sent")
    }

    @Test func resumeKeepsAnOpenPromptOnceAndExpiresAnEndedOne() async throws {
        let transport = FakeApprovalTransport()
        guard case .serverRequest(let open) = try secret(id: "srq-1", session: "s2") else { return }
        transport.resumeRef = ChatSessionRef(liveId: "s2", storedId: "st1", openRequests: [open])
        let vm = model(transport)
        vm.receive(try secret(id: "srq-1"))
        vm.receive(try sudo(id: "srq-2"))
        vm.receive(.state(.disconnected(.heartbeatTimeout)))
        await vm.open()
        let cards = vm.messages.compactMap(\.prompt)
        #expect(cards.map(\.serverRequestId) == [.string("srq-1"), .string("srq-2")])
        #expect(cards.map(\.state) == [.waiting, .expired])
        #expect(cards.first?.sessionId == "s2")
    }

    @Test func requestOfAnotherSessionShowsNoCard() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try secret(session: "other"))
        #expect(vm.messages.isEmpty)
    }

    @Test func cardTakesNoTapbackOrQuoteAndStaysOutOfTheCache() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try secret())
        let message = try #require(vm.messages.first)
        #expect(message.isLocalCard)
        #expect(SessionCache.cacheable(vm.messages).isEmpty)
        #expect(!QuoteReply.canQuote(message))
        var thread = ChatThread(messages: vm.messages)
        let reacted = thread.react(.heart, id: message.id)
        #expect(!reacted)
        let row = ChatMessage(id: "h1", role: .assistant, text: "Done", date: .distantPast, reply: .complete)
        thread.replaceHistory([row])
        #expect(thread.messages.map(\.id) == ["h1", message.id])
    }

    @Test func logsHaveNoValuePromptEnvVarOrCommand() async throws {
        let capture = LogPrivacyTests.Capture()
        let observer = HermesLog.addObserver { capture.record($0) }
        defer { HermesLog.removeObserver(observer) }
        let transport = FakeApprovalTransport()
        let vm = model(transport)
        vm.receive(try secret(id: "srq-1"))
        vm.receive(try sudo(id: "srq-2"))
        transport.failValue = true
        let ids = vm.messages.map(\.id)
        await vm.answerPrompt(id: ids[0], value: Self.value)?.value
        transport.failValue = false
        await vm.answerPrompt(id: ids[0], value: Self.value)?.value
        await vm.answerPrompt(id: ids[1], value: Self.value)?.value
        #expect(capture.entries.contains { $0.message.hasPrefix("prompt shown") })
        #expect(capture.entries.contains { $0.message.hasPrefix("prompt answer not sent") })
        #expect(capture.leaks(of: [Self.value, Self.prompt, Self.envVar, Self.command]).isEmpty)
    }

    @Test func valueAndClarifyAnswersEncodeAsTheServerExpects() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(ValueAnswer(value: "x")))
        #expect(value == ["value": "x"])
        let answers: [String: String?] = ["q1": "A", "q2": nil]
        let clarify = ClarifyAnswer(answers: answers, outcome: "submitted")
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(clarify))
        let expected: JSONValue = ["answers": ["q1": "A", "q2": JSONValue.null], "outcome": "submitted"]
        #expect(json == expected)
        let cancel = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(
            ClarifyAnswer(answers: nil, outcome: "cancelled")))
        #expect(cancel == ["outcome": "cancelled"])
    }

    @Test func secretWithNoEnvVarOrPromptStillDecodes() throws {
        let request = try request(#"{"id":"r1","method":"secret","params":{"session_id":"s1"}}"#)
        let card = try #require(ChatPromptCard(request: request, sessionId: "s1"))
        #expect(card.detailText == nil)
        #expect(card.bodyText == "Enter the secret.")
    }
}
