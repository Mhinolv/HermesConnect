import Foundation

// Issue #130 round 2: a tapped voice clip played on the van Bluetooth only when music already played. A car stereo
// starts its Bluetooth audio for the iOS Now Playing app. So bubble playback and auto-play publish a Now Playing item
// and the play, pause and play/pause commands. The app gives `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`.
// Tests use a fake.

/// The mode of the bubble playback session. `.default` unless `HERMES_PLAYBACK_MODE=spokenAudio` (a drive A/B).
public enum VoicePlaybackMode: String, Sendable, Equatable {
    case `default`
    case spokenAudio

    public static let environmentKey = "HERMES_PLAYBACK_MODE"

    public static func from(environment: [String: String]) -> VoicePlaybackMode {
        switch environment[environmentKey]?.lowercased() {
        case "spokenaudio", "spoken": .spokenAudio
        default: .default
        }
    }

    /// The mode of this process.
    public static let current = from(environment: ProcessInfo.processInfo.environment)
}

/// The Now Playing entry of a voice clip: "Hermes", the chat name, the clip length, the clip time and the rate.
public struct VoiceClipNowPlayingInfo: Equatable, Sendable {
    public static let defaultTitle = "Hermes"
    /// The subtitle of a chat with no title.
    public static let newChatTitle = "New Chat"

    public let title: String
    public let subtitle: String
    public let duration: TimeInterval
    public let elapsed: TimeInterval
    /// 1 while the clip plays, 0 while it is paused.
    public let rate: Double

    public init(title: String = defaultTitle, subtitle: String, duration: TimeInterval, elapsed: TimeInterval,
                rate: Double) {
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
        self.elapsed = elapsed
        self.rate = rate
    }

    public static func make(chatTitle: String?, duration: TimeInterval, elapsed: TimeInterval,
                            playing: Bool) -> VoiceClipNowPlayingInfo {
        let name = chatTitle.flatMap { $0.isEmpty ? nil : $0 } ?? newChatTitle
        let length = max(0, duration)
        return VoiceClipNowPlayingInfo(subtitle: name, duration: length, elapsed: min(max(0, elapsed), length),
                                       rate: playing ? 1 : 0)
    }

    /// The diagnostic text. The chat name is not in it.
    var diagnostic: String {
        String(format: "title=%@ duration=%.1f elapsed=%.1f rate=%.0f", title, duration, elapsed, rate)
    }
}

/// A lock screen, car or headset control of a voice clip.
public enum VoiceClipRemoteCommand: String, Sendable, Equatable {
    case play
    case pause
    case togglePlayPause
}

/// The Now Playing entry and the remote commands of a voice clip.
@MainActor
public protocol VoiceClipRemoteControls: AnyObject {
    /// Shows or updates `info` and turns on play, pause and play/pause. A command calls `onCommand` on the main actor.
    func show(_ info: VoiceClipNowPlayingInfo,
              onCommand: @escaping @MainActor @Sendable (VoiceClipRemoteCommand) -> Void)
    /// Removes the command targets. With `clearInfo`, it removes the entry too.
    func hide(clearInfo: Bool)
}

/// Who shows the one Now Playing entry of the app. Hands-Free and Live (#138) win over a voice clip, so a clip
/// never replaces or clears the Hands-Free entry, and a clip control does nothing while Hands-Free shows.
@MainActor
public final class NowPlayingOwner {
    public enum Claimant: Equatable, Sendable {
        case handsFree
        case voiceClip(ObjectIdentifier)
    }

    public static let shared = NowPlayingOwner()

    public private(set) var current: Claimant?

    public init() {}

    /// Returns `false` when a voice clip asks while Hands-Free shows.
    @discardableResult
    public func claim(_ claimant: Claimant) -> Bool {
        if case .voiceClip = claimant, current == .handsFree { return false }
        current = claimant
        return true
    }

    /// Returns `true` when `claimant` showed the entry. Only then may it clear the entry.
    @discardableResult
    public func release(_ claimant: Claimant) -> Bool {
        guard current == claimant else { return false }
        current = nil
        return true
    }

    public func owns(_ claimant: Claimant) -> Bool { current == claimant }
}

/// The Now Playing state of the bubble player. It writes each change to the playback diagnostics.
@MainActor
public final class VoiceClipNowPlaying {
    private let controls: (any VoiceClipRemoteControls)?
    private let owner: NowPlayingOwner
    private let diagnostics: AudioDiagnosticsFile?
    private let log = HermesLog(category: "audio")
    /// `true` while this clip has command targets.
    public private(set) var isShown = false

    /// - Parameter owner: `nil` uses `NowPlayingOwner.shared`, which Hands-Free uses too.
    public init(controls: (any VoiceClipRemoteControls)?, owner: NowPlayingOwner? = nil,
                diagnostics: AudioDiagnosticsFile? = nil) {
        self.controls = controls
        self.owner = owner ?? .shared
        self.diagnostics = diagnostics
    }

    private var claimant: NowPlayingOwner.Claimant { .voiceClip(ObjectIdentifier(self)) }

    /// The clip started, paused, played again or moved. A command runs `onCommand` only while this clip owns the entry.
    public func update(_ info: VoiceClipNowPlayingInfo,
                       onCommand: @escaping @MainActor @Sendable (VoiceClipRemoteCommand) -> Void) {
        guard let controls else { return }
        guard owner.claim(claimant) else { return report("event=skip owner=handsFree") }
        let owner = owner
        let claimant = claimant
        controls.show(info) { command in
            guard owner.owns(claimant) else { return }
            onCommand(command)
        }
        isShown = true
        report("event=show " + info.diagnostic + " commands=play,pause,togglePlayPause")
    }

    /// The clip stopped or ended. The entry goes away unless Hands-Free shows it now.
    public func clear() {
        guard let controls, isShown else { return }
        isShown = false
        let owned = owner.release(claimant)
        controls.hide(clearInfo: owned)
        report(owned ? "event=clear" : "event=clear info=kept owner=handsFree")
    }

    /// A remote command arrived (diagnostics only).
    public func commandReceived(_ command: VoiceClipRemoteCommand) {
        report("event=command name=" + command.rawValue)
    }

    private func report(_ text: String) {
        log.notice("nowplaying " + text)
        diagnostics?.append("nowplaying " + text)
    }
}
