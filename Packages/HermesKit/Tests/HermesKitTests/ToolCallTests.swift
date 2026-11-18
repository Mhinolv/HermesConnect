import Foundation
import Testing
@testable import HermesKit

// Issue #120: the tool calls of a reply, the tool row text, the cache and the Voice tab tool line.

private final class ToolIds: @unchecked Sendable {
    private var next = 0
    func callAsFunction() -> String {
        next += 1
        return "id\(next)"
    }
}

private func event(_ type: String, _ payload: String) throws -> GatewayEvent.Kind {
    let json = #"{"type":"\#(type)","session_id":"s1","payload":\#(payload)}"#
    return try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8)).kind
}

private let secret = "sk-SECRET-TOKEN-123"

@Suite struct ToolCallThreadTests {
    let now = Date(timeIntervalSince1970: 1_763_290_000)

    private func running() -> (ChatThread, ToolIds) {
        var thread = ChatThread()
        let ids = ToolIds()
        thread.addOutgoing(id: "p1", text: "Find flights", date: now)
        thread.beginTurn(promptId: "p1")
        thread.apply(.messageStart(MessageStartPayload()), now: now, makeId: ids.callAsFunction)
        return (thread, ids)
    }

    @Test func replyKeepsItsToolsInCallOrderWithSummaryAndDuration() throws {
        var (thread, ids) = running()
        let make = ids.callAsFunction
        thread.apply(try event("tool.start", #"{"tool_id":"t1","name":"web_search","preview":"flights SFO","args":{"api_key":"\#(secret)"}}"#),
                     now: now, makeId: make)
        #expect(thread.runningTool == "web_search")
        #expect(thread.statusLine == "Using web_search…")
        thread.apply(try event("tool.start", #"{"tool_id":"t2","name":"browser"}"#), now: now, makeId: make)
        #expect(thread.runningTool == "browser")
        thread.apply(try event("tool.complete", #"{"tool_id":"t2","name":"browser","duration_s":64.2,"result":{"token":"\#(secret)"},"result_text":"\#(secret)"}"#),
                     now: now, makeId: make)
        // The first tool still runs.
        #expect(thread.runningTool == "web_search")
        thread.apply(try event("tool.complete", #"{"tool_id":"t1","name":"web_search","duration_s":1.234,"summary":"Searched 4 pages"}"#),
                     now: now, makeId: make)
        #expect(thread.runningTool == nil)
        // The chat status line does not change while the turn runs.
        #expect(thread.statusLine == "Using browser…")
        thread.apply(try event("tool.start", #"{"tool_id":"t3","name":"calendar","preview":"Next week"}"#), now: now,
                     makeId: make)
        thread.apply(.messageDelta(MessageDeltaPayload(text: "Here are flights.", turnId: nil, segment: nil, offset: nil)),
                     now: now, makeId: make)
        #expect(thread.messages.last?.tools == [], "a streaming reply shows no tools yet")
        thread.apply(try event("message.complete", #"{"text":"Here are flights.","status":"complete"}"#), now: now,
                     makeId: make)
        let reply = try #require(thread.messages.last)
        #expect(reply.tools == [
            ChatToolCall(id: "t1", name: "web_search", summary: "Searched 4 pages", duration: 1.234),
            ChatToolCall(id: "t2", name: "browser", summary: nil, duration: 64.2),
            ChatToolCall(id: "t3", name: "calendar", summary: "Next week", duration: nil),
        ])
        #expect(thread.runningTool == nil)
        #expect(!String(describing: reply).contains(secret))
    }

    @Test func toolsOfOneTurnDoNotGoOnTheNextReply() throws {
        var (thread, ids) = running()
        let make = ids.callAsFunction
        thread.apply(try event("tool.start", #"{"tool_id":"t1","name":"web_search"}"#), now: now, makeId: make)
        thread.apply(try event("message.complete", #"{"text":"One","status":"complete"}"#), now: now, makeId: make)
        thread.addOutgoing(id: "p2", text: "Again", date: now)
        thread.beginTurn(promptId: "p2")
        thread.apply(.messageStart(MessageStartPayload()), now: now, makeId: make)
        thread.apply(try event("message.complete", #"{"text":"Two","status":"complete"}"#), now: now, makeId: make)
        #expect(thread.messages.map(\.tools.count) == [0, 1, 0, 0])
    }

    @Test func replayedStartKeepsOneEntryAndCompleteWithNoStartStillCounts() throws {
        var (thread, ids) = running()
        let make = ids.callAsFunction
        thread.apply(try event("tool.start", #"{"tool_id":"t1","name":"web_search"}"#), now: now, makeId: make)
        thread.apply(try event("tool.start", #"{"tool_id":"t1","name":"web_search"}"#), now: now, makeId: make)
        thread.apply(try event("tool.complete", #"{"tool_id":"t9","name":"terminal","duration_s":-3}"#), now: now,
                     makeId: make)
        thread.apply(try event("message.complete", #"{"text":"Ok","status":"complete"}"#), now: now, makeId: make)
        #expect(thread.messages.last?.tools.map(\.id) == ["t1", "t9"])
        #expect(thread.messages.last?.tools.last?.duration == nil, "a negative duration reads as none")
    }

    @Test func stoppedAndFailedRepliesKeepTheirTools() throws {
        var (thread, ids) = running()
        let make = ids.callAsFunction
        thread.apply(try event("tool.start", #"{"tool_id":"t1","name":"web_search"}"#), now: now, makeId: make)
        thread.apply(try event("message.complete", #"{"text":"Part","status":"interrupted"}"#), now: now, makeId: make)
        #expect(thread.messages.last?.reply == .interrupted)
        #expect(thread.messages.last?.tools.count == 1)

        var (failing, more) = running()
        failing.apply(try event("tool.start", #"{"tool_id":"t1","name":"web_search"}"#), now: now,
                      makeId: more.callAsFunction)
        failing.connectionLost(now: now, makeId: more.callAsFunction)
        #expect(failing.messages.last?.tools.count == 1)
        #expect(failing.runningTool == nil)
    }

    @Test func toolEventsWhenIdleChangeNothing() throws {
        var thread = ChatThread()
        let ids = ToolIds()
        #expect(thread.apply(try event("tool.complete", #"{"tool_id":"t1","name":"x"}"#), now: now,
                             makeId: ids.callAsFunction) == .none)
        #expect(thread.runningTool == nil)
    }

    @Test func historyMergeKeepsTheToolsOfAReplyOnScreen() {
        let tools = [ChatToolCall(id: "t1", name: "web_search", summary: "Searched", duration: 1)]
        let current = [
            ChatMessage(id: "u", role: .user, text: "Hi", date: now, delivery: .delivered, userRowId: 2),
            ChatMessage(id: "a", role: .assistant, text: "Hello", date: now, reply: .complete, promptId: "u",
                        tools: tools),
        ]
        let messages = ChatHistory.messages(from: [TranscriptMessage(role: "user", text: "Hi", rowId: 2),
                                                   TranscriptMessage(role: "tool", text: "{}", rowId: 3),
                                                   TranscriptMessage(role: "assistant", text: "Hello", rowId: 4)],
                                            reusing: current)
        #expect(messages.map(\.id) == ["u", "a"])
        #expect(messages[1].tools == tools)
    }
}

@Suite struct ToolCallTextTests {
    @Test func rowTitleNamesOneToolAndCountsMore() {
        let one = [ChatToolCall(id: "1", name: "web_search")]
        #expect(ChatToolText.rowTitle(one) == "Used web_search")
        #expect(ChatToolText.rowTitle(one + [ChatToolCall(id: "2", name: "a"), ChatToolCall(id: "3", name: "b")])
            == "Used 3 tools")
        #expect(ChatToolText.rowValue(expanded: false) == "Collapsed")
        #expect(ChatToolText.rowValue(expanded: true) == "Expanded")
        #expect(ChatToolText.rowHint == "Shows the tools.")
    }

    @Test func durationsFollowTheDesignNotes() {
        #expect(ChatToolText.duration(0.4) == "0.4 s")
        #expect(ChatToolText.duration(0) == "0.0 s")
        #expect(ChatToolText.duration(12.4) == "12 s")
        #expect(ChatToolText.duration(64) == "1 min 4 s")
        #expect(ChatToolText.duration(3600) == "60 min 0 s")
        #expect(ChatToolText.duration(nil) == "—")
        #expect(ChatToolText.spokenDuration(1.2) == "1.2 seconds")
        #expect(ChatToolText.spokenDuration(61) == "1 minute 1 second")
        #expect(ChatToolText.spokenDuration(nil) == nil)
    }

    @Test func listRowLabelIsNameSummaryAndDuration() {
        #expect(ChatToolText.accessibilityLabel(ChatToolCall(id: "1", name: "web_search", summary: "Searched 4 pages",
                                                             duration: 1.2))
            == "web_search, Searched 4 pages, 1.2 seconds")
        #expect(ChatToolText.accessibilityLabel(ChatToolCall(id: "1", name: "web_search")) == "web_search")
    }

    @Test func longOrEmptyTextIsCut() {
        let tool = ChatToolCall(id: "1", name: "  ", summary: String(repeating: "a", count: 1_000))
        #expect(tool.name == "tool")
        #expect(tool.summary?.count == ChatToolText.summaryLimit)
        #expect(ChatToolCall(id: "1", name: "x", summary: " \n ").summary == nil)
    }
}

@Suite struct ToolCallTimelineTests {
    let now = Date(timeIntervalSince1970: 1_763_290_000)

    @Test func endedReplyGetsOneToolRowAfterItsLastBubble() {
        let reply = ChatMessage(id: "a", role: .assistant, text: "Done", date: now, reply: .interrupted,
                                tools: [ChatToolCall(id: "t1", name: "web_search")])
        let parts = ChatBubbleParts.parts(for: ChatTimeline.rows(for: [reply], statusLine: "Using x…"))
        #expect(parts.map(\.content) == [.text, .tools])
        #expect(parts.map(\.id) == ["a", "a#tools"])
        // The bubble keeps the tail and the "Stopped" footnote. The status line goes to the end.
        #expect(parts[0].row.hasTail)
        #expect(parts[0].row.footnote == .stopped)
        #expect(parts[0].row.statusLine == nil)
        #expect(parts[1].row.statusLine == "Using x…")
        #expect(parts[1].row.footnote == nil)
        #expect(!parts[1].row.hasTail)
        #expect(!parts[1].row.showsReactions)
    }

    @Test func noToolRowWhileStreamingOrWithNoTools() {
        var reply = ChatMessage(id: "a", role: .assistant, text: "Do", date: now, reply: .streaming,
                                tools: [ChatToolCall(id: "t1", name: "web_search")])
        #expect(ChatBubbleParts.parts(for: ChatTimeline.rows(for: [reply])).map(\.content) == [.text])
        reply.reply = .complete
        reply.tools = []
        #expect(ChatBubbleParts.parts(for: ChatTimeline.rows(for: [reply])).map(\.content) == [.text])
    }
}

@Suite struct ToolCallCacheTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ToolCallCacheTests-\(UUID().uuidString)",
                                                         directoryHint: .isDirectory)
    }

    @Test func toolsSurviveARestartAndTheFileHoldsNoArgs() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileSessionCacheStore(directory: folder)
        let date = Date(timeIntervalSince1970: 1_763_290_000)
        let messages = [
            ChatMessage(id: "u", role: .user, text: "Hi", date: date, delivery: .delivered, userRowId: 1),
            ChatMessage(id: "a", role: .assistant, text: "Hello", date: date, reply: .complete, promptId: "u",
                        tools: [ChatToolCall(id: "t1", name: "web_search", summary: "Searched", duration: 1.5),
                                ChatToolCall(id: "t2", name: "browser")]),
        ]
        store.saveTranscript(messages, sessionId: "s1")
        let loaded = FileSessionCacheStore(directory: folder).loadTranscript(sessionId: "s1")
        #expect(loaded == messages)
        let text = try String(contentsOf: store.transcriptURL(sessionId: "s1"), encoding: .utf8)
        #expect(text.contains(#""version":7"#))
        #expect(!text.contains("args"))
        #expect(!text.contains("result"))
    }

    @Test func version6FilesAndBrokenToolListsStillLoad() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileSessionCacheStore(directory: folder)
        try FileManager.default.createDirectory(at: store.transcriptURL(sessionId: "s1").deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let file = #"{"version":6,"body":[{"id":"a","role":"assistant","text":"Old","date":1763290000,"interrupted":false,"notDelivered":false,"attachments":[],"queued":false},{"id":"b","role":"assistant","text":"Broken","date":1763290000,"tools":"nope"},{"id":"c","role":"assistant","text":"New","date":1763290000,"tools":[{"id":"t1","name":"web_search","duration":"x"},{"summary":"no name"}]}]}"#
        try Data(file.utf8).write(to: store.transcriptURL(sessionId: "s1"))
        let loaded = store.loadTranscript(sessionId: "s1")
        #expect(loaded.map(\.text) == ["Old", "Broken", "New"])
        #expect(loaded[0].tools.isEmpty)
        #expect(loaded[1].tools.isEmpty)
        // An entry with no name breaks the list, so the list drops. The message stays.
        #expect(loaded[2].tools.isEmpty)
    }
}

@Suite struct ToolCallVoiceTabTests {
    @Test func handsFreeShowsTheToolUnderTheRingWhileThinking() {
        let display = VoiceTabDisplay.make(state: .thinking, muted: false, thinkingSeconds: 6, tool: .init(name: "web_search", isRunning: true))
        #expect(display.title == "Thinking…")
        #expect(display.subtitle == "Using web_search…")
        #expect(display.showsTool)
        #expect(display.ringAccessibilityLabel == "Voice Mode, Thinking…, Using web_search…")
        let after = VoiceTabDisplay.make(state: .thinking, muted: false, thinkingSeconds: 6, tool: nil)
        #expect(after.subtitle == "Hermes is working · 6 s")
        #expect(!after.showsTool)
        #expect(after.ringAccessibilityLabel == "Voice Mode, Thinking…")
        // Only the thinking state shows the tool.
        #expect(VoiceTabDisplay.make(state: .speaking, muted: false, thinkingSeconds: 0, tool: .init(name: "x", isRunning: true)).subtitle
            == "Tap or speak to interrupt")
        // VoiceOver does not announce tools.
        #expect(VoiceTabDisplay.announcement(.thinking) == "Thinking")
    }

    @Test func liveShowsTheToolInPlaceOfStillWorking() throws {
        let display = try #require(VoiceTabDisplay.live(phase: .working, muted: false, speaking: false,
                                                        idleWarning: false, stillWorking: true, tool: .init(name: "web_search", isRunning: true)))
        #expect(display.title == "Hermes is working…")
        #expect(display.subtitle == "Using web_search…")
        #expect(display.liveAccessibilityLabel(elapsedSeconds: 5) == "Live Mode, Hermes is working…. Using web_search…, 0:05")
        let after = try #require(VoiceTabDisplay.live(phase: .working, muted: false, speaking: false,
                                                      idleWarning: false, stillWorking: true, tool: nil))
        #expect(after.subtitle == "Still working…")
        let live = try #require(VoiceTabDisplay.live(phase: .live, muted: false, speaking: false,
                                                     idleWarning: false, stillWorking: false, tool: .init(name: "x", isRunning: true)))
        #expect(live.subtitle == "Speak any time")
        #expect(VoiceTabDisplay.liveAnnouncement(.working) == "Hermes is working")
    }
}

// Issue #129: the Voice tab keeps the last tool of the turn: "Using <tool>…", then "Used <tool>".
@Suite struct LastToolTests {
    let now = Date(timeIntervalSince1970: 1_763_290_000)

    private func running() -> (ChatThread, ToolIds) {
        var thread = ChatThread()
        let ids = ToolIds()
        thread.addOutgoing(id: "p1", text: "Find flights", date: now)
        thread.beginTurn(promptId: "p1")
        thread.apply(.messageStart(MessageStartPayload()), now: now, makeId: ids.callAsFunction)
        return (thread, ids)
    }

    @Test func lastToolStaysAfterItEndsAndANewToolReplacesIt() throws {
        var (thread, ids) = running()
        let make = ids.callAsFunction
        #expect(thread.toolActivity == nil)
        thread.apply(try event("tool.start", #"{"tool_id":"t1","name":"web_search","args":{"q":"x"}}"#), now: now, makeId: make)
        #expect(thread.toolActivity == ChatToolActivity(name: "web_search", isRunning: true))
        #expect(thread.toolActivity?.line == "Using web_search…")
        thread.apply(try event("tool.complete", #"{"tool_id":"t1","name":"web_search","summary":"Searched"}"#), now: now, makeId: make)
        #expect(thread.toolActivity == ChatToolActivity(name: "web_search", isRunning: false))
        #expect(thread.toolActivity?.line == "Used web_search")
        thread.apply(try event("tool.start", #"{"tool_id":"t2","name":"browser"}"#), now: now, makeId: make)
        #expect(thread.toolActivity?.line == "Using browser…")
        thread.apply(try event("tool.complete", #"{"tool_id":"t2","name":"browser"}"#), now: now, makeId: make)
        #expect(thread.toolActivity?.line == "Used browser")
        // Text streams: the line stays until the reply plays or the turn ends.
        thread.apply(.messageDelta(MessageDeltaPayload(text: "Here.", turnId: nil, segment: nil, offset: nil)),
                     now: now, makeId: make)
        #expect(thread.toolActivity?.line == "Used browser")
        thread.apply(try event("message.complete", #"{"text":"Here.","status":"complete"}"#), now: now, makeId: make)
        #expect(thread.toolActivity == nil)
    }

    @Test func aParallelToolThatStillRunsWinsOverTheEndedOne() throws {
        var (thread, ids) = running()
        let make = ids.callAsFunction
        thread.apply(try event("tool.start", #"{"tool_id":"t1","name":"web_search"}"#), now: now, makeId: make)
        thread.apply(try event("tool.start", #"{"tool_id":"t2","name":"browser"}"#), now: now, makeId: make)
        thread.apply(try event("tool.complete", #"{"tool_id":"t2","name":"browser"}"#), now: now, makeId: make)
        #expect(thread.toolActivity?.line == "Using web_search…")
        thread.apply(try event("tool.complete", #"{"tool_id":"t1","name":"web_search"}"#), now: now, makeId: make)
        #expect(thread.toolActivity?.line == "Used web_search")
    }

    @Test func aCompleteWithNoStartShowsUsed() throws {
        var (thread, ids) = running()
        thread.apply(try event("tool.complete", #"{"tool_id":"t9","name":"calendar"}"#), now: now,
                     makeId: ids.callAsFunction)
        #expect(thread.toolActivity?.line == "Used calendar")
    }

    @Test func theLineClearsWhenTheTurnFailsOrANewTurnStarts() throws {
        var (thread, ids) = running()
        let make = ids.callAsFunction
        thread.apply(try event("tool.start", #"{"tool_id":"t1","name":"web_search"}"#), now: now, makeId: make)
        thread.apply(try event("tool.complete", #"{"tool_id":"t1","name":"web_search"}"#), now: now, makeId: make)
        thread.connectionLost(now: now, makeId: make)
        #expect(thread.toolActivity == nil)
        thread.addOutgoing(id: "p2", text: "Again", date: now)
        thread.beginTurn(promptId: "p2")
        thread.apply(.messageStart(MessageStartPayload()), now: now, makeId: make)
        #expect(thread.toolActivity == nil)
        // A late tool event of an ended turn does nothing.
        var idle = ChatThread()
        idle.apply(try event("tool.complete", #"{"tool_id":"t1","name":"web_search"}"#), now: now, makeId: make)
        #expect(idle.toolActivity == nil)
    }

    @Test func handsFreeShowsUsedInPlaceOfHermesIsWorking() {
        let used = VoiceTabDisplay.make(state: .thinking, muted: false, thinkingSeconds: 6,
                                        tool: ChatToolActivity(name: "web_search", isRunning: false))
        #expect(used.subtitle == "Used web_search")
        #expect(used.showsTool)
        #expect(used.ringAccessibilityLabel == "Voice Mode, Thinking…, Used web_search")
        // After 10 s the tool line still wins over "Still working…".
        let late = VoiceTabDisplay.make(state: .thinking, muted: false, thinkingSeconds: 30,
                                        tool: ChatToolActivity(name: "web_search", isRunning: false))
        #expect(late.subtitle == "Used web_search")
        // The reply plays: the tool line goes.
        let speaking = VoiceTabDisplay.make(state: .speaking, muted: false, thinkingSeconds: 0,
                                            tool: ChatToolActivity(name: "web_search", isRunning: false))
        #expect(speaking.subtitle == "Tap or speak to interrupt")
        #expect(!speaking.showsTool)
    }

    @Test func liveShowsUsedInPlaceOfStillWorking() throws {
        let used = try #require(VoiceTabDisplay.live(phase: .working, muted: false, speaking: false, idleWarning: false,
                                                     stillWorking: true,
                                                     tool: ChatToolActivity(name: "web_search", isRunning: false)))
        #expect(used.subtitle == "Used web_search")
        #expect(used.showsTool)
        #expect(used.liveAccessibilityLabel(elapsedSeconds: 5) == "Live Mode, Hermes is working…. Used web_search, 0:05")
        let speaking = try #require(VoiceTabDisplay.live(phase: .live, muted: false, speaking: true, idleWarning: false,
                                                         stillWorking: false,
                                                         tool: ChatToolActivity(name: "web_search", isRunning: false)))
        #expect(speaking.subtitle == "Speak any time")
    }
}
