import Foundation

/// The live and stored ids of the chat session (docs/hermes-protocol.md 3.3).
public struct ChatSessionRef: Sendable, Equatable {
    public var liveId: String
    public var storedId: String?
    /// Issue #104: the server requests that still wait (`open_requests` of the snapshot, protocol 4.2).
    /// `nil` when the server did not send the key (an older server).
    public var openRequests: [GatewayServerRequest]?
    /// Issue #104: the snapshot `pending_approval`. It has no JSON-RPC id: answer it with `approval.respond`.
    public var pendingApproval: ApprovalRequest?

    public init(liveId: String, storedId: String? = nil, openRequests: [GatewayServerRequest]? = nil,
                pendingApproval: ApprovalRequest? = nil) {
        self.liveId = liveId
        self.storedId = storedId
        self.openRequests = openRequests
        self.pendingApproval = pendingApproval
    }

    /// Issue #104: the open requests and the pending approval of a `session.resume` snapshot.
    public init(snapshot: LiveSessionSnapshot, storedId: String?) {
        let open = snapshot.openRequests.map { $0.compactMap(GatewayServerRequest.init(open:)) }
        self.init(liveId: snapshot.sessionId, storedId: snapshot.storedSessionId ?? storedId, openRequests: open,
                  pendingApproval: snapshot.pendingApproval.flatMap {
                      ApprovalRequest(pending: .object($0), sessionId: snapshot.sessionId)
                  })
    }
}

/// Issue #104: the calls of an approval card and of the requests that the app cannot show
/// (docs/hermes-protocol.md 3.11). `GatewayClient` and `LiveChatTransport` conform. Tests use a fake.
public protocol ServerRequestTransport: Sendable {
    /// Answers an `approval` server request on its JSON-RPC id with `{choice}`.
    func answerApproval(requestId: JSONRPCID, choice: ApprovalChoice) async throws
    /// Answers a server request with an error. For `approval` that is a withdrawal, not a deny.
    func rejectServerRequest(_ id: JSONRPCID, code: Int, message: String) async throws
    /// `approval.respond {session_id, choice, request_id?}`. Returns `resolved`, the count of approvals it ended.
    func respondApproval(sessionId: String, choice: ApprovalChoice, requestId: String?) async throws -> Int
    /// `approval.received {session_id, request_id}`: the card is on screen.
    func acknowledgeApproval(sessionId: String, requestId: String) async throws
    /// `approval.pending {session_id}`: every unresolved approval of the session.
    func pendingApprovals(sessionId: String) async throws -> [ApprovalRequest]
}

/// What the chat screen needs from the gateway. `GatewayClient` conforms. Tests and the
/// DEBUG demo use fakes, so the screen runs with no server.
public protocol ChatTransport: Sendable {
    /// Connection states, events and server requests, in order. The chat view model reads it.
    var events: AsyncStream<GatewayClientEvent> { get }
    /// `session.create` with `source` (docs/hermes-protocol.md 3.4).
    func startSession(source: String, idempotencyKey: String) async throws -> ChatSessionRef
    /// `session.resume` with the stored id, after a reconnect (docs/hermes-protocol.md 3.4, 4.2).
    func resumeSession(storedId: String, source: String) async throws -> ChatSessionRef
    /// `prompt.submit`. `retryBeforeRowId` cuts the transcript before that row (a reply retry).
    /// Returns `user_row_id` when the server sends it.
    func submitPrompt(sessionId: String, text: String, retryBeforeRowId: Int?) async throws -> Int?
    /// `session.interrupt`. Returns `true` when the server stopped a turn.
    func stopReply(sessionId: String) async throws -> Bool
    /// `session.history` with the live id: the whole transcript, oldest first (docs/hermes-protocol.md 3.4).
    func history(sessionId: String) async throws -> [TranscriptMessage]
    /// `prompt.submit` with `voice_turn: true`: the text is the transcript of a voice memo (protocol 3.7, 3.9).
    func submitVoicePrompt(sessionId: String, text: String, retryBeforeRowId: Int?) async throws -> Int?
    /// `POST /api/audio/transcribe` (docs/hermes-protocol.md 3.9). Returns the trimmed transcript.
    func transcribe(audio: Data, mimeType: String) async throws -> String
    /// `POST /api/audio/speak` (docs/hermes-protocol.md 3.9, issue #10). Never `voice.tts`: that uses the server speaker.
    func speak(text: String) async throws -> SpokenAudio
}

/// Transports with no voice support (offline transport, older fakes) fail voice memos.
/// The memo then shows "Not Delivered" and stays, so the owner can try again.
extension ChatTransport {
    public func submitVoicePrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? {
        throw VoiceMemoError.unsupported
    }

    public func transcribe(audio _: Data, mimeType _: String) async throws -> String {
        throw VoiceMemoError.unsupported
    }

    public func speak(text _: String) async throws -> SpokenAudio {
        throw VoiceMemoError.unsupported
    }
}

/// What the session list needs from the gateway (issue #7). `GatewayClient` and `LiveChatTransport` conform.
public protocol SessionsTransport: Sendable {
    /// Connection states and events, in order. Each read of the property gives a new stream where the
    /// transport supports it (`LiveChatTransport`).
    var events: AsyncStream<GatewayClientEvent> { get }
    /// `session.list`: the stored sessions, most recent activity first (docs/hermes-protocol.md 3.4).
    func fetchSessions() async throws -> [SessionListItem]
    /// `session.most_recent`: the stored id of the newest session, or `nil` for no session.
    func fetchMostRecentSessionId() async throws -> String?
}

/// The `source` value that iOS sends on `session.create` (issue #6, protocol 3.4).
public enum ChatSource {
    public static let iOS = "ios"
}

extension GatewayClient: ChatTransport {
    public func startSession(source: String, idempotencyKey: String) async throws -> ChatSessionRef {
        let result = try await createSession(SessionCreateParams(source: source, idempotencyKey: idempotencyKey))
        return ChatSessionRef(liveId: result.sessionId, storedId: result.storedSessionId)
    }

    public func resumeSession(storedId: String, source: String) async throws -> ChatSessionRef {
        let snapshot = try await resumeSession(SessionResumeParams(storedSessionId: storedId, source: source,
                                                                   omitMessages: true, inlineImages: false))
        return ChatSessionRef(snapshot: snapshot, storedId: storedId)
    }

    public func submitPrompt(sessionId: String, text: String, retryBeforeRowId: Int?) async throws -> Int? {
        let params = PromptSubmitParams(sessionId: sessionId, text: text, truncateBeforeRowId: retryBeforeRowId,
                                        confirmTruncate: retryBeforeRowId == nil ? nil : true)
        return try await submitPrompt(params).userRowId
    }

    public func submitVoicePrompt(sessionId: String, text: String, retryBeforeRowId: Int?) async throws -> Int? {
        let params = PromptSubmitParams(sessionId: sessionId, text: text, voiceTurn: true,
                                        truncateBeforeRowId: retryBeforeRowId,
                                        confirmTruncate: retryBeforeRowId == nil ? nil : true)
        return try await submitPrompt(params).userRowId
    }

    public func transcribe(audio: Data, mimeType: String) async throws -> String {
        try await HermesRESTClient(endpoint: endpoint).transcribe(audio: audio, mimeType: mimeType)
    }

    public func speak(text: String) async throws -> SpokenAudio {
        try await HermesRESTClient(endpoint: endpoint).speak(text: text)
    }

    public func stopReply(sessionId: String) async throws -> Bool {
        let result = try await interrupt(sessionId: sessionId)
        return result.interrupted ?? (result.status == "interrupted")
    }

    public func history(sessionId: String) async throws -> [TranscriptMessage] {
        try await sessionHistory(sessionId: sessionId).messages
    }
}

extension GatewayClient: ServerRequestTransport {
    public func answerApproval(requestId: JSONRPCID, choice: ApprovalChoice) async throws {
        try await respond(to: requestId, result: ApprovalAnswer(choice: choice))
    }

    public func rejectServerRequest(_ id: JSONRPCID, code: Int, message: String) async throws {
        try await reject(id, code: code, message: message)
    }

    public func respondApproval(sessionId: String, choice: ApprovalChoice, requestId: String?) async throws -> Int {
        let params = ApprovalRespondParams(sessionId: sessionId, choice: choice, requestId: requestId)
        return try await call("approval.respond", params: params, as: ApprovalRespondResult.self).resolved ?? 0
    }

    public func acknowledgeApproval(sessionId: String, requestId: String) async throws {
        _ = try await call("approval.received", params: ApprovalReceivedParams(sessionId: sessionId, requestId: requestId),
                           as: JSONValue.self)
    }

    public func pendingApprovals(sessionId: String) async throws -> [ApprovalRequest] {
        let result = try await call("approval.pending", params: SessionIdParams(sessionId: sessionId),
                                    as: ApprovalPendingResult.self)
        return (result.approvals ?? []).compactMap { ApprovalRequest(pending: $0, sessionId: sessionId) }
    }
}

/// `approval.respond` params (`methods_prompt.py:1332-1344`).
struct ApprovalRespondParams: Encodable, Sendable {
    var sessionId: String
    var choice: ApprovalChoice
    var requestId: String?

    private enum CodingKeys: String, CodingKey { case sessionId = "session_id", choice, requestId = "request_id" }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(choice, forKey: .choice)
        if let requestId, !requestId.isEmpty { try container.encode(requestId, forKey: .requestId) }
    }
}

struct ApprovalRespondResult: Decodable, Sendable {
    var resolved: Int?
}

/// `approval.received` params (`methods_prompt.py:1321-1329`).
struct ApprovalReceivedParams: Encodable, Sendable {
    var sessionId: String
    var requestId: String

    private enum CodingKeys: String, CodingKey { case sessionId = "session_id", requestId = "request_id" }
}

struct ApprovalPendingResult: Decodable, Sendable {
    var approvals: [JSONValue]?
}

extension GatewayClient: SessionsTransport {
    public func fetchSessions() async throws -> [SessionListItem] {
        try await listSessions().map(SessionListItem.init(row:))
    }

    /// Issue #73: a cron run is not a chat, so launch does not open it.
    public func fetchMostRecentSessionId() async throws -> String? {
        let result = try await mostRecentSession()
        guard let id = result.sessionId, !id.isEmpty, result.source != "cron" else { return nil }
        return id
    }
}

/// Issue #97: the voice calls that voice mode (#96) and GPT-Live (#98) use. Tests use a fake.
public protocol VoiceStreamTransport: Sendable {
    /// `GET /api/audio/voice-config`: relay or client-direct for each leg.
    func voiceConfig() async throws -> VoiceClientConfig
    /// `GET /api/audio/voice-live/status`. `nil` on an older server: use `chained`.
    func voiceLiveStatus() async throws -> VoiceLiveStatus?
    /// `POST /api/audio/voice-live/session`: the SDP answer for a WebRTC offer. Each session costs money.
    func createVoiceLiveSession(offerSDP: String, history: [VoiceLiveHistoryItem]) async throws -> VoiceLiveSessionAnswer
    /// A speaker for one reply: `speak-stream`, with `POST /api/audio/speak` as the fallback.
    func makeStreamedSpeech(player: any StreamedSpeechPlaying) async throws -> StreamedSpeech
}
