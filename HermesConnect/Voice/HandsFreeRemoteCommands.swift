import HermesKit
import MediaPlayer

/// Issue #138: the Now Playing entry ("Hermes Hands-Free", the chat name) and the lock screen controls of a
/// running session. Pause, Stop and play/pause each end the session and close the microphone. Skip and seek
/// stay off. `hide()` removes the entry and the controls when the session ends.
///
/// MediaPlayer calls the handlers on its own queue. A block made in a `@MainActor` type gets main actor isolation,
/// and the Swift runtime check traps off the main thread (#127 lesson). So `stopHandler` is `nonisolated`, and the
/// block only starts a main actor task.
@MainActor
final class SystemHandsFreeRemoteControls: HandsFreeRemoteControls {
    private var targets: [(MPRemoteCommand, Any)] = []

    func show(_ info: HandsFreeNowPlayingInfo, onStop: @escaping @MainActor @Sendable () -> Void) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.nowPlayingInfo(info)
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        let handler = Self.stopHandler(onStop)
        for command in [center.pauseCommand, center.stopCommand, center.togglePlayPauseCommand] {
            command.isEnabled = true
            targets.append((command, command.addTarget(handler: handler)))
        }
        for command in [center.playCommand, center.nextTrackCommand, center.previousTrackCommand,
                        center.skipForwardCommand, center.skipBackwardCommand, center.changePlaybackPositionCommand] {
            command.isEnabled = false
        }
    }

    func hide() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets = []
    }

    nonisolated static func nowPlayingInfo(_ info: HandsFreeNowPlayingInfo) -> [String: Any] {
        [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.subtitle,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
    }

    /// The handler of the three stop controls. It runs on any queue.
    nonisolated static func stopHandler(_ onStop: @escaping @MainActor @Sendable () -> Void)
        -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        let action = stopAction(onStop)
        return { @Sendable _ in action() }
    }

    /// The work of the handler, with no event (tests cannot make an `MPRemoteCommandEvent`).
    nonisolated static func stopAction(_ onStop: @escaping @MainActor @Sendable () -> Void)
        -> @Sendable () -> MPRemoteCommandHandlerStatus {
        { @Sendable in
            Task { @MainActor in onStop() }
            return .success
        }
    }
}
