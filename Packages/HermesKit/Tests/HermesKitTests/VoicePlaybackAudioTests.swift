import Foundation
import Synchronization
import Testing
@testable import HermesKit

// Issue #130: a voice clip must play on a car Bluetooth output with no other audio first.
// A fake audio session. No test opens real audio hardware.

private final class FakePlaybackSession: VoicePlaybackSession, @unchecked Sendable {
    struct State {
        var outputs: [String]
        var otherAudio: Bool
        var category = "AVAudioSessionCategoryPlayAndRecord"
        var options = ["defaultToSpeaker", "allowBluetoothHFP"]
        var calls: [String] = []
        var mode: VoicePlaybackMode?
    }

    let state: Mutex<State>

    init(outputs: [String], otherAudio: Bool = false) {
        state = Mutex(State(outputs: outputs, otherAudio: otherAudio))
    }

    var calls: [String] { state.withLock { $0.calls } }
    var options: [String] { state.withLock { $0.options } }
    var mode: VoicePlaybackMode? { state.withLock { $0.mode } }

    var routeState: VoiceAudioRouteState {
        state.withLock {
            VoiceAudioRouteState(outputs: $0.outputs, category: $0.category, mode: "AVAudioSessionModeSpokenAudio",
                                 options: $0.options, volume: 0.5)
        }
    }

    var isOtherAudioPlaying: Bool { state.withLock { $0.otherAudio } }

    func setPlaybackCategory(duckOthers: Bool, mode: VoicePlaybackMode) throws {
        state.withLock {
            $0.mode = mode
            $0.category = "AVAudioSessionCategoryPlayback"
            $0.options = duckOthers ? ["duckOthers"] : []
            // `.playback` cannot use the HFP call channel: the route moves to the media output.
            $0.outputs = $0.outputs.map { $0 == "BluetoothHFP" ? "BluetoothA2DPOutput" : $0 }
            $0.calls.append(duckOthers ? "category-duck" : "category")
        }
    }

    func setActive(_ active: Bool) throws { state.withLock { $0.calls.append(active ? "active" : "inactive") } }
}

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("audio-diag-\(UUID().uuidString).log")
}

@Suite struct VoicePlaybackAudioTests {
    /// The bug: a mixable (ducking) session does not start the car's media stream. Music had to start it.
    @Test func withNoOtherAudioTheClipIsTheOnlyMediaStream() throws {
        let session = FakePlaybackSession(outputs: ["BluetoothA2DPOutput"])
        try VoicePlaybackAudio(session: session).play()
        #expect(session.calls == ["category", "active"])
        #expect(!session.options.contains("duckOthers"))
    }

    /// #10: with music on, the clip ducks it and plays over it.
    /// Round 2: `.default` mode, and `.spokenAudio` only for a drive A/B.
    @Test func theModeReachesTheSessionOnPlayAndResume() throws {
        let session = FakePlaybackSession(outputs: ["BluetoothA2DPOutput"])
        try VoicePlaybackAudio(session: session, mode: .default).play()
        #expect(session.mode == .default)
        try VoicePlaybackAudio(session: session, mode: .spokenAudio).resume()
        #expect(session.mode == .spokenAudio)
    }

    @Test func withOtherAudioTheClipDucksIt() throws {
        let session = FakePlaybackSession(outputs: ["BluetoothA2DPOutput"], otherAudio: true)
        try VoicePlaybackAudio(session: session).play()
        #expect(session.calls == ["category-duck", "active"])
    }

    /// After Hands-Free or a memo, the session can still be `.playAndRecord` on the HFP call channel.
    @Test func playAfterARecordSetupMovesOffTheCallChannel() throws {
        let session = FakePlaybackSession(outputs: ["BluetoothHFP"])
        try VoicePlaybackAudio(session: session).play()
        let state = session.routeState
        #expect(state.category == "AVAudioSessionCategoryPlayback")
        #expect(!state.options.contains("allowBluetoothHFP"))
        #expect(state.outputs == ["BluetoothA2DPOutput"])
    }

    @Test func resumeSetsTheCategoryAgain() throws {
        let session = FakePlaybackSession(outputs: ["BluetoothA2DPOutput"])
        let audio = VoicePlaybackAudio(session: session)
        try audio.play()
        // A recording or Hands-Free ran while the clip was paused.
        session.state.withLock {
            $0.category = "AVAudioSessionCategoryPlayAndRecord"
            $0.options = ["defaultToSpeaker", "allowBluetoothHFP"]
            $0.outputs = ["BluetoothHFP"]
        }
        try audio.resume()
        #expect(session.calls == ["category", "active", "category", "active"])
        #expect(session.routeState.category == "AVAudioSessionCategoryPlayback")
        #expect(session.routeState.outputs == ["BluetoothA2DPOutput"])
    }

    @Test func eachPlayStartAndRouteChangeWritesOneDiagnosticLine() throws {
        let file = AudioDiagnosticsFile(url: tempFile())
        defer { try? FileManager.default.removeItem(at: file.url) }
        let audio = VoicePlaybackAudio(session: FakePlaybackSession(outputs: ["BluetoothHFP"]), diagnostics: file)
        try audio.play()
        audio.routeChanged(reason: "categoryChange")
        try audio.resume()
        let lines = file.read()
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix(" playback event=play out=BluetoothA2DPOutput category=AVAudioSessionCategoryPlayback "
                    + "mode=AVAudioSessionModeSpokenAudio options=none volume=0.50 vp=off"))
        #expect(lines[1].contains(" playback event=route reason=categoryChange out=BluetoothA2DPOutput "))
        #expect(lines[2].contains(" playback event=resume "))
    }

    /// Lesson of #127: AVFAudio posts the route change on its own queue. No main actor state.
    @Test func routeChangeFromABackgroundQueueIsSafe() async throws {
        let file = AudioDiagnosticsFile(url: tempFile())
        defer { try? FileManager.default.removeItem(at: file.url) }
        let audio = VoicePlaybackAudio(session: FakePlaybackSession(outputs: ["CarAudio"]), diagnostics: file)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { await Task.detached { audio.routeChanged(reason: "newDeviceAvailable") }.value }
            }
        }
        DispatchQueue.global().sync { audio.routeChanged(reason: "oldDeviceUnavailable") }
        #expect(file.read().count == 21)
        #expect(file.read().allSatisfy { $0.contains("out=CarAudio") })
    }
}

@Suite struct AudioDiagnosticsFileTests {
    @Test func keepsTheLastLinesOnly() {
        let file = AudioDiagnosticsFile(url: tempFile(), limit: 3)
        defer { try? FileManager.default.removeItem(at: file.url) }
        for index in 1...5 { file.append("event=\(index)") }
        let lines = file.read()
        #expect(lines.count == 3)
        #expect(lines.map { $0.split(separator: " ").last.map(String.init) } == ["event=3", "event=4", "event=5"])
        // A new writer reads the file, keeps the limit and adds after the old lines.
        file.flush()
        let again = AudioDiagnosticsFile(url: file.url, limit: 3)
        again.append("event=6")
        #expect(again.read().last?.hasSuffix("event=6") == true)
        #expect(again.read().count == 3)
    }

    /// Issue #165: the append returns before the write. `flush` waits for it, and the file has every line.
    @Test func writesTheFileOnItsOwnQueue() throws {
        let file = AudioDiagnosticsFile(url: tempFile(), limit: 50)
        defer { try? FileManager.default.removeItem(at: file.url) }
        for index in 1...20 { file.append("event=\(index)") }
        file.flush()
        let text = try String(contentsOf: file.url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 20)
        #expect(lines.last?.hasSuffix("event=20") == true)
    }

    @Test func eachLineStartsWithTheUTCTimeAndHasNoNewline() {
        let file = AudioDiagnosticsFile(url: tempFile(), now: { Date(timeIntervalSince1970: 0) })
        defer { try? FileManager.default.removeItem(at: file.url) }
        file.append("event=a\nevent=b")
        #expect(file.read() == ["1970-01-01T00:00:00Z event=a event=b"])
    }

    @Test func theSharedFileIsInCaches() {
        #expect(AudioDiagnosticsFile.shared.url.lastPathComponent == "audio_diag.log")
        #expect(AudioDiagnosticsFile.shared.url.deletingLastPathComponent().lastPathComponent == "Caches")
    }

    @Test func handsFreeRouteLinesGoToTheFileToo() throws {
        let file = AudioDiagnosticsFile(url: tempFile())
        defer { try? FileManager.default.removeItem(at: file.url) }
        let route = VoiceAudioRoute(session: FakeVoiceAudioSession(outputs: ["BluetoothHFP"]), environment: [:],
                                    diagnostics: file) { _ in }
        try route.activate()
        route.routeChanged(reason: "override")
        let lines = file.read()
        #expect(lines.contains { $0.contains(" handsfree event=start out=BluetoothHFP ") })
        #expect(lines.contains { $0.contains(" handsfree event=route reason=override ") })
    }
}
