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
    /// Issue #120: the tool that runs now in this chat. The Voice tab shows "Using <tool>…".
    public private(set) var runningTool: String?
    /// Issue #129: the last tool of the turn for the Voice tab ("Using <tool>…", then "Used <tool>").
    public private(set) var toolActivity: ChatToolActivity?
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
    /// Issue #10: the reply to a voice memo whose audio just came. The screen plays it once when
    /// "Auto-Play Voice Replies" is on. Each new reply gets a new value.
    public private(set) var autoPlayReplyId: String?
    /// Issue #15: `true` while `open()` merges the server history into cached messages ("Updating…").
    public private(set) var isUpdating = false
    /// Issue #15: the messages that the last history merge added, oldest first. The screen shows the
    /// "N New Messages" pill and VoiceOver reads the count once. `clearNewMessages()` empties it.
    public private(set) var newMessageIds: [String] = []
    /// Issue #67: `/new`. The screen pushes a new chat for it.
    public private(set) var newChatRequest: NewChatRequest?
    /// Issue #67: text for the composer: a `prefill` result, or the typed text of a command that failed.
    public private(set) var composerFill: ComposerFill?
    /// Issue #17: the message that the next text send quotes. The composer shows it above the text view.
    public private(set) var replyQuote: ChatQuote?
    /// Issue #104: the last approval card that showed. Each new card gets a new value. The screen plays the
    /// `.warning` haptic for it.
    public private(set) var approvalAlert: ApprovalAlert?
    /// Issue #104: an approval came on the open socket (not a replay). The app posts a local notification when
    /// it is in the background.
    @ObservationIgnored public var onApprovalRequest: (@MainActor (ApprovalAlert) -> Void)?
    /// Issue #117: the id of the last prompt card that showed. Each new card gets a new value. The screen plays
    /// the `.warning` haptic for it.
    public private(set) var promptAlertId: String?

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
    /// Writes the audio of a voice reply to a file (issue #10). Tests use a fake.
    @ObservationIgnored private let saveSpeech: @Sendable (SpokenAudio) throws -> VoiceReplyAudio
    /// Issue #44: the on-device recognizers and the server fallback for voice memos.
    @ObservationIgnored private let transcription: VoiceTranscription
    /// Replies with a speak call that runs.
    @ObservationIgnored private var speaking: Set<String> = []
    /// Issue #36: this new chat keeps its memos under `SessionCache.newChatId` until its first prompt is
    /// accepted. Before that the server has no row, so launch cannot find the chat by its stored id.
    /// One new chat at a time holds it (`SessionListModel.newChat`).
    @ObservationIgnored private(set) var keepsNewChat: Bool
    /// Issue #67: the prompt text of a `send` or `skill` result, by message id. The bubble shows `display`.
    @ObservationIgnored private var commandPrompts: [String: String] = [:]
    /// Issue #98: the `voice_context` of each GPT-Live delegation, by message id. These go out with surface `voice-live`.
    @ObservationIgnored private var livePrompts: [String: String] = [:]
    /// Issue #96: the memos of voice mode. Their replies get the audio that played, not a `POST /api/audio/speak`.
    @ObservationIgnored private var voiceModePrompts: Set<String> = []
    /// Issue #39: the run that sends the queued messages in order. One run at a time.
    @ObservationIgnored private var outboxTask: Task<Void, Never>?
    /// Issue #12: the downloads of the `MEDIA:` files of this chat.
    @ObservationIgnored public let receivedFiles: ReceivedFileLoader
    /// Metadata only: ids, counts and states. Never the text of a message (issue #18).
    @ObservationIgnored private let log = HermesLog(category: "chat")

    /// `messages` is history that the screen shows at once (DEBUG demo). With no `messages`, a model with
    /// a `storedSessionId` and a `cache` shows the cached transcript.
    /// `keepsNewChat` (issue #36): a new chat shows the memos that the last new chat kept, and keeps its own.
    public init(transport: any ChatTransport, session: ChatSessionRef? = nil, storedSessionId: String? = nil,
                title: String? = nil, messages: [ChatMessage] = [], cache: (any SessionCacheStore)? = nil,
                keepsNewChat: Bool = false,
                redrawInterval: Duration = .milliseconds(100),
                now: @escaping @Sendable () -> Date = { Date() },
                makeId: @escaping @Sendable () -> String = { UUID().uuidString },
                loadAudio: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
                removeAudio: @escaping @Sendable (URL) -> Void = { try? FileManager.default.removeItem(at: $0) },
                saveSpeech: @escaping @Sendable (SpokenAudio) throws -> VoiceReplyAudio = { try VoiceReplyFiles.save($0) },
                transcription: VoiceTranscription = .server,
                receivedFiles: ReceivedFileLoader? = nil) {
        self.transport = transport
        self.receivedFiles = receivedFiles ?? ReceivedFileLoader(transport: transport, storedSessionId: { nil })
        self.transcription = transcription
        self.saveSpeech = saveSpeech
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
        let keeps = keepsNewChat && storedSessionId == nil && session?.storedId == nil && cache != nil
        self.keepsNewChat = keeps
        var initial = messages
        if initial.isEmpty, let stored = self.storedSessionId, let cache {
            initial = cache.loadTranscript(sessionId: stored)
        } else if initial.isEmpty, keeps, let cache {
            initial = cache.loadTranscript(sessionId: SessionCache.newChatId)
        }
        self.thread = ChatThread(messages: initial)
        self.messages = initial
        self.receivedFiles.storedSessionId = { [weak self] in self?.storedSessionId }
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
            if (try? await currentSession()) != nil { sendQueued() }
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
        isUpdating = !messages.isEmpty
        defer {
            isLoadingHistory = false
            isUpdating = false
        }
        do {
            // Always resume: the server reaps an idle live session 20 s after its socket drops.
            let live = try await resumedSession()
            let transcript = try await transport.history(sessionId: live.liveId)
            needsOpen = false
            // A session with a transcript has a server row, so the next launch can resume it.
            if !transcript.isEmpty { saveActiveSessionId() }
            // A running turn owns the end of the thread. Its `message.complete` brings the text.
            guard thread.turn == .idle else {
                await loadPendingApprovals(live)
                return
            }
            let history = ChatHistory.messages(from: transcript, reusing: thread.messages, fallbackDate: now())
            let shown = Set(thread.messages.map(\.id))
            if thread.replaceHistory(history) {
                // All new rows reach the screen in one update (issue #15).
                let added = thread.messages.map(\.id).filter { !shown.contains($0) }
                if !shown.isEmpty, !added.isEmpty { newMessageIds = added }
                redrawNow()
            }
            saveTranscript()
            // Issue #39: the link is up. The outbox sends after the history, so the order stays.
            sendQueued()
            await loadPendingApprovals(live)
        } catch where Self.isSessionNotFound(error) && !thread.messages.isEmpty {
            // QA #38 defect 1: the server lost a row that has messages on the screen. Keep them and
            // start a new session in its place. The chat stays open.
            await replaceLostSession()
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

    /// `session.create` in place of a stored session that the server lost (4007). The thread, the cache and
    /// the draft move to the new stored id. If the create fails, the next connect tries the open again.
    private func replaceLostSession() async {
        let lost = storedSessionId
        let draft = self.draft
        session = nil
        sessionIsStale = false
        storedSessionId = nil
        do {
            _ = try await currentSession()
            needsOpen = false
            log.notice("session not found: started a new session")
            saveTranscript()
            if !draft.isEmpty { updateDraft(draft) }
            sendQueued()
        } catch {
            if storedSessionId == nil { storedSessionId = lost }
            needsOpen = true
        }
    }

    /// Issue #64: the live id of the session, if this chat opened one. A delete closes it first.
    public var liveSessionId: String? { session?.liveId }

    /// Issue #64: the server closed the live session. The next send or open resumes the stored id.
    func liveSessionClosed() {
        session = nil
        sessionIsStale = false
        if storedSessionId != nil { needsOpen = true }
    }

    /// Issue #64: a rename from the list or the title menu, or the old title after a failed rename.
    func applyTitle(_ newTitle: String?) {
        if title != newTitle { title = newTitle }
    }

    /// The screen showed the new messages (the owner tapped the pill or scrolled to them).
    public func clearNewMessages() {
        if !newMessageIds.isEmpty { newMessageIds = [] }
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
        guard let cache else { return }
        if keepsNewChat { cache.saveTranscript(thread.messages, sessionId: SessionCache.newChatId) }
        if let storedSessionId { cache.saveTranscript(thread.messages, sessionId: storedSessionId) }
        saveOutboxIndex()
    }

    /// Issue #39: the outbox index has one key per chat. A chat in the new-chat slot uses the slot key, because
    /// launch opens that slot. Its stored id must not send the same messages a second time.
    private func saveOutboxIndex() {
        guard let cache else { return }
        let queued = thread.messages.contains { $0.delivery == .queued }
        if keepsNewChat { cache.saveOutbox(queued, sessionId: SessionCache.newChatId) }
        if let storedSessionId { cache.saveOutbox(queued && !keepsNewChat, sessionId: storedSessionId) }
    }

    /// Issue #36: another new chat takes the slot. Only an empty chat gives it up, so no kept memo is lost.
    func yieldNewChat() {
        guard keepsNewChat, thread.messages.isEmpty else { return }
        keepsNewChat = false
    }

    /// Issue #36: the first accepted prompt made the server row. The chat now lives under its stored id.
    private func leaveNewChatSlot() {
        guard keepsNewChat else { return }
        keepsNewChat = false
        cache?.saveTranscript([], sessionId: SessionCache.newChatId)
        cache?.saveOutbox(false, sessionId: SessionCache.newChatId)
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
            switch event.kind {
            case .requestCancel(let payload):
                // Issue #104, #117: the server withdrew a request. Only the card of that request changes.
                // The reason can be free text from the approval tool: it stays out of the log.
                log.info("server request withdrawn: \(payload.method)")
                let approval = thread.withdrawApproval(serverRequestId: payload.id, reason: payload.reason)
                let prompt = thread.withdrawPrompt(serverRequestId: payload.id, reason: payload.reason)
                if approval || prompt { redrawNow() }
                return
            case .approvalCancelled(let payload):
                log.info("approvals cancelled: \(payload.requestIds.count)")
                if thread.cancelApprovals(requestIds: payload.requestIds) { redrawNow() }
                return
            default:
                break
            }
            if case .messageComplete = event.kind { log.info("reply complete: session \(live)") }
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
            // Issue #15: a session that was open before also catches up. A reconnect after a suspend
            // can replace the client with no `.disconnected` event.
            if needsOpen || session != nil, storedSessionId != nil {
                Task { await open() }
            } else if hasQueued {
                // Issue #39: a new chat with no stored id, or a chat that did not open yet.
                sendQueued()
            }
        case .serverRequest(let request):
            guard let live = session?.liveId, request.sessionId == live else { return }
            handle(request, sessionId: live, replayed: false)
        case .state:
            break
        }
    }

    // MARK: Server requests (issue #104)

    /// `true` while an approval card waits for the owner. The chats list shows "Approval needed".
    public var hasWaitingApproval: Bool {
        messages.contains { $0.approval?.isWaiting == true }
    }

    /// An `approval` shows an approval card. Issue #117: `secret`, `sudo` and `clarify` show a prompt card.
    /// `replayed` is a request from a resume snapshot.
    private func handle(_ request: GatewayServerRequest, sessionId: String, replayed: Bool) {
        if let approval = request.approval {
            showApproval(ChatApprovalCard(request: approval, serverRequestId: request.id, sessionId: sessionId),
                         replayed: replayed)
            return
        }
        guard let card = ChatPromptCard(request: request, sessionId: sessionId) else { return }
        showPrompt(card, method: request.method)
    }

    /// Issue #117: adds the prompt card. A clarify request with no question that the owner can answer ends at once
    /// with no answers (desktop `server-requests.ts:clarify`).
    private func showPrompt(_ card: ChatPromptCard, method: String) {
        if case .clarify = card.kind, card.openQuestions.isEmpty {
            guard let requests = transport as? any ServerRequestTransport else { return }
            let id = card.serverRequestId
            let locked: [String: String?]? = if case .clarify(_, let locked) = card.kind, !locked.isEmpty { locked } else { nil }
            Task { try? await requests.answerClarify(requestId: id, answers: locked, outcome: "submitted") }
            return
        }
        let id = makeId()
        guard thread.addPrompt(id: id, card: card, date: now()) else { return }
        // The method only: never the prompt, the env var name or the command.
        log.info("prompt shown: card \(id), method \(method)")
        redrawNow()
        promptAlertId = id
    }

    /// Issue #117: Send on a secret or a password card. The value goes on the JSON-RPC id of the request. The card
    /// keeps no copy of it, and the value never goes to a log. If the answer does not go, the empty field shows
    /// again with "Not sent. Try again.". Returns the task (tests wait for it).
    @discardableResult
    public func answerPrompt(id: String, value: String) -> Task<Void, Never>? {
        guard let card = thread.message(id: id)?.prompt, card.isWaiting, card.isSecure, !value.isEmpty,
              let requests = transport as? any ServerRequestTransport else { return nil }
        let requestId = card.serverRequestId
        return sendPrompt(id: id) { try await requests.answerValue(requestId: requestId, value: value) }
    }

    /// Issue #117: Send on a question card. `typed` holds one answer for each open question, by `qid`.
    @discardableResult
    public func answerClarify(id: String, typed: [String: String]) -> Task<Void, Never>? {
        guard let card = thread.message(id: id)?.prompt, card.isWaiting, let answers = card.clarifyAnswers(typed),
              let requests = transport as? any ServerRequestTransport else { return nil }
        let requestId = card.serverRequestId
        return sendPrompt(id: id) {
            try await requests.answerClarify(requestId: requestId, answers: answers, outcome: "submitted")
        }
    }

    /// Issue #117: Cancel on a prompt card. A secret or a password gets an error answer (a withdrawal). A question
    /// gets a result with no answers (cancel-all, `ClarifyResult`). The card shows "Cancelled".
    @discardableResult
    public func cancelPrompt(id: String) -> Task<Void, Never>? {
        guard let card = thread.message(id: id)?.prompt, card.isWaiting,
              let requests = transport as? any ServerRequestTransport else { return nil }
        thread.setPromptState(.cancelled, id: id)
        redrawNow()
        log.info("prompt cancelled: card \(id)")
        let requestId = card.serverRequestId
        let secure = card.isSecure
        return Task {
            if secure {
                try? await requests.rejectServerRequest(requestId, code: ChatPromptCard.cancelErrorCode,
                                                        message: ChatPromptCard.cancelErrorMessage)
            } else {
                try? await requests.answerClarify(requestId: requestId, answers: nil, outcome: "cancelled")
            }
        }
    }

    private func sendPrompt(id: String, _ send: @escaping @Sendable () async throws -> Void) -> Task<Void, Never> {
        thread.setPromptState(.sending, id: id)
        redrawNow()
        log.info("prompt answered: card \(id)")
        return Task {
            let sent: Bool
            do {
                try await send()
                sent = true
            } catch {
                sent = false
            }
            guard thread.message(id: id)?.prompt?.state == .sending else { return }
            if !sent { log.notice("prompt answer not sent: card \(id)") }
            thread.setPromptState(sent ? .sent : .waiting, sendFailed: !sent, id: id)
            redrawNow()
        }
    }

    /// Adds the card, or updates the card of the same request. A new card plays the haptic, tells the server that
    /// it shows (`approval.received`), and, for a request on the open socket, asks the app for a notification.
    private func showApproval(_ card: ChatApprovalCard, replayed: Bool) {
        let id = makeId()
        guard thread.addApproval(id: id, card: card, date: now()) else {
            redrawNow()
            return
        }
        // Ids and counts only: never the command or the description.
        log.info("approval shown: card \(id), \(card.choices.count) choices, replayed \(replayed)")
        redrawNow()
        let alert = ApprovalAlert(id: id, storedSessionId: storedSessionId, title: title)
        approvalAlert = alert
        if !replayed { onApprovalRequest?(alert) }
        guard !card.requestId.isEmpty, let requests = transport as? any ServerRequestTransport else { return }
        let sessionId = card.sessionId
        let requestId = card.requestId
        Task { try? await requests.acknowledgeApproval(sessionId: sessionId, requestId: requestId) }
    }

    /// Issue #104: the cards of a resume snapshot. `open_requests` first: they carry the JSON-RPC id. Then the
    /// snapshot `pending_approval`. A waiting card that the snapshot does not list ended while the socket was
    /// closed: it shows "This request expired".
    private func applySnapshot(_ ref: ChatSessionRef) {
        var open = Set<String>()
        var openPrompts = Set<JSONRPCID>()
        for request in ref.openRequests ?? [] {
            if let approval = request.approval { open.insert(approval.requestId) } else { openPrompts.insert(request.id) }
            handle(request, sessionId: ref.liveId, replayed: true)
        }
        if let pending = ref.pendingApproval {
            open.insert(pending.requestId)
            showApproval(ChatApprovalCard(request: pending, serverRequestId: nil, sessionId: ref.liveId), replayed: true)
        }
        if ref.openRequests != nil, thread.expireApprovals(notIn: open) { redrawNow() }
        // Issue #117: a prompt keeps its JSON-RPC id across a reconnect (`server.py:666-680`).
        if ref.openRequests != nil, thread.expirePrompts(notIn: openPrompts) { redrawNow() }
    }

    /// Issue #104: `approval.pending` after an open. It lists every approval that waits, also the ones after the
    /// oldest. An older server without the method changes nothing.
    private func loadPendingApprovals(_ live: ChatSessionRef) async {
        guard let requests = transport as? any ServerRequestTransport,
              let pending = try? await requests.pendingApprovals(sessionId: live.liveId),
              session?.liveId == live.liveId else { return }
        for approval in pending {
            showApproval(ChatApprovalCard(request: approval, serverRequestId: nil, sessionId: live.liveId),
                         replayed: true)
        }
    }

    /// A tap on a choice of an approval card. The answer goes on the JSON-RPC id of the request. A card with no id,
    /// or an answer that did not go (the socket closed), uses `approval.respond` with the queue id. If that fails
    /// too, the buttons show again. Returns the task (tests wait for it).
    @discardableResult
    public func answerApproval(id: String, choice: ApprovalChoice) -> Task<Void, Never>? {
        guard let card = thread.message(id: id)?.approval, card.isWaiting, card.choices.contains(choice),
              let requests = transport as? any ServerRequestTransport else { return nil }
        thread.setApprovalState(.sending(choice), id: id)
        redrawNow()
        log.info("approval answered: card \(id), choice \(choice.rawValue)")
        return Task {
            let state = await Self.send(choice, for: card, with: requests)
            guard thread.message(id: id)?.approval?.state == .sending(choice) else { return }
            if state == .waiting { log.notice("approval answer not sent: card \(id)") }
            thread.setApprovalState(state, id: id)
            redrawNow()
        }
    }

    private nonisolated static func send(_ choice: ApprovalChoice, for card: ChatApprovalCard,
                                         with requests: any ServerRequestTransport) async -> ChatApprovalCard.State {
        if let serverRequestId = card.serverRequestId {
            do {
                try await requests.answerApproval(requestId: serverRequestId, choice: choice)
                return .answered(choice)
            } catch {
                guard !card.requestId.isEmpty else { return .waiting }
            }
        }
        do {
            let resolved = try await requests.respondApproval(sessionId: card.sessionId, choice: choice,
                                                              requestId: card.requestId.isEmpty ? nil : card.requestId)
            return resolved > 0 ? .answered(choice) : .expired
        } catch {
            return .waiting
        }
    }

    // MARK: Actions

    /// Shows the bubble at once, then sends the text. Returns the send task (tests wait for it).
    /// Empty text after trimming sends nothing.
    /// Issue #8: `attachments` upload first, in order, each with its own progress ring. Then `prompt.submit`.
    /// Attachments with no text also send.
    /// Issue #67: a slash command never goes to `prompt.submit` as text (`runCommand`). The screen keeps the
    /// attachments in the composer for a command.
    @discardableResult
    public func send(_ text: String, attachments: [ChatAttachment] = []) -> Task<Void, Never>? {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || !attachments.isEmpty else { return nil }
        if hasText, let command = SlashCommand(text) { return runCommand(command) }
        let id = makeId()
        thread.addOutgoing(id: id, text: hasText ? text : "", date: now(), attachments: attachments, quote: replyQuote)
        replyQuote = nil
        if let queued = queueBehindOutbox(id) { return queued }
        redrawNow()
        return Task { await deliver(id: id, retryBeforeRowId: nil) }
    }

    /// Sends a recorded voice memo (issue #9, docs/hermes-protocol.md 3.9). The bubble shows at once with
    /// "Transcribing…". Then the clip goes to `POST /api/audio/transcribe`, and the transcript goes out as
    /// `prompt.submit` with `voice_turn: true`. An empty transcript sends no turn. A failure keeps the memo.
    /// Issue #44: with an on-device engine the iPhone makes the transcript, and the transcribe call runs
    /// only when the on-device path fails.
    @discardableResult
    public func sendVoiceMemo(_ memo: VoiceMemo) -> Task<Void, Never> {
        let id = makeId()
        thread.addOutgoingVoice(id: id, memo: memo, date: now())
        // Issue #17 (QA #80): a memo does not quote. The reply ends, so the composer box goes away.
        replyQuote = nil
        if let queued = queueBehindOutbox(id) { return queued }
        redrawNow()
        // The owner never loses a recording: the memo is in the cache before the upload starts.
        saveTranscript()
        return Task { await deliverVoice(id: id) }
    }

    /// Issue #96: the transcript of one voice mode clip, with the #44 engines: on-device first, then
    /// `POST /api/audio/transcribe`. No bubble shows yet, so a "stop" clip never shows. Throws on a failure.
    public func transcribeVoiceClip(at url: URL) async throws -> String {
        let transport = self.transport
        let loadAudio = self.loadAudio
        let transcription = self.transcription
        // The clip and the transcript never go to a log.
        return try await Task.detached {
            try await transcription.transcribe(fileURL: url) {
                try await transport.transcribe(audio: try loadAudio(url), mimeType: VoiceMemoLimits.mimeType)
            }
        }.value
    }

    /// Issue #96: one voice mode turn. The memo bubble shows with its transcript, then goes as a voice turn.
    /// The voice mode engine speaks the reply with `speak-stream`, so the #10 speak call does not run for it.
    /// Offline, the memo waits in the outbox, and the #10 rules apply when it goes later.
    public func sendVoiceModeTurn(_ memo: VoiceMemo, transcript: String) async -> VoiceModeTurnResult {
        let id = makeId()
        thread.addOutgoingVoice(id: id, memo: memo, date: now())
        thread.setTranscript(.done(transcript), id: id)
        replyQuote = nil
        voiceModePrompts.insert(id)
        if let queued = queueBehindOutbox(id) {
            await queued.value
        } else {
            redrawNow()
            saveTranscript()
            await deliver(id: id, retryBeforeRowId: nil)
        }
        switch thread.message(id: id)?.delivery {
        case .delivered?:
            return .delivered(promptId: id)
        case .queued?:
            voiceModePrompts.remove(id)
            return .queued
        default:
            voiceModePrompts.remove(id)
            return .failed
        }
    }

    /// Issue #96: the audio that voice mode played becomes the voice reply of the bubble (#10). It does not auto-play.
    /// Returns the save task (tests wait for it).
    @discardableResult
    public func saveVoiceModeAudio(_ audio: SpokenAudio, promptId: String) -> Task<Void, Never>? {
        guard let reply = thread.messages.last(where: { $0.promptId == promptId && $0.role == .assistant }),
              reply.spokenReply == nil else { return nil }
        let id = reply.id
        let saveSpeech = self.saveSpeech
        return Task {
            // The audio never goes to a log.
            let result: SpokenReply
            do {
                result = .ready(try await Task.detached { try saveSpeech(audio) }.value)
            } catch {
                return
            }
            guard thread.message(id: id)?.spokenReply == nil else { return }
            thread.setSpokenReply(result, id: id)
            redrawNow()
            saveTranscript()
        }
    }

    /// Issue #98: a GPT-Live delegation. The request shows as an owner text bubble and goes out at once as
    /// `prompt.submit` with surface `voice-live`. It never waits in the outbox. Returns the bubble id.
    public func sendLiveDelegation(_ text: String, voiceContext: String) async -> String {
        let id = makeId()
        thread.addOutgoing(id: id, text: text, date: now(), attachments: [], quote: nil)
        livePrompts[id] = voiceContext
        redrawNow()
        _ = await deliver(id: id, retryBeforeRowId: nil)
        return id
    }

    /// Issue #98: the reply to a delegation bubble, for the live voice. Issue #96: the hands-free reply too.
    /// Issue #134: the text is every assistant message of the prompt in order, interim messages first, so it only
    /// grows while the turn runs. The last message gives the state.
    public func liveReplyProgress(promptId: String) -> LiveReplyProgress {
        guard let prompt = thread.message(id: promptId) else { return .failed }
        let replies = thread.messages.filter { $0.promptId == promptId && $0.role == .assistant }
        if let reply = replies.last {
            // An older failed reply of a retried prompt is not part of the answer.
            let text = replies.filter { $0.id == reply.id || !$0.isFailed }
                .map { thread.voiceText(id: $0.id) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            switch reply.reply {
            case .complete, .interrupted: return .done(text)
            case .failed: return .failed
            case .streaming, nil: return .streaming(text)
            }
        }
        switch prompt.delivery {
        case .failed, .queued: return .failed
        case .delivered where turn == .idle: return .done("")
        default: return .waiting
        }
    }

    /// "Try Again" on a bubble that shows "Not Delivered" (or "No speech found." for a memo).
    /// A memo with a transcript sends the turn again. A memo with no transcript is transcribed again.
    @discardableResult
    public func retrySend(id: String) -> Task<Void, Never>? {
        guard let message = thread.message(id: id), message.delivery == .failed else { return nil }
        // Issue #39: with messages in the outbox, the retry waits its turn in thread order.
        if let queued = queueBehindOutbox(id) { return queued }
        thread.setDelivery(.sending, id: id)
        if let voice = message.voice, voice.transcript.text == nil {
            thread.setTranscript(.pending, id: id)
            redrawNow()
            return Task { await deliverVoice(id: id) }
        }
        redrawNow()
        return Task { await deliver(id: id, retryBeforeRowId: nil) }
    }

    /// Issue #17: "Reply" (swipe or menu). The next text send quotes this message. `false` if it cannot be quoted.
    @discardableResult
    public func startReply(to id: String) -> Bool {
        guard let message = thread.message(id: id), let quote = ChatQuote(message: message) else { return false }
        replyQuote = quote
        return true
    }

    /// Issue #17: "Cancel Reply" in the composer.
    public func cancelReply() {
        replyQuote = nil
    }

    /// Issue #17: the bubble that the quote of message `id` points to, or `nil` if it is not loaded.
    public func quotedMessageId(of id: String) -> String? {
        guard let quote = thread.message(id: id)?.quote else { return nil }
        return QuoteReply.target(of: quote, in: thread.messages.filter { $0.id != id })
    }

    /// Issue #11: the owner's tapback. The same tapback again, or `nil`, removes it. It stays on the phone:
    /// nothing goes to Hermes (D3). The cache keeps it.
    public func react(_ tapback: Tapback?, id: String) {
        let changed = if let tapback { thread.react(tapback, id: id) } else { thread.removeTapback(id: id) }
        guard changed else { return }
        redrawNow()
        saveTranscript()
    }

    /// "Delete" on a bubble that shows "Not Delivered". A memo also loses its audio file.
    public func delete(id: String) {
        if let url = thread.message(id: id)?.voice?.fileURL { removeAudio(url) }
        thread.remove(id: id)
        redrawNow()
        saveTranscript()
    }

    /// Issue #10: "Audio unavailable. Tap to retry." on a voice reply. A manual retry does not auto-play.
    @discardableResult
    public func retrySpeech(id: String) -> Task<Void, Never>? {
        guard thread.message(id: id)?.spokenReply == .failed else { return nil }
        return speak(replyId: id, autoPlay: false)
    }

    /// Issue #42: the ready audio of a reply did not play, for example an `.ogg` file that an older build saved.
    /// The bubble shows "Audio unavailable. Tap to retry.", and a tap speaks the reply again.
    public func speechDidNotPlay(id: String) {
        guard thread.message(id: id)?.spokenReply?.audio != nil else { return }
        thread.setSpokenReply(.failed, id: id)
        redrawNow()
        saveTranscript()
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

    // MARK: Outbox (issue #39)

    /// `true` when a message waits in the outbox, or the outbox run sends one.
    public var hasQueued: Bool {
        outboxTask != nil || thread.messages.contains { $0.delivery == .queued }
    }

    /// "Send Now" on a queued bubble, and each connect: the queued messages go one at a time, in thread order.
    /// A message that fails because the app is offline goes back to the outbox, and the run stops.
    /// A message that the server refuses shows "Not Delivered", and the run goes on. Returns the run (tests).
    @discardableResult
    public func sendQueued() -> Task<Void, Never>? {
        if let outboxTask { return outboxTask }
        guard thread.messages.contains(where: { $0.delivery == .queued }) else { return nil }
        let task = Task { [weak self] in
            await self?.sendOutbox()
            self?.outboxTask = nil
        }
        outboxTask = task
        return task
    }

    private func sendOutbox() async {
        while let next = thread.messages.first(where: { $0.delivery == .queued }) {
            let id = next.id
            thread.setDelivery(.sending, id: id)
            let transcribe = next.voice.map { $0.transcript.text == nil } ?? false
            if transcribe { thread.setTranscript(.pending, id: id) }
            redrawNow()
            // A quit from now on must not send it again: the cache no longer has it as queued.
            saveTranscript()
            log.info("outbox: sending message \(id)")
            let outcome = transcribe ? await deliverVoice(id: id) : await deliver(id: id, retryBeforeRowId: nil)
            if outcome == .queued { return }
        }
    }

    /// A new message, or a retry, while other messages wait: it goes into the outbox after them, so the
    /// order stays. Returns the outbox run, or `nil` when the outbox is empty and the message can go now.
    private func queueBehindOutbox(_ id: String) -> Task<Void, Never>? {
        guard hasQueued else { return nil }
        thread.setDelivery(.queued, id: id)
        redrawNow()
        saveTranscript()
        return sendQueued()
    }

    /// The send failed because the app is offline: the message waits in the outbox.
    private func queue(_ id: String) {
        log.notice("prompt queued offline: message \(id)")
        thread.setDelivery(.queued, id: id)
        // An upload that the drop stopped goes again with the send.
        for item in thread.message(id: id)?.attachments ?? [] where item.upload == .failed {
            thread.setUpload(.pending, attachment: item.id, message: id)
        }
        saveTranscript()
    }

    /// A reply retry (`truncate_before_row_id`) and the prompt of a slash command result keep "Not Delivered":
    /// the outbox sends plain prompts only, and the cache cannot keep the command prompt text.
    private func canQueue(_ id: String, retryBeforeRowId: Int?) -> Bool {
        retryBeforeRowId == nil && commandPrompts[id] == nil && thread.message(id: id) != nil
    }

    /// Siri (issue #71) never queues: it says "not reachable", and a new try sends the text once.
    func failQueued(id: String) {
        guard thread.message(id: id)?.delivery == .queued else { return }
        thread.setDelivery(.failed, id: id)
        redrawNow()
        saveTranscript()
    }

    // MARK: Send

    /// How one delivery ended.
    private enum DeliveryOutcome {
        case delivered
        case failed
        /// Offline: the message went back to the outbox (issue #39).
        case queued
    }

    @discardableResult
    private func deliverVoice(id: String) async -> DeliveryOutcome {
        guard let url = thread.message(id: id)?.voice?.fileURL else { return .failed }
        let transport = self.transport
        let loadAudio = self.loadAudio
        let transcription = self.transcription
        let transcript: String
        do {
            // The clip and the transcript never go to a log.
            transcript = try await Task.detached {
                try await transcription.transcribe(fileURL: url) {
                    let audio = try loadAudio(url)
                    return try await transport.transcribe(audio: audio, mimeType: VoiceMemoLimits.mimeType)
                }
            }.value
        } catch {
            guard thread.message(id: id) != nil else { return .failed }
            if Outbox.isOffline(error, submitted: false) {
                // Issue #39: the memo waits with no transcript. The outbox transcribes it on connect.
                queue(id)
                redrawNow()
                return .queued
            }
            thread.setTranscript(.failed, id: id)
            thread.setDelivery(.failed, id: id)
            redrawNow()
            saveTranscript()
            return .failed
        }
        guard thread.message(id: id) != nil else { return .failed }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            thread.setTranscript(.empty, id: id)
            thread.setDelivery(.failed, id: id)
            redrawNow()
            saveTranscript()
            return .failed
        }
        thread.setTranscript(.done(transcript), id: id)
        redrawNow()
        return await deliver(id: id, retryBeforeRowId: nil)
    }

    @discardableResult
    private func deliver(id: String, retryBeforeRowId: Int?) async -> DeliveryOutcome {
        guard let isVoice = thread.message(id: id).map({ $0.voice != nil }) else { return .failed }
        // Issue #39: `true` from the `prompt.submit` call on. After that a drop is not "offline".
        var submitted = false
        let outcome: DeliveryOutcome
        do {
            let session = try await currentSession()
            try await uploadAttachments(of: id, to: session.liveId)
            guard let message = thread.message(id: id) else { return .failed }
            let text = commandPrompts[id] ?? AttachmentPayload.promptText(
                QuoteReply.promptText(message.text, quote: message.quote), attachments: message.attachments)
            thread.beginTurn(promptId: id)
            redrawNow()
            submitted = true
            let row = if let voiceContext = livePrompts[id], let live = transport as? any LiveDelegationTransport {
                try await live.submitLivePrompt(sessionId: session.liveId, text: text, voiceContext: voiceContext)
            } else if isVoice {
                try await transport.submitVoicePrompt(sessionId: session.liveId, text: text,
                                                      retryBeforeRowId: retryBeforeRowId)
            } else {
                try await transport.submitPrompt(sessionId: session.liveId, text: text,
                                                 retryBeforeRowId: retryBeforeRowId)
            }
            thread.setDelivery(.delivered, id: id, userRowId: row)
            log.info("prompt delivered: message \(id), \(text.count) characters, "
                     + "\(message.attachments.count) attachments, voice \(isVoice)")
            leaveNewChatSlot()
            saveActiveSessionId()
            saveTranscript()
            outcome = .delivered
        } catch where livePrompts[id] == nil && canQueue(id, retryBeforeRowId: retryBeforeRowId)
                        && Outbox.isOffline(error, submitted: submitted) {
            thread.cancelWaiting()
            queue(id)
            outcome = .queued
        } catch {
            log.notice("prompt not delivered: message \(id)")
            thread.setDelivery(.failed, id: id)
            thread.cancelWaiting()
            if isVoice { saveTranscript() }
            outcome = .failed
        }
        redrawNow()
        return outcome
    }

    /// Issue #8: each attachment that the live session does not hold yet goes up, one at a time.
    /// A failure marks the item and throws, so the message shows "Not Delivered" with "Try Again".
    private func uploadAttachments(of id: String, to session: String) async throws {
        guard let items = thread.message(id: id)?.attachments, items.contains(where: { $0.needsUpload(to: session) })
        else { return }
        guard let uploader = transport as? any AttachmentTransport else {
            for item in items where item.needsUpload(to: session) {
                thread.setUpload(.failed, attachment: item.id, message: id)
            }
            throw AttachmentUploadError.notSupported
        }
        for item in items where item.needsUpload(to: session) {
            thread.setUpload(.uploading, attachment: item.id, message: id)
            redrawNow()
            do {
                let ref = try await Self.upload(item, to: session, with: uploader)
                thread.setUpload(.attached, attachment: item.id, message: id, refText: ref, sessionId: session)
                redrawNow()
            } catch {
                thread.setUpload(.failed, attachment: item.id, message: id)
                // The items after it wait for "Try Again".
                for later in items.drop(while: { $0.id != item.id }).dropFirst() where later.needsUpload(to: session) {
                    thread.setUpload(.pending, attachment: later.id, message: id)
                }
                throw error
            }
        }
    }

    /// One attach call. A PDF on a server with no `pdftoppm` (5028) goes as a file. Returns the `ref_text`.
    private nonisolated static func upload(_ item: ChatAttachment, to session: String,
                                           with uploader: any AttachmentTransport) async throws -> String? {
        let data = try Data(contentsOf: item.fileURL, options: .mappedIfSafe)
        switch item.kind {
        case .photo:
            try await uploader.attachImage(sessionId: session, data: data, filename: item.name)
            return nil
        case .pdf:
            do {
                let last = (item.pageCount ?? 0) > AttachmentLimits.pdfPages ? AttachmentLimits.pdfPages : nil
                try await uploader.attachPDF(sessionId: session, data: data, filename: item.name, lastPage: last)
                return nil
            } catch GatewayError.rpc(let code, _) where code == pdfRendererMissingCode {
                return try await uploader.attachFile(sessionId: session, data: data, name: item.name,
                                                     mimeType: item.mimeType)
            }
        case .file:
            return try await uploader.attachFile(sessionId: session, data: data, name: item.name,
                                                 mimeType: item.mimeType)
        case .location:
            return nil
        }
    }

    // MARK: Slash commands (issue #67)

    /// Runs a slash command (docs/hermes-protocol.md 3.11). `/new` and `/usage` run in the app. Other commands
    /// call `slash.exec`, and on error 4018 `command.dispatch`. Output and errors show as a command card.
    /// A failed command puts the typed text back in the composer. Returns the task (tests wait for it).
    @discardableResult
    public func runCommand(_ command: SlashCommand) -> Task<Void, Never> {
        log.info("slash command: /\(command.name.count) characters")
        switch SlashCommandCatalog.localAction(for: command.name) {
        case .newChat?:
            newChatRequest = NewChatRequest(id: makeId())
            return Task {}
        case .usage?:
            return Task { await showUsage(command) }
        case nil:
            return Task { await runServerCommand(command, typed: command, depth: 0) }
        }
    }

    private func showUsage(_ command: SlashCommand) async {
        guard let slash = transport as? any SlashCommandTransport else {
            return commandFailed(command, message: SlashCommandError.notSupported.message)
        }
        do {
            let session = try await currentSession()
            let usage = try await slash.sessionUsage(sessionId: session.liveId)
            addCommandCard(ChatCommandCard(command: command.display, output: usage.text()))
        } catch {
            commandFailed(command, message: SlashCommandError.message(for: error, command: command))
        }
    }

    private func runServerCommand(_ command: SlashCommand, typed: SlashCommand, depth: Int) async {
        guard let slash = transport as? any SlashCommandTransport else {
            return commandFailed(typed, message: SlashCommandError.notSupported.message)
        }
        let result: SlashExecResult
        do {
            let session = try await currentSession()
            do {
                result = try await slash.execSlash(sessionId: session.liveId, command: command.text)
            } catch GatewayError.rpc(let code, _) where code == slashUseDispatchCode {
                result = try await slash.dispatchCommand(sessionId: session.liveId, name: command.name,
                                                         arg: command.arg.isEmpty ? nil : command.arg)
            }
        } catch {
            return commandFailed(typed, message: SlashCommandError.message(for: error, command: command))
        }
        guard let outcome = SlashOutcome(result) else {
            return commandFailed(typed, message: SlashCommandError.invalidAnswer.message)
        }
        switch outcome {
        case .output(let raw):
            let output = SlashOutputText.clean(raw)
            if SlashOutputText.isUnknownCommand(output) {
                return commandFailed(typed, message: "Unknown command: \(command.display)")
            }
            addCommandCard(ChatCommandCard(command: typed.display, output: output.isEmpty ? "(no output)" : output))
        case .send(let message, let display, let notice):
            showNotice(notice, for: typed)
            let id = makeId()
            let shown = display.flatMap { $0.isEmpty ? nil : $0 } ?? typed.text
            commandPrompts[id] = message
            thread.addOutgoing(id: id, text: shown, date: now())
            redrawNow()
            await deliver(id: id, retryBeforeRowId: nil)
        case .prefill(let message, let notice):
            showNotice(notice, for: typed)
            composerFill = ComposerFill(id: makeId(), text: message, reason: .prefill)
        case .alias(let target):
            guard depth < 3, let next = SlashCommand("/" + target + (command.arg.isEmpty ? "" : " " + command.arg))
            else { return commandFailed(typed, message: SlashCommandError.invalidAnswer.message) }
            switch SlashCommandCatalog.localAction(for: next.name) {
            case .newChat?:
                newChatRequest = NewChatRequest(id: makeId())
            case .usage?:
                await showUsage(typed)
            case nil:
                await runServerCommand(next, typed: typed, depth: depth + 1)
            }
        }
    }

    private func showNotice(_ notice: String?, for command: SlashCommand) {
        let text = notice.map(SlashOutputText.clean) ?? ""
        guard !text.isEmpty else { return }
        addCommandCard(ChatCommandCard(command: command.display, output: text))
    }

    private func addCommandCard(_ card: ChatCommandCard) {
        thread.addCommandCard(id: makeId(), card: card, date: now())
        redrawNow()
    }

    /// A red card. The typed text goes back into the composer.
    private func commandFailed(_ command: SlashCommand, message: String) {
        log.notice("slash command failed")
        addCommandCard(ChatCommandCard(command: command.display, output: message, isError: true))
        composerFill = ComposerFill(id: makeId(), text: command.text, reason: .restore)
    }

    /// The screen pushed the new chat of `request`.
    public func clearNewChatRequest(_ request: NewChatRequest) {
        if newChatRequest == request { newChatRequest = nil }
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
            // Issue #104: approvals that wait show their cards (protocol 4.2).
            applySnapshot(created)
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
            if isVoiceTurnReply(id) { _ = speak(replyId: id, autoPlay: true) }
            redrawNow()
            completedReplyId = id
            saveTranscript()
        }
    }

    // MARK: Voice replies (issue #10)

    /// A complete reply to a delivered voice memo, with text to speak. A text turn never calls speak.
    private func isVoiceTurnReply(_ id: String) -> Bool {
        guard let reply = thread.message(id: id), reply.reply == .complete, reply.spokenReply == nil,
              let promptId = reply.promptId, thread.message(id: promptId)?.voice != nil,
              !voiceModePrompts.contains(promptId) else { return false }
        return !VoiceReplyText.spokenText(reply.text).isEmpty
    }

    /// `POST /api/audio/speak` with the final reply text. The audio bubble shows "Preparing audio…" at once.
    private func speak(replyId id: String, autoPlay: Bool) -> Task<Void, Never>? {
        guard let reply = thread.message(id: id), !speaking.contains(id) else { return nil }
        let text = VoiceReplyText.spokenText(reply.text)
        guard !text.isEmpty else { return nil }
        speaking.insert(id)
        thread.setSpokenReply(.preparing, id: id)
        redrawNow()
        let transport = self.transport
        let saveSpeech = self.saveSpeech
        return Task {
            let result: SpokenReply
            do {
                // The reply text and the audio never go to a log.
                let audio = try await Task.detached {
                    try saveSpeech(try await transport.speak(text: text))
                }.value
                result = .ready(audio)
            } catch {
                result = .failed
            }
            speaking.remove(id)
            guard thread.message(id: id) != nil else { return }
            thread.setSpokenReply(result, id: id)
            redrawNow()
            if autoPlay, result.audio != nil { autoPlayReplyId = id }
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
        if runningTool != thread.runningTool { runningTool = thread.runningTool }
        if toolActivity != thread.toolActivity { toolActivity = thread.toolActivity }
    }

    /// The thread state that is not drawn yet (tests).
    var pendingThread: ChatThread { thread }
}

/// Issue #67: the text of a red command card.
public enum SlashCommandError: Error, Equatable {
    case notSupported
    case invalidAnswer

    public var message: String {
        switch self {
        case .notSupported: "Commands are not available."
        case .invalidAnswer: "Hermes sent an answer that the app cannot read."
        }
    }

    /// The server `message` for an RPC error. 4018 from `command.dispatch` means no command has this name.
    static func message(for error: any Error, command: SlashCommand) -> String {
        switch error {
        case GatewayError.rpc(let code, _) where code == slashUseDispatchCode:
            return "Unknown command: \(command.display)"
        case GatewayError.rpc(_, let message) where !message.isEmpty:
            return message
        case GatewayError.timeout:
            return "Hermes did not answer in time."
        case let error as SlashCommandError:
            return error.message
        default:
            return "Hermes is not connected."
        }
    }
}

/// The chat transport has no attach calls (issue #8).
public enum AttachmentUploadError: Error, Equatable {
    case notSupported
}
