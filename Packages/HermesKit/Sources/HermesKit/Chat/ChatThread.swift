import Foundation

/// Where the current turn is (docs/hermes-protocol.md 3.10).
public enum ChatTurnPhase: Sendable, Equatable {
    case idle
    /// `prompt.submit` went out. No `message.start` yet.
    case waiting
    /// `message.start` came in. No text yet: the typing indicator shows.
    case typing
    /// Text streams into the incoming bubble.
    case streaming
}

/// What one change did to the thread. The view model uses it to throttle redraws.
public enum ChatThreadChange: Sendable, Equatable {
    case none
    /// Only the text of the streaming bubble changed. Redraw at most every 100 ms.
    case text
    /// Bubbles, states or labels changed. Redraw now.
    case structure
    /// A reply ended. Redraw now and announce it once.
    case completed(id: String)
}

/// The message list and the turn state of one chat. A plain value type: the logic has no I/O.
public struct ChatThread: Sendable, Equatable {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var turn: ChatTurnPhase = .idle
    /// One line under the thread while a turn runs: "Using web_search…". Cleared on `message.complete`.
    public private(set) var statusLine: String?

    /// The incoming bubble of the current turn.
    private var replyId: String?
    /// The prompt of the current turn, for a reply retry.
    private var promptId: String?
    /// Text per `message.delta` segment.
    private var segments: [Int: String] = [:]
    /// UTF-16 units applied per segment, to drop chunks that come twice (`offset`).
    private var applied: [Int: Int] = [:]
    private var segment = 0

    public init(messages: [ChatMessage] = []) {
        self.messages = messages
    }

    public func message(id: String) -> ChatMessage? {
        messages.first { $0.id == id }
    }

    // MARK: Outgoing

    public mutating func addOutgoing(id: String, text: String, date: Date, attachments: [ChatAttachment] = []) {
        messages.append(ChatMessage(id: id, role: .user, text: text, date: date, delivery: .sending,
                                    attachments: attachments))
    }

    /// Issue #8: the attach state of one attachment of an outgoing message.
    public mutating func setUpload(_ upload: ChatAttachment.Upload, attachment: String, message id: String,
                                   refText: String? = nil, sessionId: String? = nil) {
        guard let index = index(of: id),
              let item = messages[index].attachments.firstIndex(where: { $0.id == attachment }) else { return }
        messages[index].attachments[item].upload = upload
        if let refText { messages[index].attachments[item].refText = refText }
        if upload == .attached { messages[index].attachments[item].attachedSessionId = sessionId }
    }

    /// A voice memo: the bubble shows at once with "Transcribing…" (issue #9).
    public mutating func addOutgoingVoice(id: String, memo: VoiceMemo, date: Date) {
        var memo = memo
        memo.transcript = .pending
        messages.append(ChatMessage(id: id, role: .user, text: "", date: date, delivery: .sending, voice: memo))
    }

    /// A transcript came, or the transcription failed. A transcript becomes the text of the voice turn.
    public mutating func setTranscript(_ transcript: VoiceTranscript, id: String) {
        guard let index = index(of: id), messages[index].voice != nil else { return }
        messages[index].voice?.transcript = transcript
        messages[index].text = transcript.text ?? ""
    }

    /// Issue #10: the speak state of a reply. Only a reply can have spoken audio.
    public mutating func setSpokenReply(_ spoken: SpokenReply?, id: String) {
        guard let index = index(of: id), messages[index].role == .assistant else { return }
        messages[index].spokenReply = spoken
    }

    public mutating func setDelivery(_ delivery: ChatMessage.Delivery, id: String, userRowId: Int? = nil) {
        guard let index = index(of: id) else { return }
        messages[index].delivery = delivery
        if let userRowId { messages[index].userRowId = userRowId }
    }

    public mutating func remove(id: String) {
        messages.removeAll { $0.id == id }
        if replyId == id { replyId = nil }
    }

    /// A prompt went out. The Stop button shows until the turn ends.
    public mutating func beginTurn(promptId: String) {
        self.promptId = promptId
        if turn == .idle { turn = .waiting }
    }

    /// `prompt.submit` failed before the turn started.
    public mutating func cancelWaiting() {
        if turn == .waiting { endTurn() }
    }

    // MARK: History

    /// Puts the server transcript in place of the ended messages (issue #7). Sends in progress, failed
    /// sends and the bubble of a running turn stay at the end. A failed reply goes when the history has
    /// a reply to the same prompt. Returns `false` when nothing changed.
    @discardableResult
    public mutating func replaceHistory(_ history: [ChatMessage]) -> Bool {
        let historyIds = Set(history.map(\.id))
        let answered = Set(history.compactMap { $0.role == .assistant ? $0.promptId : nil })
        let ended = Set(messages.filter(SessionCache.isEnded).map(\.id))
        let kept = messages.filter { message in
            guard !ended.contains(message.id), !historyIds.contains(message.id) else { return false }
            if case .failed = message.reply, let promptId = message.promptId, answered.contains(promptId) {
                return false
            }
            return true
        }
        let merged = history + kept
        guard merged != messages else { return false }
        messages = merged
        return true
    }

    // MARK: Events

    /// Applies one gateway event of this session. `now` dates a new bubble, `makeId` names it.
    @discardableResult
    public mutating func apply(_ kind: GatewayEvent.Kind, now: Date, makeId: () -> String) -> ChatThreadChange {
        switch kind {
        case .messageStart:
            resetStream()
            replyId = nil
            turn = .typing
            return .structure
        case .messageDelta(let delta):
            return applyDelta(delta, now: now, makeId: makeId)
        case .toolStart(let tool):
            guard turn != .idle else { return .none }
            statusLine = "Using \(tool.name)…"
            return .structure
        case .statusUpdate(let status):
            guard turn != .idle, !status.text.isEmpty else { return .none }
            statusLine = status.text
            return .structure
        case .messageComplete(let complete):
            return applyComplete(complete, now: now, makeId: makeId)
        case .error(let error):
            guard turn != .idle else { return .none }
            return fail(message: error.message, now: now, makeId: makeId)
        default:
            return .none
        }
    }

    /// The socket dropped during a turn. The reply fails, so the owner can retry.
    /// A prompt that is still sending gets only "Not Delivered" from its send, not a failed reply too.
    @discardableResult
    public mutating func connectionLost(now: Date, makeId: () -> String) -> ChatThreadChange {
        guard turn != .idle else { return .none }
        if turn == .waiting, let promptId, message(id: promptId)?.delivery == .sending { return .none }
        return fail(message: nil, now: now, makeId: makeId)
    }

    private mutating func applyDelta(_ delta: MessageDeltaPayload, now: Date, makeId: () -> String) -> ChatThreadChange {
        guard let chunk = delta.text else {
            // A segment boundary: later text goes into a new paragraph.
            segment = (delta.segment ?? segment) + 1
            return .none
        }
        let index = delta.segment ?? segment
        segment = index
        let done = applied[index] ?? 0
        var piece = chunk
        if let offset = delta.offset {
            let length = chunk.utf16.count
            if offset + length <= done { return .none }
            if offset < done {
                guard let tail = String(chunk.utf16.dropFirst(done - offset)) else { return .none }
                piece = tail
            }
            applied[index] = offset + length
        } else {
            applied[index] = done + chunk.utf16.count
        }
        guard !piece.isEmpty else { return .none }
        segments[index, default: ""] += piece
        let text = streamedText
        if let replyId, let row = self.index(of: replyId) {
            messages[row].text = text
            turn = .streaming
            return .text
        }
        let id = makeId()
        replyId = id
        messages.append(ChatMessage(id: id, role: .assistant, text: text, date: now, reply: .streaming,
                                    promptId: promptId))
        turn = .streaming
        return .structure
    }

    private mutating func applyComplete(_ complete: MessageCompletePayload, now: Date,
                                        makeId: () -> String) -> ChatThreadChange {
        let finalText = complete.text.flatMap { $0.isEmpty ? nil : $0 } ?? streamedText
        let reply: ChatMessage.Reply = switch complete.status {
        case .error: .failed(message: complete.error)
        case .interrupted: .interrupted
        default: complete.error != nil && finalText.isEmpty ? .failed(message: complete.error) : .complete
        }
        let id: String
        if let replyId, let row = index(of: replyId) {
            id = replyId
            messages[row].text = finalText
            messages[row].reply = reply
        } else if !finalText.isEmpty || reply != .complete {
            id = makeId()
            messages.append(ChatMessage(id: id, role: .assistant, text: finalText, date: now, reply: reply,
                                        promptId: promptId))
        } else {
            // A turn with no text, for example a muted background turn.
            endTurn()
            return .structure
        }
        endTurn()
        return .completed(id: id)
    }

    private mutating func fail(message: String?, now: Date, makeId: () -> String) -> ChatThreadChange {
        if let replyId, let row = index(of: replyId) {
            messages[row].reply = .failed(message: message)
        } else {
            messages.append(ChatMessage(id: makeId(), role: .assistant, text: streamedText, date: now,
                                        reply: .failed(message: message), promptId: promptId))
        }
        endTurn()
        return .structure
    }

    private var streamedText: String {
        segments.keys.sorted().compactMap { segments[$0] }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private mutating func resetStream() {
        segments = [:]
        applied = [:]
        segment = 0
    }

    private mutating func endTurn() {
        resetStream()
        replyId = nil
        statusLine = nil
        turn = .idle
    }

    private func index(of id: String) -> Int? {
        messages.firstIndex { $0.id == id }
    }
}
