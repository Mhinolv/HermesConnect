import Foundation
import Synchronization
import Testing
@testable import HermesKit

private let token = String(repeating: "c3", count: 32)

/// Answers with one scripted response and records the requests. No network.
private final class VoiceHTTP: HTTPDataLoading, Sendable {
    private let requests = Mutex<[URLRequest]>([])
    private let status: Int
    private let body: String

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    var recorded: [URLRequest] { requests.withLock { $0 } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.withLock { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private func client(_ http: VoiceHTTP) throws -> HermesRESTClient {
    HermesRESTClient(endpoint: try GatewayEndpoint(port: 9119, token: token), loader: http)
}

private func body(_ request: URLRequest) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
}

@Suite struct VoiceAPITests {
    /// The Hostinger shape: local whisper and Kokoro run only on the server, so both legs relay.
    /// `voice_chat_mode` does not change this answer (`audio.py:152-180` does not read it).
    @Test func voiceConfigRelayOnHostinger() async throws {
        let http = VoiceHTTP(body: """
        {"ok":true,"stt":{"mode":"relay","reason":"local provider runs on the host","streaming":false},
         "tts":{"mode":"relay","reason":"command provider runs on the host"}}
        """)
        let config = try await client(http).voiceConfig()
        #expect(config.stt.route == .relay)
        #expect(config.tts.route == .relay)
        #expect(config.stt.streaming == false)
        #expect(config.tts.reason == "command provider runs on the host")
        let request = try #require(http.recorded.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/audio/voice-config")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == token)
        #expect(request.url?.query == nil, "the token goes in the header, not the URL")
    }

    @Test func voiceConfigDirectKeepsNoKey() async throws {
        let key = "sk-test-DIRECTKEY-91"
        let http = VoiceHTTP(body: """
        {"ok":true,"stt":{"mode":"direct","wire":"openai-multipart","provider":"openai","base_url":"https://x",
         "api_key":"\(key)","model":"whisper-1","language":null,"streaming":true},
         "tts":{"mode":"direct","wire":"openai-speech","provider":"openai","api_key":"\(key)","voice":"alloy"}}
        """)
        let config = try await client(http).voiceConfig()
        #expect(config.stt == .init(route: .direct, provider: "openai", streaming: true))
        #expect(config.tts == .init(route: .direct, provider: "openai"))
        #expect(!String(describing: config).contains(key))
        #expect(!String(reflecting: config).contains(key))
    }

    @Test func voiceConfigResolutionErrorIsRelay() async throws {
        let http = VoiceHTTP(body: #"{"ok":true,"stt":{"mode":"relay","reason":"resolution error"},"tts":{"mode":"relay","reason":"resolution error"}}"#)
        let config = try await client(http).voiceConfig()
        #expect(config.stt.route == .relay && config.stt.reason == "resolution error")
    }

    @Test func voiceConfigUnknownModeIsKept() async throws {
        let http = VoiceHTTP(body: #"{"ok":true,"stt":{"mode":"local"},"tts":{}}"#)
        let config = try await client(http).voiceConfig()
        #expect(config.stt.route == .other("local"))
        #expect(config.tts.route == .relay)
    }

    @Test(arguments: [(401, HermesAPIError.unauthorized), (404, .notFound), (500, .http(status: 500))])
    func voiceConfigErrors(status: Int, error: HermesAPIError) async throws {
        let http = VoiceHTTP(status: status, body: #"{"detail":"x"}"#)
        await #expect(throws: error) { try await client(http).voiceConfig() }
    }

    @Test func voiceConfigBadBodyIsInvalid() async throws {
        await #expect(throws: HermesAPIError.invalidResponse) { try await client(VoiceHTTP(body: #"{"ok":false}"#)).voiceConfig() }
        await #expect(throws: HermesAPIError.invalidResponse) { try await client(VoiceHTTP(body: "[]")).voiceConfig() }
    }

    /// Hostinger after the owner switch: `gpt-live` and an OpenAI key.
    @Test func voiceLiveStatusGPTLive() async throws {
        let http = VoiceHTTP(body: #"{"ok":true,"mode":"gpt-live","available":true,"reason":null,"model":"gpt-live-1","voice":"marin"}"#)
        let status = try #require(try await client(http).voiceLiveStatus())
        #expect(status == VoiceLiveStatus(mode: .gptLive, available: true, model: "gpt-live-1", voice: "marin"))
        #expect(http.recorded.first?.url?.path == "/api/audio/voice-live/status")
        #expect(http.recorded.first?.value(forHTTPHeaderField: "X-Hermes-Session-Token") == token)
    }

    /// Ouro: `gpt-live` is not available (no OpenAI API key).
    @Test func voiceLiveStatusNotAvailable() async throws {
        let http = VoiceHTTP(body: #"{"ok":true,"mode":"chained","available":false,"reason":"no OpenAI API key","model":"gpt-live-1","voice":"marin"}"#)
        let status = try #require(try await client(http).voiceLiveStatus())
        #expect(status.mode == .chained)
        #expect(status.available == false)
        #expect(status.reason == "no OpenAI API key")
    }

    @Test func voiceLiveStatusUnknownModeIsChained() async throws {
        let status = try await client(VoiceHTTP(body: #"{"ok":true,"mode":"future"}"#)).voiceLiveStatus()
        #expect(status == VoiceLiveStatus(mode: .chained, available: false))
    }

    @Test func voiceLiveStatusOnAnOldServerIsNil() async throws {
        let status = try await client(VoiceHTTP(status: 404, body: #"{"detail":"Not Found"}"#)).voiceLiveStatus()
        #expect(status == nil)
    }

    @Test func voiceLiveStatusRefusedToken() async throws {
        await #expect(throws: HermesAPIError.unauthorized) {
            try await client(VoiceHTTP(status: 401, body: "{}")).voiceLiveStatus()
        }
    }

    @Test func voiceLiveSessionSendsTheExactOffer() async throws {
        let http = VoiceHTTP(body: #"{"ok":true,"session":{"id":"sess_1"},"transport":{"sdp":"v=0\r\nanswer\r\n","type":"answer"}}"#)
        let offer = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n"
        let answer = try await client(http).createVoiceLiveSession(
            offerSDP: offer, history: [.init(role: .user, text: "Hi"), .init(role: .assistant, text: "Hello")])
        #expect(answer == VoiceLiveSessionAnswer(sessionId: "sess_1", sdp: "v=0\r\nanswer\r\n"))
        let request = try #require(http.recorded.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/audio/voice-live/session")
        #expect(request.timeoutInterval == 45)
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == token)
        let sent = try body(request)
        #expect(sent["sdp"]?.stringValue == offer, "the offer keeps its last CRLF")
        guard case .array(let history)? = sent["history"] else { Issue.record("no history"); return }
        #expect(history.count == 2)
        #expect(history[0]["type"]?.stringValue == "message")
        #expect(history[0]["role"]?.stringValue == "user")
        guard case .array(let userParts)? = history[0]["content"], case .array(let botParts)? = history[1]["content"] else {
            Issue.record("no content"); return
        }
        #expect(userParts.first?["type"]?.stringValue == "input_text")
        #expect(userParts.first?["text"]?.stringValue == "Hi")
        #expect(botParts.first?["type"]?.stringValue == "output_text")
    }

    @Test func voiceLiveSessionEmptyOfferSendsNothing() async throws {
        let http = VoiceHTTP(body: "{}")
        await #expect(throws: VoiceLiveSessionError.badOffer(detail: nil)) {
            try await client(http).createVoiceLiveSession(offerSDP: " \r\n")
        }
        #expect(http.recorded.isEmpty)
    }

    @Test(arguments: [(400, VoiceLiveSessionError.badOffer(detail: "An SDP offer is required")),
                      (503, .unavailable(detail: "An SDP offer is required")),
                      (502, .vendor(detail: "An SDP offer is required"))])
    func voiceLiveSessionRefusals(status: Int, error: VoiceLiveSessionError) async throws {
        let http = VoiceHTTP(status: status, body: #"{"detail":"An SDP offer is required"}"#)
        await #expect(throws: error) { try await client(http).createVoiceLiveSession(offerSDP: "v=0\r\n") }
    }

    @Test func voiceLiveSessionRefusedTokenAndBadAnswer() async throws {
        await #expect(throws: HermesAPIError.unauthorized) {
            try await client(VoiceHTTP(status: 401, body: "{}")).createVoiceLiveSession(offerSDP: "v=0\r\n")
        }
        await #expect(throws: HermesAPIError.invalidResponse) {
            try await client(VoiceHTTP(body: #"{"ok":true,"transport":{"sdp":""}}"#)).createVoiceLiveSession(offerSDP: "v=0\r\n")
        }
    }
}
