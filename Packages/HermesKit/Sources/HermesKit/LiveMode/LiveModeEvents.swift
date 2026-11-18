import Foundation

/// The `oai-events` data channel contract of GPT-Live, as the Hermes desktop uses it
/// (`apps/desktop/src/lib/voice-live.ts`). Issue #98.
public enum LiveModeProtocol {
    public static let dataChannel = "oai-events"
    /// `prompt.submit` surface of a delegation (`contracts/prompt_voice.py:23`).
    public static let surface = "voice-live"
    /// The vendor cap is 500 tokens for each append. About 4 characters a token, with headroom.
    public static let appendCharacterLimit = 1_400
    static let contextWindowMs = 5 * 60_000
    static let contextMaxFragments = 80
}

/// One transcript delta of the live session.
public struct LiveModeFragment: Sendable, Equatable {
    public enum Speaker: Sendable, Equatable { case user, assistant }
    public var speaker: Speaker
    public var text: String
    public var startMs: Int
    public var endMs: Int

    public init(speaker: Speaker, text: String, startMs: Int = 0, endMs: Int = 0) {
        self.speaker = speaker
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// A server event on the data channel. Unknown types are `.other`.
public enum LiveModeServerEvent: Sendable, Equatable {
    case started(sessionId: String?)
    case transcript(LiveModeFragment)
    case delegation(id: String)
    /// `context_injection_incomplete` after a close is expected. It is not an error.
    case error(code: String?, message: String)
    case closed(reason: String, usageSeconds: Double?)
    case other(String)

    private struct Raw: Decodable {
        struct Delegation: Decodable { var id: String? }
        struct Failure: Decodable { var code: String?; var message: String? }
        struct Usage: Decodable { var seconds: Double? }
        struct Session: Decodable { var id: String? }
        var type: String
        var delta: String?
        var start_ms: Int?
        var end_ms: Int?
        var delegation: Delegation?
        var error: Failure?
        var usage: Usage?
        var reason: String?
        var session: Session?
    }

    /// `nil` for text that is not a JSON event.
    public static func parse(_ text: String) -> LiveModeServerEvent? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(text.utf8)) else { return nil }
        switch raw.type {
        case "session.started":
            return .started(sessionId: raw.session?.id)
        case "session.input_transcript.delta", "session.output_transcript.delta":
            let speaker: LiveModeFragment.Speaker = raw.type == "session.input_transcript.delta" ? .user : .assistant
            return .transcript(LiveModeFragment(speaker: speaker, text: raw.delta ?? "",
                                                startMs: raw.start_ms ?? 0, endMs: raw.end_ms ?? 0))
        case "session.delegation.created":
            guard let id = raw.delegation?.id, !id.isEmpty else { return .other(raw.type) }
            return .delegation(id: id)
        case "error":
            return .error(code: raw.error?.code, message: raw.error?.message ?? "Live mode error")
        case "session.closed":
            return .closed(reason: raw.reason ?? "closed", usageSeconds: raw.usage?.seconds)
        default:
            return .other(raw.type)
        }
    }
}

/// A client event on the data channel. `json` is the text to send.
public enum LiveModeClientEvent: Sendable, Equatable {
    /// Text that the voice says (paraphrased): the Hermes reply.
    case commentary(delegationId: String?, content: String, eventId: String)
    /// Quiet progress for the voice model.
    case thinking(delegationId: String?, content: String, eventId: String)
    case instructions(content: String, eventId: String)
    case mute(Bool, eventId: String)
    case close

    public var json: String {
        var object: [String: Any] = [:]
        switch self {
        case .commentary(let id, let content, let eventId):
            object = ["type": "session.commentary.append", "content": content, "event_id": eventId,
                      "delegation_id": id.map { $0 as Any } ?? NSNull()]
        case .thinking(let id, let content, let eventId):
            object = ["type": "session.thinking.append", "content": content, "event_id": eventId,
                      "delegation_id": id.map { $0 as Any } ?? NSNull()]
        case .instructions(let content, let eventId):
            object = ["type": "session.instructions.append", "content": content, "event_id": eventId,
                      "delegation_id": NSNull()]
        case .mute(let muted, let eventId):
            object = ["type": muted ? "session.input_audio.mute" : "session.input_audio.unmute", "event_id": eventId]
        case .close:
            object = ["type": "session.close"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

public enum LiveModeText {
    /// Splits a reply into append chunks at sentence ends (`chunkForCommentary` of the desktop).
    public static func chunks(_ text: String, limit: Int = LiveModeProtocol.appendCharacterLimit) -> [String] {
        let clean = collapse(text)
        guard !clean.isEmpty else { return [] }
        guard clean.count > limit else { return [clean] }
        var result: [String] = []
        var current = ""
        for sentence in sentences(clean) {
            if sentence.count > limit {
                if !current.isEmpty { result.append(current); current = "" }
                var rest = Substring(sentence)
                while !rest.isEmpty {
                    result.append(String(rest.prefix(limit)))
                    rest = rest.dropFirst(limit)
                }
                continue
            }
            let candidate = current.isEmpty ? sentence : current + " " + sentence
            if candidate.count > limit {
                result.append(current)
                current = sentence
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The end of the last whole sentence in `text` (after ". ", "! " or "? "), or `nil`.
    /// A streaming reply sends only whole sentences. The tail goes when the reply ends.
    public static func lastSentenceEnd(in text: String) -> String.Index? {
        var found: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]), next < text.endIndex, text[next].isWhitespace { found = next }
            index = next
        }
        return found
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character == " ", let previous, ".!?".contains(previous) {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The Hermes turn of a delegation: `prompt` is the last thing the owner said (the bubble),
    /// `context` the recent spoken exchange (model input only). `delegationPrompt` of the desktop.
    public static func delegationPrompt(_ fragments: [LiveModeFragment]) -> (prompt: String, context: String) {
        var turns: [(speaker: LiveModeFragment.Speaker, text: String)] = []
        for fragment in fragments {
            if let last = turns.last, last.speaker == fragment.speaker {
                turns[turns.count - 1].text += fragment.text
            } else {
                turns.append((fragment.speaker, fragment.text))
            }
        }
        let prompt = collapse(turns.last(where: { $0.speaker == .user })?.text ?? "")
        let context = turns.compactMap { turn -> String? in
            let text = collapse(turn.text)
            guard !text.isEmpty else { return nil }
            return "\(turn.speaker == .user ? "User" : "Voice assistant"): \(text)"
        }.joined(separator: "\n")
        return (prompt.isEmpty ? String(context.suffix(400)) : prompt, context)
    }

    /// Seed history for a new session from the chat: text turns only, newest kept (`toLiveHistory`).
    public static func history(_ messages: [ChatMessage], maxMessages: Int = 24,
                               maxCharacters: Int = 6_000) -> [LiveModeHistoryMessage] {
        var result: [LiveModeHistoryMessage] = []
        var budget = maxCharacters
        for message in messages.reversed() where message.voice == nil && message.command == nil {
            let text = String(collapse(message.text).prefix(1_200))
            guard !text.isEmpty else { continue }
            if result.count >= maxMessages || budget - text.count < 0 { break }
            budget -= text.count
            result.insert(LiveModeHistoryMessage(role: message.role == .user ? "user" : "assistant", text: text), at: 0)
        }
        return result
    }
}
