import AVFoundation
import HermesKit
import Observation
import Speech

/// Issue #44: Apple On-Device transcription with the iOS 26 `SpeechAnalyzer` and `SpeechTranscriber`.
/// The transcriber runs on the iPhone only. It never uses the server-based `SFSpeechRecognizer`.
/// If the speech model for the locale is not installed, it throws, and the memo uses the server.
/// The model downloads only when the owner taps "Download Apple Speech Model" in Settings.
struct AppleSpeechTranscriber: OnDeviceTranscriber {
    enum Failure: Error {
        case unsupportedLocale
        case modelNotInstalled
    }

    /// The locale of the iPhone, or the nearest locale that the transcriber supports.
    static func locale() async throws -> Locale {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw Failure.unsupportedLocale
        }
        return locale
    }

    static func makeTranscriber() async throws -> SpeechTranscriber {
        SpeechTranscriber(locale: try await locale(), preset: .transcription)
    }

    func transcribe(fileURL: URL) async throws -> String {
        try await transcribe(fileURL: fileURL, progress: { _ in })
    }

    /// Issue #50: the end time of each result over the length of the file gives the progress of a long file.
    /// A cancelled task stops the analyzer.
    func transcribe(fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let transcriber = try await Self.makeTranscriber()
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw Failure.modelNotInstalled
        }
        let file = try AVAudioFile(forReading: fileURL)
        let seconds = Double(file.length) / max(1, file.processingFormat.sampleRate)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let text: String = transcriber.results.reduce(into: "") { text, result in
            text += String(result.text.characters)
            if seconds > 0 { progress(min(1, max(0, result.range.end.seconds / seconds))) }
        }
        try await withTaskCancellationHandler {
            do {
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
        try Task.checkCancellation()
        return try await text
    }
}

/// The Apple speech model row of Settings > Voice. The system keeps the model. The app only asks for it.
@MainActor @Observable
final class AppleSpeechAssets {
    enum State: Equatable {
        case checking
        case unsupported
        case notInstalled
        case downloading(Double)
        case installed
        case failed
    }

    private(set) var state: State = .checking
    @ObservationIgnored private var task: Task<Void, Never>?

    func refresh() async {
        guard task == nil else { return }
        do {
            let transcriber = try await AppleSpeechTranscriber.makeTranscriber()
            state = switch await AssetInventory.status(forModules: [transcriber]) {
            case .installed: .installed
            case .downloading: .downloading(0)
            case .supported: .notInstalled
            case .unsupported: .unsupported
            @unknown default: .unsupported
            }
        } catch {
            state = .unsupported
        }
    }

    /// The owner tapped "Download Apple Speech Model".
    func download() {
        guard task == nil else { return }
        state = .downloading(0)
        task = Task { [weak self] in
            do {
                let transcriber = try await AppleSpeechTranscriber.makeTranscriber()
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    let watch = Task { @MainActor [weak self] in
                        while !Task.isCancelled {
                            self?.state = .downloading(request.progress.fractionCompleted)
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                    }
                    defer { watch.cancel() }
                    try await request.downloadAndInstall()
                }
                self?.finish(.installed)
            } catch {
                self?.finish(.failed)
            }
        }
    }

    private func finish(_ state: State) {
        task = nil
        self.state = state
    }
}
