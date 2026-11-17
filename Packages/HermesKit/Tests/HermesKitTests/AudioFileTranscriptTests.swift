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

    /// Issue #87 (QA #86 note 2): the unreadable state is saved, so a relaunch shows it with no "Transcribe".
    @Test func unreadableFormatDoesNotRunAndSurvivesARelaunch() async throws {
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
        #expect(FileManager.default.fileExists(atPath: transcripts.transcriptURL(for: file).path))

        let relaunched = ReceivedAudioTranscripts(files: try loader(folder: folder, playable: false)) { _, _ in
            runs.withLock { $0 += 1 }
            return "x"
        }
        #expect(relaunched.state(for: file) == .unreadable)
        #expect(!relaunched.state(for: file).canStart)
        relaunched.start(file)
        #expect(runs.withLock { $0 } == 0)
    }

    /// Issue #87: a transcript that a #50 build saved (version 1) reads as before.
    @Test func version1TranscriptsStillRead() throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let done = folder.appending(path: "done.json")
        let empty = folder.appending(path: "empty.json")
        try Data(#"{"version":1,"text":"Old words."}"#.utf8).write(to: done)
        try Data(#"{"version":1,"text":""}"#.utf8).write(to: empty)
        #expect(ReceivedAudioTranscripts.load(done) == .done("Old words."))
        #expect(ReceivedAudioTranscripts.load(empty) == .empty)
        #expect(ReceivedAudioTranscripts.load(folder.appending(path: "none.json")) == nil)
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

// MARK: - Issue #87: sent audio files, and the runs stop when the owner leaves the chat

/// A run that waits until it is cancelled. It records the cancel, so a test sees that the engine stopped.
private final class CancelProbe: Sendable {
    private let started = Mutex(0)
    private let stopped = Mutex(0)
    var starts: Int { started.withLock { $0 } }
    var cancels: Int { stopped.withLock { $0 } }

    var transcribe: ReceivedAudioTranscripts.Transcribe {
        { [self] _, progress in
            started.withLock { $0 += 1 }
            progress(0.1)
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                stopped.withLock { $0 += 1 }
                throw error
            }
            return "late words"
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SentAudioTranscriptsTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "SentAudioTranscripts-\(UUID().uuidString)",
                                                         directoryHint: .isDirectory)
    }

    /// A sent file in its private folder, as `AttachmentImport` makes it: `<folder>/<id>/<name>`.
    private func sentFile(_ name: String, in folder: URL, mimeType: String = "audio/mp4",
                          onDisk: Bool = true) throws -> ChatAttachment {
        let id = UUID().uuidString
        let url = folder.appending(path: id, directoryHint: .isDirectory).appending(path: name)
        if onDisk {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("RIFF".utf8).write(to: url)
        }
        return ChatAttachment(id: id, kind: .file, name: name, byteCount: 4, fileURL: url, mimeType: mimeType,
                              upload: .attached)
    }

    private func emptyLoader(_ folder: URL, transport: ServerCountingTransport? = nil) -> ReceivedFileLoader {
        guard let transport else {
            return ReceivedFileLoader(download: nil, folder: folder.appending(path: "received"), storedSessionId: { "st1" })
        }
        return ReceivedFileLoader(download: { path, session, maxBytes, progress in
            try await transport.downloadReceivedFile(path: path, storedSessionId: session, maxBytes: maxBytes,
                                                     progress: progress)
        }, folder: folder.appending(path: "received"), storedSessionId: { "st1" })
    }

    private func waitForEnd(_ transcripts: ReceivedAudioTranscripts, _ item: ChatAttachment) async {
        await transcripts.task(for: item)?.value
        for _ in 0..<50 where transcripts.state(for: item).isTranscribing { await Task.yield() }
    }

    private func waitForStart(_ probe: CancelProbe, count: Int) async throws {
        for _ in 0..<300 where probe.starts < count { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Acceptance criterion: a sent audio file shows the transcribe action, as a received one does.
    @Test func sentAudioFileTranscribesAndSurvivesARelaunch() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try sentFile("Voice note.m4a", in: folder)
        let runs = Mutex<[URL]>([])
        let prepared = Mutex<[URL]>([])
        let transcripts = ReceivedAudioTranscripts(files: emptyLoader(folder), transcribe: { url, _ in
            runs.withLock { $0.append(url) }
            return "Pick up the keys."
        }, prepareSent: { url in
            prepared.withLock { $0.append(url) }
            return url
        })
        var sentChanges: [String] = []
        var receivedChanges = 0
        transcripts.onSentChange = { sentChanges.append($0.id) }
        transcripts.onChange = { _ in receivedChanges += 1 }
        #expect(transcripts.canTranscribe(item))
        #expect(transcripts.state(for: item) == .none)
        transcripts.start(item)
        #expect(transcripts.state(for: item) == .transcribing(nil))
        await waitForEnd(transcripts, item)
        #expect(transcripts.state(for: item) == .done("Pick up the keys."))
        #expect(sentChanges == [item.id, item.id])
        #expect(receivedChanges == 0)
        #expect(prepared.withLock { $0 } == [item.fileURL])
        #expect(runs.withLock { $0 } == [item.fileURL])
        // The transcript sits next to the private copy of the sent file.
        let saved = item.fileURL.deletingLastPathComponent().appending(path: "transcript.json")
        #expect(transcripts.transcriptURL(for: item) == saved)
        #expect(FileManager.default.fileExists(atPath: saved.path))

        let relaunched = ReceivedAudioTranscripts(files: emptyLoader(folder)) { _, _ in
            runs.withLock { $0.append(URL(filePath: "/again")) }
            return "other"
        }
        #expect(relaunched.state(for: item) == .done("Pick up the keys."))
        relaunched.start(item)
        #expect(relaunched.task(for: item) == nil)
        #expect(runs.withLock { $0.count } == 1)
    }

    /// The #50 engine chain: only on-device recognizers, and no server call, for each Settings choice.
    @Test func sentFileStaysOnThePhone() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for choice in TranscriptionEngine.allCases {
            let transport = ServerCountingTransport()
            let item = try sentFile("memo-\(choice.rawValue).wav", in: folder, mimeType: "audio/wav")
            let apple = FakeFileRecognizer(.success("apple words"))
            let parakeet = FakeFileRecognizer(.success("parakeet words"))
            // The app engine chain (`transcribeFile`). The prepare step is a fake: the test file is not real audio.
            let engine = transcription(choice, apple: apple, parakeet: parakeet)
            let fake = ReceivedAudioTranscripts(files: emptyLoader(folder, transport: transport), transcribe: { url, progress in
                try await engine.transcribeFile(at: url, permission: FakePermission(.authorized), progress: progress)
            }, prepareSent: { $0 })
            fake.start(item)
            await waitForEnd(fake, item)
            let expected = choice == .parakeet ? "parakeet words" : "apple words"
            #expect(fake.state(for: item) == .done(expected))
            #expect(transport.calls.isEmpty, "\(choice): \(transport.calls)")
            #expect((apple.calls + parakeet.calls).allSatisfy { $0 == item.fileURL })
        }
    }

    /// Acceptance criterion: the unreadable state is saved and shows after a relaunch. The real prepare step
    /// reads the file, so bytes that are not audio give `unreadable` with no engine run.
    @Test func sentUnreadableFormatIsSavedAndSurvivesARelaunch() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try sentFile("broken.mp3", in: folder, mimeType: "audio/mpeg")
        let runs = Mutex(0)
        let transcripts = ReceivedAudioTranscripts(files: emptyLoader(folder)) { _, _ in
            runs.withLock { $0 += 1 }
            return "x"
        }
        transcripts.start(item)
        await waitForEnd(transcripts, item)
        #expect(transcripts.state(for: item) == .unreadable)
        #expect(runs.withLock { $0 } == 0)
        #expect(FileManager.default.fileExists(atPath: transcripts.transcriptURL(for: item).path))

        let relaunched = ReceivedAudioTranscripts(files: emptyLoader(folder)) { _, _ in
            runs.withLock { $0 += 1 }
            return "x"
        }
        #expect(relaunched.state(for: item) == .unreadable)
        #expect(!relaunched.state(for: item).canStart)
        relaunched.start(item)
        #expect(relaunched.task(for: item) == nil)
        #expect(runs.withLock { $0 } == 0)
    }

    @Test func onlySentAudioFilesOnThePhoneHaveTheAction() throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcripts = ReceivedAudioTranscripts(files: emptyLoader(folder)) { _, _ in "x" }
        for name in ["a.mp3", "b.M4A", "c.ogg", "d.wav"] {
            #expect(transcripts.canTranscribe(try sentFile(name, in: folder, mimeType: "")), "\(name)")
        }
        // An `audio/` MIME type with no audio extension.
        #expect(transcripts.canTranscribe(try sentFile("recording", in: folder, mimeType: "audio/mpeg")))
        #expect(!transcripts.canTranscribe(try sentFile("Lease.pdf", in: folder, mimeType: "application/pdf")))
        #expect(!transcripts.canTranscribe(try sentFile("notes.txt", in: folder, mimeType: "text/plain")))
        // A cell from a server `@file:` ref, or a copy that the system cleared: no file on the phone.
        let gone = try sentFile("gone.mp3", in: folder, onDisk: false)
        #expect(!transcripts.canTranscribe(gone))
        transcripts.start(gone)
        #expect(transcripts.task(for: gone) == nil)
        #expect(transcripts.state(for: gone) == .none)
        // Photos and PDFs are not audio files, whatever their name.
        var photo = try sentFile("x.mp3", in: folder)
        photo.kind = .photo
        #expect(!photo.isAudioFile)
        var pdf = try sentFile("y.wav", in: folder)
        pdf.kind = .pdf
        #expect(!pdf.isAudioFile)
    }

    @Test func sentCancelStopsTheRunAndSavesNothing() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try sentFile("long.m4a", in: folder)
        let probe = CancelProbe()
        let transcripts = ReceivedAudioTranscripts(files: emptyLoader(folder), transcribe: probe.transcribe,
                                                   prepareSent: { $0 })
        transcripts.start(item)
        try await waitForStart(probe, count: 1)
        let task = transcripts.task(for: item)
        transcripts.cancel(item)
        #expect(transcripts.state(for: item) == .none)
        await task?.value
        #expect(probe.cancels == 1)
        #expect(transcripts.state(for: item) == .none)
        #expect(!FileManager.default.fileExists(atPath: transcripts.transcriptURL(for: item).path))
    }

    /// Acceptance criterion: a running transcription stops when the owner leaves the chat (QA #86 note 1).
    /// The screen calls `cancelAll()`: the received and the sent runs stop, and nothing is saved.
    @Test func leavingTheChatStopsEachRun() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ReceivedFileLoader(download: nil, folder: folder.appending(path: "received"),
                                       storedSessionId: { "st1" },
                                       prepareAudio: { VoiceReplyAudio(fileURL: $0, duration: 720) })
        let received = ReceivedFile(path: "/home/hermes/.hermes/outputs/call.wav")
        let local = files.localURL(for: received)
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: local)
        for _ in 0..<200 where files.audio(for: received) == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        let item = try sentFile("sent.m4a", in: folder)
        let probe = CancelProbe()
        let transcripts = ReceivedAudioTranscripts(files: files, transcribe: probe.transcribe, prepareSent: { $0 })
        transcripts.start(received)
        transcripts.start(item)
        try await waitForStart(probe, count: 2)
        #expect(transcripts.isRunning)
        let tasks = [transcripts.task(for: received), transcripts.task(for: item)].compactMap(\.self)
        #expect(tasks.count == 2)

        transcripts.cancelAll()
        #expect(!transcripts.isRunning)
        #expect(transcripts.state(for: received) == .none)
        #expect(transcripts.state(for: item) == .none)
        for task in tasks { await task.value }
        #expect(probe.cancels == 2)
        #expect(!FileManager.default.fileExists(atPath: transcripts.transcriptURL(for: received).path))
        #expect(!FileManager.default.fileExists(atPath: transcripts.transcriptURL(for: item).path))
    }

    /// The store goes with the screen. A run that it started does not keep the engine busy.
    @Test func releasingTheStoreStopsTheRun() async throws {
        let folder = tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try sentFile("sent.m4a", in: folder)
        let probe = CancelProbe()
        var transcripts: ReceivedAudioTranscripts? = ReceivedAudioTranscripts(
            files: emptyLoader(folder), transcribe: probe.transcribe, prepareSent: { $0 })
        transcripts?.start(item)
        try await waitForStart(probe, count: 1)
        let task = try #require(transcripts?.task(for: item))
        transcripts = nil
        await task.value
        #expect(probe.cancels == 1)
        #expect(!FileManager.default.fileExists(atPath: item.fileURL.deletingLastPathComponent()
            .appending(path: "transcript.json").path))
    }
}
