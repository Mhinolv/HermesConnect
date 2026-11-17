import Foundation
import Testing
@testable import HermesKit

/// Issue #45: the spoken text of one reply.
@Suite struct SiriSpeechTests {
    @Test func markdownBecomesPlainText() {
        let spoken = SiriSpeech.spokenText("# Plan\n**Buy** milk and _eggs_.\n- One\n- Two\n> Quoted line")
        #expect(spoken == SiriSpokenText(text: "Plan. Buy milk and eggs. One. Two. Quoted line.", isComplete: true))
        #expect(!spoken.text.contains("*"))
        #expect(!spoken.text.contains("#"))
    }

    @Test func bareURLsAndURLLabelsAreALink() {
        #expect(SiriSpeech.spokenText("See https://example.com/a?b=1.").text == "See a link.")
        #expect(SiriSpeech.spokenText("Open www.apple.com now").text == "Open a link now.")
        #expect(SiriSpeech.spokenText("Read <https://example.com> today.").text == "Read a link today.")
        // A link with its own label keeps the label.
        #expect(SiriSpeech.spokenText("Read [the docs](https://example.com).").text == "Read the docs.")
    }

    @Test func tablesAndCodeAreNotRead() {
        let reply = "Here it is:\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nAnd code:\n```swift\nlet x = 1\n```\nDone."
        #expect(SiriSpeech.spokenText(reply).text
            == "Here it is: There is a table in the app. And code: There is code in the app. Done.")
        // Two code blocks in a row are said once.
        #expect(SiriSpeech.spokenText("```\na\n```\n```\nb\n```").text == SiriSpeech.code)
    }

    @Test func photosAndFilesAreNamed() {
        #expect(SiriSpeech.spokenText("MEDIA:/tmp/chart.png").text == "Hermes sent a photo.")
        #expect(SiriSpeech.spokenText("Report attached.\nMEDIA:/tmp/report.pdf").text
            == "Hermes sent a file. Report attached.")
        let photo = ChatAttachment(id: "p1", kind: .photo, name: "IMG.jpg", byteCount: 1, fileURL: URL(fileURLWithPath: "/tmp/x"),
                                   mimeType: "image/jpeg")
        #expect(SiriSpeech.spokenText("", attachments: [photo]).text == "Hermes sent a photo.")
    }

    @Test func shortTextIsCompleteAt400Characters() {
        let text = String(repeating: "a", count: 399) + "."
        #expect(SiriSpeech.cut(text) == SiriSpokenText(text: text, isComplete: true))
    }

    @Test func longTextIsCutAtTheLastSentenceEnd() {
        let sentence = "This is one sentence of about forty chars. "
        let reply = String(repeating: sentence, count: 20)
        let spoken = SiriSpeech.spokenText(reply)
        #expect(!spoken.isComplete)
        #expect(spoken.text.hasSuffix(". The rest is in the app."))
        let head = spoken.text.dropLast(" The rest is in the app.".count)
        #expect(head.count <= SiriSpeech.limit)
        #expect(head.hasSuffix("chars."))
        #expect(head.count > SiriSpeech.limit - sentence.count)
    }

    @Test func aDotInsideAWordIsNotASentenceEnd() {
        let reply = String(repeating: "v1.2 ", count: 100)
        let spoken = SiriSpeech.cut(reply.trimmingCharacters(in: .whitespaces))
        #expect(!spoken.isComplete)
        // No sentence end: cut at the last space.
        #expect(spoken.text.hasSuffix("v1.2… The rest is in the app."))
    }

    @Test func oneLongWordIsCutAtTheLimit() {
        let spoken = SiriSpeech.cut(String(repeating: "x", count: 500))
        #expect(spoken.text == String(repeating: "x", count: 400) + "… The rest is in the app.")
        #expect(!spoken.isComplete)
    }

    @Test func emptyReplyIsEmpty() {
        #expect(SiriSpeech.spokenText("") == SiriSpokenText(text: "", isComplete: true))
        #expect(SiriSpeech.spokenText("---").text == "")
    }
}

/// Issue #45: the dialogs that stop a run.
@Suite struct SiriDialogTests {
    @Test func setupComesFirstThenTheLock() {
        #expect(SiriDialog.blocking(isSetUp: false, isDeviceLocked: true, usesSiriWhenLocked: true) == SiriDialog.notSetUp)
        #expect(SiriDialog.blocking(isSetUp: true, isDeviceLocked: true, usesSiriWhenLocked: false)
            == "Unlock your iPhone to use Hermes.")
        #expect(SiriDialog.blocking(isSetUp: true, isDeviceLocked: true, usesSiriWhenLocked: true) == nil)
        #expect(SiriDialog.blocking(isSetUp: true, isDeviceLocked: false, usesSiriWhenLocked: false) == nil)
    }

    @Test func useSiriWhenLockedIsOffByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "siri-\(UUID().uuidString)"))
        #expect(!SiriSettings.usesSiriWhenLocked(defaults))
        defaults.set(true, forKey: SiriSettings.useWhenLockedKey)
        #expect(SiriSettings.usesSiriWhenLocked(defaults))
    }

    @Test func raceReturnsFalseAtTheTimeout() async {
        let fast = await SiriTiming.finishes(within: .seconds(5)) {}
        #expect(fast)
        let slow = await SiriTiming.finishes(within: .milliseconds(20)) { try? await Task.sleep(for: .seconds(5)) }
        #expect(!slow)
    }
}

private func reply(_ text: String, id: String = UUID().uuidString) -> ChatMessage {
    ChatMessage(id: id, role: .assistant, text: text, date: .now, reply: .complete)
}

/// A fixed test event. The JSON is a literal, so the decode cannot fail.
private func ev(_ json: String) -> GatewayClientEvent {
    // swiftlint:disable:next force_try
    .event(try! JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8)))
}

/// Issue #45: "Read Hermes".
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SiriReadTests {
    @Test func readsThreeUnreadRepliesNewestFirstWithTheirTitles() {
        let rows = (1...4).map { SessionListItem(id: "k\($0)", title: "S\($0)", isUnread: true) }
            + [SessionListItem(id: "k5", title: "Old")]
        let result = SiriRead.result(rows: rows, reachable: true) { id in reply("Reply \(id)") }
        #expect(result.dialog == "S1: Reply k1.\nS2: Reply k2.\nS3: Reply k3.")
        #expect(result.readSessionIds == ["k1", "k2", "k3"])
    }

    @Test func aCutReplyStaysUnread() {
        let rows = [SessionListItem(id: "a", title: "Long", isUnread: true),
                    SessionListItem(id: "b", title: "Short", isUnread: true)]
        let long = String(repeating: "Word word word. ", count: 40)
        let result = SiriRead.result(rows: rows, reachable: true) { $0 == "a" ? reply(long) : reply("Ok") }
        #expect(result.readSessionIds == ["b"])
        #expect(result.dialog.contains("The rest is in the app."))
    }

    @Test func noUnreadReadsTheLastReply() {
        let rows = [SessionListItem(id: "a", title: "Empty"), SessionListItem(id: "b", title: "Trip")]
        let result = SiriRead.result(rows: rows, reachable: false) { $0 == "b" ? reply("Flight at 9") : nil }
        #expect(result.dialog == "No new replies. The last one, from Trip: Flight at 9.")
        #expect(result.readSessionIds.isEmpty)
    }

    @Test func noRepliesAndNoConnection() {
        let none = SiriRead.result(rows: [SessionListItem(id: "a")], reachable: true) { _ in nil }
        #expect(none.dialog == "There are no replies from Hermes yet.")
        let empty = SiriRead.result(rows: [], reachable: true) { _ in nil }
        #expect(empty.dialog == SiriDialog.noReplies)
        let offline = SiriRead.result(rows: [], reachable: false) { _ in nil }
        #expect(offline.dialog == "I can't reach Hermes right now.")
    }

    @Test func lastReplySkipsStreamingAndEmptyReplies() {
        var streaming = reply("Partial")
        streaming.reply = .streaming
        let messages = [reply("Done"), ChatMessage(id: "u", role: .user, text: "Hi", date: .now), reply("  "), streaming]
        #expect(SiriRead.lastReply(of: messages)?.text == "Done")
    }

    @Test func runSyncsThenReadsAndMarksRead() async {
        let chats = FakeChatTransport()
        chats.transcript = [TranscriptMessage(role: "user", text: "Hi", rowId: 1),
                            TranscriptMessage(role: "assistant", text: "Fresh reply", rowId: 2)]
        let cache = InMemorySessionCacheStore(sessions: [SessionListItem(id: "k1", title: "Plans", messageCount: 0)])
        let transport = FakeSessionsTransport(rows: [SessionListItem(id: "k1", title: "Plans", messageCount: 2)])
        let sessions = SessionListModel(transport: transport, chatTransport: chats, cache: cache)
        let result = await SiriRead.run(sessions: sessions, syncTimeout: .seconds(5)) { _ in true }
        #expect(result.dialog == "Plans: Fresh reply.")
        #expect(chats.histories == ["s2"])
        #expect(sessions.session(id: "k1")?.isUnread == false)
        #expect(cache.loadSessions().first?.isUnread == false)
    }

    @Test func runWithNoLinkReadsTheCache() async {
        let cache = InMemorySessionCacheStore(
            sessions: [SessionListItem(id: "k1", title: "Plans", isUnread: true)],
            transcripts: ["k1": [reply("Cached reply", id: "r1")]])
        let transport = FakeSessionsTransport()
        let sessions = SessionListModel(transport: transport, chatTransport: FakeChatTransport(), cache: cache)
        let result = await SiriRead.run(sessions: sessions, syncTimeout: .seconds(5)) { _ in false }
        #expect(result.dialog == "Plans: Cached reply.")
        #expect(transport.fetches == 0)
    }

    @Test func aSlowSyncStopsAtTheTimeoutAndReadsTheCache() async {
        let cache = InMemorySessionCacheStore(
            sessions: [SessionListItem(id: "k1", title: "Plans", isUnread: true)],
            transcripts: ["k1": [reply("Cached reply", id: "r1")]])
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: FakeChatTransport(),
                                        cache: cache)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await SiriRead.run(sessions: sessions, syncTimeout: .milliseconds(50)) { _ in
            try? await Task.sleep(for: .seconds(10))
            return true
        }
        #expect(clock.now - start < .seconds(2))
        #expect(result.dialog == "Plans: Cached reply.")
    }
}

/// Issue #45: "Ask Hermes" in the background.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SiriAskTests {
    private func waitForSubmit(_ chats: FakeChatTransport) async {
        for _ in 0..<400 where chats.submits.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func returnsTheReplyAsTheDialogAndMarksTheSessionRead() async throws {
        let chats = FakeChatTransport()
        let cache = InMemorySessionCacheStore(sessions: [SessionListItem(id: "k1", title: "Car", messageCount: 2)],
                                              activeSessionId: "k1")
        let transport = FakeSessionsTransport(rows: [SessionListItem(id: "k1", title: "Car", messageCount: 4)])
        let sessions = SessionListModel(transport: transport, chatTransport: chats, cache: cache)
        Task { @MainActor in
            await waitForSubmit(chats)
            chats.input.yield(ev(#"{"type":"message.start","session_id":"s2","payload":{}}"#))
            chats.input.yield(ev(
                #"{"type":"message.complete","session_id":"s2","payload":{"text":"It is in **Lot B**.","status":"complete"}}"#))
        }
        let outcome = await SiriAsk.run(text: " Where is my car? ", sessions: sessions, timeout: .seconds(5),
                                        poll: .milliseconds(5)) { _ in true }
        #expect(outcome == .reply(SiriSpokenText(text: "It is in Lot B.", isComplete: true), sessionId: "k1"))
        #expect(outcome.dialog == "It is in Lot B.")
        #expect(chats.submits.map(\.text) == ["Where is my car?"])
        #expect(sessions.session(id: "k1")?.isUnread == false)
    }

    @Test func aCutReplyKeepsTheSessionUnread() async throws {
        let chats = FakeChatTransport()
        let cache = InMemorySessionCacheStore(sessions: [SessionListItem(id: "k1", title: "Car", messageCount: 2)],
                                              activeSessionId: "k1")
        let transport = FakeSessionsTransport(rows: [SessionListItem(id: "k1", title: "Car", messageCount: 4)])
        let sessions = SessionListModel(transport: transport, chatTransport: chats, cache: cache)
        let long = String(repeating: "Word word word. ", count: 40)
        Task { @MainActor in
            await waitForSubmit(chats)
            chats.input.yield(ev(
                #"{"type":"message.complete","session_id":"s2","payload":{"text":"\#(long)","status":"complete"}}"#))
        }
        let outcome = await SiriAsk.run(text: "Tell me", sessions: sessions, timeout: .seconds(5),
                                        poll: .milliseconds(5)) { _ in true }
        guard case .reply(let spoken, _) = outcome else {
            Issue.record("expected a reply, got \(outcome)")
            return
        }
        #expect(!spoken.isComplete)
        #expect(spoken.text.hasSuffix("The rest is in the app."))
        #expect(sessions.session(id: "k1")?.isUnread == true)
    }

    @Test func aSlowReplySaysStillWorkingThenNotifies() async throws {
        let chats = FakeChatTransport()
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: chats,
                                        cache: InMemorySessionCacheStore(activeSessionId: "k1"))
        let outcome = await SiriAsk.run(text: "Plan my week", sessions: sessions, timeout: .milliseconds(200),
                                        poll: .milliseconds(5)) { _ in true }
        #expect(outcome.dialog == "Hermes is still working. I'll notify you when the reply comes.")
        guard case .stillWorking(let pending) = outcome else {
            Issue.record("expected still working, got \(outcome)")
            return
        }
        let notifier = FakeNotifier()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            chats.input.yield(ev(
                #"{"type":"message.complete","session_id":"s2","payload":{"text":"Monday: gym.","status":"complete"}}"#))
        }
        let posted = await SiriAsk.notifyWhenDone(pending, title: { "Week" }, showsPreview: true, notifier: notifier,
                                                  timeout: .seconds(5), poll: .milliseconds(5))
        #expect(posted)
        #expect(notifier.posted == [CatchUpNotification(sessionId: "k1", title: "Week", body: "Monday: gym.")])
    }

    @Test func theLateNotificationHasNoTextWithPreviewOff() async throws {
        let chats = FakeChatTransport()
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: chats,
                                        cache: InMemorySessionCacheStore(activeSessionId: "k1"))
        let outcome = await SiriAsk.run(text: "Plan", sessions: sessions, timeout: .milliseconds(100),
                                        poll: .milliseconds(5)) { _ in true }
        guard case .stillWorking(let pending) = outcome else {
            Issue.record("expected still working, got \(outcome)")
            return
        }
        chats.input.yield(ev(
            #"{"type":"message.complete","session_id":"s2","payload":{"text":"Secret plan.","status":"complete"}}"#))
        let notifier = FakeNotifier()
        await SiriAsk.notifyWhenDone(pending, title: { "Week" }, showsPreview: false, notifier: notifier,
                                     timeout: .seconds(5), poll: .milliseconds(5))
        #expect(notifier.posted.map(\.body) == ["New message from Hermes"])
    }

    @Test func noLinkSendsNothing() async {
        let chats = FakeChatTransport()
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: chats,
                                        cache: InMemorySessionCacheStore(activeSessionId: "k1"))
        let outcome = await SiriAsk.run(text: "Hi", sessions: sessions, timeout: .seconds(1)) { _ in false }
        #expect(outcome == .unreachable)
        #expect(outcome.dialog == "I can't reach Hermes right now.")
        #expect(chats.submits.isEmpty)
    }

    @Test func aFailedSendIsUnreachable() async {
        let chats = FakeChatTransport()
        chats.failSubmit = true
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: chats,
                                        cache: InMemorySessionCacheStore(activeSessionId: "k1"))
        let outcome = await SiriAsk.run(text: "Hi", sessions: sessions, timeout: .seconds(2),
                                        poll: .milliseconds(5)) { _ in true }
        #expect(outcome == .unreachable)
    }

    @Test func aFailedReplyHasItsOwnDialog() async throws {
        let chats = FakeChatTransport()
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: chats,
                                        cache: InMemorySessionCacheStore(activeSessionId: "k1"))
        Task { @MainActor in
            await waitForSubmit(chats)
            chats.input.yield(ev(
                #"{"type":"message.complete","session_id":"s2","payload":{"text":"","status":"error","error":"x"}}"#))
        }
        let outcome = await SiriAsk.run(text: "Hi", sessions: sessions, timeout: .seconds(5),
                                        poll: .milliseconds(5)) { _ in true }
        #expect(outcome == .replyFailed)
    }

    @Test func noSessionStartsANewChat() async throws {
        let chats = FakeChatTransport()
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: chats,
                                        cache: InMemorySessionCacheStore())
        Task { @MainActor in
            await waitForSubmit(chats)
            chats.input.yield(ev(
                #"{"type":"message.complete","session_id":"s1","payload":{"text":"Hello.","status":"complete"}}"#))
        }
        let outcome = await SiriAsk.run(text: "Hi", sessions: sessions, timeout: .seconds(5),
                                        poll: .milliseconds(5)) { _ in true }
        #expect(outcome.dialog == "Hello.")
        #expect(chats.starts.map(\.0) == [ChatSource.iOS])
    }
}
