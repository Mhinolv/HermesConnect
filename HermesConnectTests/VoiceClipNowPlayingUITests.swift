import AVFoundation
import Foundation
import HermesKit
import MediaPlayer
import Testing
@testable import HermesConnect

/// Issue #130 round 2: a tapped voice clip played on the van Bluetooth only when music already played.
/// The car starts its Bluetooth audio for the iOS Now Playing app. The clip must be the Now Playing item.
@MainActor
@Suite(.serialized) struct VoiceClipNowPlayingUITests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceClipNowPlayingUITests")

    private func tone(_ name: String, seconds: Double = 2) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try DemoChatTransport.toneWAV(seconds: seconds).write(to: url)
        return url
    }

    /// The bug: the bubble player set no Now Playing item, so the car did not switch to the app.
    @Test func aPlayingBubbleIsTheNowPlayingItemAndStopClearsIt() throws {
        let url = try tone("now-playing-130.wav")
        let player = VoiceMemoPlayer()
        player.play(url)
        defer { player.stop() }
        #expect(player.isPlaying(url))
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        #expect(info?[MPMediaItemPropertyTitle] as? String == "Hermes")
        #expect(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect((info?[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0) > 1.5)
        #expect(MPRemoteCommandCenter.shared().pauseCommand.isEnabled)
        player.stop()
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
    }

    /// Round 2: `.default` mode in place of `.spokenAudio` (a drive A/B with `HERMES_PLAYBACK_MODE`).
    @Test func theBubbleSessionUsesTheDefaultMode() throws {
        let url = try tone("mode-130.wav")
        let player = VoiceMemoPlayer()
        player.play(url)
        defer { player.stop() }
        #expect(AVAudioSession.sharedInstance().mode == .default)
        #expect(AVAudioSession.sharedInstance().category == .playback)
    }

    /// Pause and play from the lock screen, the car or a headset go through the same rules as a tap.
    @Test func remoteCommandsPauseAndPlayTheLoadedClip() throws {
        let url = try tone("commands-130.wav")
        let player = VoiceMemoPlayer()
        player.chatTitle = { "Trip" }
        player.play(url)
        defer { player.stop() }
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String == "Trip")
        player.remoteCommand(.pause)
        #expect(!player.isPlaying(url))
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        player.remoteCommand(.togglePlayPause)
        #expect(player.isPlaying(url))
        player.remoteCommand(.togglePlayPause)
        #expect(!player.isPlaying(url))
        player.remoteCommand(.play)
        #expect(player.isPlaying(url))
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
    }

    /// MediaPlayer can call the handler on its own queue. The handler must not trap there (#127 lesson).
    @Test func theCommandHandlerRunsFromABackgroundQueue() async throws {
        final class Box: @unchecked Sendable { var got: VoiceClipRemoteCommand? }
        let box = Box()
        let action = SystemVoiceClipRemoteControls.commandAction(.pause) { box.got = $0 }
        _ = SystemVoiceClipRemoteControls.commandHandler(.pause) { box.got = $0 }
        let status = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: action()) }
        }
        #expect(status == .success)
        for _ in 0..<200 where box.got == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(box.got == .pause)
    }

    /// #138: while Hands-Free shows its entry, a clip neither replaces it nor clears it.
    @Test func aClipKeepsTheHandsFreeEntry() throws {
        let url = try tone("hands-free-130.wav")
        let handsFree = SystemHandsFreeRemoteControls()
        handsFree.show(HandsFreeNowPlayingInfo(title: "Hermes Hands-Free", subtitle: "Trip")) {}
        defer { handsFree.hide() }
        let player = VoiceMemoPlayer()
        player.play(url)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
            == "Hermes Hands-Free")
        player.stop()
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
            == "Hermes Hands-Free")
        #expect(MPRemoteCommandCenter.shared().stopCommand.isEnabled)
        handsFree.hide()
        #expect(NowPlayingOwner.shared.current == nil)
    }
}
