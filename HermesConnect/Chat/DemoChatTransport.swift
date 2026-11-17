#if DEBUG
import Foundation
import HermesKit
import UserNotifications

/// DEBUG only: a notification center with a fixed permission, for the issue #15 screenshots.
struct DemoNotificationCenter: NotificationCentering {
    var status: UNAuthorizationStatus
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization(options _: UNAuthorizationOptions) async throws -> Bool { status == .authorized }
    func add(_: UNNotificationRequest) async throws {}
    func setBadgeCount(_: Int) async throws {}
}

/// DEBUG only: a "Demo conversation" that replays fixture gateway events, so the chat screen
/// runs on the Simulator with no server. Start it with the launch environment `HERMES_DEMO=<scenario>`.
/// Release builds do not contain this file.
final class DemoChatTransport: ChatTransport, SessionsTransport, @unchecked Sendable {
    enum Scenario: String {
        /// Seeded thread. Each send streams a scripted reply.
        case live
        /// Seeded thread, idle.
        case thread
        /// Issue #60: the seeded thread with the composer focused, so the keyboard shows.
        case keyboard
        /// Seeded thread plus a reply that streams with a tool line and holds before `message.complete`.
        case streaming
        /// Seeded thread with a failed reply, plus a send that fails ("Not Delivered").
        case failed
        /// No messages. The composer has focus.
        case empty
        /// Issue #7: the session list with a cron row, an iMessage row and an unread row. No chat is pushed.
        /// `HERMES_DEMO_SEARCH=<text>` puts the text in the search field.
        case list
        /// The session list with no sessions ("No Chats").
        case listEmpty = "list-empty"
        /// The session list before the first answer, with no cache (placeholder rows).
        case listLoading = "list-loading"
        /// Seeded thread with voice memos in each state (issue #9). The composer shows the mic.
        case voice
        /// Seeded thread with hands-free recording at 0:12 (Cancel, timer, waveform, Send).
        case recording
        /// Seeded thread with a held recording and the finger part way to cancel ("Slide to Cancel").
        case hold
        /// Seeded thread with a recording that a phone call paused.
        case paused
        /// Issue #8: photo, file and location bubbles, a failed upload, rings, and 3 items in the strip.
        case attachments
        /// Issue #10: voice replies. One plays, one shows "Preparing audio…", one failed.
        case voiceReplies = "voice-replies"
        /// Issue #10: the same thread with the first voice reply paused part way.
        case voiceRepliesPaused = "voice-replies-paused"
        /// Issue #49: the same thread with the full text of the first voice reply open in a sheet.
        case voiceReplyText = "voice-reply-text"
        /// Issue #11: each agent ack, owner tapbacks, and one bubble with both.
        case tapbacks
        /// Issue #11: the same thread with the tapback capsule open on a reply.
        case tapbacksPicker = "tapbacks-picker"
        /// Issue #12: a reply with `MEDIA:` files in each state: image, PDF, audio, a ring, an error, a large file.
        case receivedFiles = "received-files"
        /// Issue #12: the same thread with the PDF open in Quick Look.
        case receivedFilesPreview = "received-files-preview"

        /// Issue #56: the owner's grocery table reply.
        case markdownTable = "markdown-table"
        /// Issue #56: the same reply, scrolled to its top (large text sizes).
        case markdownTableTop = "markdown-table-top"
        /// Issue #56: the same reply in the full reply sheet.
        case markdownSheet = "markdown-sheet"
        /// Issue #56: a reply with headings, lists, a quote and a rule.
        case markdownBlocks = "markdown-blocks"
        /// Issue #56: the same reply, scrolled to its top (large text sizes).
        case markdownBlocksTop = "markdown-blocks-top"

        /// Issue #15: the seeded thread shows "Updating…" for 4 s, then 2 missed messages arrive.
        case catchUp = "catch-up"
        /// Issue #15: the same catch-up while the owner reads older messages: the "New Messages" pill shows.
        case catchUpPill = "catch-up-pill"
        /// Issue #15: Settings > Notifications. `notifications-off` adds the "Notifications Off" row.
        case notificationSettings = "notifications"
        case notificationsOff = "notifications-off"
        /// Issue #44: Settings > Voice with the transcription picker. The suffix sets the Parakeet row.
        case voiceSettings = "voice-settings"
        case voiceSettingsParakeet = "voice-settings-parakeet"
        case voiceSettingsDownloading = "voice-settings-downloading"
        case voiceSettingsReady = "voice-settings-ready"
        /// QA 52-1: the Parakeet model did not load ("Parakeet model damaged. Download again.").
        case voiceSettingsDamaged = "voice-settings-damaged"
        /// Issue #67: a `/usage` output card and an unknown command error card.
        case slashCommands = "slash-commands"

        static var current: Scenario? {
            ProcessInfo.processInfo.environment["HERMES_DEMO"].flatMap(Scenario.init(rawValue:))
        }

        /// The prompt that the demo sends at launch, if any.
        var autoPrompt: String? {
            switch self {
            case .streaming: "What's the weather in Austin this weekend?"
            case .failed: "Can you check the server logs?"
            case .live, .thread, .keyboard, .empty, .list, .listEmpty, .listLoading, .voice, .recording, .hold, .paused,
                 .attachments, .voiceReplies, .voiceRepliesPaused, .voiceReplyText, .tapbacks, .tapbacksPicker, .receivedFiles, .receivedFilesPreview, .markdownTable, .markdownTableTop, .markdownSheet, .markdownBlocks,
                 .markdownBlocksTop, .catchUp, .catchUpPill,
                 .notificationSettings, .notificationsOff, .voiceSettings, .voiceSettingsParakeet, .voiceSettingsDownloading,
                 .voiceSettingsReady, .voiceSettingsDamaged, .slashCommands: nil
            }
        }

        /// The list scenarios show the session list. The others push the demo chat at launch.
        var showsList: Bool { self == .list || self == .listEmpty || self == .listLoading }

        /// The text in the search field of the list (`HERMES_DEMO_SEARCH`).
        static var search: String? {
            ProcessInfo.processInfo.environment["HERMES_DEMO_SEARCH"]
        }

        /// `true` for the scenarios that show the recording bar with a fake recorder.
        var recordsAtLaunch: Bool { self == .recording || self == .hold || self == .paused }

        /// `true` for the voice reply scenarios (issue #10).
        var showsVoiceReplies: Bool { self == .voiceReplies || self == .voiceRepliesPaused || self == .voiceReplyText }

        /// `true` for the tapback scenarios (issue #11).
        var showsTapbacks: Bool { self == .tapbacks || self == .tapbacksPicker }

        /// `true` for the Markdown scenarios (issue #56).
        var showsMarkdown: Bool {
            [.markdownTable, .markdownTableTop, .markdownSheet, .markdownBlocks, .markdownBlocksTop].contains(self)
        }

        /// `true` for the catch-up scenarios (issue #15).
        var catchesUp: Bool { self == .catchUp || self == .catchUpPill }

        /// `true` for the Settings > Notifications scenarios (issue #15).
        var showsNotificationSettings: Bool { self == .notificationSettings || self == .notificationsOff }
        var showsVoiceSettings: Bool {
            [.voiceSettings, .voiceSettingsParakeet, .voiceSettingsDownloading, .voiceSettingsReady,
             .voiceSettingsDamaged].contains(self)
        }
    }

    let scenario: Scenario
    private let broadcast = GatewayEventBroadcast()
    var events: AsyncStream<GatewayClientEvent> { broadcast.subscribe() }
    private let lock = NSLock()
    private var seq = 0
    private var rowId = 200
    private var stopped = false

    static let sessionId = "d3m0c4t5"
    static let storedId = "20261116_094100_demo01"

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        try await Task.sleep(for: .milliseconds(150))
        return ChatSessionRef(liveId: Self.sessionId, storedId: Self.storedId)
    }

    struct DemoFailure: Error {}

    func resumeSession(storedId: String, source _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: Self.sessionId, storedId: storedId)
    }

    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? {
        try await Task.sleep(for: .milliseconds(350))
        if scenario == .failed { throw DemoFailure() }
        let row = lock.withLock {
            stopped = false
            rowId += 2
            return rowId
        }
        let hold = scenario == .streaming
        Task.detached { [self] in await replay(Self.weatherReply, hold: hold) }
        return row
    }

    func stopReply(sessionId _: String) async throws -> Bool {
        lock.withLock { stopped = true }
        return true
    }

    func submitVoicePrompt(sessionId: String, text: String, retryBeforeRowId: Int?) async throws -> Int? {
        try await submitPrompt(sessionId: sessionId, text: text, retryBeforeRowId: retryBeforeRowId)
    }

    /// A fixed transcript after a short wait. The demo does not read the clip.
    func transcribe(audio _: Data, mimeType _: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(1500))
        if scenario == .failed { throw DemoFailure() }
        return Self.memoTranscript
    }

    /// Issue #10: a soft generated tone as the spoken reply, after a short wait. No server.
    func speak(text _: String) async throws -> SpokenAudio {
        try await Task.sleep(for: .milliseconds(1200))
        if scenario == .failed { throw DemoFailure() }
        return SpokenAudio(data: Self.toneWAV(seconds: 6), mimeType: "audio/wav")
    }

    /// A quiet 8 kHz mono 16-bit WAV tone.
    static func toneWAV(seconds: Double) -> Data {
        let rate = 8000
        let count = Int(Double(rate) * seconds)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(count * 2))
        for index in 0..<count {
            // Issue #49: the loudness rises and falls like speech, so the reply waveform has shape.
            let time = Double(index) / Double(rate)
            let envelope = 0.15 + 0.85 * abs(sin(time * 2.3) * sin(time * 0.9 + 0.6))
            let sample = sin(Double(index) * 2 * .pi * 220 / Double(rate)) * 4000 * envelope
            append(Int16(sample))
        }
        return data
    }

    /// The saved demo reply file of the voice reply scenarios.
    static func demoReplyAudio(seconds: Double) -> VoiceReplyAudio {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-reply-v49-\(Int(seconds)).wav")
        if !FileManager.default.fileExists(atPath: url.path) { try? toneWAV(seconds: seconds).write(to: url) }
        return VoiceReplyAudio(fileURL: url, duration: seconds, waveform: VoiceWaveform.bars(contentsOf: url) ?? [])
    }

    static let memoTranscript = "Remind me to call Sam at three about the lease, and ask whether the movers can come "
        + "on Saturday morning instead of Friday, because the elevator is booked on Friday afternoon."

    /// The demo has no server transcript. The seeded messages stay as they are.
    /// Issue #15: the catch-up scenarios return the seeded thread plus 2 missed messages after 4 s.
    func history(sessionId _: String) async throws -> [TranscriptMessage] {
        guard scenario.catchesUp else { throw DemoFailure() }
        try await Task.sleep(for: .seconds(4))
        let seeds = seedMessages(now: Self.seedDate)
        var rows = seeds.map { message in
            var row = TranscriptMessage(role: message.role == .user ? "user" : "assistant", text: message.text,
                                        rowId: message.userRowId ?? seeds.first { $0.id == message.promptId }
                                            .flatMap(\.userRowId).map { $0 + 1 })
            row.timestamp = message.date.timeIntervalSince1970
            return row
        }
        let late = Self.seedDate.addingTimeInterval(-60)
        for (index, (role, text)) in Self.missedMessages.enumerated() {
            var row = TranscriptMessage(role: role, text: text, rowId: 107 + index)
            row.timestamp = late.addingTimeInterval(Double(index) * 20).timeIntervalSince1970
            rows.append(row)
        }
        return rows
    }

    /// One date for the seeded thread, so the catch-up history keeps the same times.
    static let seedDate = Date()

    static let missedMessages = [
        ("user", "Cron: morning digest"),
        ("assistant", "Your digest: 3 new emails, rain after 4 PM, and the movers confirmed Saturday at 9 AM."),
    ]

    // MARK: Session list

    func fetchSessions() async throws -> [SessionListItem] {
        if scenario == .listLoading {
            try await Task.sleep(for: .seconds(3600))
        }
        try await Task.sleep(for: .milliseconds(300))
        return scenario == .listEmpty ? [] : Self.sessionRows()
    }

    func fetchMostRecentSessionId() async throws -> String? {
        scenario.showsList ? nil : Self.storedId
    }

    /// The fixture list: the demo chat, a cron run (unread), an iMessage session and older chats.
    static func sessionRows(now: Date = Date()) -> [SessionListItem] {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let lastWeek = calendar.date(byAdding: .day, value: -4, to: now) ?? now
        let older = calendar.date(byAdding: .day, value: -24, to: now) ?? now
        return [
            SessionListItem(id: storedId, title: "Calendar and logs",
                            preview: "Run this on the server: journalctl --user -u hermes-gateway -f",
                            startedAt: now.addingTimeInterval(-6 * 60), messageCount: 6, source: ChatSource.iOS),
            SessionListItem(id: "cron_a1_20261117_080000", title: "Morning Zillow new rental watch",
                            preview: "3 new issues, 2 merged PRs and a calendar change for Thursday.",
                            startedAt: now.addingTimeInterval(-3 * 3600), messageCount: 2, source: "cron",
                            isUnread: true),
            SessionListItem(id: "20261115_181200_photon", title: "Dinner plans",
                            preview: "Booked a table for two at 7:30 PM. The confirmation is in your email.",
                            startedAt: yesterday, messageCount: 8, source: "photon"),
            SessionListItem(id: "20261112_090000_trip01", title: "Trip to Denver",
                            preview: "The flight lands at 11:05 AM. I added the hotel to your calendar.",
                            startedAt: lastWeek, messageCount: 14, source: ChatSource.iOS),
            SessionListItem(id: "20261023_140000_old001", title: nil,
                            preview: "Here is the summary of the PDF that you sent.",
                            startedAt: older, messageCount: 3, source: "desktop"),
        ]
    }

    // MARK: Replay

    private var isStopped: Bool { lock.withLock { stopped } }

    private func emit(_ type: String, _ payload: String) {
        let next = lock.withLock {
            seq += 1
            return seq
        }
        let json = #"{"type":"\#(type)","session_id":"\#(Self.sessionId)","seq":\#(next),"payload":\#(payload)}"#
        guard let event = try? JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8)) else { return }
        broadcast.yield(.event(event))
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func replay(_ reply: String, hold: Bool) async {
        emit("message.start", #"{"turn_id":"demo"}"#)
        try? await Task.sleep(for: .milliseconds(900))
        emit("tool.start", #"{"tool_id":"t1","name":"web_search"}"#)
        try? await Task.sleep(for: .milliseconds(1200))
        emit("tool.complete", #"{"tool_id":"t1","name":"web_search"}"#)
        let words = reply.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let stopAt = hold ? words.count * 3 / 5 : words.count
        var offset = 0
        for (index, word) in words.enumerated() {
            if isStopped {
                emit("message.complete", #"{"text":"","status":"interrupted"}"#)
                return
            }
            if index == stopAt { return }
            let chunk = index == 0 ? word : " " + word
            emit("message.delta", #"{"text":\#(Self.quoted(chunk)),"turn_id":"demo","segment":0,"offset":\#(offset)}"#)
            offset += chunk.utf16.count
            try? await Task.sleep(for: .milliseconds(45))
        }
        emit("message.complete", #"{"text":\#(Self.quoted(reply)),"status":"complete"}"#)
    }

    static let weatherReply = """
        Austin looks **warm and dry** this weekend: Saturday 78°F and sunny, Sunday 74°F with a light \
        breeze. Rain chances stay under *10%*. Forecast source: https://example.com/weather/austin
        """

    // MARK: Seed

    /// The seeded history: a time header, a short run, a code block, a link and a long reply.
    func seedMessages(now: Date = Date()) -> [ChatMessage] {
        guard scenario != .empty else { return [] }
        let early = now.addingTimeInterval(-2 * 3600)
        let recent = now.addingTimeInterval(-6 * 60)
        var messages = [
            ChatMessage(id: "d1", role: .user, text: "What's on my calendar tomorrow?", date: early,
                        delivery: .delivered, userRowId: 101),
            ChatMessage(id: "d2", role: .assistant,
                        text: "You have **two** meetings tomorrow:\n10:00 AM *Design review*\n2:30 PM Call with Sam\n"
                            + "Details are in [your calendar](https://example.com/calendar).",
                        date: early.addingTimeInterval(20), reply: .complete, promptId: "d1"),
            ChatMessage(id: "d3", role: .user, text: "Move the call to 3?", date: early.addingTimeInterval(60),
                        delivery: .delivered, userRowId: 103),
            ChatMessage(id: "d4", role: .assistant, text: "Done. The call with Sam is now at 3:00 PM.",
                        date: early.addingTimeInterval(75), reply: .complete, promptId: "d3"),
            ChatMessage(id: "d5", role: .user, text: "How do I follow the gateway log?", date: recent,
                        delivery: .delivered, userRowId: 105),
            ChatMessage(id: "d6", role: .assistant,
                        text: "Run this on the server:\n```\njournalctl --user -u hermes-gateway -f\n```\n"
                            + "Press `Ctrl-C` to stop. The log shows each turn, tool call and reconnect, so it is "
                            + "the first place to look when a reply is slow or a tool fails. Add `--since \"10 min ago\"` "
                            + "to see only recent lines.",
                        date: recent.addingTimeInterval(15), reply: .complete, promptId: "d5"),
        ]
        if scenario.showsVoiceReplies {
            messages += Self.voiceReplyMessages(now: now)
        }
        if scenario == .voice || scenario.recordsAtLaunch {
            let late = now.addingTimeInterval(-3 * 60)
            func memo(_ name: String, _ seconds: TimeInterval, _ transcript: VoiceTranscript) -> VoiceMemo {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).m4a")
                let levels = (0..<VoiceMemoLimits.waveformBars).map { index in
                    Float(0.25 + 0.6 * abs(sin(Double(index) * 0.7 + seconds)))
                }
                return VoiceMemo(fileURL: url, duration: seconds, waveform: levels, transcript: transcript)
            }
            messages.append(ChatMessage(id: "v1", role: .user, text: Self.memoTranscript, date: late,
                                        delivery: .delivered, userRowId: 107,
                                        voice: memo("v1", 14, .done(Self.memoTranscript))))
            messages.append(ChatMessage(id: "v2", role: .assistant,
                                        text: "I'll remind you at 2:55 PM. I also asked the movers about Saturday.",
                                        date: late.addingTimeInterval(8), reply: .complete, promptId: "v1"))
            messages.append(ChatMessage(id: "v3", role: .user, text: "", date: late.addingTimeInterval(60),
                                        delivery: .failed, voice: memo("v3", 3, .empty)))
            messages.append(ChatMessage(id: "v4", role: .user, text: "", date: late.addingTimeInterval(90),
                                        delivery: .failed, voice: memo("v4", 22, .failed)))
            if scenario == .voice {
                messages.append(ChatMessage(id: "v5", role: .user, text: "", date: late.addingTimeInterval(120),
                                            delivery: .sending, voice: memo("v5", 9, .pending)))
            }
        }
        if scenario == .failed {
            messages.append(ChatMessage(id: "d7", role: .user, text: "Summarize today's inbox",
                                        date: recent.addingTimeInterval(90), delivery: .delivered, userRowId: 107))
            messages.append(ChatMessage(id: "d8", role: .assistant, text: "You have 14 new emails. The most urgent",
                                        date: recent.addingTimeInterval(100), reply: .failed(message: nil),
                                        promptId: "d7"))
        }
        if scenario == .attachments { messages += AttachmentDemo.messages(now: now) }
        if scenario == .slashCommands {
            let late = now.addingTimeInterval(-60)
            messages.append(ChatMessage(id: "c1", role: .assistant, text: "", date: late, command: ChatCommandCard(
                command: "/usage", output: "Usage: 12 calls · 48,210 in / 6,904 out · 55,114 total")))
            messages.append(ChatMessage(id: "c2", role: .assistant, text: "", date: late.addingTimeInterval(20),
                                        command: ChatCommandCard(command: "/foo", output: "Unknown command: /foo",
                                                                 isError: true)))
        }
        if scenario == .receivedFiles || scenario == .receivedFilesPreview { messages += ReceivedFileDemo.messages(now: now) }
        if scenario.showsTapbacks { messages += Self.tapbackMessages(now: now) }
        if scenario.showsMarkdown {
            let late = now.addingTimeInterval(-60)
            let table = scenario != .markdownBlocks && scenario != .markdownBlocksTop
            messages.append(ChatMessage(id: "m1", role: .user,
                                        text: table ? "What grocery stores are near me?" : "Plan my Saturday move",
                                        date: late, delivery: .delivered, userRowId: 401))
            messages.append(ChatMessage(id: "m2", role: .assistant, text: table ? Self.groceryTable : Self.markdownBlocks,
                                        date: late.addingTimeInterval(9), reply: .complete, promptId: "m1"))
        }
        return messages
    }

    /// Issue #56: the reply in the owner's screenshot (`.team/qa/owner-56/01-table-raw.png`).
    static let groceryTable = """
    Two nearby grocery options in **Anaconda**, using the location your phone just reported:

    | Store | Estimated drive | Address |
    |---|---:|---|
    | **Albertsons** | **10 minutes · 7.1 miles** | 1300 E Park Ave. Listed hours: **7 a.m.–10 p.m. daily**. ([local.albertsons.com](https://local.albertsons.com/mt/anaconda/1300-e-park-ave.html)) |
    | **Stokes Market** | **14 minutes · 9.2 miles** | 1525 W Park Ave. ([stokesmarket.com](https://stokesmarket.com)) |

    I'd pick **Albertsons** for the shorter trip. Drive estimates don't include live traffic or road conditions.
    """

    /// Issue #56: headings, lists, a quote and a rule.
    static let markdownBlocks = """
    # Saturday move
    ## Morning
    1. Pick up the van at **8:00 AM**
    2. Load the boxes
       - Kitchen first
       - Then the books
    3. Drive to the new place

    ### Bring
    - Tape and markers
    - Water and snacks

    > The movers said: park on Elm St. The alley is closed.

    ---
    Text me if the van is late.
    """

    /// Issue #11: the reply that the picker scenario opens the capsule on.
    static let tapbackPickerId = "t6"

    /// Issue #11: thumbs up, heart (thanks), no ack (slash command), thumbs down and eyes, plus owner tapbacks.
    static func tapbackMessages(now: Date) -> [ChatMessage] {
        let late = now.addingTimeInterval(-4 * 60)
        func prompt(_ id: String, _ text: String, _ seconds: Double, ack: AgentAck?,
                    tapback: Tapback? = nil) -> ChatMessage {
            ChatMessage(id: id, role: .user, text: text, date: late.addingTimeInterval(seconds), delivery: .delivered,
                        userRowId: 300 + Int(seconds), agentAck: ack, tapback: tapback)
        }
        func reply(_ id: String, _ text: String, _ seconds: Double, to promptId: String,
                   reply: ChatMessage.Reply = .complete, tapback: Tapback? = nil) -> ChatMessage {
            ChatMessage(id: id, role: .assistant, text: text, date: late.addingTimeInterval(seconds), reply: reply,
                        promptId: promptId, tapback: tapback)
        }
        return [
            prompt("t1", "Book the 7:40 train to Dallas", 0, ack: .done, tapback: .exclamation),
            reply("t2", "Booked. Seat 14C, arrives 11:05 AM.", 10, to: "t1", tapback: .heart),
            prompt("t3", "Thanks!", 20, ack: .thanks),
            reply("t4", "Any time.", 25, to: "t3"),
            prompt("t5", "/usage", 40, ack: nil),
            reply("t6", "312k tokens today, 41% of the daily budget.", 42, to: "t5", tapback: .haha),
            prompt("t7", "Restart the backup job", 60, ack: .failed),
            reply("t8", "The backup host did not answer.", 70, to: "t7", reply: .failed(message: nil)),
            prompt("t9", "Check the disk on the server", 90, ack: .seen),
        ]
    }

    /// Issue #10: three voice turns. The replies have audio that is ready, "Preparing audio…" and failed.
    static func voiceReplyMessages(now: Date) -> [ChatMessage] {
        let late = now.addingTimeInterval(-3 * 60)
        func memo(_ name: String, _ seconds: TimeInterval, _ text: String) -> VoiceMemo {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).m4a")
            let levels = (0..<VoiceMemoLimits.waveformBars).map { index in
                Float(0.25 + 0.6 * abs(sin(Double(index) * 0.7 + seconds)))
            }
            return VoiceMemo(fileURL: url, duration: seconds, waveform: levels, transcript: .done(text))
        }
        let ask1 = "What's on my calendar tomorrow?"
        let ask2 = "Move the call with Sam to three."
        let ask3 = "Remind me to pack the charger."
        return [
            ChatMessage(id: "r1", role: .user, text: ask1, date: late, delivery: .delivered, userRowId: 111,
                        voice: memo("r1", 3, ask1), agentAck: .done),
            ChatMessage(id: "r2", role: .assistant,
                        text: "You have two meetings tomorrow: the **design review** at 10 and the call with Sam "
                            + "at 2:30. The review room changed to *Juniper*, and Sam asked to move the call if the "
                            + "review runs long.",
                        date: late.addingTimeInterval(6), reply: .complete, promptId: "r1",
                        spokenReply: .ready(demoReplyAudio(seconds: 24)), tapback: .heart),
            ChatMessage(id: "r3", role: .user, text: ask2, date: late.addingTimeInterval(40), delivery: .delivered,
                        userRowId: 113, voice: memo("r3", 2, ask2)),
            ChatMessage(id: "r4", role: .assistant, text: "Done. The call with Sam is now at 3:00 PM.",
                        date: late.addingTimeInterval(46), reply: .complete, promptId: "r3", spokenReply: .failed),
            ChatMessage(id: "r5", role: .user, text: ask3, date: late.addingTimeInterval(80), delivery: .delivered,
                        userRowId: 115, voice: memo("r5", 2, ask3)),
            ChatMessage(id: "r6", role: .assistant, text: "I'll remind you at 8 PM tonight.",
                        date: late.addingTimeInterval(86), reply: .complete, promptId: "r5", spokenReply: .preparing),
        ]
    }
}
/// DEBUG only: a recorder with no microphone. Time starts at 0:12 and the levels are a fixed wave.
@MainActor
final class DemoVoiceRecorder: VoiceRecording {
    private var startedAt: Date?
    private var pausedAt: TimeInterval?
    private var ticks = 0
    var onInterruption: (() -> Void)?

    var access: MicrophoneAccess { .granted }
    func requestAccess() async -> Bool { true }
    func start(url _: URL) throws { startedAt = Date() }
    func pause() { pausedAt = currentTime }
    func stop() -> TimeInterval { defer { startedAt = nil }; return currentTime }
    func discard() { startedAt = nil }

    var currentTime: TimeInterval {
        if let pausedAt { return pausedAt }
        guard let startedAt else { return 0 }
        return 12 + Date().timeIntervalSince(startedAt)
    }

    func level() -> Float {
        ticks += 1
        return -40 + 34 * Float(abs(sin(Double(ticks) * 0.45)) * (0.5 + 0.5 * abs(cos(Double(ticks) * 0.13))))
    }

    /// Puts the controller in the state of the scenario.
    static func start(_ scenario: DemoChatTransport.Scenario, on controller: VoiceMemoController) {
        switch scenario {
        case .recording:
            controller.startTapMode()
        case .hold:
            controller.press()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                controller.drag(dx: -34)
            }
        case .paused:
            controller.startTapMode()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                controller.interrupt()
            }
        default:
            break
        }
    }
}
#endif

#if DEBUG
/// Issue #12: fixture downloads for `HERMES_DEMO=received-files`. No network. The path picks the result.
extension DemoChatTransport: ReceivedFileDownloading {
    func downloadReceivedFile(path: String, storedSessionId _: String?, maxBytes: Int?,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await ReceivedFileDemo.download(path: path, maxBytes: maxBytes, progress: progress)
    }
}
#endif
