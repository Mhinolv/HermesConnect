import Foundation
import Observation

/// The state of the chat screen (issue #6). The MessageKit controller only draws it.
///
/// - Events change `thread` at once, so no delta is lost.
/// - Text-only changes reach `messages` at most once per `redrawInterval` (100 ms).
///   Other changes reach it at once.
/// - Message text never goes to a log.
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

    @ObservationIgnored private var thread = ChatThread()
    @ObservationIgnored private let transport: any ChatTransport
    @ObservationIgnored private let redrawInterval: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let makeId: @Sendable () -> String
    @ObservationIgnored private let sessionKey: String
    @ObservationIgnored private var session: ChatSessionRef?
    @ObservationIgnored private var sessionTask: Task<ChatSessionRef, any Error>?
    @ObservationIgnored private var redrawTask: Task<Void, Never>?
    @ObservationIgnored private var lastRedraw: ContinuousClock.Instant?

    /// `messages` is history that the screen shows at once (DEBUG demo, later the session history).
    public init(transport: any ChatTransport, session: ChatSessionRef? = nil, title: String? = nil,
                messages: [ChatMessage] = [], redrawInterval: Duration = .milliseconds(100),
                now: @escaping @Sendable () -> Date = { Date() },
                makeId: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.transport = transport
        self.session = session
        self.title = title
        self.redrawInterval = redrawInterval
        self.now = now
        self.makeId = makeId
        self.sessionKey = makeId()
        self.thread = ChatThread(messages: messages)
        self.messages = messages
    }

    /// `true` from the send until `message.complete`. The Stop button shows.
    public var isReplyActive: Bool { turn != .idle }

    /// Reads gateway events until the task is cancelled. The screen runs it in `.task`.
    public func run() async {
        for await event in transport.events {
            if Task.isCancelled { return }
            receive(event)
        }
    }

    /// Applies one item of the event stream. Events of other sessions are ignored.
    public func receive(_ item: GatewayClientEvent) {
        switch item {
        case .event(let event):
            if case .sessionTitle(let payload) = event.kind {
                if let stored = session?.storedId, payload.sessionId == stored, !payload.title.isEmpty {
                    title = payload.title
                }
                return
            }
            guard let live = session?.liveId, event.sessionId == live else { return }
            let makeId = self.makeId
            changed(thread.apply(event.kind, now: now(), makeId: makeId))
        case .state(.disconnected):
            let makeId = self.makeId
            changed(thread.connectionLost(now: now(), makeId: makeId))
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

    /// "Try Again" on a bubble that shows "Not Delivered".
    @discardableResult
    public func retrySend(id: String) -> Task<Void, Never>? {
        guard let message = thread.message(id: id), message.delivery == .failed else { return nil }
        thread.setDelivery(.sending, id: id)
        redrawNow()
        return Task { await deliver(id: id, retryBeforeRowId: nil) }
    }

    /// "Delete" on a bubble that shows "Not Delivered".
    public func delete(id: String) {
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

    private func deliver(id: String, retryBeforeRowId: Int?) async {
        guard let text = thread.message(id: id)?.text else { return }
        do {
            let session = try await currentSession()
            thread.beginTurn(promptId: id)
            redrawNow()
            let row = try await transport.submitPrompt(sessionId: session.liveId, text: text,
                                                       retryBeforeRowId: retryBeforeRowId)
            thread.setDelivery(.delivered, id: id, userRowId: row)
        } catch {
            thread.setDelivery(.failed, id: id)
            thread.cancelWaiting()
        }
        redrawNow()
    }

    /// The live session. The first send creates it with `source: "ios"`. Sends at the same time share one create.
    private func currentSession() async throws -> ChatSessionRef {
        if let session { return session }
        if let sessionTask { return try await sessionTask.value }
        let transport = self.transport
        let key = sessionKey
        let task = Task { try await transport.startSession(source: ChatSource.iOS, idempotencyKey: key) }
        sessionTask = task
        do {
            let created = try await task.value
            session = created
            sessionTask = nil
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
