import Foundation

// Issue #50: transcribe a received audio file on the phone, with the #44 recognizers.
// The file never goes to the server for this. There is no server step.

/// The speech recognition permission of iOS. Apple On-Device asks for it. Parakeet does not.
public enum SpeechPermission: Sendable, Equatable {
    case authorized
    case denied
    case notDetermined
}

/// Reads and asks for the speech recognition permission. The app uses `SFSpeechRecognizer`. Tests use a fake.
public protocol SpeechPermissionChecking: Sendable {
    func status() -> SpeechPermission
    /// Shows the system prompt once. Returns the new status.
    func request() async -> SpeechPermission
}

/// Why an audio file has no transcript.
public enum AudioFileTranscriptionError: Error, Sendable, Equatable {
    /// The owner turned off speech recognition for Hermes, and no other on-device engine worked.
    case noPermission
    /// Each on-device engine failed.
    case failed
}

extension VoiceTranscription {
    /// The on-device recognizers for an audio file, in order. Parakeet falls back to Apple On-Device.
    /// "Server" in Settings gives Apple On-Device: the file stays on the phone (issue #50).
    var fileChain: [(TranscriptionEngine, any OnDeviceTranscriber)] {
        let steps: [(TranscriptionEngine, (any OnDeviceTranscriber)?)] = effectiveEngine == .parakeet
            ? [(.parakeet, parakeet), (.appleOnDevice, apple)]
            : [(.appleOnDevice, apple)]
        return steps.compactMap { engine, recognizer in recognizer.map { (engine, $0) } }
    }

    /// The trimmed transcript of an audio file, on the phone only. An empty string: no speech found.
    /// It throws `AudioFileTranscriptionError`, or `CancellationError` when the task is cancelled.
    /// Neither the audio nor the text goes to a log.
    public func transcribeFile(at fileURL: URL, permission: any SpeechPermissionChecking,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let log = HermesLog(category: "voice")
        var foundNoSpeech = false
        var failure = AudioFileTranscriptionError.failed
        for (engine, recognizer) in fileChain {
            try Task.checkCancellation()
            if engine == .appleOnDevice {
                var status = permission.status()
                if status == .notDetermined { status = await permission.request() }
                guard status == .authorized else {
                    log.notice("audio file: speech permission off")
                    failure = .noPermission
                    continue
                }
            }
            do {
                let text = try await recognizer.transcribe(fileURL: fileURL, progress: progress)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                if !text.isEmpty {
                    log.info("audio file transcribed on device: \(engine.rawValue)")
                    return text
                }
                foundNoSpeech = true
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                log.notice("audio file transcription failed: \(engine.rawValue), next step")
            }
        }
        if foundNoSpeech { return "" }
        throw failure
    }
}

/// The transcript line under a received audio bubble (issue #50, the #9 memo transcript style).
public enum AudioFileTranscript: Sendable, Equatable {
    /// No transcript yet. The line shows "Transcribe".
    case none
    /// The fraction from 0 to 1, or `nil` when the engine gives no progress. A tap cancels.
    case transcribing(Double?)
    case done(String)
    /// The engine found no speech.
    case empty
    /// Speech recognition is off for Hermes. The screen shows "Open Settings". A tap tries again.
    case noPermission
    /// iOS cannot read the audio format.
    case unreadable
    /// The engines failed. A tap tries again.
    case failed

    /// The line under the bubble. `done` gives the transcript.
    public var caption: String {
        switch self {
        case .none: "Transcribe"
        case .transcribing(let fraction):
            if let fraction { "Transcribing… \(Int((fraction * 100).rounded(.down)))%. Tap to cancel." }
            else { "Transcribing… Tap to cancel." }
        case .done(let text): text
        case .empty: "No speech found."
        case .noPermission: "Speech Recognition is off. Tap to try again."
        case .unreadable: "Can't read this audio format."
        case .failed: "Couldn't transcribe. Tap to retry."
        }
    }

    /// `true` when the "Transcribe" action starts a run.
    public var canStart: Bool {
        switch self {
        case .none, .failed, .noPermission: true
        case .transcribing, .done, .empty, .unreadable: false
        }
    }

    public var isTranscribing: Bool {
        if case .transcribing = self { return true }
        return false
    }

    public var isError: Bool { self == .empty || self == .failed }
}

/// The transcripts of the received audio files of a chat (issue #50).
///
/// - A transcript is saved next to the downloaded file, so it shows again after a relaunch with no new run.
/// - One run per file at a time. "Cancel" stops it, and the line shows "Transcribe" again.
/// - The run uses only the on-device engines. Nothing goes to the server.
@MainActor
public final class ReceivedAudioTranscripts {
    /// Transcribes the playable file. It reports a fraction from 0 to 1.
    public typealias Transcribe = @Sendable (_ fileURL: URL, _ progress: @escaping @Sendable (Double) -> Void)
        async throws -> String

    /// The file name of the saved transcript, in the folder of the downloaded file.
    public static let fileName = "transcript.json"

    /// The screen redraws the bubble of a file when its transcript changes.
    public var onChange: ((ReceivedFile) -> Void)?
    private let files: ReceivedFileLoader
    private let transcribe: Transcribe
    private var states: [String: AudioFileTranscript] = [:]
    private var runs: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private let log = HermesLog(category: "voice")

    public init(files: ReceivedFileLoader, transcribe: @escaping Transcribe) {
        self.files = files
        self.transcribe = transcribe
    }

    /// The app: the engine of Settings > Voice > Transcription, on the phone only.
    public convenience init(files: ReceivedFileLoader, transcription: VoiceTranscription,
                            permission: any SpeechPermissionChecking) {
        self.init(files: files) { url, progress in
            try await transcription.transcribeFile(at: url, permission: permission, progress: progress)
        }
    }

    /// The saved transcript of a file: `<folder of the download>/transcript.json`.
    public func transcriptURL(for file: ReceivedFile) -> URL {
        files.localURL(for: file).deletingLastPathComponent().appending(path: Self.fileName)
    }

    /// The state now. A transcript that an earlier launch saved is `done` (or `empty`).
    public func state(for file: ReceivedFile) -> AudioFileTranscript {
        let url = transcriptURL(for: file)
        if let state = states[url.path] { return state }
        let state = Self.load(url) ?? .none
        states[url.path] = state
        return state
    }

    /// The "Transcribe" action. It does nothing while the audio prepares or a run is in progress.
    public func start(_ file: ReceivedFile) {
        guard file.kind == .audio, state(for: file).canStart else { return }
        let url = transcriptURL(for: file)
        let audioURL: URL
        switch files.audio(for: file) {
        case .ready(let audio):
            audioURL = audio.fileURL
        case .failed:
            // A downloaded file that iOS cannot decode. A file that did not download has no audio bubble.
            if files.state(for: file).fileURL != nil { set(.unreadable, for: file, key: url.path) }
            return
        case .preparing:
            return
        }
        let id = UUID()
        set(.transcribing(nil), for: file, key: url.path)
        let transcribe = self.transcribe
        log.info("audio file transcription started")
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.progress(fraction, for: file, key: url.path, run: id) }
        }
        let task = Task { [weak self] in
            let result: AudioFileTranscript
            do {
                let text = try await transcribe(audioURL, report)
                result = text.isEmpty ? .empty : .done(text)
            } catch AudioFileTranscriptionError.noPermission {
                result = .noPermission
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                result = .failed
            }
            self?.finish(file, key: url.path, run: id, result: result, saveTo: url)
        }
        runs[url.path] = (id, task)
    }

    /// "Cancel" while it runs. The line shows "Transcribe" again.
    public func cancel(_ file: ReceivedFile) {
        let key = transcriptURL(for: file).path
        guard let run = runs.removeValue(forKey: key) else { return }
        run.task.cancel()
        log.info("audio file transcription cancelled")
        set(.none, for: file, key: key)
    }

    /// The running task of a file (tests).
    public func task(for file: ReceivedFile) -> Task<Void, Never>? {
        runs[transcriptURL(for: file).path]?.task
    }

    private func progress(_ fraction: Double, for file: ReceivedFile, key: String, run: UUID) {
        guard runs[key]?.id == run, case .transcribing(let old) = states[key] else { return }
        let next = min(1, max(0, fraction))
        // A redraw for each whole percent only.
        if let old, Int(old * 100) == Int(next * 100) { return }
        set(.transcribing(next), for: file, key: key)
    }

    private func finish(_ file: ReceivedFile, key: String, run: UUID, result: AudioFileTranscript, saveTo url: URL) {
        guard runs[key]?.id == run else { return }
        runs[key] = nil
        switch result {
        case .done(let text): Self.save(text, to: url)
        case .empty: Self.save("", to: url)
        default: break
        }
        log.info("audio file transcription ended")
        set(result, for: file, key: key)
    }

    private func set(_ state: AudioFileTranscript, for file: ReceivedFile, key: String) {
        guard states[key] != state else { return }
        states[key] = state
        onChange?(file)
    }

    // MARK: Saved transcripts

    private struct Saved: Codable {
        var version: Int
        var text: String
    }

    static func load(_ url: URL) -> AudioFileTranscript? {
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return nil }
        return saved.text.isEmpty ? .empty : .done(saved.text)
    }

    static func save(_ text: String, to url: URL) {
        guard let data = try? JSONEncoder().encode(Saved(version: 1, text: text)) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            #if os(iOS)
            try? (url as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication,
                                                 forKey: .fileProtectionKey)
            #endif
        } catch {
            HermesLog(category: "voice").notice("audio file transcript not saved")
        }
    }
}
