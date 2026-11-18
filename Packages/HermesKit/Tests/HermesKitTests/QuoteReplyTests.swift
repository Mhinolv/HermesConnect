import Foundation
import Testing
@testable import HermesKit

/// Issue #17: reply by quote. The quote goes to Hermes as text at the start of the prompt (owner decision D7).
private let utc = TimeZone(identifier: "UTC")!
/// 2025-11-16 09:41:00 UTC.
private let nineFortyOne = Date(timeIntervalSince1970: 1_763_286_060)

private func reply(_ text: String, id: String = "a1", date: Date = nineFortyOne) -> ChatMessage {
    ChatMessage(id: id, role: .assistant, text: text, date: date, reply: .complete, promptId: "u0")
}

private func quote(_ excerpt: String, author: ChatMessage.Role = .assistant, id: String? = "a1") -> ChatQuote {
    ChatQuote(messageId: id, author: author, time: "9:41 AM", excerpt: excerpt)
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "QuoteReplyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@Suite struct QuoteReplyFormatTests {
    @Test func promptTextHasTheHeaderTheQuotedLinesABlankLineThenTheReply() {
        let text = QuoteReply.promptText("Yes, move it.", quote: quote("The call is at 3:00 PM.\n\nShall I move it?"))
        #expect(text == "> Hermes, 9:41 AM:\n> The call is at 3:00 PM.\n>\n> Shall I move it?\n\nYes, move it.")
        let own = QuoteReply.promptText("And this one", quote: quote("Buy milk", author: .user))
        #expect(own == "> You, 9:41 AM:\n> Buy milk\n\nAnd this one")
    }

    @Test func noQuoteLeavesTheTextAsItIs() {
        #expect(QuoteReply.promptText("hello", quote: nil) == "hello")
        // A reply of attachments only: the block with no blank line after it.
        #expect(QuoteReply.promptText("  ", quote: quote("Hi")) == "> Hermes, 9:41 AM:\n> Hi")
    }

    @Test func excerptIsCutAt500CharactersWithAnEllipsis() {
        let exact = String(repeating: "a", count: 500)
        #expect(QuoteReply.excerpt(exact) == exact)
        let long = String(repeating: "b", count: 498) + "  " + String(repeating: "c", count: 100)
        let cut = QuoteReply.excerpt(long)
        #expect(cut.count <= 500)
        #expect(cut == String(repeating: "b", count: 498) + "…")
        #expect(QuoteReply.excerpt(String(repeating: "x", count: 900)).count == 500)
    }

    @Test func timeTextIsTheSameOnEveryDevice() {
        #expect(QuoteReply.timeText(nineFortyOne, timeZone: utc) == "9:41 AM")
        #expect(QuoteReply.timeText(nineFortyOne.addingTimeInterval(12 * 3600 + 24 * 60), timeZone: utc) == "10:05 PM")
    }

    @Test func quoteOfAReplyHasTheSenderTimeAndVisibleText() throws {
        let made = try #require(ChatQuote(message: reply("Here it is MEDIA:/tmp/report.pdf"), timeZone: utc))
        #expect(made == ChatQuote(messageId: "a1", author: .assistant, time: "9:41 AM", excerpt: "Here it is"))
        #expect(made.replyingTitle == "Replying to Hermes")
        #expect(made.accessibilityText == "Reply to Hermes: Here it is")
    }

    @Test func aMessageWithNoTextQuotesTheNamesOfItsAttachments() throws {
        let file = ChatAttachment(id: "f1", kind: .file, name: "Lease.pdf", byteCount: 10,
                                  fileURL: URL(fileURLWithPath: "/tmp/Lease.pdf"), mimeType: "application/pdf")
        let photo = ChatAttachment(id: "p1", kind: .photo, name: "IMG_1.jpg", byteCount: 10,
                                   fileURL: URL(fileURLWithPath: "/tmp/IMG_1.jpg"), mimeType: "image/jpeg")
        let sent = ChatMessage(id: "u1", role: .user, text: "", date: nineFortyOne, delivery: .delivered,
                               attachments: [photo, file])
        #expect(try #require(ChatQuote(message: sent, timeZone: utc)).excerpt == "Photo, Lease.pdf")
        let files = reply("MEDIA:/tmp/out/chart.png")
        #expect(try #require(ChatQuote(message: files, timeZone: utc)).excerpt == "chart.png")
    }

    @Test func streamingRepliesCommandCardsAndEmptyBubblesCannotBeQuoted() {
        var streaming = reply("Partial")
        streaming.reply = .streaming
        #expect(ChatQuote(message: streaming) == nil)
        let card = ChatMessage(id: "c1", role: .assistant, text: "Model: x", date: nineFortyOne,
                               command: ChatCommandCard(command: "/model", output: "Model: x"))
        #expect(ChatQuote(message: card) == nil)
        #expect(ChatQuote(message: reply("  \n")) == nil)
    }

    @Test func previewTextIsOneLine() {
        #expect(quote("Line one\n\n  Line two  \nThree").previewText == "Line one Line two Three")
        #expect(quote("Run **this**:\n```\nls -la\n```\nPress `q`.").previewText == "Run this: ls -la Press q.")
    }
}

@Suite struct QuoteReplySplitTests {
    @Test func splitReadsBackTheQuoteAndTheReply() {
        let original = quote("Two meetings:\n\n> nested line\n10:00 AM", id: nil)
        let text = QuoteReply.promptText("Cancel the first.\n\nThanks", quote: original)
        let split = QuoteReply.split(text)
        #expect(split.quote == original)
        #expect(split.text == "Cancel the first.\n\nThanks")
    }

    @Test func splitOfABlockWithNoReply() {
        let split = QuoteReply.split("> You, 12:05 PM:\n> Buy milk")
        #expect(split.quote == ChatQuote(messageId: nil, author: .user, time: "12:05 PM", excerpt: "Buy milk"))
        #expect(split.text == "")
    }

    @Test func textThatIsNotTheFormatDoesNotChange() {
        for text in ["hello", "> just a Markdown quote\n\nHi", "> Hermes, 9:41 AM:\nno quote lines",
                     "> Hermes, 9:41 AM:\n> quoted\nno blank line", "> Sam, 9:41 AM:\n> quoted\n\nHi",
                     "> Hermes, at noon:\n> quoted\n\nHi", ""] {
            let split = QuoteReply.split(text)
            #expect(split.quote == nil)
            #expect(split.text == text)
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct QuoteReplyModelTests {
    private func model(_ transport: FakeChatTransport, messages: [ChatMessage]) -> ChatViewModel {
        let counter = QuoteCounter()
        return ChatViewModel(transport: transport, messages: messages, redrawInterval: .seconds(60),
                             makeId: { counter.next() })
    }

    @Test func replySendsTheQuoteInThePromptAndTheBubbleShowsOnlyTheReply() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport, messages: [reply("The call is at 3:00 PM.")])
        #expect(vm.startReply(to: "a1"))
        let expected = ChatQuote(messageId: "a1", author: .assistant, time: QuoteReply.timeText(nineFortyOne),
                                 excerpt: "The call is at 3:00 PM.")
        #expect(vm.replyQuote == expected)

        await vm.send("Move it to 4")?.value
        #expect(vm.replyQuote == nil)
        let sent = try #require(vm.messages.last)
        #expect(sent.text == "Move it to 4")
        #expect(sent.quote == expected)
        #expect(transport.submits.map(\.text)
            == ["> Hermes, \(expected.time):\n> The call is at 3:00 PM.\n\nMove it to 4"])

        // The next message has no quote.
        await vm.send("Thanks")?.value
        #expect(transport.submits.last?.text == "Thanks")
        #expect(vm.messages.last?.quote == nil)
    }

    @Test func cancelReplyRemovesTheQuote() async {
        let transport = FakeChatTransport()
        let vm = model(transport, messages: [reply("Hi")])
        vm.startReply(to: "a1")
        vm.cancelReply()
        #expect(vm.replyQuote == nil)
        await vm.send("Plain")?.value
        #expect(transport.submits.map(\.text) == ["Plain"])
    }

    @Test func aSlashCommandKeepsTheQuoteForTheNextMessage() async {
        let transport = FakeChatTransport()
        let vm = model(transport, messages: [reply("Hi")])
        vm.startReply(to: "a1")
        _ = vm.send("/help")
        #expect(vm.replyQuote?.messageId == "a1")
    }

    @Test func aStreamingReplyOrAnUnknownIdSetsNoQuote() {
        var streaming = reply("Partial")
        streaming.reply = .streaming
        let vm = model(FakeChatTransport(), messages: [streaming])
        #expect(!vm.startReply(to: "a1"))
        #expect(!vm.startReply(to: "nope"))
        #expect(vm.replyQuote == nil)
    }

    @Test func tryAgainSendsTheQuoteAgain() async throws {
        let transport = FakeChatTransport()
        transport.failSubmit = true
        let vm = model(transport, messages: [reply("Hi")])
        vm.startReply(to: "a1")
        await vm.send("Hello")?.value
        let id = try #require(vm.messages.last?.id)
        #expect(vm.messages.last?.delivery == .failed)
        transport.failSubmit = false
        await vm.retrySend(id: id)?.value
        #expect(transport.submits.count == 2)
        #expect(transport.submits[0].text == transport.submits[1].text)
        #expect(transport.submits[1].text.hasPrefix("> Hermes, "))
        #expect(transport.submits[1].text.hasSuffix("\n> Hi\n\nHello"))
    }

    /// QA #80: a voice memo does not quote. It clears the quote, so the box does not quote the next text.
    @Test func aVoiceMemoClearsTheQuote() async {
        let transport = FakeChatTransport()
        let vm = model(transport, messages: [reply("Hi")])
        vm.startReply(to: "a1")
        let memo = VoiceMemo(fileURL: URL(fileURLWithPath: "/tmp/quote-memo.m4a"), duration: 2, waveform: [0.5])
        _ = vm.sendVoiceMemo(memo)
        #expect(vm.replyQuote == nil)
        #expect(vm.messages.last?.quote == nil)
    }

    @Test func aTapOnTheQuoteFindsTheOriginal() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport, messages: [reply("Older", id: "a0"), reply("The call is at 3.")])
        vm.startReply(to: "a1")
        await vm.send("Move it")?.value
        let id = try #require(vm.messages.last?.id)
        #expect(vm.quotedMessageId(of: id) == "a1")
        #expect(vm.quotedMessageId(of: "a1") == nil)
    }

    @Test func voiceOverReadsTheQuoteFirst() async throws {
        let vm = model(FakeChatTransport(), messages: [reply("The call is at 3.")])
        vm.startReply(to: "a1")
        await vm.send("Move it")?.value
        let row = try #require(ChatTimeline.rows(for: vm.messages).last)
        #expect(ChatTimeline.accessibilityLabel(for: row).hasPrefix("Reply to Hermes: The call is at 3., You, Move it"))
    }
}

private final class QuoteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> String { lock.withLock { value += 1; return "q\(value)" } }
}

@Suite struct QuoteReplyHistoryTests {
    private let block = "> Hermes, 9:41 AM:\n> The call is at 3.\n\nMove it"

    @Test func aServerPromptWithAQuoteShowsTheReplyAndTheQuote() throws {
        let transcript = [TranscriptMessage(role: "assistant", text: "The call is at 3.", rowId: 1),
                          TranscriptMessage(role: "user", text: block, rowId: 2)]
        let messages = ChatHistory.messages(from: transcript)
        let prompt = try #require(messages.last)
        #expect(prompt.text == "Move it")
        #expect(prompt.quote == ChatQuote(messageId: nil, author: .assistant, time: "9:41 AM", excerpt: "The call is at 3."))
        // With no id, the tap finds the original by its sender and text.
        let original = try #require(prompt.quote)
        #expect(QuoteReply.target(of: original, in: messages) == messages.first?.id)
        #expect(QuoteReply.target(of: original, in: [messages[1]]) == nil)
    }

    @Test func aBubbleOnTheScreenKeepsItsQuoteWithTheId() throws {
        let shown = ChatMessage(id: "m7", role: .user, text: "Move it", date: nineFortyOne, delivery: .delivered,
                                userRowId: 2, quote: quote("The call is at 3."))
        let messages = ChatHistory.messages(from: [TranscriptMessage(role: "user", text: block, rowId: 2)],
                                            reusing: [shown])
        #expect(messages.map(\.id) == ["m7"])
        #expect(messages[0].text == "Move it")
        #expect(messages[0].quote?.messageId == "a1")
    }

    @Test func attachmentRefsComeFirstThenTheQuote() throws {
        let row = TranscriptMessage(role: "user", text: "@file:attachments/x.txt\n\n" + block, rowId: 5)
        let prompt = try #require(ChatHistory.messages(from: [row]).first)
        #expect(prompt.attachments.map(\.name) == ["x.txt"])
        #expect(prompt.text == "Move it")
        #expect(prompt.quote?.excerpt == "The call is at 3.")
    }
}

@Suite struct QuoteReplyCacheTests {
    @Test func theQuoteSurvivesARelaunch() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sent = ChatMessage(id: "u1", role: .user, text: "Move it", date: nineFortyOne, delivery: .delivered,
                               userRowId: 2, quote: quote("The call is at 3.\nOK?"))
        FileSessionCacheStore(directory: directory).saveTranscript([reply("The call is at 3.\nOK?"), sent],
                                                                   sessionId: "k1")
        let loaded = FileSessionCacheStore(directory: directory).loadTranscript(sessionId: "k1")
        #expect(loaded.last == sent)
        #expect(loaded.first?.quote == nil)
    }

    @Test func olderFilesAndABrokenQuoteStillLoad() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionCacheStore(directory: directory)
        let url = store.transcriptURL(sessionId: "k1")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"""
        {"version":5,"body":[
         {"id":"u1","role":"user","text":"Hi","date":1763290000,"userRowId":1,"interrupted":false,"notDelivered":false},
         {"id":"u2","role":"user","text":"Bad","date":1763290002,"quote":7},
         {"id":"u3","role":"user","text":"Empty","date":1763290003,"quote":{"author":"assistant"}},
         {"id":"u4","role":"user","text":"Good","date":1763290004,"quote":{"author":"user","time":"9:41 AM","excerpt":"x"}}
        ]}
        """#.utf8).write(to: url)
        let loaded = store.loadTranscript(sessionId: "k1")
        #expect(loaded.map(\.id) == ["u1", "u2", "u3", "u4"])
        #expect(loaded.prefix(3).allSatisfy { $0.quote == nil })
        #expect(loaded[3].quote == ChatQuote(messageId: nil, author: .user, time: "9:41 AM", excerpt: "x"))
        store.saveTranscript(loaded, sessionId: "k1")
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains(#""version":\#(SessionCache.formatVersion)"#))
    }
}

/// QA #80 defect 1: a reply with attachments and no text still shows its quote line.
@Suite struct QuoteReplyPartsTests {
    @Test func aReplyOfAttachmentsOnlyHasATextPartForTheQuote() throws {
        let photo = ChatAttachment(id: "p1", kind: .photo, name: "IMG_1.jpg", byteCount: 10,
                                   fileURL: URL(fileURLWithPath: "/tmp/IMG_1.jpg"), mimeType: "image/jpeg")
        let sent = ChatMessage(id: "u1", role: .user, text: "", date: nineFortyOne, delivery: .delivered,
                               attachments: [photo], quote: quote("The call is at 3."))
        let row = try #require(ChatTimeline.rows(for: [sent]).first)
        let parts = ChatBubbleParts.parts(for: row)
        #expect(parts.map(\.id) == ["u1#p1", "u1#text"])
        #expect(parts.last?.content == .text)
        // No quote: the photo only, as before.
        var plain = sent
        plain.quote = nil
        let plainRow = try #require(ChatTimeline.rows(for: [plain]).first)
        #expect(ChatBubbleParts.parts(for: plainRow).map(\.id) == ["u1#p1"])
    }
}
