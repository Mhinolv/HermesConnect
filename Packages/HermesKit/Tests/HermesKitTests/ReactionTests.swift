import Foundation
import Testing
@testable import HermesKit

private let base = Date(timeIntervalSince1970: 1_763_290_000)

private func complete(_ json: String) throws -> GatewayEvent.Kind {
    .messageComplete(try JSONDecoder().decode(MessageCompletePayload.self, from: Data(json.utf8)))
}

private func delta(_ text: String) -> GatewayEvent.Kind {
    .messageDelta(MessageDeltaPayload(text: text, turnId: "t1", segment: nil, offset: nil))
}

private func errorEvent() throws -> GatewayEvent.Kind {
    .error(try JSONDecoder().decode(GatewayErrorPayload.self, from: Data(#"{"message":"boom"}"#.utf8)))
}

private final class Ids: @unchecked Sendable {
    private var value = 0
    func callAsFunction() -> String {
        value += 1
        return "r\(value)"
    }
}

/// Issue #11: agent acks from the turn state (D3) and owner tapbacks on the phone.
@Suite struct AgentAckTests {
    /// A prompt that went out and was accepted. Returns the thread with the turn running.
    private func delivered(_ text: String) -> (ChatThread, Ids) {
        var thread = ChatThread()
        thread.addOutgoing(id: "p1", text: text, date: base)
        thread.beginTurn(promptId: "p1")
        thread.setDelivery(.delivered, id: "p1", userRowId: 7)
        return (thread, Ids())
    }

    private func ack(_ thread: ChatThread) -> AgentAck? { thread.message(id: "p1")?.agentAck }

    @Test func noAckWhileThePromptSends() {
        var thread = ChatThread()
        thread.addOutgoing(id: "p1", text: "hello", date: base)
        thread.beginTurn(promptId: "p1")
        #expect(thread.message(id: "p1")?.agentAck == nil)
    }

    @Test func eyesWhileTheTurnRunsThenThumbsUpOnComplete() throws {
        var (thread, ids) = delivered("What is on my calendar?")
        #expect(ack(thread) == .seen)
        thread.apply(.messageStart(MessageStartPayload()), now: base, makeId: ids.callAsFunction)
        #expect(ack(thread) == .seen)
        let tool = try JSONDecoder().decode(ToolStartPayload.self, from: Data(#"{"tool_id":"c1","name":"calendar"}"#.utf8))
        thread.apply(.toolStart(tool), now: base, makeId: ids.callAsFunction)
        thread.apply(delta("Two meetings."), now: base, makeId: ids.callAsFunction)
        #expect(ack(thread) == .seen)
        thread.apply(try complete(#"{"text":"Two meetings.","status":"complete"}"#), now: base,
                     makeId: ids.callAsFunction)
        #expect(ack(thread) == .done)
        // The reply never gets an agent ack.
        #expect(thread.messages.last?.agentAck == nil)
    }

    @Test func messageStartBeforeTheSubmitAnswerShowsEyes() {
        var thread = ChatThread()
        let ids = Ids()
        thread.addOutgoing(id: "p1", text: "hello", date: base)
        thread.beginTurn(promptId: "p1")
        thread.apply(.messageStart(MessageStartPayload()), now: base, makeId: ids.callAsFunction)
        #expect(thread.message(id: "p1")?.agentAck == .seen)
    }

    @Test func errorShowsThumbsDown() throws {
        var (thread, ids) = delivered("Check the logs")
        thread.apply(.messageStart(MessageStartPayload()), now: base, makeId: ids.callAsFunction)
        thread.apply(try errorEvent(), now: base, makeId: ids.callAsFunction)
        #expect(ack(thread) == .failed)
    }

    @Test func completeWithErrorStatusShowsThumbsDown() throws {
        var (thread, ids) = delivered("Check the logs")
        thread.apply(try complete(#"{"status":"error","error":"model down"}"#), now: base, makeId: ids.callAsFunction)
        #expect(ack(thread) == .failed)
    }

    @Test func droppedConnectionShowsThumbsDown() {
        var (thread, ids) = delivered("Check the logs")
        thread.apply(.messageStart(MessageStartPayload()), now: base, makeId: ids.callAsFunction)
        thread.connectionLost(now: base, makeId: ids.callAsFunction)
        #expect(ack(thread) == .failed)
    }

    @Test func stoppedTurnShowsNoAck() throws {
        var (thread, ids) = delivered("Write a long essay")
        thread.apply(delta("Once"), now: base, makeId: ids.callAsFunction)
        thread.apply(try complete(#"{"text":"Once","status":"interrupted"}"#), now: base, makeId: ids.callAsFunction)
        #expect(ack(thread) == nil)
    }

    @Test func thanksShowsAHeart() throws {
        for text in ["Thanks!", "thank you so much", "Perfect, thx", "ty", "Much appreciated."] {
            var (thread, ids) = delivered(text)
            thread.apply(try complete(#"{"text":"You're welcome.","status":"complete"}"#), now: base,
                         makeId: ids.callAsFunction)
            #expect(ack(thread) == .thanks, "\(text)")
        }
    }

    @Test func thanksWithAnErrorStillShowsThumbsDown() throws {
        var (thread, ids) = delivered("thanks")
        thread.apply(try errorEvent(), now: base, makeId: ids.callAsFunction)
        #expect(ack(thread) == .failed)
    }

    @Test func slashCommandsNeverShowAnAck() throws {
        for text in ["/model gpt", "  /help", "/thanks"] {
            var (thread, ids) = delivered(text)
            #expect(ack(thread) == nil, "\(text)")
            thread.apply(.messageStart(MessageStartPayload()), now: base, makeId: ids.callAsFunction)
            #expect(ack(thread) == nil, "\(text)")
            thread.apply(try complete(#"{"text":"ok","status":"complete"}"#), now: base, makeId: ids.callAsFunction)
            #expect(ack(thread) == nil, "\(text)")
        }
        var (thread, ids) = delivered("/compress")
        thread.apply(try errorEvent(), now: base, makeId: ids.callAsFunction)
        #expect(ack(thread) == nil)
    }

    @Test func failedSubmitClearsTheAck() {
        var thread = ChatThread()
        let ids = Ids()
        thread.addOutgoing(id: "p1", text: "hello", date: base)
        thread.beginTurn(promptId: "p1")
        thread.apply(.messageStart(MessageStartPayload()), now: base, makeId: ids.callAsFunction)
        thread.setDelivery(.failed, id: "p1")
        thread.cancelWaiting()
        #expect(thread.message(id: "p1")?.agentAck == nil)
    }

    @Test func aBackgroundTurnDoesNotAckTheLastPrompt() throws {
        var (thread, ids) = delivered("hello")
        thread.apply(try complete(#"{"text":"Hi","status":"complete"}"#), now: base, makeId: ids.callAsFunction)
        #expect(ack(thread) == .done)
        // A cron delivery: a turn with no prompt from the phone.
        thread.apply(.messageStart(MessageStartPayload()), now: base, makeId: ids.callAsFunction)
        thread.apply(try errorEvent(), now: base, makeId: ids.callAsFunction)
        #expect(ack(thread) == .done)
    }

    @Test func aRetriedPromptGoesBackToEyes() throws {
        var (thread, ids) = delivered("hello")
        thread.apply(try errorEvent(), now: base, makeId: ids.callAsFunction)
        #expect(ack(thread) == .failed)
        thread.beginTurn(promptId: "p1")
        thread.setDelivery(.delivered, id: "p1")
        #expect(ack(thread) == .seen)
    }

    @Test func rules() {
        #expect(AgentAckRules.isSlashCommand("/help"))
        #expect(AgentAckRules.isSlashCommand("\n /model"))
        #expect(!AgentAckRules.isSlashCommand("a/b"))
        #expect(!AgentAckRules.isSlashCommand(""))
        #expect(AgentAckRules.isThanks("Thank you!"))
        #expect(AgentAckRules.isThanks("THANKS a lot"))
        #expect(AgentAckRules.isThanks("tysm"))
        #expect(!AgentAckRules.isThanks("No thanks, cancel it"))
        #expect(!AgentAckRules.isThanks("Type the command"))
        #expect(!AgentAckRules.isThanks("What is the thankfulness index?"))
    }

    @Test func symbolsMatchTheDesignNotes() {
        #expect(AgentAck.seen.symbolName == "eyes")
        #expect(AgentAck.done.symbolName == "hand.thumbsup.fill")
        #expect(AgentAck.failed.symbolName == "hand.thumbsdown.fill")
        #expect(AgentAck.thanks.symbolName == "heart.fill")
        #expect(Tapback.allCases.map(\.symbolName) == ["heart.fill", "hand.thumbsup.fill", "hand.thumbsdown.fill",
                                                      "face.smiling", "exclamationmark.2", "questionmark"])
        #expect(Tapback.allCases.map(\.title) == ["Heart", "Thumbs Up", "Thumbs Down", "Ha Ha", "Exclamation",
                                                 "Question"])
    }
}

@Suite struct TapbackTests {
    private func thread() -> ChatThread {
        ChatThread(messages: [
            ChatMessage(id: "u1", role: .user, text: "Hi", date: base, delivery: .delivered, userRowId: 1),
            ChatMessage(id: "a1", role: .assistant, text: "Hello", date: base, reply: .complete, promptId: "u1"),
        ])
    }

    @Test func oneTapbackPerMessageAndASecondTapRemovesIt() {
        var thread = thread()
        do { let changed = thread.react(.heart, id: "a1"); #expect(changed) }
        #expect(thread.message(id: "a1")?.tapback == .heart)
        do { let changed = thread.react(.haha, id: "a1"); #expect(changed) }
        #expect(thread.message(id: "a1")?.tapback == .haha)
        do { let changed = thread.react(.haha, id: "a1"); #expect(changed) }
        #expect(thread.message(id: "a1")?.tapback == nil)
        do { let changed = thread.react(.question, id: "u1"); #expect(changed) }
        #expect(thread.message(id: "u1")?.tapback == .question)
        do { let changed = thread.removeTapback(id: "u1"); #expect(changed) }
        #expect(thread.message(id: "u1")?.tapback == nil)
        do { let changed = thread.removeTapback(id: "u1"); #expect(!changed) }
        do { let changed = thread.react(.heart, id: "missing"); #expect(!changed) }
    }

    @Test func noTapbackOnABubbleInProgress() {
        var thread = ChatThread()
        thread.addOutgoing(id: "p1", text: "hello", date: base)
        do { let changed = thread.react(.heart, id: "p1"); #expect(!changed) }
        #expect(thread.message(id: "p1")?.tapback == nil)
    }

    @Test func historyMergeKeepsTapbacksAndAcks() {
        var messages = thread().messages
        messages[0].agentAck = .done
        messages[0].tapback = .exclamation
        messages[1].tapback = .heart
        let transcript = [
            TranscriptMessage(role: "user", text: "Hi", rowId: 1),
            TranscriptMessage(role: "assistant", text: "Hello", rowId: 2),
        ]
        let merged = ChatHistory.messages(from: transcript, reusing: messages, fallbackDate: base)
        #expect(merged.map(\.id) == ["u1", "a1"])
        #expect(merged[0].agentAck == .done)
        #expect(merged[0].tapback == .exclamation)
        #expect(merged[1].tapback == .heart)

        // A second merge keeps the reactions of rows that took a history id.
        var fromHistory = ChatHistory.messages(from: transcript, fallbackDate: base)
        fromHistory[1].tapback = .thumbsUp
        let again = ChatHistory.messages(from: transcript, reusing: fromHistory, fallbackDate: base)
        #expect(again[1].id == fromHistory[1].id)
        #expect(again[1].tapback == .thumbsUp)
    }

    @Test func accessibilityLabelsNameTheReactions() {
        var message = ChatMessage(id: "u1", role: .user, text: "Thanks", date: base, delivery: .delivered)
        message.agentAck = .thanks
        message.tapback = .thumbsUp
        let row = ChatTimeline.rows(for: [message])[0]
        let label = ChatTimeline.accessibilityLabel(for: row)
        #expect(label.contains("Thanks, Hermes reacted heart, You reacted thumbs up, "))
        #expect(ChatTimeline.reactionLabels(for: row) == ["Hermes reacted heart", "You reacted thumbs up"])
    }

    @Test func onlyTheFirstPartOfAMessageShowsTheReactions() {
        let photo = ChatAttachment(id: "x1", kind: .photo, name: "IMG_1.jpg", byteCount: 10,
                                   fileURL: URL(fileURLWithPath: "/tmp/IMG_1.jpg"), mimeType: "image/jpeg")
        var message = ChatMessage(id: "u1", role: .user, text: "Look", date: base, delivery: .delivered,
                                  attachments: [photo])
        message.agentAck = .done
        let parts = ChatBubbleParts.parts(for: ChatTimeline.rows(for: [message]))
        #expect(parts.map(\.row.showsReactions) == [true, false])
        #expect(ChatBubbleParts.accessibilityLabel(for: parts[0]).contains("Hermes reacted thumbs up"))
        #expect(!ChatBubbleParts.accessibilityLabel(for: parts[1]).contains("reacted"))
    }
}

@Suite struct ReactionCacheTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ReactionCacheTests-\(UUID().uuidString)",
                                                         directoryHint: .isDirectory)
    }

    @Test func tapbacksAndAcksSurviveARelaunch() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var messages = [
            ChatMessage(id: "u1", role: .user, text: "Thanks", date: base, delivery: .delivered, userRowId: 1),
            ChatMessage(id: "a1", role: .assistant, text: "Any time", date: base, reply: .complete, promptId: "u1"),
            ChatMessage(id: "u2", role: .user, text: "/help", date: base, delivery: .delivered, userRowId: 3),
        ]
        messages[0].agentAck = .thanks
        messages[0].tapback = .haha
        messages[1].tapback = .heart
        FileSessionCacheStore(directory: directory).saveTranscript(messages, sessionId: "k1")
        let loaded = FileSessionCacheStore(directory: directory).loadTranscript(sessionId: "k1")
        #expect(loaded == messages)
    }

    @Test func eyesOfARunningTurnDoNotComeBackAfterARelaunch() {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var message = ChatMessage(id: "u1", role: .user, text: "Hi", date: base, delivery: .delivered)
        message.agentAck = .seen
        FileSessionCacheStore(directory: directory).saveTranscript([message], sessionId: "k1")
        let loaded = FileSessionCacheStore(directory: directory).loadTranscript(sessionId: "k1")
        #expect(loaded.first?.agentAck == nil)
    }

    @Test func filesFromBeforeTapbacksStillLoad() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionCacheStore(directory: directory)
        try FileManager.default.createDirectory(at: store.transcriptURL(sessionId: "k1").deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // A version 2 file (issue #10) has no reaction keys. A later build may write values this build lacks.
        try Data(#"""
        {"version":2,"body":[
          {"id":"m1","role":"user","text":"Hi","date":1763290000,"interrupted":false,"notDelivered":false},
          {"id":"m2","role":"assistant","text":"Hello","date":1763290001,"promptId":"m1","interrupted":false,
           "notDelivered":false},
          {"id":"m3","role":"user","text":"Ok","date":1763290002,"ack":"sparkles","tapback":"wave"},
          {"id":"m4","role":"assistant","text":"Done","date":1763290003,"tapback":7}
        ]}
        """#.utf8).write(to: store.transcriptURL(sessionId: "k1"))
        let messages = store.loadTranscript(sessionId: "k1")
        #expect(messages.map(\.id) == ["m1", "m2", "m3", "m4"])
        #expect(messages.allSatisfy { $0.agentAck == nil && $0.tapback == nil })
        #expect(messages[0].delivery == .delivered)
        #expect(messages[1].reply == .complete)
    }

    @Test func formatVersionIsThree() {
        #expect(SessionCache.formatVersion == 3)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct TapbackViewModelTests {
    @Test func reactSavesToTheCacheAndANewModelShowsIt() {
        let cache = InMemorySessionCacheStore(transcripts: ["k1": [
            ChatMessage(id: "u1", role: .user, text: "Hi", date: base, delivery: .delivered, userRowId: 1),
            ChatMessage(id: "a1", role: .assistant, text: "Hello", date: base, reply: .complete, promptId: "u1"),
        ]])
        let vm = ChatViewModel(transport: FakeChatTransport(), storedSessionId: "k1", cache: cache)
        vm.react(.thumbsUp, id: "a1")
        #expect(vm.messages.first { $0.id == "a1" }?.tapback == .thumbsUp)
        #expect(cache.loadTranscript(sessionId: "k1").first { $0.id == "a1" }?.tapback == .thumbsUp)

        let relaunched = ChatViewModel(transport: FakeChatTransport(), storedSessionId: "k1", cache: cache)
        #expect(relaunched.messages.first { $0.id == "a1" }?.tapback == .thumbsUp)
        relaunched.react(.thumbsUp, id: "a1")
        #expect(relaunched.messages.first { $0.id == "a1" }?.tapback == nil)
        relaunched.react(.heart, id: "u1")
        relaunched.react(nil, id: "u1")
        #expect(cache.loadTranscript(sessionId: "k1").allSatisfy { $0.tapback == nil })
    }

    @Test func aSentPromptGetsEyesThenThumbsUp() async throws {
        let transport = FakeChatTransport()
        let vm = ChatViewModel(transport: transport, makeId: { UUID().uuidString })
        await vm.send("hello")?.value
        #expect(vm.messages.first?.agentAck == .seen)
        let json = #"{"type":"message.complete","session_id":"s1","payload":{"text":"Hi","status":"complete"}}"#
        vm.receive(.event(try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))))
        #expect(vm.messages.first?.agentAck == .done)
    }
}
