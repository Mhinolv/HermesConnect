import Foundation

// Issue #97: the voice REST calls on the forwarded port, with the session token header
// (`hermes_cli/web_routers/audio.py:152-212`). No call reads `voice.voice_chat_mode`, so all of them
// work in `chained` and in `gpt-live` mode.

/// How the phone reaches one voice provider (`GET /api/audio/voice-config`).
public enum VoiceRoute: Sendable, Equatable {
    /// The phone uses the relay calls on the server (`/api/audio/*`). Hostinger gives this
    /// for local whisper and Kokoro.
    case relay
    /// The server offers its provider key to the phone. iOS does not use it in v3 (out of scope of #97),
    /// so the app still uses the relay calls.
    case direct
    case other(String)

    init(_ raw: String?) {
        switch raw {
        case "relay", nil: self = .relay
        case "direct": self = .direct
        case let value?: self = .other(value)
        }
    }
}

/// `GET /api/audio/voice-config` result. The decoder reads only non-secret fields:
/// `api_key` and `base_url` of a direct provider never get into memory of the app.
public struct VoiceClientConfig: Decodable, Sendable, Equatable {
    public struct Leg: Decodable, Sendable, Equatable {
        public var route: VoiceRoute
        public var provider: String?
        /// Why the server relays, for example `"resolution error"`.
        public var reason: String?
        /// STT only: the server serves live dictation on `/api/audio/transcribe-stream`.
        public var streaming: Bool

        public init(route: VoiceRoute, provider: String? = nil, reason: String? = nil, streaming: Bool = false) {
            self.route = route
            self.provider = provider
            self.reason = reason
            self.streaming = streaming
        }

        private enum CodingKeys: String, CodingKey { case mode, provider, reason, streaming }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            route = VoiceRoute(try container.decodeIfPresent(String.self, forKey: .mode))
            provider = try? container.decodeIfPresent(String.self, forKey: .provider)
            reason = try? container.decodeIfPresent(String.self, forKey: .reason)
            streaming = (try? container.decodeIfPresent(Bool.self, forKey: .streaming)) ?? false
        }
    }

    public var stt: Leg
    public var tts: Leg

    public init(stt: Leg, tts: Leg) {
        self.stt = stt
        self.tts = tts
    }

    private enum CodingKeys: String, CodingKey { case ok, stt, tts }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard (try container.decodeIfPresent(Bool.self, forKey: .ok)) != false else {
            throw HermesAPIError.invalidResponse
        }
        stt = try container.decode(Leg.self, forKey: .stt)
        tts = try container.decode(Leg.self, forKey: .tts)
    }
}

/// `voice.voice_chat_mode` of the profile.
public enum VoiceChatMode: String, Sendable, Equatable {
    case chained
    case gptLive = "gpt-live"
}

/// `GET /api/audio/voice-live/status` result (`audio.py:183-190`, desktop `lib/voice-live.ts:24-30`).
public struct VoiceLiveStatus: Decodable, Sendable, Equatable {
    public var mode: VoiceChatMode
    /// `true` when GPT-Live can start (an OpenAI API key is on the server).
    public var available: Bool
    public var reason: String?
    public var model: String?
    public var voice: String?

    public init(mode: VoiceChatMode, available: Bool, reason: String? = nil, model: String? = nil,
                voice: String? = nil) {
        self.mode = mode
        self.available = available
        self.reason = reason
        self.model = model
        self.voice = voice
    }

    private enum CodingKeys: String, CodingKey { case ok, mode, available, reason, model, voice }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard (try container.decodeIfPresent(Bool.self, forKey: .ok)) != false else {
            throw HermesAPIError.invalidResponse
        }
        // An unknown mode is `chained`, as the desktop app does (`store/voice-live.ts:60-62`).
        mode = VoiceChatMode(rawValue: (try? container.decodeIfPresent(String.self, forKey: .mode)) ?? "") ?? .chained
        available = (try? container.decodeIfPresent(Bool.self, forKey: .available)) ?? false
        reason = try? container.decodeIfPresent(String.self, forKey: .reason)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        voice = try? container.decodeIfPresent(String.self, forKey: .voice)
    }
}

/// One turn of the history that a GPT-Live session starts with (desktop `LiveHistoryMessage`).
public struct VoiceLiveHistoryItem: Encodable, Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant, developer }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case type, role, content }
    private struct Part: Encodable { var type: String; var text: String }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("message", forKey: .type)
        try container.encode(role.rawValue, forKey: .role)
        try container.encode([Part(type: role == .assistant ? "output_text" : "input_text", text: text)],
                             forKey: .content)
    }
}

/// `POST /api/audio/voice-live/session` result: the SDP answer of the WebRTC offer (`audio.py:193-212`).
public struct VoiceLiveSessionAnswer: Sendable, Equatable {
    public var sessionId: String?
    public var sdp: String
    public var type: String

    public init(sessionId: String?, sdp: String, type: String = "answer") {
        self.sessionId = sessionId
        self.sdp = sdp
        self.type = type
    }
}

/// A refused `POST /api/audio/voice-live/session`. `detail` is the server text for an alert. It never goes to a log.
public enum VoiceLiveSessionError: Error, Sendable, Equatable {
    /// 400: the offer is empty or bad.
    case badOffer(detail: String?)
    /// 503: GPT-Live cannot start here, for example no OpenAI API key.
    case unavailable(detail: String?)
    /// 502: the vendor refused the session.
    case vendor(detail: String?)
}

extension HermesRESTClient {
    /// `GET /api/audio/voice-config`. iOS reads the routes only. It never takes provider keys.
    public func voiceConfig() async throws -> VoiceClientConfig {
        try await voiceLoad(request(path: "/api/audio/voice-config", query: []))
    }

    /// `GET /api/audio/voice-live/status`. `nil` when the server is older and has no such route (404):
    /// the app then uses `chained` mode, as the desktop app does.
    public func voiceLiveStatus() async throws -> VoiceLiveStatus? {
        do {
            return try await voiceLoad(request(path: "/api/audio/voice-live/status", query: []))
        } catch HermesAPIError.notFound {
            return nil
        }
    }

    /// `POST /api/audio/voice-live/session` with the WebRTC offer. The offer goes byte for byte, with
    /// its last CRLF, because the vendor parser needs it exact (`audio.py:201-204`). Each session costs money.
    public func createVoiceLiveSession(offerSDP: String, history: [VoiceLiveHistoryItem] = [])
        async throws -> VoiceLiveSessionAnswer {
        guard !offerSDP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceLiveSessionError.badOffer(detail: nil)
        }
        var request = request(path: "/api/audio/voice-live/session", query: [], timeout: Self.voiceLiveTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(VoiceLiveSessionBody(sdp: offerSDP, history: history))
        let result: VoiceLiveSessionResponse = try await voiceLoad(request) { status, detail in
            switch status {
            case 400: VoiceLiveSessionError.badOffer(detail: detail)
            case 502: VoiceLiveSessionError.vendor(detail: detail)
            case 503: VoiceLiveSessionError.unavailable(detail: detail)
            default: nil
            }
        }
        guard result.ok != false, let transport = result.transport, !transport.sdp.isEmpty else {
            throw HermesAPIError.invalidResponse
        }
        return VoiceLiveSessionAnswer(sessionId: result.session?.id, sdp: transport.sdp, type: transport.type ?? "answer")
    }

    /// The desktop app waits 45 s for the session (`lib/voice-live.ts:342`).
    static let voiceLiveTimeout: TimeInterval = 45

    private struct VoiceLiveSessionBody: Encodable {
        var sdp: String
        var history: [VoiceLiveHistoryItem]
    }

    private struct VoiceLiveSessionResponse: Decodable {
        struct Session: Decodable { var id: String? }
        struct Transport: Decodable { var sdp: String; var type: String? }
        var ok: Bool?
        var session: Session?
        var transport: Transport?
    }

    private struct ErrorDetail: Decodable { var detail: String? }

    /// Loads and decodes like the other REST calls. `refusal` can map a status and its `detail` to an error.
    private func voiceLoad<Output: Decodable>(
        _ request: URLRequest, refusal: (Int, String?) -> (any Error)? = { _, _ in nil }) async throws -> Output {
        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HermesAPIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw HermesAPIError.unauthorized
        default:
            let detail = (try? JSONDecoder().decode(ErrorDetail.self, from: data))?.detail
            if let error = refusal(http.statusCode, detail) { throw error }
            if http.statusCode == 404 { throw HermesAPIError.notFound }
            throw HermesAPIError.http(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Output.self, from: data)
        } catch {
            throw HermesAPIError.invalidResponse
        }
    }
}
