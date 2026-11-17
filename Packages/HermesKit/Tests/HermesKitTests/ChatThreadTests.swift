import Foundation
import Testing
@testable import HermesKit

private func delta(_ text: String?, segment: Int? = nil, offset: Int? = nil) -> GatewayEvent.Kind {
    .messageDelta(MessageDeltaPayload(text: text, turnId: "t1", segment: segment, offset: offset))
}

private func complete(_ json: String) throws -> GatewayEvent.Kind {
    .messageComplete(try JSONDecoder().decode(MessageCompletePayload.self, from: Data(json.utf8)))
}

private final class IdMaker: @unchecked Sendable {
    private var next = 0
    func callAsFunction() -> String {
        next += 1
        return "id\(next)"
    }
}

@Suite struct ChatThreadTests {
    let now = Date(timeIntervalSince1970: 1_763_288_100)

    private func streaming() -> (ChatThread, IdMaker) {
        var thread = ChatThread()
        let ids = IdMaker()
        thread.addOutgoing(id: "p1", text: "hello", date: now)
        thread.beginTurn(promptId: "p1")
        return (thread, ids)
    }

    @Test func outgoingShowsAtOnceAsSending() {
        var thread = ChatThread()
        thread.addOutgoing(id: "p1", text: "/help", date: now)
        #expect(thread.messages.map(\.text) == ["/help"])
        #expect(thread.messages[0].delivery == .sending)
        thread.setDelivery(.delivered, id: "p1", userRowId: 118)
        #expect(thread.messages[0].delivery == .delivered)
        #expect(thread.messages[0].userRowId == 118)
    }

    @Test func turnGoesWaitingTypingStreamingIdle() throws {
        var (thread, ids) = streaming()
        #expect(thread.turn == .waiting)
        #expect(thread.apply(.messageStart(MessageStartPayload()), now: now, makeId: ids.callAsFunction) == .structure)
        #expect(thread.turn == .typing)
        #expect(thread.messages.count == 1)

        #expect(thread.apply(delta("Hello", offset: 0), now: now, makeId: ids.callAsFunction) == .structure)
        #expect(thread.turn == .streaming)
        #expect(thread.messages.last?.role == .assistant)
        #expect(thread.messages.last?.reply == .streaming)
        #expect(thread.messages.last?.promptId == "p1")

        #expect(thread.apply(delta("! How can I help?", offset: 5), now: now, makeId: ids.callAsFunction) == .text)
        #expect(thread.messages.last?.text == "Hello! How can I help?")

        let change = thread.apply(try complete(#"{"text":"Hello! How can I help?","status":"complete"}"#),
                                  now: now, makeId: ids.callAsFunction)
        #expect(change == .completed(id: "id1"))
        #expect(thread.turn == .idle)
        #expect(thread.messages.last?.reply == .complete)
        #expect(thread.messages.count == 2)
    }

    @Test func duplicateAndOverlappingChunksAreDropped() {
        var (thread, ids) = streaming()
        thread.apply(delta("Hello", offset: 0), now: now, makeId: ids.callAsFunction)
        #expect(thread.apply(delta("Hello", offset: 0), now: now, makeId: ids.callAsFunction) == .none)
        thread.apply(delta("lo, world", offset: 3), now: now, makeId: ids.callAsFunction)
        #expect(thread.messages.last?.text == "Hello, world")
    }

    @Test func offsetCountsUTF16Units() {
        var (thread, ids) = streaming()
        thread.apply(delta("👋 hi", offset: 0), now: now, makeId: ids.callAsFunction)
        // "👋" is 2 UTF-16 units: "👋 hi" is 5.
        thread.apply(delta("hi there", offset: 3), now: now, makeId: ids.callAsFunction)
        #expect(thread.messages.last?.text == "👋 hi there")
    }

    @Test func segmentBoundaryStartsAParagraph() {
        var (thread, ids) = streaming()
        thread.apply(delta("Let me check.", segment: 0, offset: 0), now: now, makeId: ids.callAsFunction)
        thread.apply(delta(nil, segment: 0), now: now, makeId: ids.callAsFunction)
        thread.apply(delta("Found it.", segment: 1, offset: 0), now: now, makeId: ids.callAsFunction)
        #expect(thread.messages.last?.text == "Let me check.\n\nFound it.")
        #expect(thread.messages.filter { $0.role == .assistant }.count == 1)
    }

    @Test func chunksWithoutOffsetAppend() {
        var (thread, ids) = streaming()
        for word in ["a", "b", "c"] { thread.apply(delta(word), now: now, makeId: ids.callAsFunction) }
        #expect(thread.messages.last?.text == "abc")
    }

    @Test func toolLineShowsAndClearsOnComplete() throws {
        var (thread, ids) = streaming()
        thread.apply(.messageStart(MessageStartPayload()), now: now, makeId: ids.callAsFunction)
        let tool = ToolStartPayload(toolId: "x", name: "web_search")
        #expect(thread.apply(.toolStart(tool), now: now, makeId: ids.callAsFunction) == .structure)
        #expect(thread.statusLine == "Using web_search…")
        thread.apply(.statusUpdate(StatusUpdatePayload(kind: "compacting", text: "Compacting context…")),
                     now: now, makeId: ids.callAsFunction)
        #expect(thread.statusLine == "Compacting context…")
        thread.apply(try complete(#"{"text":"Done.","status":"complete"}"#), now: now, makeId: ids.callAsFunction)
        #expect(thread.statusLine == nil)
        #expect(thread.messages.last?.text == "Done.")
    }

    @Test func toolLineIsIgnoredWhenIdle() {
        var thread = ChatThread()
        let ids = IdMaker()
        let change = thread.apply(.toolStart(ToolStartPayload(toolId: "x", name: "web_search")), now: now,
                                  makeId: ids.callAsFunction)
        #expect(change == .none)
        #expect(thread.statusLine == nil)
    }

    @Test func errorStatusKeepsPartialText() throws {
        var (thread, ids) = streaming()
        thread.apply(delta("Partial", offset: 0), now: now, makeId: ids.callAsFunction)
        thread.apply(try complete(#"{"text":"","status":"error","error":"model overloaded"}"#), now: now,
                     makeId: ids.callAsFunction)
        #expect(thread.messages.last?.text == "Partial")
        #expect(thread.messages.last?.reply == .failed(message: "model overloaded"))
        #expect(thread.turn == .idle)
    }

    @Test func interruptedReplyKeepsText() throws {
        var (thread, ids) = streaming()
        thread.apply(delta("Long answer", offset: 0), now: now, makeId: ids.callAsFunction)
        thread.apply(try complete(#"{"text":"Long answer","status":"interrupted"}"#), now: now,
                     makeId: ids.callAsFunction)
        #expect(thread.messages.last?.reply == .interrupted)
    }

    @Test func sessionErrorDuringTurnFailsTheReply() {
        var (thread, ids) = streaming()
        thread.apply(.error(GatewayErrorPayload(message: "boom")), now: now, makeId: ids.callAsFunction)
        #expect(thread.messages.last?.role == .assistant)
        #expect(thread.messages.last?.reply == .failed(message: "boom"))
        #expect(thread.messages.last?.promptId == "p1")
        #expect(thread.turn == .idle)
    }

    @Test func connectionLossFailsAnActiveTurnOnly() {
        var idle = ChatThread()
        let ids = IdMaker()
        #expect(idle.connectionLost(now: now, makeId: ids.callAsFunction) == .none)
        var (thread, more) = streaming()
        thread.apply(delta("Hi", offset: 0), now: now, makeId: more.callAsFunction)
        #expect(thread.connectionLost(now: now, makeId: more.callAsFunction) == .structure)
        #expect(thread.messages.last?.reply == .failed(message: nil))
    }

    @Test func dropWhileThePromptIsSendingAddsNoFailedReply() {
        var (thread, ids) = streaming()
        #expect(thread.connectionLost(now: now, makeId: ids.callAsFunction) == .none)
        #expect(thread.messages.count == 1)
        // The send then fails: only "Not Delivered".
        thread.setDelivery(.failed, id: "p1")
        thread.cancelWaiting()
        #expect(thread.turn == .idle)
        #expect(ChatTimeline.rows(for: thread.messages).map(\.footnote) == [.notDelivered])
    }

    @Test func dropAfterDeliveryBeforeStartFailsTheReply() {
        var (thread, ids) = streaming()
        thread.setDelivery(.delivered, id: "p1")
        #expect(thread.connectionLost(now: now, makeId: ids.callAsFunction) == .structure)
        #expect(thread.messages.last?.reply == .failed(message: nil))
        #expect(thread.turn == .idle)
    }

    @Test func completeWithoutDeltasMakesTheBubble() throws {
        var (thread, ids) = streaming()
        let change = thread.apply(try complete(#"{"text":"Only final","status":"complete"}"#), now: now,
                                  makeId: ids.callAsFunction)
        #expect(change == .completed(id: "id1"))
        #expect(thread.messages.last?.text == "Only final")
    }

    @Test func emptyCompleteEndsTheTurnWithoutABubble() throws {
        var (thread, ids) = streaming()
        thread.apply(try complete(#"{"text":"","status":"complete"}"#), now: now, makeId: ids.callAsFunction)
        #expect(thread.messages.count == 1)
        #expect(thread.turn == .idle)
    }

    @Test func cancelWaitingOnlyEndsAWaitingTurn() {
        var (thread, ids) = streaming()
        thread.apply(.messageStart(MessageStartPayload()), now: now, makeId: ids.callAsFunction)
        thread.cancelWaiting()
        #expect(thread.turn == .typing)
        var (waiting, _) = streaming()
        waiting.cancelWaiting()
        #expect(waiting.turn == .idle)
    }
}

@Suite struct ChatTimelineTests {
    let base = Date(timeIntervalSince1970: 1_763_288_100)

    private func message(_ id: String, _ role: ChatMessage.Role, minutes: Double,
                         delivery: ChatMessage.Delivery? = nil, reply: ChatMessage.Reply? = nil) -> ChatMessage {
        ChatMessage(id: id, role: role, text: id, date: base.addingTimeInterval(minutes * 60),
                    delivery: role == .user ? (delivery ?? .delivered) : nil,
                    reply: role == .assistant ? (reply ?? .complete) : nil)
    }

    @Test func tailOnlyOnLastBubbleOfARun() {
        let rows = ChatTimeline.rows(for: [
            message("u1", .user, minutes: 0), message("u2", .user, minutes: 1),
            message("a1", .assistant, minutes: 2), message("a2", .assistant, minutes: 3),
            message("u3", .user, minutes: 4),
        ])
        #expect(rows.map(\.hasTail) == [false, true, false, true, true])
    }

    @Test func timeHeaderAfterMoreThan15Minutes() {
        let rows = ChatTimeline.rows(for: [
            message("u1", .user, minutes: 0), message("a1", .assistant, minutes: 15),
            message("a2", .assistant, minutes: 30.5),
        ])
        #expect(rows.map { $0.timeHeader != nil } == [true, false, true])
        // A header also ends the run: "a1" gets the tail.
        #expect(rows.map(\.hasTail) == [true, true, true])
    }

    @Test func deliveryFootnoteOnlyUnderTheLastOutgoingBubble() {
        let rows = ChatTimeline.rows(for: [
            message("u1", .user, minutes: 0), message("a1", .assistant, minutes: 1),
            message("u2", .user, minutes: 2, delivery: .sending), message("u3", .user, minutes: 3, delivery: .failed),
        ])
        #expect(rows.map(\.footnote) == [nil, nil, .sending, .notDelivered])
    }

    @Test func replyFootnotesAndStatusLine() {
        let rows = ChatTimeline.rows(for: [
            message("a1", .assistant, minutes: 0, reply: .failed(message: nil)),
            message("a2", .assistant, minutes: 1, reply: .interrupted),
            message("a3", .assistant, minutes: 2, reply: .streaming),
        ], statusLine: "Using web_search…")
        #expect(rows.map(\.footnote) == [.replyFailed, .stopped, nil])
        #expect(rows.map(\.statusLine) == [nil, nil, "Using web_search…"])
        #expect(ChatRow.Footnote.replyFailed.text == "Reply failed. Tap to retry.")
    }

    @Test func headerText() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let locale = Locale(identifier: "en_US")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12)))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9, minute: 41)))
        func text(_ date: Date) -> String {
            ChatTimeline.headerText(for: date, now: now, calendar: calendar, locale: locale)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(text(today) == "Today 9:41 AM")
        #expect(text(today.addingTimeInterval(-86_400)) == "Yesterday 9:41 AM")
        #expect(text(today.addingTimeInterval(-3 * 86_400)) == "Friday 9:41 AM")
        #expect(text(try #require(calendar.date(byAdding: .day, value: -30, to: today))) == "Oct 17, 2026 9:41 AM")
    }

    @Test func accessibilityLabel() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9, minute: 41)))
        let you = ChatRow(message: ChatMessage(id: "1", role: .user, text: "hi", date: date, delivery: .failed),
                          timeHeader: nil, hasTail: true, footnote: .notDelivered)
        let hermes = ChatRow(message: ChatMessage(id: "2", role: .assistant, text: "Hello", date: date, reply: .complete),
                             timeHeader: nil, hasTail: true)
        func label(_ row: ChatRow) -> String {
            ChatTimeline.accessibilityLabel(for: row, calendar: calendar, locale: Locale(identifier: "en_US"))
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(label(you) == "You, hi, 9:41 AM, Not Delivered")
        #expect(label(hermes) == "Hermes, Hello, 9:41 AM")
    }
}

@Suite struct ChatMarkdownTests {
    @Test func inlineStyles() {
        let runs = ChatMarkdown.runs("Say **bold**, *it* and `ls -la`.")
        #expect(runs == [
            ChatTextRun("Say "), ChatTextRun("bold", isBold: true), ChatTextRun(", "),
            ChatTextRun("it", isItalic: true), ChatTextRun(" and "), ChatTextRun("ls -la", isCode: true),
            ChatTextRun("."),
        ])
    }

    @Test func markdownAndBareLinks() throws {
        let runs = ChatMarkdown.runs("See [docs](https://example.com/a) or https://example.org now")
        #expect(runs.map(\.text) == ["See ", "docs", " or ", "https://example.org", " now"])
        #expect(runs[1].link == URL(string: "https://example.com/a"))
        #expect(runs[3].link == URL(string: "https://example.org"))
    }

    @Test func unsafeLinkSchemesStayPlain() {
        let runs = ChatMarkdown.runs("[tap](javascript:alert(1)) [x](file:///etc/passwd)")
        #expect(runs.allSatisfy { $0.link == nil })
    }

    @Test func fencedCodeBlock() {
        let runs = ChatMarkdown.runs("Run this:\n```swift\nlet a = 1\nprint(a)\n```\nDone.")
        #expect(runs == [
            ChatTextRun("Run this:\n"), ChatTextRun("let a = 1\nprint(a)", isCodeBlock: true),
            ChatTextRun("\nDone."),
        ])
    }

    @Test func openFenceWhileStreaming() {
        let runs = ChatMarkdown.runs("Code:\n```\nfor i in")
        #expect(runs.last == ChatTextRun("for i in", isCodeBlock: true))
    }

    @Test func markdownInsideCodeBlockStaysLiteral() {
        let runs = ChatMarkdown.runs("```\n**not bold**\n```")
        #expect(runs == [ChatTextRun("**not bold**", isCodeBlock: true)])
    }

    @Test func plainTextAndNewlinesStay() {
        #expect(ChatMarkdown.runs("line 1\nline 2") == [ChatTextRun("line 1\nline 2")])
        #expect(ChatMarkdown.runs("") == [])
    }
}
