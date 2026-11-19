import Foundation
import Synchronization
import Testing
@testable import HermesKit

// Issue #127: the Hands-Free reply must play on the built-in speaker when no Bluetooth or wired output is there.
// A fake audio session. No test opens real audio hardware.

final class FakeVoiceAudioSession: VoiceAudioSession, @unchecked Sendable {
    struct State {
        var outputs: [String]
        var calls: [String] = []
        var mode: VoiceAudioMode?
    }

    let state: Mutex<State>

    init(outputs: [String]) { state = Mutex(State(outputs: outputs)) }

    var outputs: [String] {
        get { state.withLock { $0.outputs } }
        set { state.withLock { $0.outputs = newValue } }
    }

    var calls: [String] { state.withLock { $0.calls } }

    var routeState: VoiceAudioRouteState {
        state.withLock { state in
            VoiceAudioRouteState(outputs: state.outputs, category: "AVAudioSessionCategoryPlayAndRecord",
                                 mode: state.mode.map { "mode-\($0.rawValue)" } ?? "default",
                                 options: ["defaultToSpeaker", "allowBluetoothHFP", "duckOthers"], volume: 0.5)
        }
    }

    func setVoiceCategory(mode: VoiceAudioMode) throws {
        state.withLock {
            $0.mode = mode
            $0.calls.append("category")
        }
    }

    func setActive(_ active: Bool) throws { state.withLock { $0.calls.append("active") } }

    func overrideOutputToSpeaker() throws {
        state.withLock {
            $0.calls.append("speaker")
            $0.outputs = [VoiceAudioRoute.speaker]
        }
    }
}

private final class FakeRoutePlayer: StreamedSpeechPlaying, @unchecked Sendable {
    let events = Mutex<[String]>([])
    func begin(sampleRate: Double) throws { events.withLock { $0.append("begin") } }
    func enqueue(_ pcm: Data) {}
    func drain() async {}
    func playClip(_ audio: SpokenAudio) async throws { events.withLock { $0.append("clip") } }
    func stop() {}
}

private final class Lines: @unchecked Sendable {
    let value = Mutex<[String]>([])
    var all: [String] { value.withLock { $0 } }
    func add(_ line: String) { value.withLock { $0.append(line) } }
}

@Suite struct VoiceAudioRouteTests {
    @Test func receiverRouteAtStartEndsOnTheSpeaker() throws {
        let session = FakeVoiceAudioSession(outputs: [VoiceAudioRoute.receiver])
        let route = VoiceAudioRoute(session: session, environment: [:])
        try route.activate()
        #expect(session.outputs == [VoiceAudioRoute.speaker])
        #expect(session.calls == ["category", "active", "speaker"])
    }

    @Test(arguments: [["BluetoothHFP"], ["BluetoothA2DPOutput"], ["Headphones"], ["USBAudio"], ["CarAudio"],
                      ["AirPlay"], [VoiceAudioRoute.speaker], ["Receiver", "BluetoothHFP"]])
    func otherOutputsKeepTheReply(outputs: [String]) throws {
        let session = FakeVoiceAudioSession(outputs: outputs)
        let route = VoiceAudioRoute(session: session, environment: [:])
        try route.activate()
        route.routeChanged(reason: "newDeviceAvailable")
        route.beforeReply()
        #expect(session.outputs == outputs)
        #expect(!session.calls.contains("speaker"))
    }

    @Test func noOutputIsNotOverridden() {
        #expect(!VoiceAudioRoute.needsSpeaker([]))
        #expect(VoiceAudioRoute.needsSpeaker([VoiceAudioRoute.receiver]))
    }

    @Test func bluetoothGoneToReceiverMovesBackToTheSpeaker() throws {
        let session = FakeVoiceAudioSession(outputs: ["BluetoothHFP"])
        let route = VoiceAudioRoute(session: session, environment: [:])
        try route.activate()
        session.outputs = [VoiceAudioRoute.receiver]
        route.routeChanged(reason: "oldDeviceUnavailable")
        #expect(session.outputs == [VoiceAudioRoute.speaker])
    }

    @Test func eachReplyChecksTheRouteBeforeItPlays() async throws {
        let session = FakeVoiceAudioSession(outputs: [VoiceAudioRoute.speaker])
        let route = VoiceAudioRoute(session: session, environment: [:])
        try route.activate()
        // For example a category change after a live session dropped the speaker.
        session.outputs = [VoiceAudioRoute.receiver]
        let base = FakeRoutePlayer()
        let player = VoiceRoutePlayer(base: base) { _ in
            route.beforeReply()
            base.events.withLock { $0.append(session.outputs.joined()) }
        }
        try player.begin(sampleRate: 24_000)
        #expect(base.events.withLock { $0 } == [VoiceAudioRoute.speaker, "begin"])
        session.outputs = [VoiceAudioRoute.receiver]
        try await player.playClip(SpokenAudio(data: Data(), mimeType: "audio/wav"))
        #expect(base.events.withLock { $0 }.suffix(2) == [VoiceAudioRoute.speaker, "clip"])
    }

    @Test func diagnosticsPrintOneLinePerEventOnlyWithTheFlag() throws {
        let lines = Lines()
        let session = FakeVoiceAudioSession(outputs: [VoiceAudioRoute.receiver])
        let route = VoiceAudioRoute(session: session, environment: ["HERMES_AUDIO_DIAG": "1"]) { lines.add($0) }
        try route.activate()
        route.beforeReply()
        route.routeChanged(reason: "override")
        let all = lines.all
        #expect(all.allSatisfy { $0.hasPrefix("AUDIO_DIAG event=") })
        #expect(all.first == "AUDIO_DIAG event=start out=Receiver category=AVAudioSessionCategoryPlayAndRecord "
                    + "mode=default options=defaultToSpeaker,allowBluetoothHFP,duckOthers volume=0.50 vp=off")
        #expect(all.contains { $0.hasPrefix("AUDIO_DIAG event=active out=Receiver") })
        #expect(all.contains { $0.hasPrefix("AUDIO_DIAG event=speaker out=Speaker") })
        #expect(all.contains { $0.hasPrefix("AUDIO_DIAG event=reply out=Speaker") })
        #expect(all.contains { $0.hasPrefix("AUDIO_DIAG event=route reason=override out=Speaker") })

        let quiet = Lines()
        let other = VoiceAudioRoute(session: FakeVoiceAudioSession(outputs: [VoiceAudioRoute.speaker]),
                                    environment: [:]) { quiet.add($0) }
        try other.activate()
        other.beforeReply()
        #expect(quiet.all.isEmpty)
    }

    @Test func diagnosticsGoToTheLogAtNoticeLevel() throws {
        let entries = Mutex<[HermesLog.Entry]>([])
        let id = HermesLog.addObserver { entry in
            if entry.category == "audio" { entries.withLock { $0.append(entry) } }
        }
        defer { HermesLog.removeObserver(id) }
        let route = VoiceAudioRoute(session: FakeVoiceAudioSession(outputs: [VoiceAudioRoute.receiver]),
                                    environment: [:]) { _ in }
        try route.activate()
        route.routeChanged(reason: "categoryChange")
        let logged = entries.withLock { $0 }
        #expect(logged.contains { $0.level == .notice && $0.message.hasPrefix("event=start out=Receiver") })
        #expect(logged.contains { $0.level == .notice && $0.message.hasPrefix("event=route reason=categoryChange") })
    }

    @Test func modeComesFromTheEnvironment() throws {
        #expect(VoiceAudioRoute(session: FakeVoiceAudioSession(outputs: []), environment: [:]).mode == .voiceChat)
        let session = FakeVoiceAudioSession(outputs: [VoiceAudioRoute.speaker])
        let route = VoiceAudioRoute(session: session, environment: ["HERMES_AUDIO_MODE": "videoChat"])
        try route.activate()
        #expect(session.state.withLock { $0.mode } == .videoChat)
        #expect(VoiceAudioRoute(session: session, environment: ["HERMES_AUDIO_MODE": "bad"]).mode == .voiceChat)
    }

    /// Issue #134: one line per reply with the speak path and the `start` frame rate. `StreamedSpeech` calls the
    /// player on its own executor, so the test calls it from background queues.
    @Test func eachReplyLineShowsThePathAndTheRateFromABackgroundQueue() async throws {
        let lines = Lines()
        let directory = FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = AudioDiagnosticsFile(url: directory.appending(path: AudioDiagnosticsFile.fileName))
        let route = VoiceAudioRoute(session: FakeVoiceAudioSession(outputs: [VoiceAudioRoute.speaker]),
                                    environment: ["HERMES_AUDIO_DIAG": "1"], diagnostics: file) { lines.add($0) }
        let player = VoiceRoutePlayer(base: FakeRoutePlayer()) { route.beforeReply($0) }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                try? player.begin(sampleRate: 24_000)
                done.resume()
            }
        }
        try await Task.detached { try await player.playClip(SpokenAudio(data: Data(), mimeType: "audio/wav")) }.value
        let replies = lines.all.filter { $0.hasPrefix("AUDIO_DIAG event=reply") }
        #expect(replies.count == 2)
        #expect(replies.first?.hasPrefix("AUDIO_DIAG event=reply path=stream rate=24000 out=Speaker") == true)
        #expect(replies.last?.hasPrefix("AUDIO_DIAG event=reply path=fallback rate=none out=Speaker") == true)
        // The diag file of #130 gets the same lines. No text and no audio.
        let saved = file.read().filter { $0.contains("handsfree event=reply") }
        #expect(saved.count == 2)
        #expect(saved.first?.contains("path=stream rate=24000") == true)
        #expect(saved.last?.contains("path=fallback rate=none") == true)
    }

    @Test func theEngineLineShowsVoiceProcessingAndDucking() throws {
        let lines = Lines()
        let status = Mutex(VoiceProcessingStatus.off)
        let route = VoiceAudioRoute(session: FakeVoiceAudioSession(outputs: [VoiceAudioRoute.speaker]),
                                    processing: { status.withLock { $0 } },
                                    environment: ["HERMES_AUDIO_DIAG": "1"]) { lines.add($0) }
        try route.activate()
        status.withLock { $0 = VoiceProcessingStatus(enabled: true, ducking: "min") }
        route.engineStarted()
        route.beforeReply()
        let all = lines.all
        #expect(all.first?.hasSuffix(" vp=off") == true)
        #expect(all.contains { $0.hasPrefix("AUDIO_DIAG event=engine out=Speaker") && $0.hasSuffix(" vp=on ducking=min") })
        #expect(all.last?.hasPrefix("AUDIO_DIAG event=reply") == true)
        #expect(all.last?.hasSuffix(" vp=on ducking=min") == true)
        #expect(VoiceProcessingStatus(enabled: true).description == "vp=on ducking=default")
    }
}

@Suite struct VoiceInputMeterTests {
    private func level(of samples: [Float], meter: VoiceInputMeter = VoiceInputMeter()) -> Float {
        samples.withUnsafeBufferPointer { meter.record($0) }
        return meter.level()
    }

    @Test func silenceIsTheRecorderFloor() {
        #expect(VoiceInputMeter().level() == VoiceInputMeter.silence)
        #expect(level(of: [Float](repeating: 0, count: 480)) == VoiceInputMeter.silence)
    }

    @Test func levelIsTheRMSInDecibels() {
        #expect(abs(level(of: [Float](repeating: 0.1, count: 480)) - -20) < 0.01)
        #expect(abs(level(of: [Float](repeating: -1, count: 480))) < 0.01)
        // A full-scale sine has an RMS of 1/sqrt(2): -3 dBFS.
        let sine = (0..<4_800).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        #expect(abs(level(of: sine) - -3.01) < 0.05)
    }

    @Test func thresholdsKeepTheirMeaning() {
        let tuning = VoiceModeTuning()
        // Speech at -30 dBFS starts a clip but is not a barge-in. Speech at -20 dBFS is a barge-in.
        let speech = level(of: [Float](repeating: 0.0316, count: 480))
        #expect(speech >= tuning.speechDecibels && speech < tuning.bargeInDecibels)
        #expect(level(of: [Float](repeating: 0.1, count: 480)) >= tuning.bargeInDecibels)
        // Room noise at -55 dBFS is silence for the end of the turn.
        #expect(level(of: [Float](repeating: 0.00178, count: 480)) < tuning.speechDecibels)
    }

    @Test func eachReadCoversTheSamplesSinceTheLastRead() {
        let meter = VoiceInputMeter()
        _ = level(of: [Float](repeating: 1, count: 480), meter: meter)
        #expect(abs(level(of: [Float](repeating: 0.01, count: 480), meter: meter) - -40) < 0.01)
        // No new samples: the last level stays.
        #expect(abs(meter.level() - -40) < 0.01)
        meter.reset()
        #expect(meter.level() == VoiceInputMeter.silence)
    }
}
