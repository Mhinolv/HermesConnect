import Foundation

/// One bubble of the chat thread (issue #6).
public struct ChatMessage: Identifiable, Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        /// The owner. Outgoing bubble.
        case user
        /// The agent. Incoming bubble.
        case assistant
    }

    /// The send state of an outgoing message.
    public enum Delivery: Sendable, Equatable {
        case sending
        case delivered
        /// `prompt.submit` failed. The bubble shows "Not Delivered".
        case failed
        /// Issue #39: the app was offline. The message waits in the outbox: "Will send when connected".
        case queued
    }

    /// The state of an incoming reply.
    public enum Reply: Sendable, Equatable {
        case streaming
        case complete
        /// The owner stopped the reply (`session.interrupt`).
        case interrupted
        /// The turn ended with an error. `message` is server text for the screen, never for logs.
        case failed(message: String?)
    }

    public let id: String
    public let role: Role
    public var text: String
    public var date: Date
    /// Set for `.user` messages only.
    public var delivery: Delivery?
    /// Set for `.assistant` messages only.
    public var reply: Reply?
    /// The transcript row of a delivered prompt. A reply retry cuts the transcript before it.
    public var userRowId: Int?
    /// For a reply: the id of the prompt that started the turn.
    public var promptId: String?
    /// Set for a voice memo (issue #9). `text` is empty until the transcript comes, then it is the transcript.
    public var voice: VoiceMemo?
    /// Issue #8: photos, files and the location card of an outgoing message, in pick order.
    public var attachments: [ChatAttachment]
    /// Issue #10: the spoken audio of a reply to a voice memo. `nil` for a text turn.
    public var spokenReply: SpokenReply?
    /// Issue #11: the agent ack on an owner prompt, from the turn state (D3). `nil` on replies.
    public var agentAck: AgentAck?
    /// Issue #11: the owner's tapback. It stays on the phone.
    public var tapback: Tapback?
    /// Issue #67: a local command card (`.assistant`, no `reply`). It never goes to Hermes or to the cache.
    public var command: ChatCommandCard?
    /// Issue #17: the message that this owner prompt replies to. `text` is the reply only.
    public var quote: ChatQuote?
    /// Issue #104: a local approval card (`.assistant`, no `reply`). It never goes to the cache.
    public var approval: ChatApprovalCard?
    /// Issue #117: a local secret, password or question card (`.assistant`, no `reply`). It never goes to the
    /// cache and never holds the answer.
    public var prompt: ChatPromptCard?
    /// Issue #120: the tool calls of a reply, in call order. Set on `message.complete`. Empty for other messages.
    public var tools: [ChatToolCall]

    public init(id: String, role: Role, text: String, date: Date, delivery: Delivery? = nil,
                reply: Reply? = nil, userRowId: Int? = nil, promptId: String? = nil, voice: VoiceMemo? = nil,
                attachments: [ChatAttachment] = [], spokenReply: SpokenReply? = nil,
                agentAck: AgentAck? = nil, tapback: Tapback? = nil, command: ChatCommandCard? = nil,
                quote: ChatQuote? = nil, approval: ChatApprovalCard? = nil,
                prompt: ChatPromptCard? = nil, tools: [ChatToolCall] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.delivery = delivery
        self.reply = reply
        self.userRowId = userRowId
        self.promptId = promptId
        self.voice = voice
        self.attachments = attachments
        self.spokenReply = spokenReply
        self.agentAck = agentAck
        self.tapback = tapback
        self.command = command
        self.quote = quote
        self.approval = approval
        self.prompt = prompt
        self.tools = tools
    }

    /// Issue #67, #104, #117: a command card, an approval card or a prompt card. Local cards keep their place by
    /// date in a history merge and take no tapback or quote.
    public var isLocalCard: Bool { command != nil || approval != nil || prompt != nil }

    public var isFailed: Bool {
        if delivery == .failed { return true }
        if case .failed = reply { return true }
        return false
    }
}
