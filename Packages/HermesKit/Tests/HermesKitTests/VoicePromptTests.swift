import Foundation
import Testing
@testable import HermesKit

/// Issue #121: a scripted on-device voice. It records each line and gives each `listen()` the next answer.
@MainActor
final class FakePromptVoice: VoicePromptVoice {
    private(set) var lines: [String] = []
    private(set) var listens = 0
    private(set) var stops = 0
    var answers: [VoicePromptHeard] = []

    func speak(_ line: String) async { lines.append(line) }

    func listen() async -> VoicePromptHeard {
        listens += 1
        // A short wait, as a real microphone, so a tap can come first.
        try? await Task.sleep(for: .milliseconds(5))
        return answers.isEmpty ? .nothing : answers.removeFirst()
    }

    func stop() { stops += 1 }
}

@MainActor
final class FakePromptHold: VoicePromptHolding {
    private(set) var holds = 0
    private(set) var releases = 0
    var isHeld: Bool { holds > releases }
    func holdForPrompt() { holds += 1 }
    func releasePrompt() { releases += 1 }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct VoicePromptTests {
    static let value = "VALUE-6b1f hunter2"
    static let command = "CMD-21aa rm -rf /tmp/cache"
    static let envVar = "ENV-90c4 WEATHER_API_KEY"

    private func model(_ transport: FakeApprovalTransport) -> ChatViewModel {
        ChatViewModel(transport: transport, session: ChatSessionRef(liveId: "s1", storedId: "st1"), title: "Plans",
                      redrawInterval: .seconds(60))
    }

    private func request(_ id: String, _ method: String, _ params: JSONValue) throws -> GatewayClientEvent {
        .serverRequest(try GatewayServerRequest(id: .string(id), method: method, params: params))
    }

    private func approval(id: String = "srq-1", choices: [String] = ["once", "deny"]) throws -> GatewayClientEvent {
        try request(id, "approval", .object([
            "session_id": .string("s1"), "request_id": .string("a-\(id)"), "command": .string(Self.command),
            "description": .string("Clear the cache"), "choices": .array(choices.map(JSONValue.string)),
        ]))
    }

    private func clarify(id: String = "srq-2", choices: [String] = ["Work", "Personal"], multi: Bool = false,
                         second: Bool = false) throws -> GatewayClientEvent {
        var questions: [JSONValue] = [.object([
            "qid": .string("q1"), "question": .string("Which calendar?"),
            "choices": .array(choices.map(JSONValue.string)), "multi_select": .bool(multi),
        ])]
        if second { questions.append(.object(["qid": .string("q2"), "question": .string("Any note?")])) }
        return try request(id, "clarify", .object(["session_id": .string("s1"), "questions": .array(questions)]))
    }

    private func secret(id: String = "srq-3") throws -> GatewayClientEvent {
        try request(id, "secret", .object([
            "session_id": .string("s1"), "env_var": .string(Self.envVar), "prompt": .string("Paste the key"),
        ]))
    }

    private func sudo(id: String = "srq-4") throws -> GatewayClientEvent {
        try request(id, "sudo", .object(["session_id": .string("s1"), "command": .string(Self.command)]))
    }

    private struct Rig {
        let transport: FakeApprovalTransport
        let chat: ChatViewModel
        let voice: FakePromptVoice
        let hold: FakePromptHold
        let prompts: VoicePromptCoordinator
    }

    private func rig(_ answers: [VoicePromptHeard] = []) -> Rig {
        let transport = FakeApprovalTransport()
        let chat = model(transport)
        let voice = FakePromptVoice()
        voice.answers = answers
        let hold = FakePromptHold()
        let prompts = VoicePromptCoordinator(voice: voice, resultHold: .milliseconds(20))
        prompts.start(chat: chat, hold: hold)
        return Rig(transport: transport, chat: chat, voice: voice, hold: hold, prompts: prompts)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out: \(what)")
    }

    // MARK: Lines and matches

    @Test func theLinesFollowTheDesignTable() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try approval(choices: ["once", "session", "always", "deny"]))
        vm.receive(try clarify())
        vm.receive(try clarify(id: "srq-5", second: true))
        vm.receive(try secret())
        vm.receive(try sudo())
        let items = vm.waitingPrompts
        #expect(items.count == 5)
        #expect(items.map(VoicePromptSpeech.line) == [
            "Hermes needs your approval. Say allow once, this chat, always, or deny.",
            "Hermes has a question. Which calendar? Say Work, or Personal.",
            "Hermes has a question. Answer on the screen.",
            "Hermes needs a secret. Type it on the screen.",
            "Hermes needs your password. Type it on the screen.",
        ])
        // The offered choices only.
        let small = try #require(model(FakeApprovalTransport()).then { $0.receive(try approval()) }.waitingPrompts.first)
        #expect(VoicePromptSpeech.line(small) == "Hermes needs your approval. Say allow once, or deny.")
        #expect(VoicePromptSpeech.retryLine(small) == "Say allow once, or deny, or tap.")
        // No line holds the command or the env var name.
        for line in items.map(VoicePromptSpeech.line) {
            #expect(!line.contains("CMD-21aa") && !line.contains("ENV-90c4"))
        }
    }

    @Test func spokenApprovalChoicesMatchOnlyOfferedChoices() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try approval(choices: ["once", "session", "always", "deny"]))
        let all = try #require(vm.waitingPrompts.first)
        #expect(VoicePromptSpeech.match("Allow once.", for: all) == .approval(.once))
        #expect(VoicePromptSpeech.match("allow", for: all) == .approval(.once))
        #expect(VoicePromptSpeech.match("For this chat", for: all) == .approval(.session))
        #expect(VoicePromptSpeech.match("Always allow", for: all) == .approval(.always))
        #expect(VoicePromptSpeech.match("No!", for: all) == .approval(.deny))
        #expect(VoicePromptSpeech.match("deny it", for: all) == .approval(.deny))
        #expect(VoicePromptSpeech.match("Stop.", for: all) == .stop)
        #expect(VoicePromptSpeech.match("maybe later", for: all) == nil)
        #expect(VoicePromptSpeech.match("", for: all) == nil)
        let two = try #require(model(FakeApprovalTransport()).then { $0.receive(try approval()) }.waitingPrompts.first)
        #expect(VoicePromptSpeech.match("always", for: two) == nil, "always is not offered")
        #expect(VoicePromptSpeech.match("this chat", for: two) == nil)
    }

    @Test func spokenClarifyChoicesMatchTextOrOrdinal() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try clarify(choices: ["Work", "Work trip", "Personal"]))
        let item = try #require(vm.waitingPrompts.first)
        #expect(item.takesSpokenAnswer)
        #expect(VoicePromptSpeech.match("work trip please", for: item) == .clarify(qid: "q1", choice: "Work trip"))
        #expect(VoicePromptSpeech.match("Personal.", for: item) == .clarify(qid: "q1", choice: "Personal"))
        #expect(VoicePromptSpeech.match("the second", for: item) == .clarify(qid: "q1", choice: "Work trip"))
        #expect(VoicePromptSpeech.match("third", for: item) == .clarify(qid: "q1", choice: "Personal"))
        #expect(VoicePromptSpeech.match("fourth", for: item) == nil)
        #expect(VoicePromptSpeech.match("something else", for: item) == nil)
        // A multi-select question, or two questions: answer on the screen.
        let multi = model(FakeApprovalTransport())
        multi.receive(try clarify(multi: true))
        #expect(multi.waitingPrompts.first?.takesSpokenAnswer == false)
        let two = model(FakeApprovalTransport())
        two.receive(try clarify(second: true))
        #expect(two.waitingPrompts.first?.takesSpokenAnswer == false)
    }

    // MARK: Negation (QA 121-1 defect 1)

    private func allChoices() throws -> VoicePromptItem {
        let vm = model(FakeApprovalTransport())
        vm.receive(try approval(choices: ["once", "session", "always", "deny"]))
        return try #require(vm.waitingPrompts.first)
    }

    @Test(arguments: ["don't allow", "Don’t allow.", "dont allow", "do not allow that", "never allow", "not allow once",
                      "do not always allow", "don't allow this chat", "I won't allow it", "no, allow once",
                      "can't allow", "not now, always", "nope always", "don't deny", "allow once, no deny"])
    func aNegationNeverAllows(_ said: String) throws {
        let item = try allChoices()
        let answer = VoicePromptSpeech.match(said, for: item)
        #expect(answer != .approval(.once) && answer != .approval(.session) && answer != .approval(.always),
                "\"\(said)\" gave \(String(describing: answer))")
    }

    @Test func aNegationWithNoClearDenyGivesNoAnswer() throws {
        let item = try allChoices()
        for said in ["don't allow", "do not allow that", "never allow", "not allow once", "do not always allow"] {
            #expect(VoicePromptSpeech.match(said, for: item) == nil, "\"\(said)\"")
        }
    }

    @Test func clearPhrasesStillMatch() throws {
        let item = try allChoices()
        #expect(VoicePromptSpeech.match("no", for: item) == .approval(.deny))
        #expect(VoicePromptSpeech.match("No.", for: item) == .approval(.deny))
        #expect(VoicePromptSpeech.match("deny", for: item) == .approval(.deny))
        #expect(VoicePromptSpeech.match("no, deny it", for: item) == .approval(.deny))
        #expect(VoicePromptSpeech.match("allow once", for: item) == .approval(.once))
        #expect(VoicePromptSpeech.match("yes allow once", for: item) == .approval(.once))
        #expect(VoicePromptSpeech.match("always allow", for: item) == .approval(.always))
        #expect(VoicePromptSpeech.match("for this chat", for: item) == .approval(.session))
    }

    @Test func aClarifyAnswerWithANegationOrTwoChoicesGivesNoAnswer() throws {
        let vm = model(FakeApprovalTransport())
        vm.receive(try clarify(choices: ["Work", "Personal"]))
        let item = try #require(vm.waitingPrompts.first)
        #expect(VoicePromptSpeech.match("not work", for: item) == nil)
        #expect(VoicePromptSpeech.match("don't pick personal", for: item) == nil)
        #expect(VoicePromptSpeech.match("never the first", for: item) == nil)
        #expect(VoicePromptSpeech.match("work or personal", for: item) == nil)
        #expect(VoicePromptSpeech.match("personal", for: item) == .clarify(qid: "q1", choice: "Personal"))
        // A choice that holds a negation word still matches when the owner says exactly that choice.
        let yesNo = model(FakeApprovalTransport())
        yesNo.receive(try clarify(choices: ["Yes", "No", "Not sure"]))
        let other = try #require(yesNo.waitingPrompts.first)
        #expect(VoicePromptSpeech.match("No.", for: other) == .clarify(qid: "q1", choice: "No"))
        #expect(VoicePromptSpeech.match("not sure", for: other) == .clarify(qid: "q1", choice: "Not sure"))
        #expect(VoicePromptSpeech.match("yes", for: other) == .clarify(qid: "q1", choice: "Yes"))
        #expect(VoicePromptSpeech.match("not yes", for: other) == nil)
    }

    @Test func thePromptOverlayHidesTheToolLine() {
        let loop = VoiceTabDisplay.make(state: .thinking, muted: false, thinkingSeconds: 3, tool: "web_search")
        #expect(loop.showsTool)
        let shown = VoiceTabDisplay.prompt(.listening, over: loop)
        #expect(!shown.showsTool)
        #expect(shown.title == "Hermes needs an answer")
        #expect(shown.subtitle == "Listening")
        #expect(!shown.muteEnabled)
    }

    // MARK: The coordinator

    @Test func aSpokenChoiceAnswersTheApprovalOnTheRequestIdThenTheLoopGoesOn() async throws {
        let r = rig([.text("allow once")])
        r.chat.receive(try approval())
        try await until("card") { r.prompts.item != nil }
        #expect(r.hold.isHeld, "the loop holds while the card waits")
        #expect(r.prompts.shownCount == 1)
        try await until("answer") { r.transport.answers.count == 1 }
        #expect(r.transport.answers == [.init(id: .string("srq-1"), choice: .once)])
        try await until("result") { r.prompts.phase == .done("Allowed once") }
        #expect(r.voice.lines == ["Hermes needs your approval. Say allow once, or deny."]
                || r.voice.lines == ["Hermes needs your approval. Say allow once, or deny.", "Allowed once"])
        try await until("hidden") { r.prompts.item == nil }
        #expect(r.voice.lines.last == "Allowed once", "the voice says the result")
        #expect(!r.hold.isHeld, "the loop goes on after the answer")
        #expect(r.hold.holds == 1 && r.hold.releases == 1)
    }

    @Test func aTapAnswersTooAndStopsTheMicrophone() async throws {
        let r = rig([.nothing, .nothing])
        r.chat.receive(try approval())
        try await until("listening") { r.prompts.phase == .listening }
        let id = try #require(r.prompts.item?.id)
        await r.chat.answerApproval(id: id, choice: .deny)?.value
        try await until("result") { r.prompts.phase == .done("Denied") }
        #expect(r.voice.stops >= 1, "the mic closes at once")
        #expect(r.transport.answers == [.init(id: .string("srq-1"), choice: .deny)])
        try await until("hidden") { r.prompts.item == nil }
        #expect(!r.hold.isHeld)
    }

    @Test func noMatchAsksAgainThenASecondMissWaitsForATap() async throws {
        let r = rig([.text("banana"), .text("pear")])
        r.chat.receive(try approval())
        try await until("waiting") { r.prompts.phase == .waiting && r.voice.listens == 2 }
        #expect(r.voice.lines == ["Hermes needs your approval. Say allow once, or deny.",
                                  "Say allow once, or deny, or tap."])
        #expect(r.transport.answers.isEmpty)
        #expect(r.prompts.item?.isWaiting == true)
        #expect(r.hold.isHeld, "the loop still waits for the tap")
    }

    @Test func stopEndsTheLoop() async throws {
        let r = rig([.text("stop")])
        var stopped = false
        r.prompts.onStop = { stopped = true }
        r.chat.receive(try approval())
        try await until("stop") { stopped }
        #expect(r.transport.answers.isEmpty)
    }

    @Test func aClarifyQuestionTakesASpokenChoice() async throws {
        let r = rig([.text("personal")])
        r.chat.receive(try clarify())
        try await until("answer") { r.transport.clarifies.count == 1 }
        #expect(r.transport.clarifies == [.init(id: .string("srq-2"), answers: ["q1": "Personal"], outcome: "submitted")])
        #expect(r.voice.lines.first == "Hermes has a question. Which calendar? Say Work, or Personal.")
        try await until("result") { r.prompts.phase == .done("Sent") }
    }

    @Test func aClarifyWithTwoQuestionsDoesNotListen() async throws {
        let r = rig([.text("work")])
        r.chat.receive(try clarify(second: true))
        try await until("waiting") { r.prompts.phase == .waiting && !r.voice.lines.isEmpty }
        #expect(r.voice.lines == ["Hermes has a question. Answer on the screen."])
        #expect(r.voice.listens == 0)
    }

    @Test func aSecretNeverListensAndTheValueNeverReachesTheVoice() async throws {
        for event in [try secret(), try sudo()] {
            let r = rig([.text(Self.value)])
            r.chat.receive(event)
            try await until("waiting") { r.prompts.phase == .waiting && !r.voice.lines.isEmpty }
            #expect(r.voice.listens == 0, "the mic stays closed for a secret or a password")
            let id = try #require(r.prompts.item?.id)
            await r.chat.answerPrompt(id: id, value: Self.value)?.value
            try await until("sent") { r.prompts.phase == .done("Sent") }
            try await until("hidden") { r.prompts.item == nil }
            #expect(r.transport.values.map(\.value) == [Self.value])
            #expect(!r.voice.lines.contains { $0.contains("VALUE-6b1f") || $0.contains("hunter2") })
            #expect(!r.voice.lines.contains { $0.contains("CMD-21aa") || $0.contains("ENV-90c4") })
            #expect(!String(describing: r.prompts.item as Any).contains("hunter2"))
            #expect(!r.hold.isHeld)
        }
    }

    @Test func anExpiredCardSaysSoAndTheLoopGoesOn() async throws {
        let r = rig([.nothing, .nothing])
        r.chat.receive(try approval())
        try await until("card") { r.prompts.item != nil }
        // The server withdraws the request (the 300 s timeout).
        r.chat.receive(.event(try JSONDecoder().decode(GatewayEvent.self, from: Data(#"""
        {"type":"request.cancel","session_id":"s1","payload":{"id":"srq-1","method":"approval","reason":"timeout"}}
        """#.utf8))))
        try await until("expired") { r.prompts.phase == .done("The request expired.") || r.prompts.item == nil }
        try await until("hidden") { r.prompts.item == nil }
        #expect(r.voice.lines.last == "The request expired.")
        #expect(!r.hold.isHeld)
    }

    @Test func twoPromptsShowOldestFirst() async throws {
        let r = rig([.text("deny"), .text("work")])
        r.chat.receive(try approval())
        r.chat.receive(try clarify())
        try await until("first") { r.transport.answers.count == 1 }
        try await until("second") { r.transport.clarifies.count == 1 }
        #expect(r.prompts.shownCount == 2)
        try await until("hidden") { r.prompts.item == nil }
        #expect(r.hold.holds == 1 && r.hold.releases == 1, "one hold for both cards")
    }

    @Test func aListenFailureWaitsForATap() async throws {
        let r = rig([.unavailable])
        r.chat.receive(try approval())
        try await until("waiting") { r.prompts.phase == .waiting && r.voice.listens == 1 }
        #expect(r.voice.lines.count == 1)
        #expect(r.prompts.item?.isWaiting == true)
    }

    @Test func stopHidesTheCardAndKeepsItInTheChat() async throws {
        let r = rig([.nothing, .nothing])
        r.chat.receive(try approval())
        try await until("card") { r.prompts.item != nil }
        r.prompts.stop()
        #expect(r.prompts.item == nil)
        #expect(r.chat.waitingPrompts.count == 1)
    }
}

private extension ChatViewModel {
    func then(_ body: (ChatViewModel) throws -> Void) rethrows -> ChatViewModel {
        try body(self)
        return self
    }
}
