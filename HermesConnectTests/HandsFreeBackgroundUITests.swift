import Foundation
import HermesKit
import MediaPlayer
import Testing
@testable import HermesConnect

// Issue #138: Hands-Free goes on with the screen locked and in other apps. Now Playing and the lock screen Stop.
// Fakes only: no test opens the microphone, registers real remote commands or reaches a server.

@MainActor
private final class FakeMic: VoiceModeMicrophone {
    var access: VoiceModeMicrophoneAccess = .granted
    private(set) var deactivations = 0
    private(set) var isOpen = false

    func requestAccess() async -> Bool { true }
    func activate() throws {}
    func deactivate() { deactivations += 1 }
    func startClip(url _: URL) throws { isOpen = true }
    func stopClip() -> TimeInterval {
        isOpen = false
        return 1
    }
    func discardClip() { isOpen = false }
    func level() -> Float { -60 }
}

private final class SilentPlayer: StreamedSpeechPlaying, @unchecked Sendable {
    func begin(sampleRate _: Double) throws {}
    func enqueue(_: Data) {}
    func drain() async {}
    func playClip(_: SpokenAudio) async throws {}
    func stop() {}
}

@MainActor
private final class FakeControls: HandsFreeRemoteControls {
    private(set) var shown: HandsFreeNowPlayingInfo?
    private(set) var hides = 0
    private var onStop: (@MainActor @Sendable () -> Void)?

    func show(_ info: HandsFreeNowPlayingInfo, onStop: @escaping @MainActor @Sendable () -> Void) {
        shown = info
        self.onStop = onStop
    }

    func hide() {
        shown = nil
        onStop = nil
        hides += 1
    }

    /// The owner taps Stop on the lock screen.
    func tapStop() { onStop?() }
}

private struct NoSpeech: Error {}

@MainActor
@Suite struct HandsFreeBackgroundUITests {
    private func rig() -> (VoiceTabModel, FakeMic, FakeControls) {
        let mic = FakeMic()
        let controls = FakeControls()
        let suite = "hands-free-bg-\(UUID().uuidString)"
        let model = VoiceTabModel(sessions: ChatLaunch.makeOfflineSessions(), store: VoiceTargetStore(suite: suite),
                                  remoteControls: controls) {
            VoiceModeSessionModel(controller: VoiceModeController(
                microphone: mic, player: SilentPlayer(), makeSpeech: { _ in throw NoSpeech() },
                makeClipURL: { FileManager.default.temporaryDirectory.appending(path: "hf-bg-\(UUID()).m4a") },
                removeFile: { _ in }, autoTick: false))
        }
        return (model, mic, controls)
    }

    /// Observation sends the change on a later main actor turn.
    private func settle(_ until: () -> Bool) async throws {
        for _ in 0..<100 where !until() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func nowPlayingShowsWhileTheSessionRunsAndGoesAwayAtTheEnd() async throws {
        let (model, mic, controls) = rig()
        #expect(model.nowPlaying == nil)
        await model.ringTap()
        try await settle { controls.shown != nil }
        #expect(controls.shown == HandsFreeNowPlayingInfo(title: "Hermes Hands-Free", subtitle: "New Chat"))
        model.end()
        try await settle { controls.shown == nil }
        #expect(controls.shown == nil)
        #expect(controls.hides == 1)
        #expect(!mic.isOpen)
    }

    @Test func stopOnTheLockScreenEndsTheSessionAndClosesTheMic() async throws {
        let (model, mic, controls) = rig()
        await model.ringTap()
        try await settle { controls.shown != nil }
        #expect(mic.isOpen)
        controls.tapStop()
        #expect(model.state == .ended(.end))
        #expect(!model.isRunning)
        #expect(!mic.isOpen)
        #expect(mic.deactivations == 1)
        try await settle { controls.shown == nil }
        #expect(controls.hides == 1)
    }

    @Test func aSilenceEndInTheBackgroundAlsoRemovesTheControls() async throws {
        let (model, _, controls) = rig()
        await model.ringTap()
        try await settle { controls.shown != nil }
        // The engine ends by itself, with no view and no tap: the same path as the 30 s silence end.
        model.controller?.end()
        try await settle { controls.shown == nil }
        #expect(controls.hides == 1)
        #expect(model.stoppedAt != nil)
    }

    @Test func aRunningSessionKeepsTheLinkForTheForegroundReconnect() async throws {
        let (model, _, controls) = rig()
        let left = Date.now.addingTimeInterval(-600)
        #expect(model.awakeAway(backgroundedAt: left) >= 600)
        await model.ringTap()
        try await settle { controls.shown != nil }
        #expect(model.awakeAway(backgroundedAt: left) == 0)
        model.end()
        try await settle { controls.shown == nil }
        // The session ended just now: only the time after the end counts.
        #expect(model.awakeAway(backgroundedAt: left) < 5)
    }

    /// MediaPlayer calls the handler on its own queue. The handler must not trap there (#127 lesson).
    @Test func theStopHandlerRunsFromABackgroundQueue() async throws {
        final class Flag: @unchecked Sendable { var stopped = false }
        let flag = Flag()
        let action = SystemHandsFreeRemoteControls.stopAction { flag.stopped = true }
        // The real handler wraps the same action. Its block is also made off the main actor.
        _ = SystemHandsFreeRemoteControls.stopHandler { flag.stopped = true }
        let status = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: action())
            }
        }
        #expect(status == .success)
        try await settle { flag.stopped }
        #expect(flag.stopped)
    }

    @Test func theNowPlayingEntryHasTheTitleAndTheChatName() {
        let info = SystemHandsFreeRemoteControls.nowPlayingInfo(
            HandsFreeNowPlayingInfo(title: "Hermes Hands-Free", subtitle: "Trip"))
        #expect(info[MPMediaItemPropertyTitle] as? String == "Hermes Hands-Free")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Trip")
        #expect(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true)
    }
}
