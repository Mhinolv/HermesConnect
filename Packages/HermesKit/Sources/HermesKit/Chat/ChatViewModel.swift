import Foundation
import Observation

/// The state of the chat screen (issue #6). The MessageKit controller only draws it.
///
/// - Events change `thread` at once, so no delta is lost.
/// - Text-only changes reach `messages` at most once per `redrawInterval` (100 ms).
///   Other changes reach it at once.
/// - Message text never goes to a log.
/// - Issue #7: a model with a stored id shows the cached transcript at once. `open()` resumes the session
///   and merges `session.history`. Ended messages go to the cache after each change.
@MainActor @Observable
public final class ChatViewModel {
    /// The bubbles that the screen shows.
    public private(set) var messages: [ChatMessage] = []
    public private(set) var turn: ChatTurnPhase = .idle
    public private(set) var statusLine: String?
    /// The session title, or `nil` for a new chat ("New Chat").
    public private(set) var title: String?
    /// The last reply that ended. VoiceOver reads it once.
    public private(set) var completedReplyId: String?
    /// The stored id (docs/hermes-protocol.md 3.3). A new chat gets it from `session.create`.
    public private(set) var storedSessionId: String?
    /// `true` while `open()` waits for the history and no cached message shows. The screen shows a `ProgressView`.
    public private(set) var isLoadingHistory = false
    /// `session.resume` answered "not found" (4007): the server has no row for the stored id. The app
    /// drops the session and shows the list (QA #27 defect 1).
    public private(set) var isSessionGone = false

    @ObservationIgnored private var thread = ChatThread()
    @ObservationIgnored private let transport: any ChatTransport
    @ObservationIgnored private let redrawInterval: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let makeId: @Sendable () -> String
    @ObservationIgnored private let sessionKey: String
    @ObservationIgnored private var session: ChatSessionRef?
    @ObservationIgnored private var sessionTask: Task<ChatSessionRef, any Error>?
    /// The socket dropped since the session opened. The next send calls `session.resume`.
    @ObservationIgnored private var sessionIsStale = false
    @ObservationIgnored private var redrawTask: Task<Void, Never>?
    @ObservationIgnored private var lastRedraw: ContinuousClock.Instant?
    @ObservationIgnored private let cache: (any SessionCacheStore)?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    /// The last `open()` did not finish (offline). The next connect runs it again.
    @ObservationIgnored private var needsOpen = false
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    /// Reads a memo file for the upload. Tests use a fake.
    @ObservationIgnored private let loadAudio: @Sendable (URL) throws -> Data
    /// Deletes a memo file when the owner deletes the memo.
    @ObservationIgnored private let removeAudio: @Sendable (URL) -> Void

    /// `messages` is history that the screen shows at once (DEBUG demo). With no `messages`, a model with
    /// a `storedSessionId` and a `cache` shows the cached transcript.
    public init(transport: any ChatTransport, session: ChatSessionRef? = nil, storedSessionId: String? = nil,
                title: String? = nil, messages: [ChatMessage] = [], cache: (any SessionCacheStore)? = nil,
                redrawInterval: Duration = .milliseconds(100),
                now: @escaping @Sendable () -> Date = { Date() },
                makeId: @escaping @Sendable () -> String = { UUID().uuidString },
                loadAudio: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
                removeAudio: @escaping @Sendable (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }) {
        self.transport = transport
        self.loadAudio = loadAudio
        self.removeAudio = removeAudio
        self.session = session
        self.storedSessionId = storedSessionId ?? session?.storedId
        self.title = title
        self.cache = cache
        self.redrawInterval = redrawInterval
        self.now = now
        self.makeId = makeId
        self.sessionKey = makeId()
        var initial = messages
        if initial.isEmpty, let stored = self.storedSessionId, let cache {
            initial = cache.loadTranscript(sessionId: stored)
        }
        self.thread = ChatThread(messages: initial)
        self.messages = initial
    }

    /// The composer text that the owner did not send. One draft per session.
    public var draft: String {
        guard let storedSessionId else { return "" }
        return cache?.loadDraft(sessionId: storedSessionId) ?? ""
    }

    /// The composer calls this on each change. A new chat with no stored id keeps no draft.
    public func updateDraft(_ text: String) {
        guard let storedSessionId else { return }
        cache?.saveDraft(text, sessionId: storedSessionId)
    }

    /// `true` from the send until `message.complete`. The Stop button shows.
    public var isReplyActive: Bool { turn != .idle }

    /// Reads gateway events until the task is cancelled.
    public func run() async {
        for await event in transport.events {
            if Task.isCancelled { return }
            receive(event)
        }
    }

    /// Reads gateway events for the life of the model, also while its screen is not on top (issue #7).
    /// So a reply that streams while the owner looks at the list still ends. A second call does nothing.
    public func startEvents() {
        guard eventTask == nil else { return }
        let stream = transport.events
        eventTask = Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                self.receive(item)
            }
        }
    }

    /// Stops `startEvents()` (tests).
    public func stopEvents() {
        eventTask?.cancel()
        eventTask = nil
    }

    // MARK: Open

    /// Opens a stored session: `session.resume`, then `session.history` merged into the thread (issue #7).
    /// Cached messages show at once. The merge keeps the ids on screen, so the thread does not jump.
    /// A new chat (no stored id) calls `session.create` now. If that fails, the first send creates it.
    /// Calls at the same time share one run.
    public func open() async {
        guard let storedSessionId else {
            _ = try? await currentSession()
            return
        }
        if let openTask { return await openTask.value }
        let task = Task { await loadHistory() }
        openTask = task
        await task.value
        openTask = nil
    }

    private func loadHistory() async {
        isLoadingHistory = messages.isEmpty
        defer { isLoadingHistory = false }
        do {
            // Always resume: the server reaps an idle live session 20 s after its socket drops.
            let live = try await resumedSession()
            let transcript = try await transport.history(sessionId: live.liveId)
            needsOpen = false
            // A session with a transcript has a server row, so the next launch can resume it.
            if !transcript.isEmpty { saveActiveSessionId() }
            // A running turn owns the end of the thread. Its `message.complete` brings the text.
            guard thread.turn == .idle else { return }
            let history = ChatHistory.messages(from: transcript, reusing: thread.messages, fallbackDate: now())
            if thread.replaceHistory(history) { redrawNow() }
            saveTranscript()
        } catch where Self.isSessionNotFound(error) {
            // A dead id (for example a New Chat that never got a prompt): never resume it again.
            needsOpen = false
            if let storedSessionId, cache?.loadActiveSessionId() == storedSessionId {
                cache?.saveActiveSessionId(nil)
            }
            isSessionGone = true
        } catch {
            needsOpen = true
        }
    }

    /// `session.resume` error 4007: no stored session with this id (`methods_session.py`, protocol 3.4).
    public nonisolated static let sessionNotFoundCode = 4007

    public nonisolated static func isSessionNotFound(_ error: any Error) -> Bool {
        if case GatewayError.rpc(let code, _) = error { return code == sessionNotFoundCode }
        return false
    }

    /// The active id is the session that launch opens. It is saved only for a session with a server row:
    /// after an accepted prompt, or after a resume that has a transcript. `session.create` makes no row.
    private func saveActiveSessionId() {
        guard let storedSessionId else { return }
        cache?.saveActiveSessionId(storedSessionId)
    }

    /// `session.resume` with the stored id. A send at the same time shares the call.
    private func resumedSession() async throws -> ChatSessionRef {
        if sessionTask == nil, session != nil { sessionIsStale = true }
        return try await currentSession()
    }

    private func saveTranscript() {
        guard let storedSessionId, let cache else { return }
        cache.saveTranscript(thread.messages, sessionId: storedSessionId)
    }

    /// Applies one item of the event stream. Events of other sessions are ignored.
    public func receive(_ item: GatewayClientEvent) {
        switch item {
        case .event(let event):
            if case .sessionTitle(let payload) = event.kind {
                if let stored = storedSessionId, payload.sessionId == stored, !payload.title.isEmpty {
                    title = payload.title
                }
                return
            }
            guard let live = session?.liveId, event.sessionId == live else { return }
            let makeId = self.makeId
            changed(thread.apply(event.kind, now: now(), makeId: makeId))
        case .state(.disconnected):
            // The live id can die with the socket. The next send resumes the stored id.
            sessionIsStale = session != nil
            if session != nil { needsOpen = true }
            let makeId = self.makeId
            changed(thread.connectionLost(now: now(), makeId: makeId))
        case .state(.connected):
            // Back after a drop or an offline open: resume and catch up with the history.
            if needsOpen, storedSessionId != nil {
                Task { await open() }
            }
        case .state, .serverRequest:
            break
        }
    }

    // MARK: Actions

    /// Shows the bubble at once, then sends the text as it is (also text that starts with `/`).
    /// Returns the send task (tests wait for it). Empty text after trimming sends nothing.
    @discardableResult
    public func send(_ text: String) -> Task<Void, Never>? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let id = makeId()
        thread.addOutgoing(id: id, text: text, date: now())
        redrawNow()
        return Task { await deliver(id: id, retryBeforeRowId: nil) }
    }

    /// Sends a recorded voice memo (issue #9, docs/hermes-protocol.md 3.9). The bubble shows at once with
    /// "Transcribing…". Then the clip goes to `POST /api/audio/transcribe`, and the transcript goes out as
    /// `prompt.submit` with `voice_turn: true`. An empty transcript sends no turn. A failure keeps the memo.
    @discardableResult
    public func sendVoiceMemo(_ memo: VoiceMemo) -> Task<Void, Never> {
        let id = makeId()
        thread.addOutgoingVoice(id: id, memo: memo, date: now())
        redrawNow()
        return Task { await deliverVoice(id: id) }
    }

    /// "Try Again" on a bubble that shows "Not Delivered" (or "No speech found." for a memo).
    /// A memo with a transcript sends the turn again. A memo with no transcript is transcribed again.
    @discardableResult
    public func retrySend(id: String) -> Task<Void, Never>? {
        guard let message = thread.message(id: id), message.delivery == .failed else { return nil }
        thread.setDelivery(.sending, id: id)
        if let voice = message.voice, voice.transcript.text == nil {
            thread.setTranscript(.pending, id: id)
            redrawNow()
            return Task { await deliverVoice(id: id) }
        }
        redrawNow()
        return Task { await deliver(id: id, retryBeforeRowId: nil) }
    }

    /// "Delete" on a bubble that shows "Not Delivered". A memo also loses its audio file.
    public func delete(id: String) {
        if let url = thread.message(id: id)?.voice?.fileURL { removeAudio(url) }
        thread.remove(id: id)
        redrawNow()
    }

    /// "Reply failed. Tap to retry.": drop the failed reply and run the prompt again.
    /// A known prompt row is regenerated (`truncate_before_row_id`), so the transcript has no copy.
    @discardableResult
    public func retryReply(id: String) -> Task<Void, Never>? {
        guard !isReplyActive, let reply = thread.message(id: id), case .failed = reply.reply,
              let promptId = reply.promptId, let prompt = thread.message(id: promptId) else { return nil }
        thread.remove(id: id)
        thread.setDelivery(.sending, id: promptId)
        redrawNow()
        return Task { await deliver(id: promptId, retryBeforeRowId: prompt.userRowId) }
    }

    /// The Stop button: `session.interrupt`. The server ends the turn with `message.complete`.
    @discardableResult
    public func stop() -> Task<Void, Never>? {
        guard isReplyActive, let live = session?.liveId else { return nil }
        let transport = self.transport
        return Task {
            _ = try? await transport.stopReply(sessionId: live)
        }
    }

    // MARK: Send

    private func deliverVoice(id: String) async {
        guard let url = thread.message(id: id)?.voice?.fileURL else { return }
        let transport = self.transport
        let loadAudio = self.loadAudio
        let transcript: String
        do {
            // The clip and the transcript never go to a log.
            transcript = try await Task.detached {
                let audio = try loadAudio(url)
                return try await transport.transcribe(audio: audio, mimeType: VoiceMemoLimits.mimeType)
            }.value
        } catch {
            thread.setTranscript(.failed, id: id)
            thread.setDelivery(.failed, id: id)
            redrawNow()
            return
        }
        guard thread.message(id: id) != nil else { return }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            thread.setTranscript(.empty, id: id)
            thread.setDelivery(.failed, id: id)
            redrawNow()
            return
        }
        thread.setTranscript(.done(transcript), id: id)
        redrawNow()
        await deliver(id: id, retryBeforeRowId: nil)
    }

    private func deliver(id: String, retryBeforeRowId: Int?) async {
        guard let message = thread.message(id: id) else { return }
        let text = message.text
        let isVoice = message.voice != nil
        do {
            let session = try await currentSession()
            thread.beginTurn(promptId: id)
            redrawNow()
            let row = if isVoice {
                try await transport.submitVoicePrompt(sessionId: session.liveId, text: text,
                                                      retryBeforeRowId: retryBeforeRowId)
            } else {
                try await transport.submitPrompt(sessionId: session.liveId, text: text,
                                                 retryBeforeRowId: retryBeforeRowId)
            }
            thread.setDelivery(.delivered, id: id, userRowId: row)
            saveActiveSessionId()
            saveTranscript()
        } catch {
            thread.setDelivery(.failed, id: id)
            thread.cancelWaiting()
        }
        redrawNow()
    }

    /// The live session. The first send creates it with `source: "ios"`. After a drop, the send resumes
    /// the stored id. Sends at the same time share one call.
    private func currentSession() async throws -> ChatSessionRef {
        if let session, !sessionIsStale { return session }
        if let sessionTask { return try await sessionTask.value }
        let transport = self.transport
        let key = sessionKey
        // A session that is stale, or not resumed yet, resumes its stored id. A new chat creates one.
        let storedId = (sessionIsStale || session == nil) ? (session?.storedId ?? storedSessionId) : nil
        let task = Task {
            if let storedId {
                return try await transport.resumeSession(storedId: storedId, source: ChatSource.iOS)
            }
            return try await transport.startSession(source: ChatSource.iOS, idempotencyKey: key)
        }
        sessionTask = task
        do {
            let created = try await task.value
            session = created
            sessionIsStale = false
            sessionTask = nil
            if storedSessionId == nil, let stored = created.storedId {
                // No active id yet: the server writes no row until the first prompt (QA #27 defect 1).
                storedSessionId = stored
            }
            return created
        } catch {
            sessionTask = nil
            throw error
        }
    }

    // MARK: Redraw

    private func changed(_ change: ChatThreadChange) {
        switch change {
        case .none: break
        case .text: scheduleRedraw()
        case .structure: redrawNow()
        case .completed(let id):
            redrawNow()
            completedReplyId = id
            saveTranscript()
        }
    }

    private func scheduleRedraw() {
        guard redrawTask == nil else { return }
        let elapsed = lastRedraw.map { ContinuousClock.now - $0 } ?? redrawInterval
        let wait = max(.zero, redrawInterval - elapsed)
        redrawTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.redrawNow()
        }
    }

    /// Copies the thread to the published state. Tests call it to end a throttle window.
    public func redrawNow() {
        redrawTask?.cancel()
        redrawTask = nil
        lastRedraw = ContinuousClock.now
        if messages != thread.messages { messages = thread.messages }
        if turn != thread.turn { turn = thread.turn }
        if statusLine != thread.statusLine { statusLine = thread.statusLine }
    }

    /// The thread state that is not drawn yet (tests).
    var pendingThread: ChatThread { thread }
}
