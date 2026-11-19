import Foundation

// Issue #138: a Hands-Free or Live session that the owner started keeps running on screen lock and in other apps.
// The audio session and the voice engine stay active, so iOS does not suspend the app. This file has the rules
// that do not need iOS: the Now Playing text and the time away for the foreground reconnect.

/// The Now Playing entry of a running session. The lock screen shows it with one Stop control.
public struct HandsFreeNowPlayingInfo: Sendable, Equatable {
    public var title: String
    /// The chat name.
    public var subtitle: String

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    public static let handsFreeTitle = "Hermes Hands-Free"
    public static let liveTitle = "Hermes Live"

    /// The entry while a session runs. `nil` when no session runs: the lock screen controls go away.
    public static func make(handsFree: Bool, live: Bool, chatTitle: String) -> HandsFreeNowPlayingInfo? {
        if live { return HandsFreeNowPlayingInfo(title: liveTitle, subtitle: chatTitle) }
        if handsFree { return HandsFreeNowPlayingInfo(title: handsFreeTitle, subtitle: chatTitle) }
        return nil
    }
}

/// The Now Playing entry and the lock screen controls (pause, stop, play/pause). Each control ends the session.
/// The app gives `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`. Tests give a fake.
@MainActor
public protocol HandsFreeRemoteControls: AnyObject {
    /// Shows `info`. A lock screen control calls `onStop` on the main actor.
    func show(_ info: HandsFreeNowPlayingInfo, onStop: @escaping @MainActor @Sendable () -> Void)
    /// Removes the entry and the controls.
    func hide()
}

/// Issue #138: the time that the app could be suspended, for `AppModel.foregroundAction`.
/// While a session runs, iOS keeps the app and its SSH link alive. The clock starts at the later of the move to the
/// background and the end of the session in the background.
public enum HandsFreeAwake {
    /// - Parameters:
    ///   - backgroundedAt: when the app went to the background.
    ///   - stoppedAt: when the last session stopped, `nil` if none stopped.
    ///   - running: a session runs now.
    public static func away(backgroundedAt: Date, stoppedAt: Date?, running: Bool, now: Date) -> TimeInterval {
        if running { return 0 }
        let start = max(backgroundedAt, stoppedAt ?? backgroundedAt)
        return max(0, now.timeIntervalSince(start))
    }
}
