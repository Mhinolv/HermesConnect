@preconcurrency import AVFoundation
import HermesKit
import Speech

/// Issue #170: live dictation from the microphone with the iOS 26 `SpeechAnalyzer` and `SpeechTranscriber`.
///
/// - On the iPhone only, with the Apple speech model of #44. Nothing goes to the server.
/// - Volatile results give the partial words. A final result ends a phrase.
/// - The audio stays in memory. No file is written, and nothing goes to a log.
@MainActor
final class AppleLiveDictationSource: LiveSpeechSource {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?

    func start() async throws(LiveDictationFailure) -> AsyncThrowingStream<LiveDictationEvent, any Error> {
        guard await AVAudioApplication.requestRecordPermission() else { throw .microphoneOff }
        let transcriber: SpeechTranscriber
        let format: AVAudioFormat
        do {
            transcriber = SpeechTranscriber(locale: try await AppleSpeechTranscriber.locale(), transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        } catch {
            throw .unsupported
        }
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { throw .modelNotInstalled }
        guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw .unsupported
        }
        format = best

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()
        let engine = AVAudioEngine()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let node = engine.inputNode
            let hardware = node.outputFormat(forBus: 0)
            guard hardware.sampleRate > 0, let converter = AVAudioConverter(from: hardware, to: format) else {
                throw LiveDictationFailure.failed
            }
            AudioFeed(converter: converter, format: format, input: input).install(on: node, format: hardware)
            engine.prepare()
            try engine.start()
            try await analyzer.start(inputSequence: inputs)
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            input.finish()
            await analyzer.cancelAndFinishNow()
            Self.deactivate()
            throw .failed
        }
        self.engine = engine
        self.analyzer = analyzer
        self.input = input

        let (stream, output) = AsyncThrowingStream<LiveDictationEvent, any Error>.makeStream()
        results = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    output.yield(result.isFinal ? .final(text) : .partial(text))
                }
                output.finish()
            } catch {
                output.finish(throwing: error)
            }
        }
        return stream
    }

    func finish() async {
        guard let analyzer else { return }
        stopAudio()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        self.analyzer = nil
        results = nil
    }

    func cancel() {
        stopAudio()
        results?.cancel()
        results = nil
        if let analyzer {
            self.analyzer = nil
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private func stopAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        input?.finish()
        input = nil
        Self.deactivate()
    }

    private static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Converts the microphone buffers to the format of the analyzer. The audio thread calls `push`.
private final class AudioFeed: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation

    init(converter: AVAudioConverter, format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation) {
        self.converter = converter
        self.format = format
        self.input = input
    }

    /// The tap block runs on the audio thread, so it must not belong to the main actor.
    nonisolated func install(on node: AVAudioInputNode, format hardware: AVAudioFormat) {
        node.installTap(onBus: 0, bufferSize: 4096, format: hardware) { [self] buffer, _ in push(buffer) }
    }

    nonisolated func push(_ buffer: AVAudioPCMBuffer) {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }
}
