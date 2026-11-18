import Foundation

// Params and results of the core session and prompt methods.
// Shapes: `tui_gateway/contracts/sessions.py`, `contracts/prompt_voice.py`, `contracts/common.py`.
// Params models on the server are `extra="forbid"` (`contracts/base.py:37`): send only known keys.
// Synthesized `Encodable` omits `nil` optionals.

/// One transcript row (`contracts/common.py:168-186`).
public struct TranscriptMessage: Decodable, Sendable, Equatable {
    public var role: String
    public var text: String?
    public var content: JSONValue?
    public var toolCallId: String?
    public var timestamp: Double?
    public var rowId: Int?
    public var displayKind: String?
    public var name: String?
    public var reasoning: String?

    public init(role: String, text: String? = nil, rowId: Int? = nil) {
        self.role = role
        self.text = text
        self.rowId = rowId
    }

    private enum CodingKeys: String, CodingKey {
        case role, text, content, toolCallId = "tool_call_id", timestamp, rowId = "row_id"
        case displayKind = "display_kind", name, reasoning
    }
}

// MARK: session.create

/// `session.create` params (`contracts/sessions.py:118-139`). The client never sends
/// `close_on_disconnect: true`, because the server closes such a session when the socket drops.
public struct SessionCreateParams: Encodable, Sendable, Equatable {
    public var source: String?
    public var cwd: String?
    public var title: String?
    public var model: String?
    public var provider: String?
    public var parentSessionId: String?
    /// A stable key, so a retried create returns the same session (`contracts/sessions.py:136-138`).
    public var idempotencyKey: String?

    public init(source: String? = nil, cwd: String? = nil, title: String? = nil, model: String? = nil,
                provider: String? = nil, parentSessionId: String? = nil, idempotencyKey: String? = nil) {
        self.source = source
        self.cwd = cwd
        self.title = title
        self.model = model
        self.provider = provider
        self.parentSessionId = parentSessionId
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case source, cwd, title, model, provider, parentSessionId = "parent_session_id"
        case idempotencyKey = "idempotency_key"
    }
}

/// `session.create` result (`contracts/sessions.py:142-147`).
public struct SessionCreateResult: Decodable, Sendable, Equatable {
    /// The live id. Prompt, interrupt and history calls use it.
    public var sessionId: String
    /// The stored id. Lists and `session.resume` use it.
    public var storedSessionId: String
    public var messageCount: Int
    public var messages: [TranscriptMessage]
    public var info: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", storedSessionId = "stored_session_id", messageCount = "message_count"
        case messages, info
    }
}

// MARK: session.resume / session.activate

/// `session.resume` params (`contracts/sessions.py:182-196`). `sessionId` is the STORED id.
public struct SessionResumeParams: Encodable, Sendable, Equatable {
    public var sessionId: String
    public var source: String?
    public var lazy: Bool?
    public var omitMessages: Bool?
    /// `false` renders image parts as `[image]`, so the reply stays small on mobile.
    public var inlineImages: Bool

    public init(storedSessionId: String, source: String? = nil, lazy: Bool? = nil,
                omitMessages: Bool? = nil, inlineImages: Bool = false) {
        self.sessionId = storedSessionId
        self.source = source
        self.lazy = lazy
        self.omitMessages = omitMessages
        self.inlineImages = inlineImages
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", source, lazy, omitMessages = "omit_messages", inlineImages = "inline_images"
    }
}

/// `session.activate` params (`contracts/sessions.py:204-206`). `sessionId` is the LIVE id.
public struct SessionActivateParams: Encodable, Sendable, Equatable {
    public var sessionId: String
    public var omitMessages: Bool

    public init(sessionId: String, omitMessages: Bool = true) {
        self.sessionId = sessionId
        self.omitMessages = omitMessages
    }

    private enum CodingKeys: String, CodingKey { case sessionId = "session_id", omitMessages = "omit_messages" }
}

/// A turn that still runs when the client attaches (`contracts/sessions.py:29-43`).
public struct InflightTurn: Decodable, Sendable, Equatable {
    public var assistant: String?
    public var streaming: Bool?
    public var user: String?
    public var error: String?
    public var status: String?
}

/// An unanswered server-to-client request, sent again after a reconnect (`contracts/sessions.py:20-26`).
public struct OpenRequestEntry: Decodable, Sendable, Equatable {
    public var id: String
    public var method: String
    public var params: [String: JSONValue]
}

/// The snapshot that `session.resume` and `session.activate` return (`contracts/sessions.py:73-102`).
public struct LiveSessionSnapshot: Decodable, Sendable, Equatable {
    public var sessionId: String
    public var storedSessionId: String?
    public var messageCount: Int
    public var messages: [TranscriptMessage]
    public var info: JSONValue?
    public var messagesOmitted: Bool?
    public var running: Bool?
    public var status: String?
    public var inflight: InflightTurn?
    public var openRequests: [OpenRequestEntry]?
    /// Issue #104: the oldest unresolved approval (`contracts/common.py:208-221`). It has no JSON-RPC id.
    public var pendingApproval: [String: JSONValue]?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", storedSessionId = "stored_session_id", messageCount = "message_count"
        case messages, info, messagesOmitted = "messages_omitted", running, status, inflight
        case openRequests = "open_requests", pendingApproval = "pending_approval"
    }
}

// MARK: session.list / session.history

/// `session.list` params (`contracts/sessions.py:221-224`).
public struct SessionListParams: Encodable, Sendable, Equatable {
    public var limit: Int?
    public var includeHidden: Bool?
    public var title: String?

    public init(limit: Int? = nil, includeHidden: Bool? = nil, title: String? = nil) {
        self.limit = limit
        self.includeHidden = includeHidden
        self.title = title
    }

    private enum CodingKeys: String, CodingKey { case limit, includeHidden = "include_hidden", title }
}

/// One `session.list` row (`contracts/sessions.py:227-241`).
public struct SessionListRow: Decodable, Sendable, Equatable {
    public var id: String
    public var resolvedId: String?
    public var title: String?
    public var preview: String?
    public var startedAt: Double?
    public var messageCount: Int?
    public var source: String?
    public var lineageRootId: String?

    private enum CodingKeys: String, CodingKey {
        case id, resolvedId = "resolved_id", title, preview, startedAt = "started_at"
        case messageCount = "message_count", source, lineageRootId = "_lineage_root_id"
    }
}

public struct SessionListResult: Decodable, Sendable, Equatable {
    public var sessions: [SessionListRow]
}

/// `session.most_recent` result (`methods_session.py:563-578`). `sessionId` is the STORED id, or `nil`
/// when the server has no session yet.
public struct SessionMostRecentResult: Decodable, Sendable, Equatable {
    public var sessionId: String?
    public var title: String?
    public var startedAt: Double?
    public var source: String?

    private enum CodingKeys: String, CodingKey { case sessionId = "session_id", title, startedAt = "started_at", source }
}

/// `session.history` result (`contracts/sessions.py:496-498`).
public struct SessionHistoryResult: Decodable, Sendable, Equatable {
    public var count: Int
    public var messages: [TranscriptMessage]
}

// MARK: prompt.submit

/// `prompt.submit` params (`contracts/prompt_voice.py:26-48`).
public struct PromptSubmitParams: Encodable, Sendable, Equatable {
    public var sessionId: String
    public var text: String
    public var voiceTurn: Bool?
    public var queued: Bool?
    public var displayKind: String?
    /// Edit or regenerate: cut the transcript before this row. Needs `confirmTruncate: true`.
    public var truncateBeforeRowId: Int?
    public var confirmTruncate: Bool?
    /// Issue #98: `voice-live` for a GPT-Live delegation (`ClientSurface`).
    public var surface: String?
    /// Issue #98: the recent spoken exchange. The server gives it to the model only (with `surface: "voice-live"`).
    public var voiceContext: String?

    public init(sessionId: String, text: String, voiceTurn: Bool? = nil, queued: Bool? = nil,
                displayKind: String? = nil, truncateBeforeRowId: Int? = nil, confirmTruncate: Bool? = nil) {
        self.sessionId = sessionId
        self.text = text
        self.voiceTurn = voiceTurn
        self.queued = queued
        self.displayKind = displayKind
        self.truncateBeforeRowId = truncateBeforeRowId
        self.confirmTruncate = confirmTruncate
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", text, voiceTurn = "voice_turn", queued, displayKind = "display_kind"
        case truncateBeforeRowId = "truncate_before_row_id", confirmTruncate = "confirm_truncate"
        case surface, voiceContext = "voice_context"
    }
}

/// `PromptSubmitStatus` (`contracts/prompt_voice.py:51-55`). Unknown values decode as `.unknown`.
public enum PromptSubmitStatus: Sendable, Equatable, Decodable {
    case streaming, queued, steered, redirected
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "streaming": self = .streaming
        case "queued": self = .queued
        case "steered": self = .steered
        case "redirected": self = .redirected
        default: self = .unknown(raw)
        }
    }
}

/// `prompt.submit` result (`contracts/prompt_voice.py:58-80`).
public struct PromptSubmitResult: Decodable, Sendable, Equatable {
    public var status: PromptSubmitStatus?
    public var userRowId: Int?
    public var admissionId: String?

    private enum CodingKeys: String, CodingKey { case status, userRowId = "user_row_id", admissionId = "admission_id" }
}

// MARK: session.interrupt

/// `session.interrupt` result (`contracts/sessions.py:611-619`).
public struct SessionInterruptResult: Decodable, Sendable, Equatable {
    /// `"interrupted"` or `"not_interrupted"`.
    public var status: String
    public var interrupted: Bool?
}

// MARK: session.events.since

/// `session.events.since` result (`contracts/sessions.py:734-740`).
public struct SessionEventsSinceResult: Decodable, Sendable, Equatable {
    public var events: [GatewayEvent]
    public var latestSeq: Int
    public var truncated: Bool
    public var count: Int
    public var epoch: String
    public var openRequests: [OpenRequestEntry]

    private enum CodingKeys: String, CodingKey {
        case events, latestSeq = "latest_seq", truncated, count, epoch, openRequests = "open_requests"
    }
}

/// Params with only the live `session_id` (`contracts/common.py` `SessionParams`).
struct SessionIdParams: Encodable, Sendable {
    var sessionId: String
    private enum CodingKeys: String, CodingKey { case sessionId = "session_id" }
}

struct SessionEventsSinceParams: Encodable, Sendable {
    var sessionId: String
    var lastSeen: Int
    private enum CodingKeys: String, CodingKey { case sessionId = "session_id", lastSeen = "last_seen" }
}
