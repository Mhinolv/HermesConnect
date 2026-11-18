import Foundation

// Issue #97: the `speak-stream` WebSocket (`hermes_cli/web_routers/audio.py:604-785`, docs/hermes-protocol.md 3.9).
//
//   client → {"text":"<delta>"} many times, {"done":true} at the end of the reply, {"stop":true} for barge-in
//   server → {"type":"start","sample_rate":N,"channels":1} with the first audio, binary s16le mono PCM,
//            then {"type":"end"}, or {"type":"fallback"} when synthesis made no audio

/// One server frame of `speak-stream`.
public enum SpeakStreamEvent: Sendable, Equatable {
    case start(sampleRate: Int, channels: Int)
    /// Raw s16le mono PCM. A chunk can end in the middle of a sample (see `PCM16Samples`).
    case audio(Data)
    case end
    /// The server made no audio. Speak the whole reply with `POST /api/audio/speak`.
    case fallback
}

/// Why the voice audio failed, for the #96 states. No case holds a URL, a token or text.
public enum SpeechStreamError: Error, Sendable, Equatable {
    /// The server refused the token (close 4401 or 4403, HTTP 401 or 403). The app asks for a new session.
    case unauthorized
    /// No link to the server: the SSH forward or the network is down.
    case offline
    /// The server failed or sent a bad frame.
    case server

    /// Maps a socket or REST error.
    public static func from(_ error: any Error) -> SpeechStreamError {
        switch error {
        case let error as SpeechStreamError: return error
        case let closed as GatewayWebSocketClosed:
            if [4401, 4403].contains(closed.closeCode ?? 0) || [401, 403].contains(closed.httpStatus ?? 0) {
                return .unauthorized
            }
            if closed.httpStatus == nil, closed.urlErrorCode != nil { return .offline }
            return .server
        case HermesAPIError.unauthorized, HermesAPIError.http(status: 401), HermesAPIError.http(status: 403):
            return .unauthorized
        case GatewayError.notConnected: return .offline
        case is URLError: return .offline
        default: return .server
        }
    }
}

/// One open `speak-stream` socket: one reply. Use it from one task for receive and any task for send.
public final class SpeakStreamConnection: Sendable {
    private let socket: any GatewayWebSocket

    init(socket: any GatewayWebSocket) {
        self.socket = socket
    }

    /// Opens `ws://127.0.0.1:<port>/api/audio/speak-stream?token=…` on the SSH forward.
    public static func open(endpoint: GatewayEndpoint, connector: any GatewayWebSocketConnecting)
        async throws -> SpeakStreamConnection {
        do {
            return SpeakStreamConnection(socket: try await connector.connect(to: endpoint.speakStreamURL))
        } catch {
            throw SpeechStreamError.from(error)
        }
    }

    /// Sends one reply delta as it is. The server cuts sentences and strips Markdown per sentence.
    public func send(text: String) async throws {
        guard !text.isEmpty else { return }
        try await sendFrame(["text": .string(text)])
    }

    /// `{"done":true}`: the reply text is complete.
    public func finish() async throws {
        try await sendFrame(["done": .bool(true)])
    }

    /// Barge-in: `{"stop":true}`, then close. The server stops synthesis on either one.
    public func stop() async {
        try? await sendFrame(["stop": .bool(true)])
        close()
    }

    public func close() {
        socket.close(code: 1000)
    }

    /// The next server frame. After `end` or `fallback` the caller stops reading.
    /// Unknown text frames are skipped. Throws `SpeechStreamError` when the socket ends.
    public func next() async throws -> SpeakStreamEvent {
        while true {
            let message: GatewayWebSocketMessage
            do {
                message = try await socket.receive()
            } catch {
                throw SpeechStreamError.from(error)
            }
            switch message {
            case .data(let data):
                return .audio(data)
            case .text(let text):
                if let event = Self.decode(text) { return event }
            }
        }
    }

    static func decode(_ text: String) -> SpeakStreamEvent? {
        guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(text.utf8)) else { return nil }
        switch frame.type {
        case "start":
            let rate = frame.sampleRate ?? PCM16Samples.defaultSampleRate
            return .start(sampleRate: rate > 0 ? rate : PCM16Samples.defaultSampleRate, channels: frame.channels ?? 1)
        case "end": return .end
        case "fallback": return .fallback
        default: return nil
        }
    }

    private struct Frame: Decodable {
        var type: String?
        var sampleRate: Int?
        var channels: Int?
        enum CodingKeys: String, CodingKey { case type, sampleRate = "sample_rate", channels }
    }

    private func sendFrame(_ frame: [String: JSONValue]) async throws {
        let data = try JSONEncoder().encode(frame)
        do {
            try await socket.send(String(decoding: data, as: UTF8.self))
        } catch {
            throw SpeechStreamError.from(error)
        }
    }
}

/// Turns s16le PCM chunks into Float samples from -1 to 1. Provider chunks are not sample-aligned,
/// so an odd last byte waits for the next chunk (desktop `voice-playback.ts:452-470`).
public struct PCM16Samples: Sendable {
    /// The server rate when a `start` frame has no rate (`audio.py:396`).
    public static let defaultSampleRate = 24_000

    private var carry: UInt8?

    public init() {}

    public mutating func samples(from chunk: Data) -> [Float] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(chunk.count + 1)
        if let carry { bytes.append(carry) }
        bytes.append(contentsOf: chunk)
        carry = bytes.count % 2 == 1 ? bytes.removeLast() : nil
        var output = [Float](repeating: 0, count: bytes.count / 2)
        for index in output.indices {
            let value = Int16(bitPattern: UInt16(bytes[2 * index]) | UInt16(bytes[2 * index + 1]) << 8)
            output[index] = Float(value) / 32_768
        }
        return output
    }
}
