import AVFoundation
import HermesKit

/// Issue #121: the voice of Hermes prompts in Hands-Free and Live. On-device speech (`AVSpeechSynthesizer`) says the
/// line. A short clip goes to the on-device transcriber (#44 `SpeechTranscriber`) for a spoken choice. Nothing goes to
/// the server or the live model. The clip file is deleted at once. Nothing here logs a line or a transcript.
@MainActor
final class OnDevicePromptVoice: NSObject, VoicePromptVoice {
    /// The limits of one spoken answer.
    struct Tuning {
        var speechDecibels: Float = -40
        var onsetSeconds: TimeInterval = 0.15
        var silenceSeconds: TimeInterval = 1.2
        var noSpeechSeconds: TimeInterval = 6
        var maxSeconds: TimeInterval = 10
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let transcriber: any OnDeviceTranscriber
    private let tuning: Tuning
    private var spoken: CheckedContinuation<Void, Never>?
    private var utterance: ObjectIdentifier?
    private var recorder: AVAudioRecorder?
    /// One more on each listen and stop. A listen of an older serial returns `.nothing`.
    private var serial = 0

    init(transcriber: any OnDeviceTranscriber = AppleSpeechTranscriber(), tuning: Tuning = Tuning()) {
        self.transcriber = transcriber
        self.tuning = tuning
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ line: String) async {
        finishSpeech()
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        self.utterance = ObjectIdentifier(utterance)
        await withCheckedContinuation { continuation in
            spoken = continuation
            synthesizer.speak(utterance)
        }
    }

    func listen() async -> VoicePromptHeard {
        stopRecorder()
        serial += 1
        let serial = serial
        guard AVAudioApplication.shared.recordPermission == .granted else { return .unavailable }
        let url = FileManager.default.temporaryDirectory.appending(path: "prompt-answer-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let recorder = try? AVAudioRecorder(url: url, settings: AVVoiceRecorder.settings) else { return .unavailable }
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            recorder.deleteRecording()
            return .unavailable
        }
        self.recorder = recorder
        let start = Date()
        var voiceSince: Date?
        var heard = false
        var lastVoice = start
        while true {
            try? await Task.sleep(for: .milliseconds(50))
            guard serial == self.serial, recorder.isRecording else { return .nothing }
            recorder.updateMeters()
            let now = Date()
            if recorder.averagePower(forChannel: 0) >= tuning.speechDecibels {
                let since = voiceSince ?? now
                voiceSince = since
                if now.timeIntervalSince(since) >= tuning.onsetSeconds { heard = true }
                lastVoice = now
            } else {
                voiceSince = nil
            }
            let elapsed = now.timeIntervalSince(start)
            if heard, now.timeIntervalSince(lastVoice) >= tuning.silenceSeconds || elapsed >= tuning.maxSeconds { break }
            if !heard, elapsed >= tuning.noSpeechSeconds {
                stopRecorder()
                return .nothing
            }
        }
        recorder.stop()
        self.recorder = nil
        do {
            let text = try await transcriber.transcribe(fileURL: url)
            guard serial == self.serial else { return .nothing }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .nothing : .text(text)
        } catch {
            return .unavailable
        }
    }

    func stop() {
        serial += 1
        stopRecorder()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finishSpeech()
    }

    private func stopRecorder() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
    }

    private func finishSpeech() {
        utterance = nil
        spoken?.resume()
        spoken = nil
    }

    fileprivate func ended(_ id: ObjectIdentifier) {
        guard id == utterance else { return }
        finishSpeech()
    }
}

extension OnDevicePromptVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }
}
