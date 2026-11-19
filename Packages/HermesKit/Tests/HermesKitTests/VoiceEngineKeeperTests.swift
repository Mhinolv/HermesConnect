import Foundation
import Synchronization
import Testing
@testable import HermesKit

// Issue #135: the Hands-Free engine starts again after the HFP route change, with a tap in the new format.
// A fake engine. No test opens real audio hardware.

@MainActor
private final class FakeCaptureEngine: VoiceCaptureEngine {
    var isRunning = false
    var inputFormat = VoiceInputFormat(sampleRate: 48_000, channels: 1)
    var startError: (any Error)?
    private(set) var taps: [VoiceInputFormat] = []
    private(set) var starts = 0

    func prepareVoiceProcessing() {}

    func installTap() { taps.append(inputFormat) }

    func start() throws {
        if let startError { throw startError }
        starts += 1
        isRunning = true
    }

    /// The HFP route comes up: the input format changes and the engine stops (as `AVAudioEngine` does).
    func routeToHFP() {
        inputFormat = VoiceInputFormat(sampleRate: 16_000, channels: 1)
        isRunning = false
    }
}

private struct EngineFailure: Error {}

@MainActor
private struct KeeperRig {
    let engine = FakeCaptureEngine()
    let file: AudioDiagnosticsFile
    let route: VoiceAudioRoute
    let clock = FakeVoiceClock()
    let keeper: VoiceEngineKeeper

    init() {
        file = AudioDiagnosticsFile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("keeper-\(UUID().uuidString).log"))
        route = VoiceAudioRoute(session: FakeVoiceAudioSession(outputs: ["BluetoothHFP"]), environment: [:],
                                diagnostics: file)
        let clock = clock
        keeper = VoiceEngineKeeper(engine: engine, route: route, clock: { clock.now })
    }

    var lines: [String] { file.read() }
}

@MainActor
struct VoiceEngineKeeperTests {
    @Test func startPutsTheTapInTheInputFormatThenStarts() throws {
        let rig = KeeperRig()
        try rig.keeper.start()
        #expect(rig.engine.taps == [VoiceInputFormat(sampleRate: 48_000, channels: 1)])
        #expect(rig.engine.isRunning)
        #expect(rig.lines.contains { $0.contains("handsfree event=tap rate=48000 ch=1 out=BluetoothHFP") })
        #expect(rig.lines.last?.contains("handsfree event=engine") == true)
    }

    /// The device log of 2026-11-18: the clip opened after the HFP change stopped the engine.
    @Test func aClipAfterTheHFPChangeStartsTheEngineWithTheNewFormat() throws {
        let rig = KeeperRig()
        rig.keeper.active = true
        try rig.keeper.start()
        rig.engine.routeToHFP()
        try rig.keeper.ensureRunning()
        #expect(rig.engine.isRunning)
        #expect(rig.engine.taps.last == VoiceInputFormat(sampleRate: 16_000, channels: 1))
        #expect(rig.keeper.tapFormat == VoiceInputFormat(sampleRate: 16_000, channels: 1))
        #expect(rig.engine.starts == 2)
    }

    @Test func aFormatChangeOnARunningEngineGetsANewTap() throws {
        let rig = KeeperRig()
        try rig.keeper.start()
        rig.engine.inputFormat = VoiceInputFormat(sampleRate: 24_000, channels: 1)
        try rig.keeper.ensureRunning()
        #expect(rig.engine.taps.last?.sampleRate == 24_000)
        #expect(rig.engine.starts == 1)
        // Same format, engine running: nothing to do.
        try rig.keeper.ensureRunning()
        #expect(rig.engine.taps.count == 2)
    }

    @Test func failuresWriteTheDomainAndCode() {
        let rig = KeeperRig()
        rig.engine.startError = NSError(domain: NSOSStatusErrorDomain, code: 561_017_449,
                                        userInfo: [NSLocalizedDescriptionKey: "secret text"])
        #expect(throws: NSError.self) { try rig.keeper.start() }
        let fail = rig.lines.first { $0.contains("event=fail") }
        #expect(fail?.contains("event=fail step=engine domain=NSOSStatusErrorDomain code=561017449 out=") == true)
        #expect(!rig.lines.joined().contains("secret text"))

        let bad = KeeperRig()
        bad.engine.inputFormat = VoiceInputFormat(sampleRate: 0, channels: 0)
        #expect(throws: VoiceInputFormatError.self) { try bad.keeper.start() }
        #expect(bad.engine.taps.isEmpty)
        #expect(bad.lines.contains { $0.contains("event=fail step=tap domain=") })
    }

    @Test func sessionFailureIsLogged() {
        final class FailingSession: VoiceAudioSession, @unchecked Sendable {
            var routeState: VoiceAudioRouteState { VoiceAudioRouteState(outputs: ["Speaker"]) }
            func setVoiceCategory(mode: VoiceAudioMode) throws {}
            func setActive(_ active: Bool) throws { throw NSError(domain: NSOSStatusErrorDomain, code: 560_557_684) }
            func overrideOutputToSpeaker() throws {}
        }
        let file = AudioDiagnosticsFile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(UUID().uuidString).log"))
        let route = VoiceAudioRoute(session: FailingSession(), environment: [:], diagnostics: file)
        #expect(throws: NSError.self) { try route.activate() }
        #expect(file.read().last?.contains("event=fail step=session domain=NSOSStatusErrorDomain code=560557684")
            == true)
        #expect(!file.read().contains { $0.contains("event=active") })
    }

    /// The silent microphone of the third start: the restart failed once, and nothing tried again.
    @Test func healStartsAStoppedEngineAgainAtMostEveryHalfSecond() throws {
        let rig = KeeperRig()
        rig.keeper.active = true
        try rig.keeper.start()
        rig.engine.routeToHFP()
        rig.engine.startError = EngineFailure()
        rig.keeper.refresh()
        #expect(!rig.engine.isRunning)
        rig.keeper.heal()
        #expect(!rig.engine.isRunning)
        rig.engine.startError = nil
        rig.clock.advance(0.1)
        rig.keeper.heal()
        #expect(!rig.engine.isRunning, "a heal waits for the interval")
        rig.clock.advance(0.5)
        rig.keeper.heal()
        #expect(rig.engine.isRunning)
        #expect(rig.engine.taps.last?.sampleRate == 16_000)

        // After the deactivation nothing starts.
        rig.keeper.active = false
        rig.engine.routeToHFP()
        rig.clock.advance(1)
        rig.keeper.heal()
        rig.keeper.refresh()
        #expect(!rig.engine.isRunning)
        #expect(rig.keeper.tapFormat == nil)
    }

    /// AVFAudio posts the configuration change on its own queue. The app hops to the main actor.
    @Test func aConfigurationChangeFromABackgroundQueueStartsTheEngine() async throws {
        let rig = KeeperRig()
        rig.keeper.active = true
        try rig.keeper.start()
        rig.engine.routeToHFP()
        let keeper = rig.keeper
        let route = rig.route
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                // The diagnostics are safe on any queue.
                route.failed(.clip, error: EngineFailure())
                Task { @MainActor in
                    keeper.refresh()
                    done.resume()
                }
            }
        }
        #expect(rig.engine.isRunning)
        #expect(rig.engine.taps.last?.sampleRate == 16_000)
        #expect(rig.lines.contains { $0.contains("event=fail step=clip domain=") })
    }
}
