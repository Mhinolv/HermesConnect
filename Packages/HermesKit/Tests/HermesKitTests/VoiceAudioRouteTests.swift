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
        let player = VoiceRoutePlayer(base: base) {
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
                    + "mode=default options=defaultToSpeaker,allowBluetoothHFP,duckOthers volume=0.50")
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
}
