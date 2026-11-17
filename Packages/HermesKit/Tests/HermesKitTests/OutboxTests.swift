import Foundation
import Testing
@testable import HermesKit

/// Issue #39: a fake link that goes offline and online. Offline calls throw `GatewayError.notConnected`,
/// as `LiveChatTransport.readyClient()` does. No network.
final class OutboxTransport: ChatTransport, AttachmentTransport, @unchecked Sendable {
    let events: AsyncStream<GatewayClientEvent>
    private let lock = NSLock()
    private var _online: Bool
    private var _submits: [String] = []
    private var _voiceSubmits: [String] = []
    private var _attaches: [String] = []
    private var _transcribes = 0
    /// Errors for the next `prompt.submit` calls, in order. An empty list answers with a row id.
    private var _submitErrors: [any Error] = []
    /// When set, `prompt.submit` waits for `release()` (a quit during the send).
    private var _gate: CheckedContinuation<Void, Never>?
    private var _holdSubmit = false

    init(online: Bool) {
        _online = online
        events = AsyncStream { _ in }
    }

    var online: Bool {
        get { lock.withLock { _online } }
        set { lock.withLock { _online = newValue } }
    }

    var submits: [String] { lock.withLock { _submits } }
    var voiceSubmits: [String] { lock.withLock { _voiceSubmits } }
    var attaches: [String] { lock.withLock { _attaches } }
    var transcribes: Int { lock.withLock { _transcribes } }

    func failNextSubmits(_ errors: [any Error]) { lock.withLock { _submitErrors = errors } }
    func holdSubmit() { lock.withLock { _holdSubmit = true } }
    var isHolding: Bool { lock.withLock { _gate != nil } }

    func release() {
        let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            _holdSubmit = false
            defer { _gate = nil }
            return _gate
        }
        gate?.resume()
    }

    private func requireLink() throws {
        if !online { throw GatewayError.notConnected }
    }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        try requireLink()
        return ChatSessionRef(liveId: "live1", storedId: "20261117_090000_new001")
    }

    func resumeSession(storedId: String, source _: String) async throws -> ChatSessionRef {
        try requireLink()
        return ChatSessionRef(liveId: "live2", storedId: storedId)
    }

    func submitPrompt(sessionId _: String, text: String, retryBeforeRowId _: Int?) async throws -> Int? {
        try await submit(text, voice: false)
    }

    func submitVoicePrompt(sessionId _: String, text: String, retryBeforeRowId _: Int?) async throws -> Int? {
        try await submit(text, voice: true)
    }

    private func submit(_ text: String, voice: Bool) async throws -> Int? {
        try requireLink()
        let hold = lock.withLock { _holdSubmit }
        if hold { await withCheckedContinuation { continuation in lock.withLock { _gate = continuation } } }
        return try lock.withLock {
            if voice { _voiceSubmits.append(text) } else { _submits.append(text) }
            if !_submitErrors.isEmpty { throw _submitErrors.removeFirst() }
            return 300 + _submits.count + _voiceSubmits.count
        }
    }

    func stopReply(sessionId _: String) async throws -> Bool { true }

    func history(sessionId _: String) async throws -> [TranscriptMessage] {
        try requireLink()
        return []
    }

    func transcribe(audio _: Data, mimeType _: String) async throws -> String {
        try requireLink()
        lock.withLock { _transcribes += 1 }
        return "call the movers"
    }

    func attachImage(sessionId _: String, data _: Data, filename: String) async throws {
        try requireLink()
        lock.withLock { _attaches.append(filename) }
    }

    func attachFile(sessionId _: String, data _: Data, name: String, mimeType _: String) async throws -> String? {
        try requireLink()
        lock.withLock { _attaches.append(name) }
        return "@file:\(name)"
    }

    func attachPDF(sessionId _: String, data _: Data, filename: String, lastPage _: Int?) async throws {
        try requireLink()
        lock.withLock { _attaches.append(filename) }
    }
}

private let connected = GatewayClientEvent.state(.connected(GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef")))

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("the condition did not become true")
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct OutboxTests {
    private let stored = "20261117_080000_abc123"

    private func makeModel(_ transport: OutboxTransport, cache: any SessionCacheStore = InMemorySessionCacheStore(),
                           storedSessionId: String? = "20261117_080000_abc123",
                           keepsNewChat: Bool = false) -> ChatViewModel {
        ChatViewModel(transport: transport, storedSessionId: storedSessionId, cache: cache, keepsNewChat: keepsNewChat,
                      redrawInterval: .zero, loadAudio: { _ in Data([1, 2, 3]) })
    }

    private func footnotes(_ model: ChatViewModel) -> [ChatRow.Footnote?] {
        ChatTimeline.rows(for: model.messages).filter { $0.message.role == .user }.map(\.footnote)
    }

    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    // MARK: Queue while offline

    @Test func anOfflineSendShowsWillSendWhenConnectedAndNotNotDelivered() async {
        let transport = OutboxTransport(online: false)
        let model = makeModel(transport)
        await model.send("Book a table")?.value
        #expect(model.messages.map(\.delivery) == [.queued])
        #expect(footnotes(model) == [.queued])
        #expect(ChatRow.Footnote.queued.text == "Will send when connected")
        #expect(!ChatRow.Footnote.queued.isError)
        #expect(!model.messages.contains { $0.isFailed })
        #expect(transport.submits.isEmpty)
    }

    @Test func everyQueuedBubbleShowsTheCaptionAndTheLastDeliveredKeepsDelivered() async {
        let transport = OutboxTransport(online: true)
        let model = makeModel(transport)
        await model.send("first")?.value
        transport.online = false
        await model.send("second")?.value
        await model.send("third")?.value
        #expect(footnotes(model) == [.delivered, .queued, .queued])
    }

    // MARK: Send on reconnect, in order

    @Test func aReconnectSendsTheQueueInTheOrderThatTheOwnerTyped() async throws {
        let transport = OutboxTransport(online: false)
        let model = makeModel(transport)
        for text in ["one", "two", "three"] { await model.send(text)?.value }
        #expect(model.messages.map(\.delivery) == [.queued, .queued, .queued])
        transport.online = true
        model.receive(connected)
        try await waitUntil { model.messages.allSatisfy { $0.delivery == .delivered } }
        #expect(transport.submits == ["one", "two", "three"])
        #expect(footnotes(model) == [nil, nil, .delivered])
        #expect(!model.hasQueued)
    }

    @Test func aNewSendWhileMessagesWaitGoesAfterThem() async throws {
        let transport = OutboxTransport(online: false)
        let model = makeModel(transport)
        await model.send("one")?.value
        // The link is back, but no connect event came yet. The new text must not pass the queue.
        transport.online = true
        await model.send("two")?.value
        #expect(transport.submits == ["one", "two"])
        #expect(model.messages.map(\.delivery) == [.delivered, .delivered])
    }

    @Test func aRunThatIsStillOfflineStopsAndKeepsTheOrder() async {
        let transport = OutboxTransport(online: false)
        let model = makeModel(transport)
        await model.send("one")?.value
        await model.send("two")?.value
        // "Send Now" with no link: the first goes back to the outbox and the run stops.
        await model.sendQueued()?.value
        #expect(model.messages.map(\.delivery) == [.queued, .queued])
        #expect(transport.submits.isEmpty)
        transport.online = true
        await model.sendQueued()?.value
        #expect(transport.submits == ["one", "two"])
    }

    @Test func sendNowAndConnectAtTheSameTimeSendEachMessageOnce() async throws {
        let transport = OutboxTransport(online: false)
        let model = makeModel(transport)
        await model.send("one")?.value
        await model.send("two")?.value
        transport.online = true
        let first = model.sendQueued()
        model.receive(connected)
        let second = model.sendQueued()
        await first?.value
        await second?.value
        try await waitUntil { !model.hasQueued }
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.submits == ["one", "two"])
    }

    @Test func deleteTakesAMessageOutOfTheOutbox() async {
        let transport = OutboxTransport(online: false)
        let cache = InMemorySessionCacheStore()
        let model = makeModel(transport, cache: cache)
        await model.send("one")?.value
        await model.send("two")?.value
        model.delete(id: model.messages[0].id)
        #expect(cache.outboxSessionIds() == [stored])
        model.delete(id: model.messages[0].id)
        #expect(cache.outboxSessionIds().isEmpty)
        transport.online = true
        #expect(model.sendQueued() == nil)
        #expect(transport.submits.isEmpty)
    }

    // MARK: Server refusals keep "Not Delivered"

    @Test func aQueuedSendThatTheServerRefusesShowsNotDeliveredWithRetry() async throws {
        let transport = OutboxTransport(online: false)
        let model = makeModel(transport)
        await model.send("one")?.value
        await model.send("two")?.value
        transport.online = true
        transport.failNextSubmits([GatewayError.rpc(code: 4009, message: "session busy")])
        await model.sendQueued()?.value
        // The refused message shows "Not Delivered". The run goes on with the next one.
        #expect(model.messages.map(\.delivery) == [.failed, .delivered])
        #expect(footnotes(model) == [.notDelivered, .delivered])
        await model.retrySend(id: model.messages[0].id)?.value
        #expect(model.messages[0].delivery == .delivered)
        #expect(transport.submits == ["one", "two", "one"])
    }

    @Test func aServerRefusalWhileOnlineStillShowsNotDelivered() async {
        let transport = OutboxTransport(online: true)
        let model = makeModel(transport)
        transport.failNextSubmits([GatewayError.rpc(code: 5000, message: "boom")])
        await model.send("one")?.value
        #expect(model.messages.map(\.delivery) == [.failed])
        #expect(!model.hasQueued)
    }

    @Test func aDropAfterThePromptWentOutIsNotQueued() async {
        // The server can have the prompt. A second send could copy it, so the owner decides ("Try Again").
        let transport = OutboxTransport(online: true)
        let model = makeModel(transport)
        transport.failNextSubmits([GatewayError.disconnected(.heartbeatTimeout)])
        await model.send("one")?.value
        #expect(model.messages.map(\.delivery) == [.failed])
        transport.failNextSubmits([GatewayError.timeout(method: "prompt.submit")])
        await model.send("two")?.value
        #expect(model.messages.map(\.delivery) == [.failed, .failed])
        #expect(!model.hasQueued)
    }

    @Test func theOfflineRulesQueueOnlyWhatDidNotReachTheServer() {
        #expect(Outbox.isOffline(GatewayError.notConnected, submitted: true))
        #expect(Outbox.isOffline(GatewayError.notConnected, submitted: false))
        #expect(Outbox.isOffline(GatewayError.disconnected(.heartbeatTimeout), submitted: false))
        #expect(!Outbox.isOffline(GatewayError.disconnected(.heartbeatTimeout), submitted: true))
        #expect(!Outbox.isOffline(GatewayError.disconnected(.unauthorized), submitted: false))
        #expect(!Outbox.isOffline(GatewayError.timeout(method: "prompt.submit"), submitted: true))
        #expect(!Outbox.isOffline(GatewayError.timeout(method: "session.resume"), submitted: false))
        #expect(!Outbox.isOffline(GatewayError.rpc(code: 4009, message: "busy"), submitted: false))
        #expect(Outbox.isOffline(URLError(.notConnectedToInternet), submitted: false))
        #expect(Outbox.isOffline(URLError(.cannotConnectToHost), submitted: false))
        #expect(!Outbox.isOffline(URLError(.timedOut), submitted: false))
        #expect(!Outbox.isOffline(HermesAPIError.http(status: 500), submitted: false))
    }

    // MARK: Relaunch

    @Test func theQueueSurvivesARelaunchAndSendsOnceOnConnect() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let offline = OutboxTransport(online: false)
        let before = makeModel(offline, cache: FileSessionCacheStore(directory: folder))
        await before.send("one")?.value
        await before.send("two")?.value

        // Relaunch: a new store on the same folder, and a session list that the owner does not leave.
        let cache = FileSessionCacheStore(directory: folder)
        #expect(cache.outboxSessionIds() == [stored])
        #expect(cache.loadTranscript(sessionId: stored).map(\.delivery) == [.queued, .queued])
        let online = OutboxTransport(online: true)
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: online, cache: cache)
        sessions.receive(connected)
        try await waitUntil { online.submits.count == 2 }
        let chat = sessions.chat(for: stored)
        try await waitUntil { !chat.hasQueued }
        #expect(online.submits == ["one", "two"])
        #expect(cache.outboxSessionIds().isEmpty)

        // A second relaunch and connect send nothing again.
        let again = OutboxTransport(online: true)
        let later = SessionListModel(transport: FakeSessionsTransport(), chatTransport: again,
                                     cache: FileSessionCacheStore(directory: folder))
        later.receive(connected)
        try await Task.sleep(for: .milliseconds(100))
        #expect(again.submits.isEmpty)
        #expect(FileSessionCacheStore(directory: folder).loadTranscript(sessionId: stored).map(\.delivery)
            == [.delivered, .delivered])
    }

    @Test func aQuitWhileTheOutboxSendsNeverSendsTheMessageTwice() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = OutboxTransport(online: false)
        let model = makeModel(transport, cache: FileSessionCacheStore(directory: folder))
        await model.send("one")?.value
        transport.online = true
        transport.holdSubmit()
        let run = model.sendQueued()
        try await waitUntil { transport.isHolding }
        // The app quits now: the prompt can be on its way. The cache must not have it as queued.
        let cache = FileSessionCacheStore(directory: folder)
        #expect(cache.outboxSessionIds().isEmpty)
        #expect(!cache.loadTranscript(sessionId: stored).contains { $0.delivery == .queued })
        let relaunched = OutboxTransport(online: true)
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: relaunched, cache: cache)
        sessions.receive(connected)
        try await Task.sleep(for: .milliseconds(100))
        #expect(relaunched.submits.isEmpty)
        transport.release()
        await run?.value
        #expect(transport.submits == ["one"])
    }

    @Test func aNewChatQueuesUnderTheSlotKeyOnly() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = FileSessionCacheStore(directory: folder)
        let transport = OutboxTransport(online: false)
        let model = makeModel(transport, cache: cache, storedSessionId: nil, keepsNewChat: true)
        await model.send("hello")?.value
        #expect(model.messages.map(\.delivery) == [.queued])
        // Launch opens the slot. The list must not send the same text from a second model.
        #expect(cache.outboxSessionIds() == [SessionCache.newChatId])
        let relaunched = makeModel(OutboxTransport(online: false), cache: FileSessionCacheStore(directory: folder),
                                   storedSessionId: nil, keepsNewChat: true)
        #expect(relaunched.messages.map(\.delivery) == [.queued])
        transport.online = true
        model.receive(connected)
        try await waitUntil { !model.hasQueued }
        #expect(transport.submits == ["hello"])
        #expect(model.storedSessionId == "20261117_090000_new001")
        #expect(cache.outboxSessionIds().isEmpty)
    }

    // MARK: Attachments and voice memos

    @Test func photosAndFilesWaitInTheOutboxAndUploadOnConnect() async throws {
        let folder = tempFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photoURL = folder.appending(path: "photo.jpg")
        let fileURL = folder.appending(path: "Lease.pdf")
        try Data([1, 2, 3]).write(to: photoURL)
        try Data([4, 5, 6]).write(to: fileURL)
        let items = [
            ChatAttachment(id: "p1", kind: .photo, name: "photo.jpg", byteCount: 3, fileURL: photoURL,
                           mimeType: "image/jpeg", pixelWidth: 10, pixelHeight: 10),
            ChatAttachment(id: "f1", kind: .file, name: "notes.txt", byteCount: 3, fileURL: fileURL,
                           mimeType: "text/plain"),
        ]
        let cacheFolder = folder.appending(path: "cache", directoryHint: .isDirectory)
        let transport = OutboxTransport(online: false)
        let model = makeModel(transport, cache: FileSessionCacheStore(directory: cacheFolder))
        await model.send("see these", attachments: items)?.value
        #expect(model.messages.first?.delivery == .queued)
        // No failed ring while the message waits.
        #expect(model.messages.first?.attachments.map(\.upload) == [.pending, .pending])

        // Relaunch: the items come back from the cache and upload again with the send.
        let relaunched = OutboxTransport(online: true)
        let after = makeModel(relaunched, cache: FileSessionCacheStore(directory: cacheFolder))
        #expect(after.messages.first?.attachments.map(\.upload) == [.pending, .pending])
        await after.open()
        try await waitUntil { !after.hasQueued }
        #expect(relaunched.attaches == ["photo.jpg", "notes.txt"])
        #expect(relaunched.submits.count == 1)
        #expect(after.messages.first?.delivery == .delivered)
    }

    @Test func aVoiceMemoRecordedOfflineIsTranscribedAndSentOnConnect() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = OutboxTransport(online: false)
        let model = makeModel(transport, cache: FileSessionCacheStore(directory: folder))
        let memo = VoiceMemo(fileURL: URL(fileURLWithPath: "/tmp/memo-39.m4a"), duration: 4, waveform: [0.2, 0.6])
        await model.sendVoiceMemo(memo).value
        #expect(model.messages.first?.delivery == .queued)
        #expect(model.messages.first?.voice?.transcript == .pending)
        #expect(footnotes(model) == [.queued])
        // VoiceOver does not say "Transcribing" while the memo waits.
        let row = ChatTimeline.rows(for: model.messages)[0]
        #expect(!ChatTimeline.accessibilityLabel(for: row).contains("Transcribing"))

        // Relaunch keeps the memo queued with no transcript.
        let relaunched = OutboxTransport(online: true)
        let after = makeModel(relaunched, cache: FileSessionCacheStore(directory: folder))
        #expect(after.messages.first?.delivery == .queued)
        #expect(after.messages.first?.voice?.transcript == .pending)
        after.receive(connected)
        try await waitUntil { after.messages.first?.delivery == .delivered }
        #expect(relaunched.transcribes == 1)
        #expect(relaunched.voiceSubmits == ["call the movers"])
        #expect(after.messages.first?.voice?.transcript == .done("call the movers"))
    }

    @Test func aMemoWithATranscriptWaitsForTheSubmitOnly() async throws {
        let transport = OutboxTransport(online: true)
        let model = makeModel(transport)
        let memo = VoiceMemo(fileURL: URL(fileURLWithPath: "/tmp/memo-39b.m4a"), duration: 4, waveform: [0.2])
        transport.failNextSubmits([GatewayError.notConnected])
        await model.sendVoiceMemo(memo).value
        #expect(model.messages.first?.delivery == .queued)
        #expect(model.messages.first?.voice?.transcript == .done("call the movers"))
        await model.sendQueued()?.value
        #expect(transport.transcribes == 1)
        #expect(transport.voiceSubmits == ["call the movers", "call the movers"])
        #expect(model.messages.first?.delivery == .delivered)
    }

    // MARK: Siri

    @Test func siriTurnsAQueuedTextIntoNotDelivered() async {
        let transport = OutboxTransport(online: false)
        let model = makeModel(transport)
        await model.send("Hi")?.value
        let id = model.messages[0].id
        model.failQueued(id: id)
        #expect(model.messages[0].delivery == .failed)
        transport.online = true
        #expect(model.sendQueued() == nil)
        #expect(transport.submits.isEmpty)
    }
}

/// Issue #39: the cache format of the outbox. Older files still load.
@Suite struct OutboxCacheTests {
    private let date = Date(timeIntervalSince1970: 1_763_370_000)

    @Test func aVersion5TranscriptWithNoQueuedKeyStillLoads() throws {
        let json = """
        {"version":5,"body":[{"id":"u1","role":"user","text":"Hi","date":1763370000,"interrupted":false,
        "notDelivered":false},{"id":"u2","role":"user","text":"","date":1763370010,"interrupted":false,
        "notDelivered":true,"voice":{"path":"/tmp/a.m4a","duration":3,"waveform":[],"transcript":"failed"}}]}
        """
        let folder = FileManager.default.temporaryDirectory.appending(path: "outbox-v5-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileSessionCacheStore(directory: folder)
        let url = store.transcriptURL(sessionId: "s1")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        try Data(#"{"version":5,"body":{"activeSessionId":"s1","drafts":{}}}"#.utf8).write(to: store.stateURL)
        #expect(store.loadTranscript(sessionId: "s1").map(\.delivery) == [.delivered, .failed])
        #expect(store.outboxSessionIds().isEmpty)
        #expect(store.loadActiveSessionId() == "s1")
    }

    @Test func aQueuedMessageIsKeptAndAnOlderBuildReadsItAsNotDelivered() throws {
        let message = ChatMessage(id: "q1", role: .user, text: "later", date: date, delivery: .queued)
        let cached = CachedMessage(message)
        #expect(cached.queued)
        #expect(cached.notDelivered)
        #expect(cached.message.delivery == .queued)
        #expect(SessionCache.cacheable([message]).map(\.id) == ["q1"])
        // A text that the outbox sends right now is not kept: a quit then must not send it twice.
        var sending = message
        sending.delivery = .sending
        #expect(SessionCache.cacheable([sending]).isEmpty)
        // A broken value reads as not queued.
        let broken = #"{"id":"q2","role":"user","text":"x","date":1763370000,"notDelivered":true,"queued":"yes"}"#
        let decoded = try JSONDecoder().decode(CachedMessage.self, from: Data(broken.utf8))
        #expect(decoded.message.delivery == .failed)
    }

    @Test func aPendingTranscriptStaysPendingOnlyForAQueuedMemo() {
        let memo = VoiceMemo(fileURL: URL(fileURLWithPath: "/tmp/m.m4a"), duration: 2, waveform: [], transcript: .pending)
        let queued = ChatMessage(id: "v1", role: .user, text: "", date: date, delivery: .queued, voice: memo)
        #expect(CachedMessage(queued).message.voice?.transcript == .pending)
        var sending = queued
        sending.delivery = .sending
        #expect(CachedMessage(sending).message.voice?.transcript == .failed)
        #expect(CachedMessage(sending).message.delivery == .failed)
    }

    @Test func theOutboxIndexKeepsTheOrderAndClearsOnDelete() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "outbox-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileSessionCacheStore(directory: folder)
        store.saveOutbox(true, sessionId: "b")
        store.saveOutbox(true, sessionId: "a")
        store.saveOutbox(true, sessionId: "b")
        store.saveDraft("draft", sessionId: "a")
        #expect(FileSessionCacheStore(directory: folder).outboxSessionIds() == ["b", "a"])
        store.removeSession(sessionId: "b")
        #expect(store.outboxSessionIds() == ["a"])
        #expect(store.loadDraft(sessionId: "a") == "draft")
        store.saveOutbox(false, sessionId: "a")
        #expect(store.outboxSessionIds().isEmpty)
        let memory = InMemorySessionCacheStore()
        memory.saveOutbox(true, sessionId: "x")
        memory.removeSession(sessionId: "x")
        #expect(memory.outboxSessionIds().isEmpty)
    }
}
