import Foundation

/// The live and stored ids of the chat session (docs/hermes-protocol.md 3.3).
public struct ChatSessionRef: Sendable, Equatable {
    public var liveId: String
    public var storedId: String?

    public init(liveId: String, storedId: String? = nil) {
        self.liveId = liveId
        self.storedId = storedId
    }
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
        return ChatSessionRef(liveId: snapshot.sessionId, storedId: snapshot.storedSessionId ?? storedId)
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
