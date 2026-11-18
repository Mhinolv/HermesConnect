import Foundation

// Issue #102: live mode in the Voice tab. What the Quiet Ring, the live capsule and the mini bar show for
// each state of the #98 `LiveModeController`. The engine does not change. The views only draw this.

/// "Hands-Free | Live" (the mode picker of the Voice tab).
public enum VoiceTabMode: String, Sendable, Equatable, Codable, CaseIterable {
    case handsFree
    case live
}

/// What `GET /api/audio/voice-live/status` said for the active server.
public enum LiveAvailability: Sendable, Equatable {
    /// No answer yet.
    case checking
    case available
    /// `available: false`. `reason` is the server text, if any.
    case unavailable(reason: String?)
    /// An older Hermes with no `voice-live` routes.
    case olderServer
    /// The status call failed, or the app is offline.
    case failed

    public init(status: VoiceLiveStatus?) {
        guard let status else { self = .olderServer; return }
        self = status.available ? .available : .unavailable(reason: status.reason)
    }

    public var isAvailable: Bool { self == .available }

    /// The line under the picker. `nil` while the check runs.
    /// - Parameter selected: the Live segment is on. The cost line shows only then (frame 01 has no line).
    public func line(server: String?, selected: Bool) -> String? {
        let name = server.flatMap { $0.isEmpty ? nil : $0 } ?? "this server"
        switch self {
        case .checking: return nil
        case .available: return selected ? LiveModeFormat.costCaption : nil
        case .unavailable(let reason):
            let text = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? "Live is not available on \(name)." : text
        case .olderServer: return LiveModeStatusText.olderServer
        case .failed: return "Live is not available on \(name)."
        }
    }
}

/// Keeps the last mode for each server (design notes, "Mode picker").
public struct VoiceTabModeStore: Sendable {
    public static let defaultsKey = "voiceTabMode"
    private let suite: String?

    /// `suite` nil is `UserDefaults.standard`.
    public init(suite: String? = nil) {
        self.suite = suite
    }

    private var defaults: UserDefaults { suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private func key(_ server: UUID?) -> String { server?.uuidString ?? "none" }

    public func load(server: UUID?) -> VoiceTabMode {
        let modes = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        return modes[key(server)].flatMap(VoiceTabMode.init(rawValue:)) ?? .handsFree
    }

    public func save(_ mode: VoiceTabMode, server: UUID?) {
        var modes = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        modes[key(server)] = mode.rawValue
        defaults.set(modes, forKey: Self.defaultsKey)
    }
}

extension VoiceTabDisplay {
    /// The Voice tab in live mode (design notes #102, state table). `nil` when no live session runs.
    /// - Parameters:
    ///   - speaking: Hermes talks (the remote audio plays). Else the owner has the floor: the ring is blue.
    ///   - failure: the error line of the failed state.
    public static func live(phase: LiveModePhase, muted: Bool, speaking: Bool, idleWarning: Bool,
                            stillWorking: Bool, failure: String? = nil) -> VoiceTabDisplay? {
        func session(_ ring: VoiceRingStyle, _ title: String, _ subtitle: String?, action: VoiceTabAction? = nil,
                     muteEnabled: Bool = true) -> VoiceTabDisplay {
            VoiceTabDisplay(ring: ring, title: title, subtitle: subtitle, action: action, isSession: true,
                            muteOn: muted, muteEnabled: muteEnabled, isLive: true)
        }
        switch phase {
        case .idle:
            return nil
        case .connecting:
            return session(.working, "Connecting…", nil, muteEnabled: false)
        case .reconnecting:
            return session(.working, "Reconnecting…", nil)
        case .working:
            return session(.working, "Hermes is working…", stillWorking ? "Still working…" : nil)
        case .failed:
            return session(.paused, "Live mode stopped", failure, action: .tryAgain, muteEnabled: false)
        case .live:
            if muted { return session(.muted, "Muted", "Tap Mute to listen again") }
            let line = idleWarning ? "Ending soon. Speak to continue." : "Speak any time"
            return session(speaking ? .speaking : .listening, "Live", line)
        }
    }

    /// Live: a tap on the ring does nothing (the owner speaks any time). "Try Again" is the button.
    /// Magic Tap mutes (design notes, VoiceOver).
    public static func liveRingTap(_ phase: LiveModePhase) -> VoiceRingCommand {
        phase == .failed ? .resume : .none
    }

    /// The VoiceOver label in live mode: "Live Mode, <state>, <elapsed>".
    public func liveAccessibilityLabel(elapsedSeconds: Int) -> String {
        let state = subtitle.map { "\(title). \($0)" } ?? title
        return "Live Mode, \(state), \(LiveModeFormat.elapsed(elapsedSeconds))"
    }

    /// The mini bar title in live mode: "Live 2:14".
    public static func liveMiniTitle(elapsedSeconds: Int) -> String {
        "Live \(LiveModeFormat.elapsed(elapsedSeconds))"
    }

    /// The live states that VoiceOver announces: Hermes working only. The end toast is announced on its own.
    public static func liveAnnouncement(_ phase: LiveModePhase) -> String? {
        phase == .working ? "Hermes is working" : nil
    }
}
