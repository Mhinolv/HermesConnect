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
    /// Issue #120: the name of the tool that runs now, for the Voice tab. `nil` between tools.
    public private(set) var runningTool: String?
    /// Issue #129: the last tool of the turn. It stays after `tool.complete` ("Used web_search") until the turn ends.
    public private(set) var toolActivity: ChatToolActivity?

    /// The incoming bubble of the current turn.
    private var replyId: String?
    /// The prompt of the current turn, for a reply retry.
    private var promptId: String?
    /// Issue #11: the prompts from the phone whose turn did not end, oldest first. The first one gets the
    /// ack of the running turn. Hermes queues a prompt sent during a turn, so each prompt keeps its own ack
    /// (QA #40 defect 1). A turn that the phone did not start (cron, background) finds none.
    private var ackPromptIds: [String] = []
    /// Text per `message.delta` segment.
    private var segments: [Int: String] = [:]
    /// UTF-16 units applied per segment, to drop chunks that come twice (`offset`).
    private var applied: [Int: Int] = [:]
    private var segment = 0
    /// Issue #134: the spoken text of a reply when it differs from the bubble text. `message.complete` carries only
    /// the final message, so the interim messages of the turn stay here for voice mode and Live mode.
    private var voiceTexts: [String: String] = [:]
    /// Issue #120: the tool calls of the current turn, in call order. They go on the reply at `message.complete`.
    private var turnTools: [ChatToolCall] = []
    /// Issue #120: the `tool_id`s that started and did not complete, oldest first.
    private var openToolIds: [String] = []

    public init(messages: [ChatMessage] = []) {
        self.messages = messages
    }

    public func message(id: String) -> ChatMessage? {
        messages.first { $0.id == id }
    }

    /// Issue #134: the text that voice mode speaks for reply `id`: every message of the turn in order (interim
    /// messages, then the final message). It only grows while the turn streams. Empty for an unknown id.
    public func voiceText(id: String) -> String {
        voiceTexts[id] ?? message(id: id)?.text ?? ""
    }

    // MARK: Outgoing

    public mutating func addOutgoing(id: String, text: String, date: Date, attachments: [ChatAttachment] = [],
                                     quote: ChatQuote? = nil) {
        messages.append(ChatMessage(id: id, role: .user, text: text, date: date, delivery: .sending,
                                    attachments: attachments, quote: quote))
    }

    /// Issue #8: the attach state of one attachment of an outgoing message.
    /// Issue #67: the local card of a command, at the end of the thread.
    public mutating func addCommandCard(id: String, card: ChatCommandCard, date: Date) {
        messages.append(ChatMessage(id: id, role: .assistant, text: card.output, date: date, command: card))
    }

    // MARK: Approvals (issue #104)

    /// The id of the card for this approval: the same queue id, or the same server request id.
    public func approvalCardId(requestId: String, serverRequestId: JSONRPCID?) -> String? {
        messages.first { message in
            guard let card = message.approval else { return false }
            if !requestId.isEmpty, card.requestId == requestId { return true }
            if let serverRequestId, card.serverRequestId == serverRequestId { return true }
            return false
        }?.id
    }

    /// Shows the card of one approval at the end of the thread. A request that a card shows already (a replay
    /// after a reconnect) updates that card: a waiting card takes the new server request id.
    /// Returns `true` when a new card shows.
    @discardableResult
    public mutating func addApproval(id: String, card: ChatApprovalCard, date: Date) -> Bool {
        if let existing = approvalCardId(requestId: card.requestId, serverRequestId: card.serverRequestId),
           let index = index(of: existing) {
            guard messages[index].approval?.isWaiting == true else { return false }
            if let serverRequestId = card.serverRequestId { messages[index].approval?.serverRequestId = serverRequestId }
            messages[index].approval?.sessionId = card.sessionId
            if messages[index].approval?.requestId.isEmpty == true {
                messages[index].approval?.requestId = card.requestId
            }
            return false
        }
        messages.append(ChatMessage(id: id, role: .assistant, text: "", date: date, approval: card))
        return true
    }

    public mutating func setApprovalState(_ state: ChatApprovalCard.State, id: String) {
        guard let index = index(of: id), messages[index].approval != nil else { return }
        messages[index].approval?.state = state
    }

    /// `true` while a card waits for the owner. The chats list shows "Approval needed".
    public var hasWaitingApproval: Bool {
        messages.contains { $0.approval?.isWaiting == true }
    }

    /// `request.cancel {id, method, reason}`: the server withdrew the request. A card that the owner answered keeps
    /// its result. A timeout marks a waiting card "This request expired". Other reasons remove it.
    @discardableResult
    public mutating func withdrawApproval(serverRequestId: String, reason: String) -> Bool {
        guard let index = messages.firstIndex(where: {
            $0.approval?.serverRequestId == .string(serverRequestId)
        }), let card = messages[index].approval else { return false }
        switch card.state {
        case .waiting:
            if reason == "timeout" {
                messages[index].approval?.state = .expired
            } else {
                messages.remove(at: index)
            }
            return true
        case .sending, .answered, .expired, .cancelled:
            return false
        }
    }

    /// `approval.cancelled`: the server dropped these approvals and resolved them as deny. No ids means all.
    @discardableResult
    public mutating func cancelApprovals(requestIds: [String]) -> Bool {
        let ids = Set(requestIds)
        var changed = false
        for index in messages.indices {
            guard let card = messages[index].approval, card.isWaiting || isSending(card) else { continue }
            guard ids.isEmpty || ids.contains(card.requestId) else { continue }
            messages[index].approval?.state = .cancelled
            changed = true
        }
        return changed
    }

    /// After a resume: a waiting card that the server does not list any more ended while the socket was closed.
    @discardableResult
    public mutating func expireApprovals(notIn open: Set<String>) -> Bool {
        var changed = false
        for index in messages.indices {
            guard let card = messages[index].approval, card.isWaiting, !card.requestId.isEmpty,
                  !open.contains(card.requestId) else { continue }
            messages[index].approval?.state = .expired
            changed = true
        }
        return changed
    }

    private func isSending(_ card: ChatApprovalCard) -> Bool {
        if case .sending = card.state { return true }
        return false
    }

    // MARK: Prompts (issue #117)

    /// Shows the card of one prompt at the end of the thread. A request that a card shows already (a replay after
    /// a reconnect) changes nothing. Returns `true` when a new card shows.
    @discardableResult
    public mutating func addPrompt(id: String, card: ChatPromptCard, date: Date) -> Bool {
        if let index = messages.firstIndex(where: { $0.prompt?.serverRequestId == card.serverRequestId }) {
            messages[index].prompt?.sessionId = card.sessionId
            return false
        }
        messages.append(ChatMessage(id: id, role: .assistant, text: "", date: date, prompt: card))
        return true
    }

    public mutating func setPromptState(_ state: ChatPromptCard.State, sendFailed: Bool = false, id: String) {
        guard let index = index(of: id), messages[index].prompt != nil else { return }
        messages[index].prompt?.state = state
        messages[index].prompt?.sendFailed = sendFailed
    }

    /// `request.cancel {id, method, reason}` for a prompt. A timeout marks a waiting card "This request expired".
    /// Other reasons remove it. A card that the owner answered keeps its result.
    @discardableResult
    public mutating func withdrawPrompt(serverRequestId: String, reason: String) -> Bool {
        guard let index = messages.firstIndex(where: { $0.prompt?.serverRequestId == .string(serverRequestId) }),
              messages[index].prompt?.isWaiting == true else { return false }
        if reason == "timeout" {
            messages[index].prompt?.state = .expired
        } else {
            messages.remove(at: index)
        }
        return true
    }

    /// After a resume: a waiting card that `open_requests` does not list any more ended while the socket was
    /// closed.
    @discardableResult
    public mutating func expirePrompts(notIn open: Set<JSONRPCID>) -> Bool {
        var changed = false
        for index in messages.indices {
            guard let card = messages[index].prompt, card.isWaiting, !open.contains(card.serverRequestId) else { continue }
            messages[index].prompt?.state = .expired
            changed = true
        }
        return changed
    }

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
        // Issue #11: Hermes took the prompt of the running turn. A send again or a failed send has no ack.
        switch delivery {
        case .delivered: if ackPromptIds.contains(id) { setAck(.seen, on: id) }
        case .sending: messages[index].agentAck = nil
        case .failed, .queued:
            messages[index].agentAck = nil
            ackPromptIds.removeAll { $0 == id }
        }
    }

    // MARK: Tapbacks (issue #11)

    /// Sets the owner's tapback. The same tapback again removes it. A bubble that still sends or streams
    /// takes none. Returns `false` when nothing changed.
    @discardableResult
    public mutating func react(_ tapback: Tapback, id: String) -> Bool {
        guard let index = index(of: id) else { return false }
        let message = messages[index]
        guard message.delivery != .sending, message.reply != .streaming, !message.isLocalCard else { return false }
        messages[index].tapback = message.tapback == tapback ? nil : tapback
        return true
    }

    /// "Remove Reaction". Returns `false` when the bubble has no tapback.
    @discardableResult
    public mutating func removeTapback(id: String) -> Bool {
        guard let index = index(of: id), messages[index].tapback != nil else { return false }
        messages[index].tapback = nil
        return true
    }

    /// The ack goes on a prompt from the phone. A slash command never gets one (D3).
    private mutating func setAck(_ ack: AgentAck?, on id: String?) {
        guard let id, let index = index(of: id), messages[index].role == .user else { return }
        messages[index].agentAck = AgentAckRules.isSlashCommand(messages[index].text) ? nil : ack
    }

    public mutating func remove(id: String) {
        messages.removeAll { $0.id == id }
        voiceTexts[id] = nil
        if replyId == id { replyId = nil }
    }

    /// A prompt went out. The Stop button shows until the turn ends.
    public mutating func beginTurn(promptId: String) {
        self.promptId = promptId
        if !ackPromptIds.contains(promptId) { ackPromptIds.append(promptId) }
        if turn == .idle { turn = .waiting }
    }

    /// `prompt.submit` failed before the turn started.
    public mutating func cancelWaiting() {
        guard turn == .waiting else { return }
        endTurn()
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
        // Issue #67: a command card is local. It keeps its place by date between the history rows.
        // Issue #104: an approval card is local too.
        var merged = history + kept.filter { !$0.isLocalCard }
        for card in kept where card.isLocalCard {
            let index = merged.firstIndex { !$0.isLocalCard && $0.date > card.date } ?? merged.endIndex
            merged.insert(card, at: index)
        }
        // Issue #11: a prompt that the history answers has ended. A later turn must not ack it.
        ackPromptIds.removeAll { answered.contains($0) }
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
            setAck(.seen, on: ackPromptIds.first)
            return .structure
        case .messageDelta(let delta):
            return applyDelta(delta, now: now, makeId: makeId)
        case .messageInterim(let interim):
            return applyInterim(interim, now: now, makeId: makeId)
        case .toolStart(let tool):
            guard turn != .idle else { return .none }
            statusLine = ChatToolText.runningLine(tool.name)
            startTool(tool)
            return .structure
        case .toolComplete(let tool):
            guard turn != .idle else { return .none }
            completeTool(tool)
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

    /// Issue #120: a `tool.start` that comes twice (a replay) keeps the first entry.
    private mutating func startTool(_ tool: ToolStartPayload) {
        if !turnTools.contains(where: { $0.id == tool.toolId }) {
            turnTools.append(ChatToolCall(id: tool.toolId, name: tool.name, summary: tool.preview))
        }
        openToolIds.removeAll { $0 == tool.toolId }
        openToolIds.append(tool.toolId)
        runningTool = turnTools.first { $0.id == tool.toolId }?.name
        toolActivity = runningTool.map { ChatToolActivity(name: $0, isRunning: true) }
    }

    /// Issue #120: the summary and the duration. A `tool.complete` with no `tool.start` still adds the tool.
    private mutating func completeTool(_ tool: ToolCompletePayload) {
        if let index = turnTools.firstIndex(where: { $0.id == tool.toolId }) {
            let summary = tool.summary.flatMap { ChatToolText.clean($0, limit: ChatToolText.summaryLimit) }
            if let summary { turnTools[index].summary = summary }
            turnTools[index].duration = ChatToolCall.validDuration(tool.durationS)
        } else {
            turnTools.append(ChatToolCall(id: tool.toolId, name: tool.name, summary: tool.summary,
                                          duration: tool.durationS))
        }
        openToolIds.removeAll { $0 == tool.toolId }
        let open = openToolIds.last
        runningTool = open.flatMap { id in turnTools.first { $0.id == id }?.name }
        // Issue #129: a tool that still runs wins. Else the tool that ended now stays as "Used <tool>".
        let ended = turnTools.first { $0.id == tool.toolId }?.name
        toolActivity = runningTool.map { ChatToolActivity(name: $0, isRunning: true) }
            ?? ended.map { ChatToolActivity(name: $0, isRunning: false) }
    }

    /// Issue #120: the tools of the turn go on its reply.
    private mutating func attachTools(to row: Int) {
        guard !turnTools.isEmpty else { return }
        messages[row].tools = turnTools
    }

    /// The socket dropped during a turn. The reply fails, so the owner can retry.
    /// A prompt that is still sending gets only "Not Delivered" from its send, not a failed reply too.
    @discardableResult
    public mutating func connectionLost(now: Date, makeId: () -> String) -> ChatThreadChange {
        guard turn != .idle else { return .none }
        if turn == .waiting, let promptId, message(id: promptId)?.delivery == .sending { return .none }
        let change = fail(message: nil, now: now, makeId: makeId)
        // Issue #11: the queued prompts get no events on this socket. Catch-up sets their final ack.
        for id in ackPromptIds { setAck(.failed, on: id) }
        ackPromptIds = []
        return change
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
        return showStreamed(now: now, makeId: makeId)
    }

    /// Issue #134: `message.interim` seals the segment, so later text starts a new paragraph (and a new segment for
    /// a server that sends no `segment`). A seal of text that no delta carried adds that text.
    private mutating func applyInterim(_ interim: MessageInterimPayload, now: Date,
                                       makeId: () -> String) -> ChatThreadChange {
        guard turn != .idle else { return .none }
        let index = interim.segment ?? segment
        segment = max(segment, index + 1)
        guard !interim.alreadyStreamed, !interim.text.isEmpty, segments[index, default: ""].isEmpty else { return .none }
        segments[index] = interim.text
        applied[index] = interim.text.utf16.count
        return showStreamed(now: now, makeId: makeId)
    }

    /// The streamed text goes into the reply bubble. The first text adds the bubble.
    private mutating func showStreamed(now: Date, makeId: () -> String) -> ChatThreadChange {
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
        // Issue #134: the sealed segments come before the final text, unless the final text has them already.
        let sealed = segments.keys.sorted().filter { $0 < segment }.compactMap { segments[$0] }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        let voiceText = sealed.isEmpty || finalText.hasPrefix(sealed) ? finalText : sealed + "\n\n" + finalText
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
            attachTools(to: row)
        } else if !finalText.isEmpty || reply != .complete {
            id = makeId()
            messages.append(ChatMessage(id: id, role: .assistant, text: finalText, date: now, reply: reply,
                                        promptId: promptId))
            attachTools(to: messages.count - 1)
        } else {
            // A turn with no text, for example a muted background turn.
            ackTurnEnd(nil)
            endTurn()
            return .structure
        }
        if voiceText != finalText { voiceTexts[id] = voiceText }
        ackTurnEnd(reply)
        endTurn()
        return .completed(id: id)
    }

    private mutating func fail(message: String?, now: Date, makeId: () -> String) -> ChatThreadChange {
        if let replyId, let row = index(of: replyId) {
            messages[row].reply = .failed(message: message)
            attachTools(to: row)
        } else {
            messages.append(ChatMessage(id: makeId(), role: .assistant, text: streamedText, date: now,
                                        reply: .failed(message: message), promptId: promptId))
            attachTools(to: messages.count - 1)
        }
        ackTurnEnd(.failed(message: nil))
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

    /// Issue #11: the final ack of the turn. `reply` is the state of the reply, `nil` for a turn with no text.
    private mutating func ackTurnEnd(_ reply: ChatMessage.Reply?) {
        guard !ackPromptIds.isEmpty else { return }
        let id = ackPromptIds.removeFirst()
        guard let prompt = message(id: id) else { return }
        setAck(AgentAckRules.ack(endingWith: reply, prompt: prompt.text), on: id)
    }

    private mutating func endTurn() {
        resetStream()
        replyId = nil
        statusLine = nil
        runningTool = nil
        toolActivity = nil
        turnTools = []
        openToolIds = []
        turn = .idle
    }

    private func index(of id: String) -> Int? {
        messages.firstIndex { $0.id == id }
    }
}
