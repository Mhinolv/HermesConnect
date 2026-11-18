import Foundation

// Issue #98: GPT-Live ("Live" voice mode). The server holds the OpenAI key. The phone sends only the
// SDP offer and gets the SDP answer on the SSH forward. Media goes from the phone to OpenAI.

/// `GET /api/audio/voice-live/status` (`hermes_cli/web_routers/audio.py:183`).
public struct LiveModeStatus: Decodable, Sendable, Equatable {
    /// `chained` or `gpt-live`.
    public var mode: String
    public var available: Bool
    /// Why Live is not available. The server sends it. `nil` when Live is available.
    public var reason: String?
    public var model: String?
    public var voice: String?

    public init(mode: String = "gpt-live", available: Bool, reason: String? = nil,
                model: String? = nil, voice: String? = nil) {
        self.mode = mode
        self.available = available
        self.reason = reason
        self.model = model
        self.voice = voice
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decode(String.self, forKey: .mode)) ?? "chained"
        available = (try? container.decode(Bool.self, forKey: .available)) ?? false
        reason = try? container.decode(String.self, forKey: .reason)
        model = try? container.decode(String.self, forKey: .model)
        voice = try? container.decode(String.self, forKey: .voice)
    }

    private enum CodingKeys: String, CodingKey { case mode, available, reason, model, voice }

    /// The status of a server with no `voice-live` routes (older Hermes) or a failed check.
    public static func unavailable(_ reason: String?) -> LiveModeStatus {
        LiveModeStatus(mode: "chained", available: false, reason: reason)
    }

    /// The subtitle of a disabled "Live" item in the mode picker (design notes #98).
    public var unavailableText: String {
        let text = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "Not available on this server" : text
    }
}

/// One seed message of `POST /api/audio/voice-live/session` (`history`), as the desktop sends it.
public struct LiveModeHistoryMessage: Codable, Sendable, Equatable {
    public struct Content: Codable, Sendable, Equatable {
        public var type: String
        public var text: String
    }

    public var type = "message"
    public var role: String
    public var content: [Content]

    public init(role: String, text: String) {
        self.role = role
        content = [Content(type: role == "assistant" ? "output_text" : "input_text", text: text)]
    }
}

/// `POST /api/audio/voice-live/session` result: the session id and the SDP answer.
public struct LiveModeAnswer: Sendable, Equatable {
    public var sessionId: String?
    public var sdp: String

    public init(sessionId: String?, sdp: String) {
        self.sessionId = sessionId
        self.sdp = sdp
    }
}

public enum LiveModeError: Error, Sendable, Equatable {
    /// The server refused the session (503: no key or mode off; 502: OpenAI refused). The text is for the owner.
    case refused(String)
    case noAnswer
    case microphoneDenied
    case connectionFailed
}

/// The two `voice-live` calls. Issue #97 adds them to HermesKit. Until #97 merges, `LiveChatTransport`
/// conforms with the adapter below. Tests use a fake. No test calls a real server.
public protocol LiveModeService: Sendable {
    func liveModeStatus() async throws -> LiveModeStatus
    /// Sends `sdp` byte-exact (with the trailing CRLF). OpenAI refuses a changed offer.
    func createLiveModeSession(sdp: String, history: [LiveModeHistoryMessage]) async throws -> LiveModeAnswer
}

// MARK: - REST adapter (replace with the #97 calls after #97 merges)

struct LiveModeSessionBody: Encodable {
    var sdp: String
    var history: [LiveModeHistoryMessage]
}

private struct LiveModeSessionResponse: Decodable {
    struct Session: Decodable { var id: String? }
    struct Transport: Decodable { var sdp: String?; var type: String? }
    var ok: Bool?
    var session: Session?
    var transport: Transport?
}

private struct LiveModeErrorBody: Decodable { var detail: String? }

extension HermesRESTClient {
    /// The JSON body of `POST /api/audio/voice-live/session`. JSON keeps each byte of the SDP text.
    static func liveModeSessionBody(sdp: String, history: [LiveModeHistoryMessage]) throws -> Data {
        try JSONEncoder().encode(LiveModeSessionBody(sdp: sdp, history: history))
    }

    func liveModeStatusCall() async throws -> LiveModeStatus {
        let (data, response) = try await loader.data(for: request(path: "/api/audio/voice-live/status", query: []))
        guard let http = response as? HTTPURLResponse else { throw HermesAPIError.invalidResponse }
        // An older Hermes has no route: Live is not available, and the memo flow stays.
        if http.statusCode == 404 { return .unavailable("This Hermes version has no Live mode.") }
        if http.statusCode == 401 { throw HermesAPIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw HermesAPIError.http(status: http.statusCode) }
        guard let status = try? JSONDecoder().decode(LiveModeStatus.self, from: data) else {
            throw HermesAPIError.invalidResponse
        }
        return status
    }

    func liveModeSessionCall(sdp: String, history: [LiveModeHistoryMessage]) async throws -> LiveModeAnswer {
        var request = request(path: "/api/audio/voice-live/session", query: [], timeout: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.liveModeSessionBody(sdp: sdp, history: history)
        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HermesAPIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw HermesAPIError.unauthorized
        case 400, 502, 503:
            let detail = (try? JSONDecoder().decode(LiveModeErrorBody.self, from: data))?.detail
            throw LiveModeError.refused(detail ?? "The server could not start Live mode.")
        default: throw HermesAPIError.http(status: http.statusCode)
        }
        guard let body = try? JSONDecoder().decode(LiveModeSessionResponse.self, from: data),
              body.ok != false, let answer = body.transport?.sdp, !answer.isEmpty else {
            throw LiveModeError.noAnswer
        }
        return LiveModeAnswer(sessionId: body.session?.id, sdp: answer)
    }
}

extension LiveChatTransport: LiveModeService {
    public func liveModeStatus() async throws -> LiveModeStatus {
        try await withREST { try await $0.liveModeStatusCall() }
    }

    public func createLiveModeSession(sdp: String, history: [LiveModeHistoryMessage]) async throws -> LiveModeAnswer {
        try await withREST { try await $0.liveModeSessionCall(sdp: sdp, history: history) }
    }
}

// MARK: - prompt.submit with surface `voice-live`

/// A transport that sends a GPT-Live delegation as a Hermes turn (`prompt.submit`, `surface: "voice-live"`,
/// `voice_context`). `GatewayClient` and `LiveChatTransport` conform (`methods_prompt.py:866-871`).
public protocol LiveDelegationTransport: Sendable {
    func submitLivePrompt(sessionId: String, text: String, voiceContext: String) async throws -> Int?
}

extension GatewayClient: LiveDelegationTransport {
    public func submitLivePrompt(sessionId: String, text: String, voiceContext: String) async throws -> Int? {
        var params = PromptSubmitParams(sessionId: sessionId, text: text)
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
