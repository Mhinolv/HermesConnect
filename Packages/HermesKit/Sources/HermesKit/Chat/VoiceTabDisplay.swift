import Foundation

// Issue #101: what the Voice tab and the mini bar show for each state of the #96 engine.
// The views only draw it. No loop logic here and no loop logic in the views.

/// The look of the Quiet Ring (design notes table).
public enum VoiceRingStyle: Sendable, Equatable {
    /// Still, `.tertiaryLabel`, with the mic symbol.
    case idle
    /// `.systemBlue`, bends with the mic level.
    case listening
    /// Gray at 70 %, one arc turns (1.8 s a turn).
    case working
    /// `.label`, bends with the output level.
    case speaking
    /// Dotted.
    case muted
    /// Dotted and gray.
    case paused
}

/// The button under the title in the Paused and error states.
public enum VoiceTabAction: Sendable, Equatable {
    case resume
    case tryAgain
    case openSettings

    public var title: String {
        switch self {
        case .resume: "Resume"
        case .tryAgain: "Try Again"
        case .openSettings: "Open Settings"
        }
    }
}

/// What a tap on the ring, or Magic Tap, does in a state.
public enum VoiceRingCommand: Sendable, Equatable {
    case start
    /// Barge-in: the reply stops and listening starts.
    case interrupt
    case resume
    /// Magic Tap only: the clip ends now and goes to Hermes.
    case send
    case none
}

public struct VoiceTabDisplay: Sendable, Equatable {
    public var ring: VoiceRingStyle
    public var title: String
    public var subtitle: String?
    public var action: VoiceTabAction?
    /// `true` from start to end: "In <chat>", Mute and End show. Idle shows the mode picker and "To <chat>".
    public var isSession: Bool
    /// The Mute key is filled.
    public var muteOn: Bool
    /// `false` when Mute does nothing (Paused, error).
    public var muteEnabled: Bool
    /// Issue #102: a live session. End uses `phone.down.fill` and the live capsule shows.
    public var isLive = false
    /// Issue #120: the subtitle is the tool line ("Using web_search…"). One line with a middle cut.
    public var showsTool = false

    /// The VoiceOver label of the ring: "Voice Mode, <state>". Issue #120: the tool line follows the state.
    public var ringAccessibilityLabel: String {
        guard showsTool, let subtitle else { return "Voice Mode, \(title)" }
        return "Voice Mode, \(title), \(subtitle)"
    }

    /// Seconds of thinking before the sub line says "Still working…".
    public static let stillWorkingSeconds = 10

    /// - Parameters:
    ///   - afterBargeIn: a barge-in stopped the last reply, and no clip ended since then.
    ///   - tool: issues #120 and #129, the last tool of the turn in the target chat ("Using…" or "Used…").
    public static func make(state: VoiceModeState, muted: Bool, thinkingSeconds: Int,
                            afterBargeIn: Bool = false, tool: ChatToolActivity? = nil) -> VoiceTabDisplay {
        func session(_ ring: VoiceRingStyle, _ title: String, _ subtitle: String?, action: VoiceTabAction? = nil,
                     muteEnabled: Bool = true) -> VoiceTabDisplay {
            VoiceTabDisplay(ring: ring, title: title, subtitle: subtitle, action: action, isSession: true,
                            muteOn: muted, muteEnabled: muteEnabled)
        }
        switch state {
        case .idle:
            return idle("Hermes answers out loud")
        case .ended(let reason):
            switch reason {
            case .end: return idle("Hermes answers out loud")
            case .stopWord: return idle("Voice mode ended when you said “stop”")
            case .silence: return idle("Voice mode ended after 30 s of silence")
            }
        case .listening:
            return session(.listening, "Listening", afterBargeIn ? "Reply stopped" : "Stops after a short pause")
        case .interrupted:
            return session(.listening, "Listening", "Reply stopped")
        case .transcribing:
            return session(.working, "Transcribing…", workingLine(thinkingSeconds, counting: false))
        case .thinking:
            if let tool {
                var display = session(.working, "Thinking…", tool.line)
                display.showsTool = true
                return display
            }
            return session(.working, "Thinking…", workingLine(thinkingSeconds, counting: true))
        case .speaking:
            return session(.speaking, "Speaking", "Tap or speak to interrupt")
        case .muted:
            return session(.muted, "Muted", "Tap Mute to listen again")
        case .paused(let reason):
            let line = switch reason {
            case .call: "A call paused voice mode"
            case .background: "Voice mode pauses when Hermes is not on screen"
            case .lock: "Voice mode pauses when iPhone locks"
            }
            return session(.paused, "Paused", line, action: .resume, muteEnabled: false)
        case .error(let failure):
            switch failure {
            case .microphoneOff:
                return session(.paused, "Microphone Off", "Turn on Microphone for Hermes in Settings",
                               action: .openSettings, muteEnabled: false)
            case .offline:
                return session(.paused, "Offline", "Your clip waits in the chat",
                               action: .tryAgain, muteEnabled: false)
            case .turnFailed:
                return session(.paused, "Not Delivered", "Hermes did not get the last turn",
                               action: .tryAgain, muteEnabled: false)
            case .speakFailed:
                return session(.paused, "Reply Not Spoken", "The reply is in the chat",
                               action: .tryAgain, muteEnabled: false)
            }
        }
    }

    private static func idle(_ subtitle: String) -> VoiceTabDisplay {
        VoiceTabDisplay(ring: .idle, title: "Tap to Talk", subtitle: subtitle, action: nil, isSession: false,
                        muteOn: false, muteEnabled: false)
    }

    private static func workingLine(_ seconds: Int, counting: Bool) -> String {
        guard counting else { return "Hermes is working" }
        if seconds >= stillWorkingSeconds { return "Still working…" }
        return "Hermes is working · \(seconds) s"
    }

    /// A tap on the ring. It never ends a clip early: only Magic Tap does that.
    public static func ringTap(_ state: VoiceModeState) -> VoiceRingCommand {
        switch state {
        case .idle, .ended: .start
        case .speaking: .interrupt
        case .paused, .error: .resume
        case .listening, .transcribing, .thinking, .interrupted, .muted: .none
        }
    }

    /// Magic Tap (two-finger double tap): starts, sends or interrupts (design notes, VoiceOver).
    public static func magicTap(_ state: VoiceModeState) -> VoiceRingCommand {
        state == .listening ? .send : ringTap(state)
    }

    /// The one state that VoiceOver announces.
    public static func announcement(_ state: VoiceModeState) -> String? {
        state == .thinking ? "Thinking" : nil
    }
}

// MARK: Target chat

/// Where the voice turns go (design notes, "Target chat"). The choice stays until the owner changes it.
public enum VoiceTarget: Sendable, Equatable, Codable {
    /// The chat that was open last, else the most recent chat.
    case active
    /// A new chat. It starts when the owner speaks.
    case new
    /// A chat that the owner picked in "Choose Chat…". `server` is the active server at that time.
    case chosen(id: String, title: String, server: UUID?)
}

/// Keeps the target choice. A chosen chat of another server reads as `.active`.
public struct VoiceTargetStore: Sendable {
    public static let defaultsKey = "voiceTarget"
    private let suite: String?

    /// `suite` nil is `UserDefaults.standard`.
    public init(suite: String? = nil) {
        self.suite = suite
    }

    private var defaults: UserDefaults { suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load(server: UUID?) -> VoiceTarget {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let target = try? JSONDecoder().decode(VoiceTarget.self, from: data) else { return .active }
        if case .chosen(_, _, let owner) = target, owner != server { return .active }
        return target
    }

    public func save(_ target: VoiceTarget) {
        defaults.set(try? JSONEncoder().encode(target), forKey: Self.defaultsKey)
    }
}

public enum VoiceTargetResolver {
    /// The session id of "Active Chat": the open chat, else the chat that was open last, else the newest chat.
    /// `nil` means a new chat.
    public static func activeSessionId(open: String?, lastActive: String?, rows: [SessionListItem]) -> String? {
        open ?? lastActive ?? rows.first?.id
    }
}
