import Foundation
import Synchronization
import Testing
@testable import HermesKit

// Issue #50: transcribe a received audio file on the phone, with the #44 recognizers.

private struct RecognizerFailed: Error {}

/// A fake on-device recognizer. It counts calls, reports a set progress and returns a set result.
private final class FakeFileRecognizer: OnDeviceTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [URL] = []
    private let result: Result<String, any Error>
    private let progressSteps: [Double]
    private let delay: Duration?
    init(_ result: Result<String, any Error>, progress: [Double] = [], delay: Duration? = nil) {
        self.result = result
        progressSteps = progress
        self.delay = delay
    }

    var calls: [URL] { lock.withLock { _calls } }
    func transcribe(fileURL: URL) async throws -> String {
        try await transcribe(fileURL: fileURL, progress: { _ in })
    }

    func transcribe(fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        lock.withLock { _calls.append(fileURL) }
        for step in progressSteps { progress(step) }
        if let delay { try await Task.sleep(for: delay) }
        return try result.get()
    }
}

/// A fake speech permission.
private final class FakePermission: SpeechPermissionChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: SpeechPermission
    private let answer: SpeechPermission
    private var _requests = 0
    init(_ status: SpeechPermission, answer: SpeechPermission = .authorized) {
        _status = status
        self.answer = answer
    }

    var requests: Int { lock.withLock { _requests } }
    func status() -> SpeechPermission { lock.withLock { _status } }
    func request() async -> SpeechPermission {
        lock.withLock {
            _requests += 1
            _status = answer
            return answer
        }
    }
}

/// A transport that counts each server call that could carry the audio: `/api/audio/transcribe`,
/// the voice turn, and the file download.
private final class ServerCountingTransport: ChatTransport, ReceivedFileDownloading, @unchecked Sendable {
    let events: AsyncStream<GatewayClientEvent> = AsyncStream { _ in }
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    private func record(_ name: String) { lock.withLock { _calls.append(name) } }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        record("startSession")
        return ChatSessionRef(liveId: "s1", storedId: "st1")
    }

    func resumeSession(storedId: String, source _: String) async throws -> ChatSessionRef {
        record("resumeSession")
        return ChatSessionRef(liveId: "s1", storedId: storedId)
    }

    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? {
        record("submitPrompt")
        return 1
    }

    func submitVoicePrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? {
        record("submitVoicePrompt")
        return 2
    }

    func transcribe(audio _: Data, mimeType _: String) async throws -> String {
        record("transcribe")
        return "server words"
    }

    func stopReply(sessionId _: String) async throws -> Bool { true }
    func history(sessionId _: String) async throws -> [TranscriptMessage] { [] }

    func downloadReceivedFile(path _: String, storedSessionId _: String?, maxBytes _: Int?,
                              progress _: @escaping @Sendable (Double) -> Void) async throws -> URL {
        record("download")
        throw ReceivedFileError.offline
    }
}

private let fileURL = URL(fileURLWithPath: "/tmp/audio-file-test/call.wav")

private func transcription(_ choice: TranscriptionEngine, apple: FakeFileRecognizer?, parakeet: FakeFileRecognizer? = nil,
                           parakeetReady: Bool = true) -> VoiceTranscription {
    VoiceTranscription(engine: { choice }, apple: apple, parakeet: parakeet, parakeetReady: { parakeetReady })
}

@Suite struct AudioFileEngineTests {
    @Test func serverChoiceStaysOnThePhone() async throws {
        let apple = FakeFileRecognizer(.success(" hello there "))
        let text = try await transcription(.server, apple: apple)
            .transcribeFile(at: fileURL, permission: FakePermission(.authorized), progress: { _ in })
        #expect(text == "hello there")
        #expect(apple.calls == [fileURL])
    }

    @Test func appleChoiceUsesApple() async throws {
        let apple = FakeFileRecognizer(.success("apple words"))
        let parakeet = FakeFileRecognizer(.success("parakeet words"))
        let text = try await transcription(.appleOnDevice, apple: apple, parakeet: parakeet)
            .transcribeFile(at: fileURL, permission: FakePermission(.authorized), progress: { _ in })
        #expect(text == "apple words")
        #expect(parakeet.calls.isEmpty)
    }

    @Test func parakeetNeedsNoSpeechPermission() async throws {
        let apple = FakeFileRecognizer(.success("apple words"))
        let parakeet = FakeFileRecognizer(.success("parakeet words"))
        let permission = FakePermission(.denied)
        let text = try await transcription(.parakeet, apple: apple, parakeet: parakeet)
            .transcribeFile(at: fileURL, permission: permission, progress: { _ in })
        #expect(text == "parakeet words")
        #expect(apple.calls.isEmpty)
        #expect(permission.requests == 0)
    }

    @Test func parakeetFailureFallsBackToApple() async throws {
        let apple = FakeFileRecognizer(.success("apple words"))
        let parakeet = FakeFileRecognizer(.failure(RecognizerFailed()))
        let text = try await transcription(.parakeet, apple: apple, parakeet: parakeet)
            .transcribeFile(at: fileURL, permission: FakePermission(.authorized), progress: { _ in })
        #expect(text == "apple words")
        #expect(parakeet.calls.count == 1)
    }

    @Test func parakeetNotDownloadedUsesApple() async throws {
        let apple = FakeFileRecognizer(.success("apple words"))
        let parakeet = FakeFileRecognizer(.success("parakeet words"))
        let text = try await transcription(.parakeet, apple: apple, parakeet: parakeet, parakeetReady: false)
            .transcribeFile(at: fileURL, permission: FakePermission(.authorized), progress: { _ in })
        #expect(text == "apple words")
        #expect(parakeet.calls.isEmpty)
    }

    @Test func deniedPermissionGivesNoPermission() async {
        let apple = FakeFileRecognizer(.success("apple words"))
        await #expect(throws: AudioFileTranscriptionError.noPermission) {
            try await transcription(.appleOnDevice, apple: apple)
                .transcribeFile(at: fileURL, permission: FakePermission(.denied), progress: { _ in })
        }
        #expect(apple.calls.isEmpty)
    }

    @Test func undecidedPermissionAsksOnce() async throws {
        let apple = FakeFileRecognizer(.success("apple words"))
        let permission = FakePermission(.notDetermined, answer: .authorized)
        let text = try await transcription(.appleOnDevice, apple: apple)
            .transcribeFile(at: fileURL, permission: permission, progress: { _ in })
        #expect(text == "apple words")
        #expect(permission.requests == 1)
    }

    @Test func noSpeechGivesAnEmptyTranscript() async throws {
        let apple = FakeFileRecognizer(.success("  \n"))
        let parakeet = FakeFileRecognizer(.success(""))
        let text = try await transcription(.parakeet, apple: apple, parakeet: parakeet)
            .transcribeFile(at: fileURL, permission: FakePermission(.authorized), progress: { _ in })
        #expect(text.isEmpty)
        #expect(apple.calls.count == 1)
    }

    @Test func eachEngineFailedGivesFailed() async {
        await #expect(throws: AudioFileTranscriptionError.failed) {
            try await transcription(.parakeet, apple: FakeFileRecognizer(.failure(RecognizerFailed())),
                                    parakeet: FakeFileRecognizer(.failure(RecognizerFailed())))
                .transcribeFile(at: fileURL, permission: FakePermission(.authorized), progress: { _ in })
        }
    }

    @Test func noRecognizerGivesFailed() async {
        await #expect(throws: AudioFileTranscriptionError.failed) {
            try await VoiceTranscription.server
                .transcribeFile(at: fileURL, permission: FakePermission(.authorized), progress: { _ in })
        }
    }

    @Test func progressComesFromTheRecognizer() async throws {
        let apple = FakeFileRecognizer(.success("words"), progress: [0.25, 0.5])
        let seen = Mutex<[Double]>([])
        _ = try await transcription(.appleOnDevice, apple: apple)
            .transcribeFile(at: fileURL, permission: FakePermission(.authorized)) { value in
                seen.withLock { $0.append(value) }
            }
        #expect(seen.withLock { $0 } == [0.25, 0.5])
    }

    @Test func cancelStopsTheRun() async {
        let apple = FakeFileRecognizer(.success("late words"), delay: .seconds(30))
        let task = Task {
            try await transcription(.appleOnDevice, apple: apple)
                .transcribeFile(at: fileURL, permission: FakePermission(.authorized), progress: { _ in })
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

// MARK: - Transcripts of a chat

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ReceivedAudioTranscriptsTests {
    private let file = ReceivedFile(path: "/home/hermes/.hermes/outputs/call.wav")

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "AudioFileTranscripts-\(UUID().uuidString)",
                                                         directoryHint: .isDirectory)
    }

    /// A loader with the file on disk, as after a download. `playable: false`: iOS cannot decode it.
    private func loader(folder: URL, playable: Bool = true,
                        transport: ServerCountingTransport? = nil) throws -> ReceivedFileLoader {
        let files: ReceivedFileLoader
        let prepare: ReceivedFileLoader.PrepareAudio = { url in
            playable ? VoiceReplyAudio(fileURL: url, duration: 720) : nil
        }
        if let transport {
            files = ReceivedFileLoader(download: { path, session, maxBytes, progress in
                try await transport.downloadReceivedFile(path: path, storedSessionId: session, maxBytes: maxBytes,
                                                         progress: progress)
            }, folder: folder, storedSessionId: { "st1" }, prepareAudio: prepare)
        } else {
            files = ReceivedFileLoader(download: nil, folder: folder, storedSessionId: { "st1" }, prepareAudio: prepare)
        }
        let url = files.localURL(for: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: url)
        return files
    }

    /// Waits until the bubble audio is prepared (or found not playable).
    private func prepareAudio(_ files: ReceivedFileLoader) async throws {
        for _ in 0..<200 {
            if files.audio(for: file) != .preparing { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForEnd(_ transcripts: ReceivedAudioTranscripts) async {
        await transcripts.task(for: file)?.value
        for _ in 0..<50 where transcripts.state(for: file).isTranscribing { await Task.yield() }
    }

    @Test func transcriptShowsAndSurvivesARelaunch() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try loader(folder: folder)
        try await prepareAudio(files)
        let runs = Mutex(0)
        let transcripts = ReceivedAudioTranscripts(files: files) { _, _ in
            runs.withLock { $0 += 1 }
            return "Call notes from Tuesday."
        }
        var changes = 0
        transcripts.onChange = { _ in changes += 1 }
        #expect(transcripts.state(for: file) == .none)
        transcripts.start(file)
        #expect(transcripts.state(for: file) == .transcribing(nil))
        await waitForEnd(transcripts)
        #expect(transcripts.state(for: file) == .done("Call notes from Tuesday."))
        #expect(changes == 2)
        #expect(FileManager.default.fileExists(atPath: transcripts.transcriptURL(for: file).path))

        // Relaunch: a new loader and a new store read the saved transcript. Nothing runs again.
        let relaunched = ReceivedAudioTranscripts(files: try loader(folder: folder)) { _, _ in
            runs.withLock { $0 += 1 }
            return "other"
        }
        #expect(relaunched.state(for: file) == .done("Call notes from Tuesday."))
        relaunched.start(file)
        #expect(relaunched.task(for: file) == nil)
        #expect(runs.withLock { $0 } == 1)
    }

    @Test func noSpeechIsSavedToo() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try loader(folder: folder)
        try await prepareAudio(files)
        let transcripts = ReceivedAudioTranscripts(files: files) { _, _ in "" }
        transcripts.start(file)
        await waitForEnd(transcripts)
        #expect(transcripts.state(for: file) == .empty)
        let relaunched = ReceivedAudioTranscripts(files: files) { _, _ in "x" }
        #expect(relaunched.state(for: file) == .empty)
    }

    /// Acceptance criterion: with an on-device engine, the app sends no transcription request to the server.
    @Test func onDeviceEngineSendsNothingToTheServer() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for choice in TranscriptionEngine.allCases {
            let transport = ServerCountingTransport()
            let files = try loader(folder: folder.appending(path: choice.rawValue), transport: transport)
            try await prepareAudio(files)
            let apple = FakeFileRecognizer(.success("apple words"))
            let parakeet = FakeFileRecognizer(.success("parakeet words"))
            let transcripts = ReceivedAudioTranscripts(
                files: files, transcription: transcription(choice, apple: apple, parakeet: parakeet),
                permission: FakePermission(.authorized))
            transcripts.start(file)
            await waitForEnd(transcripts)
            let expected = choice == .parakeet ? "parakeet words" : "apple words"
            #expect(transcripts.state(for: file) == .done(expected))
            #expect(transport.calls.isEmpty, "\(choice): \(transport.calls)")
            #expect((apple.calls + parakeet.calls).allSatisfy { $0 == files.localURL(for: file) })
        }
    }

    @Test func unreadableFormatDoesNotRun() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try loader(folder: folder, playable: false)
        try await prepareAudio(files)
        let runs = Mutex(0)
        let transcripts = ReceivedAudioTranscripts(files: files) { _, _ in
            runs.withLock { $0 += 1 }
            return "x"
        }
        transcripts.start(file)
        #expect(transcripts.state(for: file) == .unreadable)
        #expect(runs.withLock { $0 } == 0)
        #expect(!FileManager.default.fileExists(atPath: transcripts.transcriptURL(for: file).path))
    }

    @Test func noRunWhileTheAudioPrepares() throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try loader(folder: folder)
        let transcripts = ReceivedAudioTranscripts(files: files) { _, _ in "x" }
        transcripts.start(file)
        #expect(transcripts.state(for: file) == .none)
    }

    @Test func cancelStopsTheRunAndSavesNothing() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try loader(folder: folder)
        try await prepareAudio(files)
        let transcripts = ReceivedAudioTranscripts(files: files) { _, progress in
            progress(0.42)
            try await Task.sleep(for: .seconds(30))
            return "late words"
        }
        transcripts.start(file)
        let task = transcripts.task(for: file)
        for _ in 0..<100 where transcripts.state(for: file) == .transcribing(nil) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transcripts.state(for: file) == .transcribing(0.42))
        #expect(AudioFileTranscript.transcribing(0.42).caption == "Transcribing… 42%. Tap to cancel.")
        transcripts.cancel(file)
        #expect(transcripts.state(for: file) == .none)
        await task?.value
        #expect(transcripts.state(for: file) == .none)
        #expect(!FileManager.default.fileExists(atPath: transcripts.transcriptURL(for: file).path))
    }

    @Test func noPermissionThenRetry() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try loader(folder: folder)
        try await prepareAudio(files)
        let permission = FakePermission(.denied)
        let apple = FakeFileRecognizer(.success("apple words"))
        let transcripts = ReceivedAudioTranscripts(files: files, transcription: transcription(.appleOnDevice, apple: apple),
                                                   permission: permission)
        transcripts.start(file)
        await waitForEnd(transcripts)
        #expect(transcripts.state(for: file) == .noPermission)
        #expect(transcripts.state(for: file).canStart)
        #expect(apple.calls.isEmpty)
    }

    @Test func failureCanRetry() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try loader(folder: folder)
        try await prepareAudio(files)
        let fail = Mutex(true)
        let transcripts = ReceivedAudioTranscripts(files: files) { _, _ in
            if fail.withLock({ $0 }) { throw AudioFileTranscriptionError.failed }
            return "second try"
        }
        transcripts.start(file)
        await waitForEnd(transcripts)
        #expect(transcripts.state(for: file) == .failed)
        fail.withLock { $0 = false }
        transcripts.start(file)
        await waitForEnd(transcripts)
        #expect(transcripts.state(for: file) == .done("second try"))
    }

    @Test func otherFilesHaveNoTranscript() throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try loader(folder: folder)
        let transcripts = ReceivedAudioTranscripts(files: files) { _, _ in "x" }
        let pdf = ReceivedFile(path: "/tmp/report.pdf")
        transcripts.start(pdf)
        #expect(transcripts.state(for: pdf) == .none)
    }

    @Test func captions() {
        #expect(AudioFileTranscript.none.caption == "Transcribe")
        #expect(AudioFileTranscript.transcribing(nil).caption == "Transcribing… Tap to cancel.")
        #expect(AudioFileTranscript.empty.caption == "No speech found.")
        #expect(AudioFileTranscript.noPermission.caption == "Speech Recognition is off. Tap to try again.")
        #expect(AudioFileTranscript.unreadable.caption == "Can't read this audio format.")
        #expect(AudioFileTranscript.failed.caption == "Couldn't transcribe. Tap to retry.")
        #expect(AudioFileTranscript.done("Hi").caption == "Hi")
        #expect(!AudioFileTranscript.done("Hi").canStart)
        #expect(!AudioFileTranscript.unreadable.canStart)
    }
}
