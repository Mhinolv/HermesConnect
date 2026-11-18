import AVFoundation
import Foundation
import HermesKit
import Testing
@testable import HermesConnect

// Issue #127: the Hands-Free reply was quiet on the speaker. The microphone ran voice processing, and the reply
// played on a second engine, so voice processing ducked the reply as "other audio".
// No test starts the engine, opens the microphone or plays audio. The clip tests use buffers made in code.

@MainActor
struct VoiceEngineMicrophoneTests {
    private func buffer(value: Float, frames: Int, rate: Double = 48_000, channels: AVAudioChannelCount = 1)
        -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            for frame in 0..<frames { buffer.floatChannelData![channel][frame] = value }
        }
        return buffer
    }

    private func clipURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vp-\(UUID().uuidString).m4a")
    }

    @Test func theReplyPlaysOnTheVoiceProcessingEngineOfTheMicrophone() {
        let microphone = AVVoiceModeMicrophone(environment: [:])
        #expect(microphone.captureEngine === microphone.player.engine)
    }

    @Test func noClipIsTheFloorLevelAndAStoppedEngineOpensNoClip() {
        let microphone = AVVoiceModeMicrophone(environment: [:])
        #expect(microphone.level() == VoiceWaveform.floorDecibels)
        #expect(throws: AVVoiceModeMicrophone.StartFailed.self) { try microphone.startClip(url: clipURL()) }
    }

    @Test func theClipIsTheInputAtTheMemoSettings() throws {
        let input = VoiceEngineInput()
        let url = clipURL()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(input.level() == nil)
        // Input before the clip is not in the clip.
        input.receive(buffer(value: 0.5, frames: 4_800))
        try input.start(url: url, settings: AVVoiceRecorder.settings)
        #expect(input.level() == VoiceInputMeter.silence)
        // One second of input at 48 kHz, in two channels: channel 0 is the voice.
        for _ in 0..<10 { input.receive(buffer(value: 0.1, frames: 4_800, channels: 2)) }
        #expect(abs((input.level() ?? 0) - -20) < 0.1)
        let seconds = input.stop()
        #expect(abs(seconds - 1) < 0.05)
        #expect(input.level() == nil)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 22_050)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length > 15_000)
    }

    @Test func aDiscardedClipLeavesNoFile() throws {
        let input = VoiceEngineInput()
        let url = clipURL()
        try input.start(url: url, settings: AVVoiceRecorder.settings)
        input.receive(buffer(value: 0.1, frames: 4_800))
        input.discard()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(input.stop() == 0)
    }

    /// Issue #127 round 3: AVFAudio calls the tap block on its own audio queue. A block with main actor
    /// isolation traps there (`dispatch_assert_queue`). This test installs the real tap on an offline engine,
    /// so AVFAudio calls it off the main thread, as on the device.
    @Test func theInputTapRunsOnTheAudioQueue() async throws {
        let input = VoiceEngineInput()
        let url = clipURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try input.start(url: url, settings: AVVoiceRecorder.settings)

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_800)
        let source = AVAudioPlayerNode()
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        AVVoiceModeMicrophone.installInputTap(on: engine.mainMixerNode, input: input)
        try engine.start()
        source.scheduleBuffer(buffer(value: 0.1, frames: 48_000), completionHandler: nil)
        source.play()
        let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_800)!
        for _ in 0..<10 { _ = try engine.renderOffline(4_800, to: output) }
        // The tap delivers on its own queue a little later.
        for _ in 0..<100 where (input.level() ?? VoiceInputMeter.silence) <= -100 {
            try await Task.sleep(for: .milliseconds(20))
        }
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        #expect((input.level() ?? VoiceInputMeter.silence) > -100)
        #expect(input.stop() > 0)
    }

    /// The route check before each reply runs where `StreamedSpeech` runs: not on the main thread.
    /// `begin(sampleRate: 0)` runs the check, then the player refuses the rate, so no audio starts.
    @Test func theReplyRouteCheckRunsOffTheMainThread() async {
        let microphone = AVVoiceModeMicrophone(environment: [:])
        let player = microphone.replyPlayer
        let refused = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue(label: "test.speech").async {
                continuation.resume(returning: (try? player.begin(sampleRate: 0)) == nil)
            }
        }
        #expect(refused)
    }
}
