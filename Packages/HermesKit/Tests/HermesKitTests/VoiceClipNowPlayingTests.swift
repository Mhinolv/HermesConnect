import Foundation
import Testing
@testable import HermesKit

// Issue #130 round 2: the Now Playing entry of bubble playback, its owner rules with Hands-Free (#138),
// and the playback mode switch. A fake control center. No test opens MediaPlayer.

@MainActor
private final class FakeClipControls: VoiceClipRemoteControls {
    var shown: [VoiceClipNowPlayingInfo] = []
    var hides: [Bool] = []
    var onCommand: (@MainActor @Sendable (VoiceClipRemoteCommand) -> Void)?

    func show(_ info: VoiceClipNowPlayingInfo,
              onCommand: @escaping @MainActor @Sendable (VoiceClipRemoteCommand) -> Void) {
        shown.append(info)
        self.onCommand = onCommand
    }

    func hide(clearInfo: Bool) { hides.append(clearInfo) }
}

@MainActor
private final class Commands {
    var received: [VoiceClipRemoteCommand] = []
}

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("nowplaying-diag-\(UUID().uuidString).log")
}

@MainActor
@Suite struct VoiceClipNowPlayingTests {
    @Test func theEntryHasHermesTheChatNameTheLengthTheTimeAndTheRate() {
        let info = VoiceClipNowPlayingInfo.make(chatTitle: "Trip", duration: 12, elapsed: 3, playing: true)
        #expect(info == VoiceClipNowPlayingInfo(title: "Hermes", subtitle: "Trip", duration: 12, elapsed: 3, rate: 1))
        let paused = VoiceClipNowPlayingInfo.make(chatTitle: nil, duration: 12, elapsed: 30, playing: false)
        #expect(paused.subtitle == "New Chat")
        #expect(paused.elapsed == 12)
        #expect(paused.rate == 0)
        #expect(VoiceClipNowPlayingInfo.make(chatTitle: "", duration: -1, elapsed: -1, playing: true)
            == VoiceClipNowPlayingInfo(subtitle: "New Chat", duration: 0, elapsed: 0, rate: 1))
    }

    @Test func showThenClearRemovesTheEntryAndWritesTheDiagnostics() {
        let controls = FakeClipControls()
        let file = AudioDiagnosticsFile(url: tempFile())
        let nowPlaying = VoiceClipNowPlaying(controls: controls, owner: NowPlayingOwner(), diagnostics: file)
        nowPlaying.update(.make(chatTitle: "Private name", duration: 5, elapsed: 0, playing: true)) { _ in }
        #expect(nowPlaying.isShown)
        nowPlaying.clear()
        #expect(controls.hides == [true])
        #expect(!nowPlaying.isShown)
        nowPlaying.clear()
        #expect(controls.hides == [true])
        let lines = file.read()
        #expect(lines.count == 2)
        #expect(lines.first?.contains("nowplaying event=show title=Hermes duration=5.0 elapsed=0.0 rate=1") == true)
        #expect(lines.last?.hasSuffix("nowplaying event=clear") == true)
        // The chat name is not in the file.
        #expect(!lines.joined().contains("Private name"))
    }

    @Test func commandsReachTheClipThatOwnsTheEntry() {
        let controls = FakeClipControls()
        let commands = Commands()
        let nowPlaying = VoiceClipNowPlaying(controls: controls, owner: NowPlayingOwner())
        nowPlaying.update(.make(chatTitle: "A", duration: 5, elapsed: 0, playing: true)) { commands.received.append($0) }
        controls.onCommand?(.pause)
        controls.onCommand?(.togglePlayPause)
        controls.onCommand?(.play)
        #expect(commands.received == [.pause, .togglePlayPause, .play])
    }

    /// #138: Hands-Free shows its own entry. A clip does not replace it, clear it, or act on its controls.
    @Test func handsFreeKeepsItsEntry() {
        let owner = NowPlayingOwner()
        let controls = FakeClipControls()
        let commands = Commands()
        let file = AudioDiagnosticsFile(url: tempFile())
        let nowPlaying = VoiceClipNowPlaying(controls: controls, owner: owner, diagnostics: file)
        owner.claim(.handsFree)
        nowPlaying.update(.make(chatTitle: "A", duration: 5, elapsed: 0, playing: true)) { _ in }
        #expect(controls.shown.isEmpty)
        #expect(owner.current == .handsFree)
        nowPlaying.clear()
        #expect(controls.hides.isEmpty)
        #expect(file.read().last?.hasSuffix("nowplaying event=skip owner=handsFree") == true)

        // Hands-Free starts while a clip shows: the clip keeps its targets but ignores them, and keeps the entry.
        owner.release(.handsFree)
        nowPlaying.update(.make(chatTitle: "A", duration: 5, elapsed: 0, playing: true)) { commands.received.append($0) }
        owner.claim(.handsFree)
        controls.onCommand?(.pause)
        #expect(commands.received.isEmpty)
        nowPlaying.clear()
        #expect(controls.hides == [false])
        #expect(owner.current == .handsFree)
    }

    @Test func aNewClipTakesTheEntryFromAnOldClip() {
        let owner = NowPlayingOwner()
        let first = FakeClipControls()
        let second = FakeClipControls()
        let old = VoiceClipNowPlaying(controls: first, owner: owner)
        let new = VoiceClipNowPlaying(controls: second, owner: owner)
        old.update(.make(chatTitle: "A", duration: 5, elapsed: 0, playing: true)) { _ in }
        new.update(.make(chatTitle: "B", duration: 5, elapsed: 0, playing: true)) { _ in }
        old.clear()
        // The old clip does not clear the entry of the new clip.
        #expect(first.hides == [false])
        new.clear()
        #expect(second.hides == [true])
        #expect(owner.current == nil)
    }

    @Test func noControlsDoesNothing() {
        let nowPlaying = VoiceClipNowPlaying(controls: nil, owner: NowPlayingOwner())
        nowPlaying.update(.make(chatTitle: "A", duration: 5, elapsed: 0, playing: true)) { _ in }
        #expect(!nowPlaying.isShown)
        nowPlaying.clear()
    }
}

@Suite struct VoicePlaybackModeTests {
    @Test func theModeIsDefaultUnlessTheEnvironmentAsksForSpokenAudio() {
        #expect(VoicePlaybackMode.from(environment: [:]) == .default)
        #expect(VoicePlaybackMode.from(environment: ["HERMES_PLAYBACK_MODE": "spokenAudio"]) == .spokenAudio)
        #expect(VoicePlaybackMode.from(environment: ["HERMES_PLAYBACK_MODE": "SPOKEN"]) == .spokenAudio)
        #expect(VoicePlaybackMode.from(environment: ["HERMES_PLAYBACK_MODE": "default"]) == .default)
        #expect(VoicePlaybackMode.from(environment: ["HERMES_PLAYBACK_MODE": "junk"]) == .default)
    }
}
