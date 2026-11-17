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

/// The transcripts of the audio files of a chat: the received files (issue #50) and the files that the owner
/// sent (issue #87).
///
/// - A transcript is saved next to the audio file, so it shows again after a relaunch with no new run.
///   Issue #87: the unreadable state is saved too.
/// - One run per file at a time. "Cancel" stops it, and the line shows "Transcribe" again.
/// - Issue #87: `cancelAll()` stops each run when the owner leaves the chat. The object stops them when it goes.
/// - The run uses only the on-device engines. Nothing goes to the server.
@MainActor
public final class ReceivedAudioTranscripts {
    /// Transcribes the playable file. It reports a fraction from 0 to 1.
    public typealias Transcribe = @Sendable (_ fileURL: URL, _ progress: @escaping @Sendable (Double) -> Void)
        async throws -> String
    /// Issue #87: the file that iOS reads for a sent audio file, or `nil` when iOS cannot read the format.
    /// It runs off the main thread. Ogg Opus becomes a WAV file next to the sent file.
    public typealias PrepareSent = @Sendable (URL) -> URL?

    /// The file name of the saved transcript, in the folder of the audio file.
    public static let fileName = "transcript.json"

    /// The screen redraws the bubble of a file when its transcript changes.
    public var onChange: ((ReceivedFile) -> Void)?
    /// Issue #87: the screen redraws the file cell of a sent audio file when its transcript changes.
    public var onSentChange: ((ChatAttachment) -> Void)?
    private let files: ReceivedFileLoader
    private let transcribe: Transcribe
    private let prepareSent: PrepareSent
    private var states: [String: AudioFileTranscript] = [:]
    /// Issue #87: `true` when the file of a sent item is still on the phone (the system can clear it).
    private var sentFiles: [String: Bool] = [:]
    private var runs: [String: Run] = [:]
    private let log = HermesLog(category: "voice")

    /// The file of a transcript: the bubble that redraws when its state changes.
    private enum Source: Sendable {
        case received(ReceivedFile)
        case sent(ChatAttachment)
    }

    private struct Run: Sendable {
        let id: UUID
        let task: Task<Void, Never>
        let source: Source
    }

    public init(files: ReceivedFileLoader, transcribe: @escaping Transcribe,
                prepareSent: @escaping PrepareSent = { ReceivedFileLoader.playableFile(at: $0)?.url }) {
        self.files = files
        self.transcribe = transcribe
        self.prepareSent = prepareSent
    }

    /// The app: the engine of Settings > Voice > Transcription, on the phone only.
    public convenience init(files: ReceivedFileLoader, transcription: VoiceTranscription,
                            permission: any SpeechPermissionChecking) {
        self.init(files: files) { url, progress in
            try await transcription.transcribeFile(at: url, permission: permission, progress: progress)
        }
    }

    /// Issue #87: the screen went. A run that nobody can see does not keep the engine busy.
    isolated deinit {
        for run in runs.values { run.task.cancel() }
    }

    /// The saved transcript of a file: `<folder of the download>/transcript.json`.
    public func transcriptURL(for file: ReceivedFile) -> URL {
        files.localURL(for: file).deletingLastPathComponent().appending(path: Self.fileName)
    }

    /// Issue #87: the saved transcript of a sent file: `<folder of the private copy>/transcript.json`.
    public func transcriptURL(for item: ChatAttachment) -> URL {
        item.fileURL.deletingLastPathComponent().appending(path: Self.fileName)
    }

    /// The state now. A transcript that an earlier launch saved is `done` (or `empty`, or `unreadable`).
    public func state(for file: ReceivedFile) -> AudioFileTranscript {
        state(key: transcriptURL(for: file))
    }

    /// Issue #87: the state of a sent file. A saved transcript shows as for a received file.
    public func state(for item: ChatAttachment) -> AudioFileTranscript {
        state(key: transcriptURL(for: item))
    }

    /// Issue #87: `true` when the file cell of a sent item gets "Transcribe": an audio file that is still on the
    /// phone. A cell from a server `@file:` ref, or a copy that the system cleared, has no action.
    public func canTranscribe(_ item: ChatAttachment) -> Bool {
        guard item.isAudioFile else { return false }
        let key = transcriptURL(for: item).path
        if let found = sentFiles[key] { return found }
        let found = FileManager.default.fileExists(atPath: item.fileURL.path)
        sentFiles[key] = found
        return found
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
            // Issue #87: the state is saved, so it shows again after a relaunch.
            if files.state(for: file).fileURL != nil {
                Self.save(.unreadable, to: url)
                set(.unreadable, for: .received(file), key: url.path)
            }
            return
        case .preparing:
            return
        }
        run(.received(file), saveTo: url) { audioURL }
    }

    /// Issue #87: the "Transcribe" action of a sent audio file. The file is prepared in the run, off the main
    /// thread. A format that iOS cannot read ends in `unreadable`, and that state is saved.
    public func start(_ item: ChatAttachment) {
        guard canTranscribe(item), state(for: item).canStart else { return }
        let prepare = prepareSent
        let source = item.fileURL
        run(.sent(item), saveTo: transcriptURL(for: item)) {
            await Task.detached(priority: .userInitiated) { prepare(source) }.value
        }
    }

    /// "Cancel" while it runs. The line shows "Transcribe" again.
    public func cancel(_ file: ReceivedFile) {
        cancel(key: transcriptURL(for: file).path)
    }

    /// Issue #87: "Cancel" of a sent audio file.
    public func cancel(_ item: ChatAttachment) {
        cancel(key: transcriptURL(for: item).path)
    }

    /// Issue #87: the owner left the chat. Each run stops, and its line shows "Transcribe" again.
    public func cancelAll() {
        for key in Array(runs.keys) { cancel(key: key) }
    }

    /// The running task of a file (tests).
    public func task(for file: ReceivedFile) -> Task<Void, Never>? {
        runs[transcriptURL(for: file).path]?.task
    }

    /// The running task of a sent file (tests).
    public func task(for item: ChatAttachment) -> Task<Void, Never>? {
        runs[transcriptURL(for: item).path]?.task
    }

    /// `true` while a run is in progress (tests).
    public var isRunning: Bool { !runs.isEmpty }

    private func state(key url: URL) -> AudioFileTranscript {
        if let state = states[url.path] { return state }
        let state = Self.load(url) ?? .none
        states[url.path] = state
        return state
    }

    /// Starts one run. `audio` gives the file that the engine reads, or `nil` when iOS cannot read it.
    private func run(_ source: Source, saveTo url: URL, audio: @escaping @Sendable () async -> URL?) {
        let key = url.path
        let id = UUID()
        set(.transcribing(nil), for: source, key: key)
        let transcribe = self.transcribe
        log.info("audio file transcription started")
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.progress(fraction, key: key, run: id) }
        }
        let task = Task { [weak self] in
            let result: AudioFileTranscript
            do {
                guard let audioURL = await audio() else {
                    try Task.checkCancellation()
                    self?.finish(key: key, run: id, result: .unreadable, saveTo: url)
                    return
                }
                let text = try await transcribe(audioURL, report)
                result = text.isEmpty ? .empty : .done(text)
            } catch AudioFileTranscriptionError.noPermission {
                result = .noPermission
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                result = .failed
            }
            self?.finish(key: key, run: id, result: result, saveTo: url)
        }
        runs[key] = Run(id: id, task: task, source: source)
    }

    private func cancel(key: String) {
        guard let run = runs.removeValue(forKey: key) else { return }
        run.task.cancel()
        log.info("audio file transcription cancelled")
        set(.none, for: run.source, key: key)
    }

    private func progress(_ fraction: Double, key: String, run: UUID) {
        guard let current = runs[key], current.id == run, case .transcribing(let old) = states[key] else { return }
        let next = min(1, max(0, fraction))
        // A redraw for each whole percent only.
        if let old, Int(old * 100) == Int(next * 100) { return }
        set(.transcribing(next), for: current.source, key: key)
    }

    private func finish(key: String, run: UUID, result: AudioFileTranscript, saveTo url: URL) {
        guard let current = runs[key], current.id == run else { return }
        runs[key] = nil
        switch result {
        case .done, .empty, .unreadable: Self.save(result, to: url)
        default: break
        }
        log.info("audio file transcription ended")
        set(result, for: current.source, key: key)
    }

    private func set(_ state: AudioFileTranscript, for source: Source, key: String) {
        guard states[key] != state else { return }
        states[key] = state
        switch source {
        case .received(let file): onChange?(file)
        case .sent(let item): onSentChange?(item)
        }
    }

    // MARK: Saved transcripts

    /// Version 1 (issue #50): `text`. Version 2 (issue #87): `unreadable` too. Version 1 files read as before.
    private struct Saved: Codable {
        var version: Int
        var text: String
        var unreadable: Bool?
    }

    static func load(_ url: URL) -> AudioFileTranscript? {
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return nil }
        if saved.unreadable == true { return .unreadable }
        return saved.text.isEmpty ? .empty : .done(saved.text)
    }

    /// Saves a final state: `done`, `empty` or `unreadable`. The other states are not saved.
    static func save(_ state: AudioFileTranscript, to url: URL) {
        let saved: Saved
        switch state {
        case .done(let text): saved = Saved(version: 2, text: text)
        case .empty: saved = Saved(version: 2, text: "")
        case .unreadable: saved = Saved(version: 2, text: "", unreadable: true)
        default: return
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
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
