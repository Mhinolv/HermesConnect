import HermesKit
import MediaPlayer

/// Issue #130 round 2: the Now Playing entry ("Hermes", the chat name, length, time, rate) and the play, pause and
/// play/pause commands of a voice clip. A car stereo starts its Bluetooth audio for the Now Playing app.
/// Skip and seek stay off. `NowPlayingOwner` keeps the Hands-Free entry of #138 first.
///
/// MediaPlayer can call the handlers on its own queue. A block made in a `@MainActor` type gets main actor
/// isolation, and the Swift runtime check traps off the main thread (#127 lesson). So `commandHandler` is
/// `nonisolated`, and the block only starts a main actor task.
@MainActor
final class SystemVoiceClipRemoteControls: VoiceClipRemoteControls {
    private var targets: [(MPRemoteCommand, Any)] = []
    /// The current handler. The targets read it, so an update needs no new targets.
    private var onCommand: (@MainActor @Sendable (VoiceClipRemoteCommand) -> Void)?

    func show(_ info: VoiceClipNowPlayingInfo,
              onCommand: @escaping @MainActor @Sendable (VoiceClipRemoteCommand) -> Void) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.nowPlayingInfo(info)
        self.onCommand = onCommand
        let center = MPRemoteCommandCenter.shared()
        let commands: [(MPRemoteCommand, VoiceClipRemoteCommand)] = [
            (center.playCommand, .play), (center.pauseCommand, .pause), (center.togglePlayPauseCommand, .togglePlayPause),
        ]
        for (command, _) in commands { command.isEnabled = true }
        for command in [center.stopCommand, center.nextTrackCommand, center.previousTrackCommand,
                        center.skipForwardCommand, center.skipBackwardCommand, center.changePlaybackPositionCommand] {
            command.isEnabled = false
        }
        guard targets.isEmpty else { return }
        for (command, name) in commands {
            let handler = Self.commandHandler(name) { [weak self] name in self?.onCommand?(name) }
            targets.append((command, command.addTarget(handler: handler)))
        }
    }

    func hide(clearInfo: Bool) {
        if clearInfo { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        for (command, target) in targets {
            command.removeTarget(target)
            // With the entry kept, Hands-Free owns the controls: leave them as it set them.
            if clearInfo { command.isEnabled = false }
        }
        targets = []
        onCommand = nil
    }

    nonisolated static func nowPlayingInfo(_ info: VoiceClipNowPlayingInfo) -> [String: Any] {
        [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.subtitle,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
    }

    /// The handler of one command. It runs on any queue.
    nonisolated static func commandHandler(_ name: VoiceClipRemoteCommand,
                                           _ perform: @escaping @MainActor @Sendable (VoiceClipRemoteCommand) -> Void)
        -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        let action = commandAction(name, perform)
        return { @Sendable _ in action() }
    }

    /// The work of the handler, with no event (tests cannot make an `MPRemoteCommandEvent`).
    nonisolated static func commandAction(_ name: VoiceClipRemoteCommand,
                                          _ perform: @escaping @MainActor @Sendable (VoiceClipRemoteCommand) -> Void)
        -> @Sendable () -> MPRemoteCommandHandlerStatus {
        { @Sendable in
            Task { @MainActor in perform(name) }
            return .success
        }
    }
}
