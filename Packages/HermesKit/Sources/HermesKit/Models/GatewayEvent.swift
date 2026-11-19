import Foundation

// Typed gateway events. Shapes: `tui_gateway/contracts/events.py`. A frame is
// `{"jsonrpc":"2.0","method":"event","params":<GatewayEvent>}` (docs/hermes-protocol.md 3.1).

/// First frame of a connection (`contracts/events.py:50-64`, sent at `tui_gateway/ws.py:654-661`).
public struct GatewayReady: Decodable, Sendable, Equatable {
    public var skinName: String?
    public var changeEvents: Bool
    public var replayEpoch: String
    /// `true` when the server answers `gateway.ping`. Older servers only answer legacy `ping`.
    public var heartbeat: Bool?
    /// `true` only for a session-authority server (canonical wire, protocol 3.12).
    public var sessionAuthority: Bool?

    public init(skinName: String? = nil, changeEvents: Bool = true, replayEpoch: String,
                heartbeat: Bool? = true, sessionAuthority: Bool? = nil) {
        self.skinName = skinName
        self.changeEvents = changeEvents
        self.replayEpoch = replayEpoch
        self.heartbeat = heartbeat
        self.sessionAuthority = sessionAuthority
    }

    private enum CodingKeys: String, CodingKey {
        case skin, changeEvents = "change_events", replayEpoch = "replay_epoch", heartbeat
        case sessionAuthority = "session_authority"
    }

    private struct Skin: Decodable { var name: String? }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skinName = (try? container.decodeIfPresent(Skin.self, forKey: .skin))?.name
        changeEvents = try container.decodeIfPresent(Bool.self, forKey: .changeEvents) ?? false
        replayEpoch = try container.decodeIfPresent(String.self, forKey: .replayEpoch) ?? ""
        heartbeat = try container.decodeIfPresent(Bool.self, forKey: .heartbeat)
        sessionAuthority = try container.decodeIfPresent(Bool.self, forKey: .sessionAuthority)
    }
}

/// `message.start` (`contracts/events.py:135-151`).
public struct MessageStartPayload: Decodable, Sendable, Equatable {
    public var turnId: String?
    public var text: String?
    public var displayKind: String?
    public var displayText: String?

    private enum CodingKeys: String, CodingKey {
        case turnId = "turn_id", text, displayKind = "display_kind", displayText = "display_text"
    }
}

/// `message.delta` (`contracts/events.py:164-178`). `text == nil` is a segment boundary.
/// `offset` counts UTF-16 code units of the segment that the server sent before this chunk.
public struct MessageDeltaPayload: Decodable, Sendable, Equatable {
    public var text: String?
    public var turnId: String?
    public var segment: Int?
    public var offset: Int?
    public var rendered: String?

    private enum CodingKeys: String, CodingKey {
        case text, turnId = "turn_id", segment, offset, rendered
    }
}

/// Issue #134: `message.interim` (`contracts/events.py:185-195`). Commentary beside tool calls, sealed as its own
/// segment. With `alreadyStreamed == false`, no `message.delta` carried the text.
public struct MessageInterimPayload: Decodable, Sendable, Equatable {
    public var text: String
    public var alreadyStreamed: Bool
    public var turnId: String?
    public var segment: Int?

    public init(text: String, alreadyStreamed: Bool, turnId: String? = nil, segment: Int? = nil) {
        self.text = text
        self.alreadyStreamed = alreadyStreamed
        self.turnId = turnId
        self.segment = segment
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        alreadyStreamed = (try? container.decodeIfPresent(Bool.self, forKey: .alreadyStreamed)) ?? false
        turnId = try? container.decodeIfPresent(String.self, forKey: .turnId)
        segment = try? container.decodeIfPresent(Int.self, forKey: .segment)
    }

    private enum CodingKeys: String, CodingKey {
        case text, alreadyStreamed = "already_streamed", turnId = "turn_id", segment
    }
}

/// `reasoning.delta` (`contracts/events.py:154-162`, `:179`).
public struct ReasoningDeltaPayload: Decodable, Sendable, Equatable {
    public var text: String
}

/// `tool.start` (`contracts/events.py:400-413`).
public struct ToolStartPayload: Decodable, Sendable, Equatable {
    public var toolId: String
    public var name: String
    public var context: String?
    public var args: [String: JSONValue]?
    public var argsText: String?
    public var preview: String?

    private enum CodingKeys: String, CodingKey {
        case toolId = "tool_id", name, context, args, argsText = "args_text", preview
    }
}

/// `tool.complete` (`contracts/events.py:416-433`).
public struct ToolCompletePayload: Decodable, Sendable, Equatable {
    public var toolId: String
    public var name: String
    public var args: [String: JSONValue]?
    public var durationS: Double?
    public var result: JSONValue?
    public var summary: String?
    public var resultText: String?
    public var inlineDiff: String?
    public var imagePath: String?

    private enum CodingKeys: String, CodingKey {
        case toolId = "tool_id", name, args, durationS = "duration_s", result, summary
        case resultText = "result_text", inlineDiff = "inline_diff", imagePath = "image_path"
    }
}

/// Token counts of a turn (`contracts/common.py:28-48`). Only the fields iOS shows.
public struct TurnUsage: Decodable, Sendable, Equatable {
    public var model: String?
    public var input: Int?
    public var output: Int?
    public var reasoning: Int?
    public var total: Int?
    public var contextPercent: Int?

    private enum CodingKeys: String, CodingKey {
        case model, input, output, reasoning, total, contextPercent = "context_percent"
    }
}

/// `TurnStatus` (`contracts/events.py:197-202`). Unknown values decode as `.unknown`.
public enum TurnStatus: Sendable, Equatable, Decodable {
    case complete, error, interrupted
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "complete": self = .complete
        case "error": self = .error
        case "interrupted": self = .interrupted
        default: self = .unknown(raw)
        }
    }
}

/// `message.complete` (`contracts/events.py:283-305`).
public struct MessageCompletePayload: Decodable, Sendable, Equatable {
    /// The final text. `nil` when the server sent a structured (non-string) value.
    public var text: String?
    public var status: TurnStatus?
    public var usage: TurnUsage?
    public var reasoning: String?
    public var warning: String?
    public var error: String?
    public var failureReason: String?
    public var recoverable: Bool?
    public var partial: Bool?

    private enum CodingKeys: String, CodingKey {
        case text, status, usage, reasoning, warning, error, failureReason = "failure_reason", recoverable, partial
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `text: str | JsonValue = ""` (`events.py:290`).
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? (container.contains(.text) ? nil : "")
        status = try? container.decodeIfPresent(TurnStatus.self, forKey: .status)
        usage = try? container.decodeIfPresent(TurnUsage.self, forKey: .usage)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        warning = try container.decodeIfPresent(String.self, forKey: .warning)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        recoverable = try container.decodeIfPresent(Bool.self, forKey: .recoverable)
        partial = try container.decodeIfPresent(Bool.self, forKey: .partial)
    }
}

/// `error` (`contracts/events.py:113-120`): a session error outside a turn.
public struct GatewayErrorPayload: Decodable, Sendable, Equatable {
    public var message: String
}

/// `status.update` (`contracts/events.py:308-315`).
public struct StatusUpdatePayload: Decodable, Sendable, Equatable {
    public var kind: String
    public var text: String
}

/// `session.title` (`contracts/events.py:355-364`). `sessionId` is the stored id.
public struct SessionTitlePayload: Decodable, Sendable, Equatable {
    public var sessionId: String
    public var title: String

    private enum CodingKeys: String, CodingKey { case sessionId = "session_id", title }
}

/// `request.cancel` (`contracts/server_requests.py:373-388`): the server withdrew a request.
public struct RequestCancelPayload: Decodable, Sendable, Equatable {
    public var id: String
    public var method: String
    public var reason: String
}

/// Issue #104: `approval.cancelled` (`contracts/events.py:560-576`). The server dropped pending approvals
/// (interrupt, reap, teardown) and resolved them as deny. `requestIds` are approval queue ids.
public struct ApprovalCancelledPayload: Decodable, Sendable, Equatable {
    public var reason: String?
    public var requestIds: [String]

    public init(reason: String? = nil, requestIds: [String] = []) {
        self.reason = reason
        self.requestIds = requestIds
    }

    private enum CodingKeys: String, CodingKey { case reason, requestIds = "request_ids" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = try? container.decodeIfPresent(String.self, forKey: .reason)
        requestIds = (try? container.decodeIfPresent([String].self, forKey: .requestIds)) ?? []
    }
}

/// One `params` object of an event frame (`apps/shared/src/gateway-events.ts:57-83`).
public struct GatewayEvent: Decodable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case gatewayReady(GatewayReady)
        case messageStart(MessageStartPayload)
        case messageDelta(MessageDeltaPayload)
        case messageInterim(MessageInterimPayload)
        case reasoningDelta(ReasoningDeltaPayload)
        case toolStart(ToolStartPayload)
        case toolComplete(ToolCompletePayload)
        case messageComplete(MessageCompletePayload)
        case error(GatewayErrorPayload)
        case statusUpdate(StatusUpdatePayload)
        case sessionTitle(SessionTitlePayload)
        case requestCancel(RequestCancelPayload)
        case approvalCancelled(ApprovalCancelledPayload)
        case sessionsChanged
        case cronChanged
        /// Any other type, or a known type with a payload that did not decode.
        case other(JSONValue?)
    }

    public var type: String
    /// The live session id. `nil` for session-less events such as `sessions.changed`.
    public var sessionId: String?
    /// Per-session counter for replay (`tui_gateway/event_replay.py:72-96`).
    public var seq: Int?
    public var kind: Kind

    public init(type: String, sessionId: String? = nil, seq: Int? = nil, kind: Kind) {
        self.type = type
        self.sessionId = sessionId
        self.seq = seq
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case type, sessionId = "session_id", seq, payload }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        sessionId = try? container.decodeIfPresent(String.self, forKey: .sessionId)
        seq = try? container.decodeIfPresent(Int.self, forKey: .seq)
        kind = Self.decodeKind(type: type, container: container)
    }

    private static func decodeKind(type: String, container: KeyedDecodingContainer<CodingKeys>) -> Kind {
        func payload<T: Decodable>(_: T.Type) -> T? { try? container.decode(T.self, forKey: .payload) }
        let kind: Kind? = switch type {
        case "gateway.ready": payload(GatewayReady.self).map(Kind.gatewayReady)
        case "message.start": payload(MessageStartPayload.self).map(Kind.messageStart)
            ?? .messageStart(MessageStartPayload())
        case "message.delta": payload(MessageDeltaPayload.self).map(Kind.messageDelta)
        case "message.interim": payload(MessageInterimPayload.self).map(Kind.messageInterim)
        case "reasoning.delta": payload(ReasoningDeltaPayload.self).map(Kind.reasoningDelta)
        case "tool.start": payload(ToolStartPayload.self).map(Kind.toolStart)
        case "tool.complete": payload(ToolCompletePayload.self).map(Kind.toolComplete)
        case "message.complete": payload(MessageCompletePayload.self).map(Kind.messageComplete)
        case "error": payload(GatewayErrorPayload.self).map(Kind.error)
        case "status.update": payload(StatusUpdatePayload.self).map(Kind.statusUpdate)
        case "session.title": payload(SessionTitlePayload.self).map(Kind.sessionTitle)
        case "request.cancel": payload(RequestCancelPayload.self).map(Kind.requestCancel)
        case "approval.cancelled": payload(ApprovalCancelledPayload.self).map(Kind.approvalCancelled)
        case "sessions.changed": .sessionsChanged
        case "cron.changed": .cronChanged
        default: nil
        }
        return kind ?? .other(try? container.decodeIfPresent(JSONValue.self, forKey: .payload))
    }
}
