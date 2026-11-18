import AVFoundation
import Foundation

/// Plays the audio of one spoken reply (issue #97). Tests use a fake. The app uses `AVAudioEnginePCMPlayer`.
/// Call it from one task or actor at a time (`StreamedSpeech` does).
public protocol StreamedSpeechPlaying: Sendable {
    /// Prepares the output for s16le mono PCM at `sampleRate` (the `start` frame of `speak-stream`).
    func begin(sampleRate: Double) throws
    /// Queues one PCM chunk. A chunk can end in the middle of a sample.
    func enqueue(_ pcm: Data)
    /// Returns when all queued audio played, or at once after `stop`.
    func drain() async
    /// Plays a whole `POST /api/audio/speak` clip (the fallback). Returns when it played, or after `stop`.
    func playClip(_ audio: SpokenAudio) async throws
    /// Barge-in: silence at once and drop the queued audio. The output stays ready for the next reply.
    func stop()
}

/// `AVAudioEngine` with one `AVAudioPlayerNode`. `stop()` stops the node, which drops the scheduled
/// buffers at once, so barge-in is silent in well under 100 ms.
///
/// The player does not set the `AVAudioSession`. Voice mode (#96) sets it (`.playAndRecord`, `.voiceChat`).
/// Tests can pass an engine in offline manual rendering mode: no audio hardware is used then.
public final class AVAudioEnginePCMPlayer: StreamedSpeechPlaying, @unchecked Sendable {
    // The engine calls come from one caller at a time (see the protocol). The lock guards the
    // counters only, because the node calls its completion handlers on its own thread.
    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var decoder = PCM16Samples()

    private let lock = NSLock()
    private var pending = 0
    private var generation = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        engine.attach(node)
    }

    public func begin(sampleRate: Double) throws {
        guard sampleRate > 0, let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw SpeechStreamError.server
        }
        decoder = PCM16Samples()
        try prepare(pcmFormat)
    }

    public func enqueue(_ pcm: Data) {
        guard let format else { return }
        let samples = decoder.samples(from: pcm)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        schedule(buffer)
    }

    public func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = lock.withLock {
                if pending == 0 { return true }
                waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    public func playClip(_ audio: SpokenAudio) async throws {
        let buffer = try Self.decode(audio)
        try prepare(buffer.format)
        schedule(buffer)
        await drain()
    }

    public func stop() {
        let woken = lock.withLock {
            generation += 1
            pending = 0
            defer { waiters = [] }
            return waiters
        }
        node.stop()
        decoder = PCM16Samples()
        woken.forEach { $0.resume() }
    }

    /// Stops the engine too. Voice mode calls it when it ends, so the output hardware is free.
    public func shutdown() {
        stop()
        engine.stop()
    }

    /// The node output format. The mixer converts it to the output rate.
    private func prepare(_ newFormat: AVAudioFormat) throws {
        if format != newFormat {
            stop()
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: newFormat)
            format = newFormat
        }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                throw SpeechStreamError.server
            }
        }
        if !node.isPlaying { node.play() }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let current = lock.withLock {
            pending += 1
            return generation
        }
        // `.dataPlayedBack` waits for the output latency too, so `drain` ends when the owner heard the audio.
        // An offline manual rendering engine (tests) never plays back, so it uses `.dataRendered`.
        let callback: AVAudioPlayerNodeCompletionCallbackType = engine.isInManualRenderingMode ? .dataRendered : .dataPlayedBack
        node.scheduleBuffer(buffer, completionCallbackType: callback) { [weak self] _ in
            self?.played(generation: current)
        }
    }

    private func played(generation finished: Int) {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard finished == generation, pending > 0 else { return [] }
            pending -= 1
            guard pending == 0 else { return [] }
            defer { waiters = [] }
            return waiters
        }
        woken.forEach { $0.resume() }
    }

    /// Decodes a speak clip to one buffer. Ogg Opus goes through `OggOpus.wav` first (issue #42).
    static func decode(_ audio: SpokenAudio) throws -> AVAudioPCMBuffer {
        let isOgg = OggOpus.isOgg(audio.data)
        let data = isOgg ? try OggOpus.wav(from: audio.data) : audio.data
        let ext = isOgg ? "wav" : VoiceReplyFiles.fileExtension(mimeType: audio.mimeType)
        let url = FileManager.default.temporaryDirectory.appending(path: "speak-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else {
            throw VoiceReplyError.cannotDecode
        }
        return buffer
    }
}
