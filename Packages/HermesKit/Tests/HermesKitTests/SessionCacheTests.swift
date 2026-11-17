import Foundation
import Testing
@testable import HermesKit

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "SessionCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private let base = Date(timeIntervalSince1970: 1_763_290_000)

private func thread(_ count: Int) -> [ChatMessage] {
    (0..<count).map { index in
        index.isMultiple(of: 2)
            ? ChatMessage(id: "u\(index)", role: .user, text: "Prompt \(index)", date: base.addingTimeInterval(Double(index)),
                          delivery: .delivered, userRowId: index)
            : ChatMessage(id: "a\(index)", role: .assistant, text: "Reply \(index)", date: base.addingTimeInterval(Double(index)),
                          reply: .complete, promptId: "u\(index - 1)")
    }
}

@Suite struct SessionCacheStoreTests {
    @Test func transcriptRoundTripsThroughTheFile() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionCacheStore(directory: directory)
        var messages = thread(4)
        messages[3].reply = .interrupted
        store.saveTranscript(messages, sessionId: "20261116_101500_ab12cd")

        // A new store on the same folder reads the same messages (an app restart).
        let loaded = FileSessionCacheStore(directory: directory).loadTranscript(sessionId: "20261116_101500_ab12cd")
        #expect(loaded == messages)
        #expect(store.loadTranscript(sessionId: "other").isEmpty)
    }

    @Test func transcriptKeepsTheLast500EndedMessages() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionCacheStore(directory: directory)
        var messages = thread(600)
        messages.append(ChatMessage(id: "s", role: .user, text: "Sending", date: base, delivery: .sending))
        messages.append(ChatMessage(id: "f", role: .user, text: "Failed", date: base, delivery: .failed))
        messages.append(ChatMessage(id: "r", role: .assistant, text: "Stream", date: base, reply: .streaming))
        messages.append(ChatMessage(id: "x", role: .assistant, text: "Broken", date: base, reply: .failed(message: nil)))
        store.saveTranscript(messages, sessionId: "k1")
        let loaded = store.loadTranscript(sessionId: "k1")
        #expect(loaded.count == SessionCache.transcriptLimit)
        #expect(loaded.first?.id == "u100")
        #expect(loaded.last?.id == "a599")
    }

    @Test func sessionsDraftsAndActiveIdRoundTrip() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionCacheStore(directory: directory)
        let rows = [
            SessionListItem(id: "k2", title: nil, preview: "Digest", startedAt: base, source: "cron", isUnread: true),
            SessionListItem(id: "k1", title: "Trip", preview: "Book it", startedAt: base, messageCount: 4, source: "ios"),
        ]
        store.saveSessions(rows)
        store.saveDraft("half a thought", sessionId: "k1")
        store.saveActiveSessionId("k1")

        let reopened = FileSessionCacheStore(directory: directory)
        #expect(reopened.loadSessions() == rows)
        #expect(reopened.loadDraft(sessionId: "k1") == "half a thought")
        #expect(reopened.loadDraft(sessionId: "k2") == "")
        #expect(reopened.loadActiveSessionId() == "k1")

        reopened.saveDraft("", sessionId: "k1")
        reopened.saveActiveSessionId(nil)
        #expect(store.loadDraft(sessionId: "k1") == "")
        #expect(store.loadActiveSessionId() == nil)
    }

    /// A file from an older or newer build: missing keys get defaults, unknown keys are ignored.
    @Test func filesWithOtherVersionsStillLoad() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionCacheStore(directory: directory)
        try FileManager.default.createDirectory(at: store.transcriptURL(sessionId: "k1").deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"version":1,"body":[{"id":"k1","title":"Trip"}]}"#.utf8).write(to: store.sessionsURL)
        try Data(#"{"version":2,"future":true,"body":{"activeSessionId":"k1","pinned":["k1"]}}"#.utf8).write(to: store.stateURL)
        try Data(#"{"version":1,"body":[{"id":"m1","role":"user","text":"Hi","date":1763290000},{"id":"m2","extra":1}]}"#.utf8)
            .write(to: store.transcriptURL(sessionId: "k1"))

        #expect(store.loadSessions() == [SessionListItem(id: "k1", title: "Trip")])
        #expect(store.loadActiveSessionId() == "k1")
        #expect(store.loadDraft(sessionId: "k1") == "")
        let messages = store.loadTranscript(sessionId: "k1")
        #expect(messages.map(\.id) == ["m1", "m2"])
        #expect(messages[0].delivery == .delivered)
        #expect(messages[1].role == .assistant)
        #expect(messages[1].reply == .complete)
    }

    @Test func brokenFilesReadAsEmpty() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionCacheStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.sessionsURL)
        try Data("[]".utf8).write(to: store.stateURL)
        #expect(store.loadSessions().isEmpty)
        #expect(store.loadActiveSessionId() == nil)
        // A save after a broken file writes a good file.
        store.saveActiveSessionId("k9")
        #expect(store.loadActiveSessionId() == "k9")
    }

    @Test func transcriptFileNamesStayInTheFolder() throws {
        let store = FileSessionCacheStore(directory: URL(filePath: "/tmp/cache", directoryHint: .isDirectory))
        let url = store.transcriptURL(sessionId: "../../etc/passwd")
        #expect(url.deletingLastPathComponent().path == "/tmp/cache/transcripts")
        #expect(!url.lastPathComponent.contains("/"))
        #expect(store.transcriptURL(sessionId: "a") != store.transcriptURL(sessionId: "b"))
    }

    @Test func folderIsExcludedFromBackup() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionCacheStore(directory: directory)
        store.saveActiveSessionId("k1")
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}

@Suite struct ChatHistoryTests {
    private func row(_ role: String, _ text: String?, _ rowId: Int?, at time: Double? = nil,
                     kind: String? = nil) -> TranscriptMessage {
        var row = TranscriptMessage(role: role, text: text, rowId: rowId)
        row.timestamp = time
        row.displayKind = kind
        return row
    }

    @Test func transcriptBecomesBubbles() {
        var parts = TranscriptMessage(role: "user", rowId: 5)
        parts.content = .array([.object(["type": "text", "text": "Look"]), .object(["type": "image_url"])])
        let transcript = [
            row("system", "You are Hermes", 1),
            row("user", "Hi", 2, at: 1_763_290_000),
            row("assistant", "Let me check", 3, at: 1_763_290_001),
            row("tool", "{}", 4),
            row("assistant", "Hello!", 5, at: 1_763_290_009),
            parts,
            row("assistant", "", 7),
            row("user", "secret", 8, kind: "hidden"),
        ]
        let messages = ChatHistory.messages(from: transcript, fallbackDate: base)
        #expect(messages.map(\.text) == ["Hi", "Hello!", "Look"])
        #expect(messages.map(\.id) == ["row-2", "row-3", "row-5"])
        #expect(messages[0].userRowId == 2)
        #expect(messages[0].delivery == .delivered)
        #expect(messages[1].reply == .complete)
        #expect(messages[1].promptId == "row-2")
        #expect(messages[1].date == Date(timeIntervalSince1970: 1_763_290_009))
        // No timestamp: the row takes the date of the row before it.
        #expect(messages[2].date == Date(timeIntervalSince1970: 1_763_290_009))
    }

    @Test func mergeKeepsTheIdsOnScreen() {
        let current = [
            ChatMessage(id: "live-u", role: .user, text: "Hi", date: base, delivery: .delivered, userRowId: 2),
            ChatMessage(id: "live-a", role: .assistant, text: "Hello", date: base, reply: .interrupted, promptId: "live-u"),
        ]
        let messages = ChatHistory.messages(from: [row("user", "Hi", 2), row("assistant", "Hello", 3),
                                                   row("user", "More", 4)], reusing: current)
        #expect(messages.map(\.id) == ["live-u", "live-a", "row-4"])
        #expect(messages[1].reply == .interrupted)
        #expect(messages[1].promptId == "live-u")
    }

    @Test func replaceHistoryKeepsSendsInProgress() {
        var thread = ChatThread(messages: [
            ChatMessage(id: "u1", role: .user, text: "Hi", date: base, delivery: .delivered, userRowId: 2),
            ChatMessage(id: "x", role: .assistant, text: "", date: base, reply: .failed(message: nil), promptId: "u1"),
            ChatMessage(id: "f", role: .user, text: "Not sent", date: base, delivery: .failed),
            ChatMessage(id: "s", role: .user, text: "Sending", date: base, delivery: .sending),
        ])
        let history = [
            ChatMessage(id: "u1", role: .user, text: "Hi", date: base, delivery: .delivered, userRowId: 2),
            ChatMessage(id: "row-3", role: .assistant, text: "Hello", date: base, reply: .complete, promptId: "u1"),
        ]
        let changed = thread.replaceHistory(history)
        #expect(changed)
        // The failed reply goes: the history has the real reply. The failed and pending sends stay.
        #expect(thread.messages.map(\.id) == ["u1", "row-3", "f", "s"])
        let again = thread.replaceHistory(history)
        #expect(!again)
    }
}

/// A sessions transport with scripted answers. No network.
final class FakeSessionsTransport: SessionsTransport, @unchecked Sendable {
    let events: AsyncStream<GatewayClientEvent>
    let input: AsyncStream<GatewayClientEvent>.Continuation
    private let lock = NSLock()
    private var _rows: [SessionListItem]
    private var _fetches = 0
    var mostRecent: String?
    var fail = false

    init(rows: [SessionListItem] = [], mostRecent: String? = nil) {
        _rows = rows
        self.mostRecent = mostRecent
        (events, input) = AsyncStream.makeStream(of: GatewayClientEvent.self)
    }

    var rows: [SessionListItem] {
        get { lock.withLock { _rows } }
        set { lock.withLock { _rows = newValue } }
    }

    var fetches: Int { lock.withLock { _fetches } }

    func fetchSessions() async throws -> [SessionListItem] {
        lock.withLock { _fetches += 1 }
        if lock.withLock({ fail }) { throw FakeChatTransport.Failure() }
        return rows
    }

    func fetchMostRecentSessionId() async throws -> String? {
        if lock.withLock({ fail }) { throw FakeChatTransport.Failure() }
        return lock.withLock { mostRecent }
    }
}

private func gatewayEvent(_ json: String) throws -> GatewayClientEvent {
    .event(try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8)))
}

private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not met")
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SessionListModelTests {
    private let rows = [
        SessionListItem(id: "k3", title: "Newest", preview: "Latest reply", startedAt: base.addingTimeInterval(30), source: "ios"),
        SessionListItem(id: "k2", title: "", preview: "Daily digest", startedAt: base.addingTimeInterval(20), source: "telegram"),
        SessionListItem(id: "k1", title: "Trip plan", preview: "Book the hotel", startedAt: base, source: "photon"),
    ]

    @Test func cachedListShowsAtOnceThenTheNetworkListReplacesIt() async throws {
        let cache = InMemorySessionCacheStore(sessions: [rows[2]])
        let transport = FakeSessionsTransport(rows: rows)
        let model = SessionListModel(transport: transport, chatTransport: FakeChatTransport(), cache: cache)
        #expect(model.sessions.map(\.id) == ["k1"])
        #expect(model.hasLoaded)
        await model.refresh()
        // Server order: newest first.
        #expect(model.sessions.map(\.id) == ["k3", "k2", "k1"])
        #expect(cache.loadSessions() == rows)
    }

    @Test func noCacheIsNotLoadedUntilTheFirstAnswer() async throws {
        let transport = FakeSessionsTransport(rows: [])
        transport.fail = true
        let model = SessionListModel(transport: transport, chatTransport: FakeChatTransport(),
                                     cache: InMemorySessionCacheStore())
        #expect(!model.hasLoaded)
        await model.refresh()
        // Offline: still the placeholder rows.
        #expect(!model.hasLoaded)
        transport.fail = false
        await model.refresh()
        #expect(model.hasLoaded)
        #expect(model.sessions.isEmpty)
    }

    @Test func failedRefreshKeepsTheCachedList() async throws {
        let transport = FakeSessionsTransport()
        transport.fail = true
        let model = SessionListModel(transport: transport, chatTransport: FakeChatTransport(),
                                     cache: InMemorySessionCacheStore(sessions: rows))
        await model.refresh()
        #expect(model.sessions == rows)
    }

    @Test func searchFiltersTitlesAndPreviewsLocally() {
        let model = SessionListModel(transport: FakeSessionsTransport(), chatTransport: FakeChatTransport(),
                                     cache: InMemorySessionCacheStore(sessions: rows))
        #expect(model.filtered("").count == 3)
        #expect(model.filtered("trip").map(\.id) == ["k1"])
        #expect(model.filtered("DIGEST").map(\.id) == ["k2"])
        #expect(model.filtered("untitled").map(\.id) == ["k2"])
        #expect(model.filtered("zebra").isEmpty)
    }

    @Test func connectSessionsChangedAndTitleEventsUpdateTheList() async throws {
        let transport = FakeSessionsTransport(rows: [rows[2]])
        let cache = InMemorySessionCacheStore()
        let model = SessionListModel(transport: transport, chatTransport: FakeChatTransport(), cache: cache)
        model.startEvents()
        transport.input.yield(.state(.connected(GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef"))))
        try await waitUntil { model.sessions.map(\.id) == ["k1"] }
        transport.rows = rows
        transport.input.yield(try gatewayEvent(#"{"type":"sessions.changed","payload":{}}"#))
        try await waitUntil { model.sessions.count == 3 }
        transport.input.yield(try gatewayEvent(#"{"type":"session.title","session_id":"s9","payload":{"session_id":"k2","title":"Digest"}}"#))
        try await waitUntil { model.session(id: "k2")?.title == "Digest" }
        #expect(cache.loadSessions().first { $0.id == "k2" }?.title == "Digest")
    }

    @Test func unreadMarkSurvivesARefresh() async throws {
        var cached = rows
        cached[1].isUnread = true
        let model = SessionListModel(transport: FakeSessionsTransport(rows: rows), chatTransport: FakeChatTransport(),
                                     cache: InMemorySessionCacheStore(sessions: cached))
        await model.refresh()
        #expect(model.session(id: "k2")?.isUnread == true)
        #expect(model.session(id: "k3")?.isUnread == false)
    }

    @Test func oneChatModelPerSession() async throws {
        let model = SessionListModel(transport: FakeSessionsTransport(), chatTransport: FakeChatTransport(),
                                     cache: InMemorySessionCacheStore(sessions: rows))
        let chat = model.chat(for: "k1")
        #expect(model.chat(for: "k1") === chat)
        #expect(chat.title == "Trip plan")
        #expect(model.chat(for: "k2").title == "Untitled")
        #expect(model.newChat(key: "n1") === model.newChat(key: "n1"))
        #expect(model.newChat(key: "n1") !== model.newChat(key: "n2"))
    }

    @Test func forgetDropsTheRowTheChatAndTheActiveId() {
        let cache = InMemorySessionCacheStore(sessions: rows, activeSessionId: "k2")
        let model = SessionListModel(transport: FakeSessionsTransport(), chatTransport: FakeChatTransport(), cache: cache)
        let chat = model.chat(for: "k2")
        model.forget("k2")
        #expect(model.sessions.map(\.id) == ["k3", "k1"])
        #expect(cache.loadSessions().map(\.id) == ["k3", "k1"])
        #expect(cache.loadActiveSessionId() == nil)
        #expect(model.chat(for: "k2") !== chat)
        // An id that is not the active id leaves the active id alone.
        cache.saveActiveSessionId("k1")
        model.forget("k3")
        #expect(cache.loadActiveSessionId() == "k1")
    }

    @Test func mostRecentComesFromTheServer() async {
        let transport = FakeSessionsTransport(mostRecent: "k3")
        let model = SessionListModel(transport: transport, chatTransport: FakeChatTransport(),
                                     cache: InMemorySessionCacheStore(activeSessionId: "k1"))
        #expect(model.cachedActiveSessionId == "k1")
        #expect(await model.mostRecentSessionId() == "k3")
        transport.fail = true
        #expect(await model.mostRecentSessionId() == nil)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SessionResumeTests {
    private let cached = [
        ChatMessage(id: "c1", role: .user, text: "Hi", date: base, delivery: .delivered, userRowId: 2),
        ChatMessage(id: "c2", role: .assistant, text: "Hello", date: base, reply: .complete, promptId: "c1"),
    ]

    @Test func openShowsTheCacheThenMergesTheHistory() async throws {
        let transport = FakeChatTransport()
        transport.transcript = [TranscriptMessage(role: "user", text: "Hi", rowId: 2),
                                TranscriptMessage(role: "assistant", text: "Hello", rowId: 3),
                                TranscriptMessage(role: "user", text: "From the Mac", rowId: 4),
                                TranscriptMessage(role: "assistant", text: "Done", rowId: 5)]
        let cache = InMemorySessionCacheStore(transcripts: ["k1": cached])
        let model = ChatViewModel(transport: transport, storedSessionId: "k1", cache: cache)
        // The cache shows before any network call.
        #expect(model.messages == cached)
        #expect(!model.isLoadingHistory)

        await model.open()
        #expect(transport.resumes == ["k1"])
        #expect(transport.histories == ["s2"])
        #expect(transport.starts.isEmpty)
        // The cached ids stay, so the thread does not reload or move.
        #expect(model.messages.map(\.id) == ["c1", "c2", "row-4", "row-5"])
        #expect(cache.loadTranscript(sessionId: "k1").map(\.text) == ["Hi", "Hello", "From the Mac", "Done"])
        #expect(cache.loadActiveSessionId() == "k1")

        // A send uses the resumed live id. No second resume, no create.
        await model.send("Thanks")?.value
        #expect(transport.submits.last?.sessionId == "s2")
        #expect(transport.resumes == ["k1"])
        #expect(cache.loadTranscript(sessionId: "k1").last?.text == "Thanks")
    }

    @Test func noCacheShowsTheLoaderUntilTheHistoryComes() async throws {
        let transport = FakeChatTransport()
        transport.transcript = [TranscriptMessage(role: "user", text: "Hi", rowId: 2)]
        let model = ChatViewModel(transport: transport, storedSessionId: "k1", cache: InMemorySessionCacheStore())
        #expect(model.messages.isEmpty)
        let open = Task { await model.open() }
        try await waitUntil { model.isLoadingHistory || !model.messages.isEmpty }
        await open.value
        #expect(!model.isLoadingHistory)
        #expect(model.messages.map(\.text) == ["Hi"])
    }

    @Test func offlineOpenKeepsTheCacheAndRetriesOnConnect() async throws {
        let transport = FakeChatTransport()
        transport.failStart = true
        let cache = InMemorySessionCacheStore(transcripts: ["k1": cached])
        let model = ChatViewModel(transport: transport, storedSessionId: "k1", cache: cache)
        await model.open()
        #expect(model.messages == cached)
        #expect(!model.isLoadingHistory)

        transport.failStart = false
        transport.transcript = [TranscriptMessage(role: "user", text: "Hi", rowId: 2),
                                TranscriptMessage(role: "assistant", text: "Hello", rowId: 3),
                                TranscriptMessage(role: "assistant", text: "Later", rowId: 6)]
        model.receive(.state(.connected(GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef"))))
        try await waitUntil { model.messages.last?.text == "Later" }
        #expect(model.messages.map(\.id) == ["c1", "c2"])
    }

    @Test func newChatCreatesTheSessionAndShowsAnEmptyThread() async throws {
        let transport = FakeChatTransport()
        let cache = InMemorySessionCacheStore()
        let model = ChatViewModel(transport: transport, cache: cache)
        await model.open()
        #expect(transport.starts.count == 1)
        #expect(transport.starts.first?.0 == "ios")
        #expect(transport.histories.isEmpty)
        #expect(model.messages.isEmpty)
        #expect(model.storedSessionId == "20261116_101500_ab12cd")
        // The first send uses the session that open() created.
        await model.send("Hello")?.value
        #expect(transport.starts.count == 1)
        #expect(transport.submits.first?.sessionId == "s1")
    }

    /// QA #27 defect 1: a New Chat with no prompt has no server row. Launch must not resume its id.
    @Test func unusedNewChatKeepsTheLastRealSessionActive() async throws {
        let transport = FakeChatTransport()
        let cache = InMemorySessionCacheStore(activeSessionId: "k1")
        let model = ChatViewModel(transport: transport, cache: cache)
        await model.open()
        #expect(model.storedSessionId == "20261116_101500_ab12cd")
        #expect(cache.loadActiveSessionId() == "k1")
        // The first accepted prompt makes the row. Now launch can open this chat.
        await model.send("Hello")?.value
        #expect(cache.loadActiveSessionId() == "20261116_101500_ab12cd")
    }

    /// QA #27 defect 1: launch resumes a dead id. 4007 clears it, and the app shows the list.
    @Test func resumeNotFoundClearsTheActiveIdAndStopsRetrying() async throws {
        let transport = FakeChatTransport()
        transport.resumeError = GatewayError.rpc(code: 4007, message: "session not found")
        let cache = InMemorySessionCacheStore(activeSessionId: "dead1")
        let model = ChatViewModel(transport: transport, storedSessionId: "dead1", cache: cache)
        #expect(!model.isSessionGone)
        await model.open()
        #expect(model.isSessionGone)
        #expect(cache.loadActiveSessionId() == nil)
        #expect(transport.histories.isEmpty)
        // A reconnect does not resume the dead id again.
        model.receive(.state(.connected(GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef"))))
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.resumes == ["dead1"])
    }

    @Test func notFoundForAnotherSessionKeepsTheActiveId() async {
        let transport = FakeChatTransport()
        transport.resumeError = GatewayError.rpc(code: 4007, message: "session not found")
        let cache = InMemorySessionCacheStore(activeSessionId: "k1")
        let model = ChatViewModel(transport: transport, storedSessionId: "old9", cache: cache)
        await model.open()
        #expect(model.isSessionGone)
        #expect(cache.loadActiveSessionId() == "k1")
    }

    @Test func otherResumeErrorsKeepTheSession() async {
        let transport = FakeChatTransport()
        transport.resumeError = GatewayError.rpc(code: 5000, message: "busy")
        let cache = InMemorySessionCacheStore(activeSessionId: "k1")
        let model = ChatViewModel(transport: transport, storedSessionId: "k1", cache: cache)
        await model.open()
        #expect(!model.isSessionGone)
        #expect(cache.loadActiveSessionId() == "k1")
        #expect(!ChatViewModel.isSessionNotFound(GatewayError.notConnected))
        #expect(ChatViewModel.isSessionNotFound(GatewayError.rpc(code: 4007, message: "")))
    }

    @Test func resumeWithNoTranscriptSavesNoActiveId() async {
        let transport = FakeChatTransport()
        let cache = InMemorySessionCacheStore(activeSessionId: "k1")
        let model = ChatViewModel(transport: transport, storedSessionId: "k2", cache: cache)
        await model.open()
        #expect(cache.loadActiveSessionId() == "k1")
        transport.transcript = [TranscriptMessage(role: "user", text: "Hi", rowId: 1)]
        await model.open()
        #expect(cache.loadActiveSessionId() == "k2")
    }

    @Test func draftIsKeptPerSession() {
        let cache = InMemorySessionCacheStore()
        let one = ChatViewModel(transport: FakeChatTransport(), storedSessionId: "k1", cache: cache)
        one.updateDraft("Remember the milk")
        #expect(ChatViewModel(transport: FakeChatTransport(), storedSessionId: "k1", cache: cache).draft == "Remember the milk")
        #expect(ChatViewModel(transport: FakeChatTransport(), storedSessionId: "k2", cache: cache).draft == "")
        // A new chat has no stored id yet, so it keeps no draft.
        let fresh = ChatViewModel(transport: FakeChatTransport(), cache: cache)
        fresh.updateDraft("lost")
        #expect(fresh.draft == "")
    }

    @Test func historyWaitsWhileATurnRuns() async throws {
        let transport = FakeChatTransport()
        transport.transcript = [TranscriptMessage(role: "user", text: "Old", rowId: 1)]
        let model = ChatViewModel(transport: transport, storedSessionId: "k1", cache: InMemorySessionCacheStore(),
                                  redrawInterval: .zero)
        await model.send("Hi")?.value
        model.receive(try gatewayEvent(#"{"type":"message.start","session_id":"s2","payload":{}}"#))
        await model.open()
        #expect(model.messages.map(\.text) == ["Hi"])
        #expect(model.isReplyActive)
    }

    @Test func startEventsAppliesEventsWithNoScreen() async throws {
        let transport = FakeChatTransport()
        let model = ChatViewModel(transport: transport, storedSessionId: "k1", cache: InMemorySessionCacheStore(),
                                  redrawInterval: .zero)
        await model.open()
        model.startEvents()
        defer { model.stopEvents() }
        transport.input.yield(try gatewayEvent(#"{"type":"session.title","session_id":"s2","payload":{"session_id":"k1","title":"Renamed"}}"#))
        try await waitUntil { model.title == "Renamed" }
    }
}

@Suite struct GatewayEventBroadcastTests {
    @Test func everyReaderGetsEveryEventAndAStoppedReaderGoes() async throws {
        let broadcast = GatewayEventBroadcast()
        var one = broadcast.subscribe().makeAsyncIterator()
        var two = broadcast.subscribe().makeAsyncIterator()
        broadcast.yield(.state(.idle))
        let oneIdle = await one.next()
        #expect(oneIdle == .state(.idle))
        let twoIdle = await two.next()
        #expect(twoIdle == .state(.idle))

        // A chat screen that closes ends its stream. The other readers still get events.
        let stream = broadcast.subscribe()
        #expect(broadcast.readerCount == 3)
        let reader = Task { for await _ in stream {} }
        try await Task.sleep(for: .milliseconds(20))
        reader.cancel()
        await reader.value
        #expect(broadcast.readerCount == 2)
        broadcast.yield(.state(.connecting))
        let oneConnecting = await one.next()
        #expect(oneConnecting == .state(.connecting))
        let twoConnecting = await two.next()
        #expect(twoConnecting == .state(.connecting))
    }
}
