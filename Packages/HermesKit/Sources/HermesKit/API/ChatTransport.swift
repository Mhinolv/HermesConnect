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
    /// `prompt.submit` with `voice_turn: true`: the text is the transcript of a voice memo (protocol 3.7, 3.9).
    func submitVoicePrompt(sessionId: String, text: String, retryBeforeRowId: Int?) async throws -> Int?
    /// `POST /api/audio/transcribe` (docs/hermes-protocol.md 3.9). Returns the trimmed transcript.
    func transcribe(audio: Data, mimeType: String) async throws -> String
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

    public func stopReply(sessionId: String) async throws -> Bool {
        let result = try await interrupt(sessionId: sessionId)
        return result.interrupted ?? (result.status == "interrupted")
    }
}
