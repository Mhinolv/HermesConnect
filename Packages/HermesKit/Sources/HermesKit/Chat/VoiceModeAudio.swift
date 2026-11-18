import Foundation
import Synchronization

// Issue #96: the audio parts of voice mode that have no hardware. The app gives the real microphone
// (`AVAudioRecorder`) and the real player (`AVAudioEnginePCMPlayer`). Tests use fakes.

/// The system microphone permission, for the voice mode engine.
public enum VoiceModeMicrophoneAccess: Sendable, Equatable {
    case granted
    case denied
    case undetermined
}

/// The microphone and the audio session of voice mode. The app uses `AVAudioRecorder` and `AVAudioSession`.
@MainActor
public protocol VoiceModeMicrophone: AnyObject {
    var access: VoiceModeMicrophoneAccess { get }
    /// Shows the system prompt. Returns `true` when the owner allows the microphone.
    func requestAccess() async -> Bool
    /// Sets the audio session for the loop: `.playAndRecord`, `.voiceChat`, Bluetooth and the speaker.
    func activate() throws
    /// Releases the audio session. Other audio comes back.
    func deactivate()
    /// Starts a new clip in `url`.
    func startClip(url: URL) throws
    /// Finishes the clip and closes the microphone. Returns the length in seconds.
    func stopClip() -> TimeInterval
    /// Closes the microphone and deletes the clip.
    func discardClip()
    /// The meter now, in dBFS. Called up to 30 times a second while a clip records.
    func level() -> Float
}

/// One spoken reply, as the engine drives it. `StreamedSpeech` (#97) conforms. Tests use a fake.
public protocol VoiceModeSpeaking: Sendable {
    /// Every state change, in order. The stream ends after the final state.
    var states: AsyncStream<StreamedSpeechState> { get }
    func start() async
    func append(_ delta: String) async
    func finish() async
    /// Barge-in. The player is silent when it returns.
    func stop() async
}

extension StreamedSpeech: VoiceModeSpeaking {}

/// Sits between `StreamedSpeech` and the real player. It keeps the PCM of the reply, so that:
/// - the engine reports the output level 30 times a second, from the samples that play now;
/// - the reply bubble gets the audio as a WAV file (#10), with no second `POST /api/audio/speak`.
///
/// The level follows the player schedule: a chunk plays after the one before it, or at once after a gap.
/// The audio never goes to a log.
final class VoiceModeSpeechTap: StreamedSpeechPlaying {
    private struct State {
        var sampleRate: Double = Double(PCM16Samples.defaultSampleRate)
        var pcm = Data()
        /// When each chunk starts to play, and its first sample.
        var segments: [(start: TimeInterval, firstSample: Int)] = []
        var playEnd: TimeInterval = 0
        var clip: SpokenAudio?
    }

    private let base: any StreamedSpeechPlaying
    private let clock: @Sendable () -> TimeInterval
    private let state = Mutex(State())

    init(player: any StreamedSpeechPlaying, clock: @escaping @Sendable () -> TimeInterval) {
        base = player
        self.clock = clock
    }

    func begin(sampleRate: Double) throws {
        try base.begin(sampleRate: sampleRate)
        state.withLock { state in
            if state.pcm.isEmpty, sampleRate > 0 { state.sampleRate = sampleRate }
        }
    }

    func enqueue(_ pcm: Data) {
        base.enqueue(pcm)
        let time = clock()
        state.withLock { state in
            let first = state.pcm.count / 2
            state.pcm.append(pcm)
            let added = state.pcm.count / 2 - first
            guard added > 0 else { return }
            let start = max(time, state.playEnd)
            state.segments.append((start, first))
            state.playEnd = start + Double(added) / state.sampleRate
        }
    }

    func drain() async { await base.drain() }

    func playClip(_ audio: SpokenAudio) async throws {
        state.withLock { $0.clip = audio }
        try await base.playClip(audio)
    }

    func stop() { base.stop() }

    /// The output level from 0 to 1 at `time`: the RMS of the next 1/30 s of samples, on the meter scale.
    /// Zero in a gap, after the end, and for a fallback clip.
    func level(at time: TimeInterval) -> Float {
        state.withLock { state in
            guard let index = state.segments.lastIndex(where: { $0.start <= time }) else { return 0 }
            let segment = state.segments[index]
            let total = state.pcm.count / 2
            let end = index + 1 < state.segments.count ? state.segments[index + 1].firstSample : total
            let sample = segment.firstSample + Int((time - segment.start) * state.sampleRate)
            guard sample < end else { return 0 }
            let window = max(1, Int(state.sampleRate / 30))
            let last = min(end, sample + window)
            var sum: Float = 0
            state.pcm.withUnsafeBytes { raw in
                for position in sample..<last {
                    let value = Int16(bitPattern: UInt16(raw[2 * position]) | UInt16(raw[2 * position + 1]) << 8)
                    let float = Float(value) / 32_768
                    sum += float * float
                }
            }
            let rms = (sum / Float(last - sample)).squareRoot()
            guard rms > 0 else { return 0 }
            return VoiceWaveform.level(decibels: 20 * log10(rms))
        }
    }

    /// The audio of the reply for the bubble: the fallback clip, or the streamed PCM as WAV. `nil` with no audio.
    func recordedAudio() -> SpokenAudio? {
        state.withLock { state in
            if let clip = state.clip { return clip }
            guard state.pcm.count >= 2 else { return nil }
            let pcm = state.pcm.count % 2 == 0 ? state.pcm : state.pcm.dropLast()
            return SpokenAudio(data: PCM16WAV.file(pcm: pcm, sampleRate: Int(state.sampleRate)), mimeType: "audio/wav")
        }
    }
}

/// A mono 16-bit PCM WAV file (RIFF, 44-byte header).
enum PCM16WAV {
    static func file(pcm: Data, sampleRate: Int) -> Data {
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(max(sampleRate, 1))
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // mono
        append(rate)
        append(rate * 2) // bytes per second
        append(UInt16(2)) // bytes per frame
        append(UInt16(16)) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
