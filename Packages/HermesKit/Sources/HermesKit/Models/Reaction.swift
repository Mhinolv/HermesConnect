import Foundation

/// Issue #11: the owner's tapback on one bubble. Hermes has no reaction API, so it stays on the phone (D3).
/// One tapback for each message. The raw value is the cache format: do not change it.
public enum Tapback: String, Sendable, Equatable, CaseIterable {
    case heart
    case thumbsUp
    case thumbsDown
    case haha
    case exclamation
    case question

    /// The SF Symbol (issue #11 design notes).
    public var symbolName: String {
        switch self {
        case .heart: "heart.fill"
        case .thumbsUp: "hand.thumbsup.fill"
        case .thumbsDown: "hand.thumbsdown.fill"
        case .haha: "face.smiling"
        case .exclamation: "exclamationmark.2"
        case .question: "questionmark"
        }
    }

    /// The name in menus and VoiceOver actions: "React Heart".
    public var title: String {
        switch self {
        case .heart: "Heart"
        case .thumbsUp: "Thumbs Up"
        case .thumbsDown: "Thumbs Down"
        case .haha: "Ha Ha"
        case .exclamation: "Exclamation"
        case .question: "Question"
        }
    }
}

/// Issue #11: the agent ack on the owner's prompt. It comes from the turn state only (D3).
/// The raw value is the cache format: do not change it.
public enum AgentAck: String, Sendable, Equatable {
    /// The turn runs.
    case seen
    /// `message.complete`.
    case done
    /// The turn ended with an error.
    case failed
    /// The turn ended and the prompt thanks the agent.
    case thanks

    public var symbolName: String {
        switch self {
        case .seen: "eyes"
        case .done: "hand.thumbsup.fill"
        case .failed: "hand.thumbsdown.fill"
        case .thanks: "heart.fill"
        }
    }

    /// The VoiceOver name: "Hermes reacted thumbs up".
    public var spokenName: String {
        switch self {
        case .seen: "eyes"
        case .done: "thumbs up"
        case .failed: "thumbs down"
        case .thanks: "heart"
        }
    }
}

/// The D3 rules for agent acks. Plain functions, so tests cover every case.
public enum AgentAckRules {
    /// Words that thank the agent. "thank" also covers "thank you".
    static let thanksWords: Set<String> = ["thanks", "thank", "thx", "ty", "tysm", "tyvm", "thankyou", "cheers"]
    static let thanksPhrases = ["much appreciated", "appreciate it", "appreciate you", "appreciate that"]

    /// A slash command ("/model gpt") never gets an ack. Leading spaces and new lines do not count.
    public static func isSlashCommand(_ text: String) -> Bool {
        text.drop { $0.isWhitespace }.hasPrefix("/")
    }

    /// The prompt thanks the agent: "Thanks!", "thank you", "thx". "No thanks" does not.
    public static func isThanks(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = lower.split { !$0.isLetter }.map(String.init)
        for (index, word) in words.enumerated() where thanksWords.contains(word) {
            if index > 0, words[index - 1] == "no" { continue }
            return true
        }
        let joined = words.joined(separator: " ")
        return thanksPhrases.contains { joined.contains($0) }
    }

    /// The ack when a turn ends. `reply` is the state of the reply bubble, or `nil` for a turn with no text.
    static func ack(endingWith reply: ChatMessage.Reply?, prompt: String) -> AgentAck? {
        switch reply {
        case .failed: .failed
        case .interrupted: nil
        case .complete, .streaming, nil: isThanks(prompt) ? .thanks : .done
        }
    }
}
