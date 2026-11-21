import Foundation

// Issue #98: GPT-Live ("Live" voice mode). The server holds the OpenAI key. The phone sends only the
// SDP offer and gets the SDP answer on the SSH forward. Media goes from the phone to OpenAI.

/// The two `voice-live` calls of #97 that the live engine needs. `LiveChatTransport` has them (#97).
/// Tests use a fake. No test calls a real server: each live session costs money.
public protocol LiveModeService: Sendable {
    /// `GET /api/audio/voice-live/status`. `nil` on an older server with no route.
    func voiceLiveStatus() async throws -> VoiceLiveStatus?
    /// `POST /api/audio/voice-live/session`. The offer goes byte for byte, with its last CRLF.
    func createVoiceLiveSession(offerSDP: String, history: [VoiceLiveHistoryItem]) async throws -> VoiceLiveSessionAnswer
}

extension LiveChatTransport: LiveModeService {}

/// Errors of the live engine that are not from the server.
public enum LiveModeError: Error, Sendable, Equatable {
    case microphoneDenied
    case connectionFailed
    /// A WebRTC step on the phone failed (issue #109). `code` is the vendor error code when known.
    case step(LiveModeStep, code: Int?)
}

/// The steps of a live start, for the error line and the log (issue #109).
public enum LiveModeStep: String, Sendable, Equatable {
    /// `RTCAudioSession` activation for voice chat.
    case audioSession = "audio session"
    /// The local WebRTC offer and ICE gathering.
    case offer
    /// `POST /api/audio/voice-live/session`.
    case session
    /// The SDP answer goes into the peer.
    case answer
}

extension VoiceLiveStatus {
    /// The text when Live is not available: the server reason, or a default.
    public var unavailableText: String {
        let text = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "Not available on this server" : text
    }
}

public enum LiveModeStatusText {
    /// The text for an older Hermes with no `voice-live` routes (status `nil`).
    public static let olderServer = "This Hermes version has no Live mode."
}

// MARK: - prompt.submit with surface `voice-live`

/// A transport that sends a GPT-Live delegation as a Hermes turn (`prompt.submit`, `surface: "voice-live"`,
/// `voice_turn: true`, `voice_context`). `GatewayClient` and `LiveChatTransport` conform (`methods_prompt.py:866-871`).
public protocol LiveDelegationTransport: Sendable {
    func submitLivePrompt(sessionId: String, text: String, voiceContext: String) async throws -> Int?
}

extension GatewayClient: LiveDelegationTransport {
    public func submitLivePrompt(sessionId: String, text: String, voiceContext: String) async throws -> Int? {
        // Issue #147: `voice_turn: true` makes the server use its voice route (`auxiliary.voice_chat`) for this turn.
        var params = PromptSubmitParams(sessionId: sessionId, text: text, voiceTurn: true)
        params.surface = LiveModeProtocol.surface
        params.voiceContext = voiceContext.isEmpty ? nil : String(voiceContext.suffix(6000))
        return try await submitPrompt(params).userRowId
    }
}

extension LiveChatTransport: LiveDelegationTransport {
    public func submitLivePrompt(sessionId: String, text: String, voiceContext: String) async throws -> Int? {
        try await readyClient().submitLivePrompt(sessionId: sessionId, text: text, voiceContext: voiceContext)
    }
}
