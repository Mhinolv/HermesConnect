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
}
