import Foundation
import Synchronization
import Testing
@testable import HermesKit

// Issue #44: on-device transcription (Apple On-Device, Parakeet) with the server as the fallback.

private struct RecognizerFailed: Error {}

/// A fake on-device recognizer: it counts calls and returns a set result.
private final class FakeRecognizer: OnDeviceTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [URL] = []
    private let result: Result<String, any Error>
    init(_ result: Result<String, any Error>) { self.result = result }
    var calls: [URL] { lock.withLock { _calls } }
    func transcribe(fileURL: URL) async throws -> String {
        lock.withLock { _calls.append(fileURL) }
        return try result.get()
    }
}

/// A fake `POST /api/audio/transcribe` that counts calls.
private final class ServerCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func call(_ text: String) -> String { lock.withLock { _count += 1 }; return text }
}

private let memoURL = URL(fileURLWithPath: "/tmp/voice-test/t1.m4a")

@Suite struct TranscriptionEngineTests {
    @Test func appleOnDeviceIsTheDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "engine-\(UUID().uuidString)"))
        #expect(TranscriptionEngine.current(defaults) == .appleOnDevice)
        defaults.set("parakeet", forKey: TranscriptionEngine.settingsKey)
        #expect(TranscriptionEngine.current(defaults) == .parakeet)
        defaults.set("server", forKey: TranscriptionEngine.settingsKey)
        #expect(TranscriptionEngine.current(defaults) == .server)
        // An unknown value from a later build falls back to the default.
        defaults.set("whisper", forKey: TranscriptionEngine.settingsKey)
        #expect(TranscriptionEngine.current(defaults) == .appleOnDevice)
    }

    @Test func threeChoicesInSettingsOrder() {
        #expect(TranscriptionEngine.allCases == [.appleOnDevice, .parakeet, .server])
        #expect(TranscriptionEngine.allCases.map(\.title) == ["Apple On-Device", "Parakeet", "Server"])
        #expect(TranscriptionEngine.appleOnDevice.isOnDevice && TranscriptionEngine.parakeet.isOnDevice)
        #expect(!TranscriptionEngine.server.isOnDevice)
    }

    @Test(arguments: [
        (TranscriptionEngine.appleOnDevice, false, TranscriptionEngine.appleOnDevice),
        (.appleOnDevice, true, .appleOnDevice),
        (.parakeet, true, .parakeet),
        // Design notes: Parakeet picked but not downloaded uses Apple On-Device.
        (.parakeet, false, .appleOnDevice),
        (.server, true, .server),
        (.server, false, .server),
    ])
    func effectiveEngine(choice: TranscriptionEngine, parakeetReady: Bool, expected: TranscriptionEngine) {
        let transcription = VoiceTranscription(engine: { choice }, apple: FakeRecognizer(.success("a")),
                                               parakeet: FakeRecognizer(.success("p")),
                                               parakeetReady: { parakeetReady })
        #expect(transcription.effectiveEngine == expected)
    }
}

@Suite struct VoiceTranscriptionTests {
    private func transcription(_ choice: TranscriptionEngine, apple: FakeRecognizer, parakeet: FakeRecognizer,
                               parakeetReady: Bool = true) -> VoiceTranscription {
        VoiceTranscription(engine: { choice }, apple: apple, parakeet: parakeet, parakeetReady: { parakeetReady })
    }

    @Test func appleOnDeviceDoesNotCallTheServer() async throws {
        let apple = FakeRecognizer(.success("  Call Sam at three. \n"))
        let parakeet = FakeRecognizer(.success("p"))
        let server = ServerCalls()
        let text = try await transcription(.appleOnDevice, apple: apple, parakeet: parakeet)
            .transcribe(fileURL: memoURL) { server.call("server") }
        #expect(text == "Call Sam at three.")
        #expect(apple.calls == [memoURL])
        #expect(parakeet.calls.isEmpty)
        #expect(server.count == 0)
    }

    @Test func parakeetDoesNotCallTheServer() async throws {
        let apple = FakeRecognizer(.success("a"))
        let parakeet = FakeRecognizer(.success("Parakeet text"))
        let server = ServerCalls()
        let text = try await transcription(.parakeet, apple: apple, parakeet: parakeet)
            .transcribe(fileURL: memoURL) { server.call("server") }
        #expect(text == "Parakeet text")
        #expect(apple.calls.isEmpty)
        #expect(server.count == 0)
    }

    @Test func parakeetNotDownloadedUsesApple() async throws {
        let apple = FakeRecognizer(.success("Apple text"))
        let parakeet = FakeRecognizer(.success("p"))
        let server = ServerCalls()
        let text = try await transcription(.parakeet, apple: apple, parakeet: parakeet, parakeetReady: false)
            .transcribe(fileURL: memoURL) { server.call("server") }
        #expect(text == "Apple text")
        #expect(parakeet.calls.isEmpty)
        #expect(server.count == 0)
    }

    @Test(arguments: [TranscriptionEngine.appleOnDevice, .parakeet])
    func onDeviceFailureUsesTheServer(choice: TranscriptionEngine) async throws {
        let apple = FakeRecognizer(.failure(RecognizerFailed()))
        let parakeet = FakeRecognizer(.failure(RecognizerFailed()))
        let server = ServerCalls()
        let text = try await transcription(choice, apple: apple, parakeet: parakeet)
            .transcribe(fileURL: memoURL) { server.call("from the server") }
        #expect(text == "from the server")
        #expect(server.count == 1)
    }

    @Test func emptyOnDeviceResultAsksTheServer() async throws {
        let apple = FakeRecognizer(.success("  "))
        let server = ServerCalls()
        let text = try await transcription(.appleOnDevice, apple: apple, parakeet: FakeRecognizer(.success("")))
            .transcribe(fileURL: memoURL) { server.call("late words") }
        #expect(text == "late words")
        #expect(server.count == 1)
    }

    @Test func missingRecognizerUsesTheServer() async throws {
        let server = ServerCalls()
        let transcription = VoiceTranscription(engine: { .appleOnDevice }, apple: nil, parakeet: nil,
                                               parakeetReady: { false })
        let text = try await transcription.transcribe(fileURL: memoURL) { server.call("s") }
        #expect(text == "s")
        #expect(server.count == 1)
    }

    @Test func serverChoiceCallsOnlyTheServer() async throws {
        let apple = FakeRecognizer(.success("a"))
        let parakeet = FakeRecognizer(.success("p"))
        let server = ServerCalls()
        let text = try await transcription(.server, apple: apple, parakeet: parakeet)
            .transcribe(fileURL: memoURL) { server.call("s") }
        #expect(text == "s")
        #expect(apple.calls.isEmpty && parakeet.calls.isEmpty)
        #expect(server.count == 1)
        #expect(VoiceTranscription.server.effectiveEngine == .server)
    }
}

// MARK: - Chat flow

/// A voice transport that counts `/api/audio/transcribe` calls and records the voice turns.
private final class CountingVoiceTransport: ChatTransport, @unchecked Sendable {
    let events: AsyncStream<GatewayClientEvent>
    private let lock = NSLock()
    private var _uploads = 0
    private var _turns: [String] = []
    let serverResult: Result<String, any Error>
    init(serverResult: Result<String, any Error> = .success("server words")) {
        self.serverResult = serverResult
        events = AsyncStream { _ in }
    }
    var uploads: Int { lock.withLock { _uploads } }
    var turns: [String] { lock.withLock { _turns } }
    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: "st1")
    }
    func resumeSession(storedId: String, source _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: storedId)
    }
    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? { 1 }
    func submitVoicePrompt(sessionId _: String, text: String, retryBeforeRowId _: Int?) async throws -> Int? {
        lock.withLock { _turns.append(text) }
        return 2
    }
    func transcribe(audio _: Data, mimeType _: String) async throws -> String {
        lock.withLock { _uploads += 1 }
        return try serverResult.get()
    }
    func stopReply(sessionId _: String) async throws -> Bool { true }
    func history(sessionId _: String) async throws -> [TranscriptMessage] { [] }
}

/// Counts reads of the memo file. The server path reads it; the on-device path does not.
private final class FileReads: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func read() -> Data { lock.withLock { _count += 1 }; return Data("m4a".utf8) }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct OnDeviceVoiceMemoChatTests {
    private func model(_ transport: CountingVoiceTransport, transcription: VoiceTranscription,
                       reads: FileReads = FileReads()) -> ChatViewModel {
        let counter = Mutex(0)
        return ChatViewModel(transport: transport, redrawInterval: .seconds(60),
                             makeId: { counter.withLock { $0 += 1; return "d\($0)" } },
                             loadAudio: { _ in reads.read() }, removeAudio: { _ in },
                             transcription: transcription)
    }

    private func memo() -> VoiceMemo { VoiceMemo(fileURL: memoURL, duration: 3, waveform: [0.4]) }

    @Test(arguments: [TranscriptionEngine.appleOnDevice, .parakeet])
    func onDeviceMemoSkipsTheTranscribeCall(choice: TranscriptionEngine) async {
        let transport = CountingVoiceTransport()
        let reads = FileReads()
        let local = FakeRecognizer(.success("on the phone"))
        let model = model(transport, transcription: VoiceTranscription(
            engine: { choice }, apple: local, parakeet: local, parakeetReady: { true }), reads: reads)
        await model.sendVoiceMemo(memo()).value
        #expect(transport.uploads == 0)
        #expect(reads.count == 0)
        #expect(transport.turns == ["on the phone"])
        #expect(model.messages.first?.voice?.transcript == .done("on the phone"))
        #expect(model.messages.first?.delivery == .delivered)
    }

    @Test func onDeviceFailureRunsTheServerPathAndKeepsTheMemo() async {
        let transport = CountingVoiceTransport()
        let reads = FileReads()
        let model = model(transport, transcription: VoiceTranscription(
            engine: { .appleOnDevice }, apple: FakeRecognizer(.failure(RecognizerFailed())), parakeet: nil,
            parakeetReady: { false }), reads: reads)
        await model.sendVoiceMemo(memo()).value
        #expect(transport.uploads == 1)
        #expect(reads.count == 1)
        #expect(transport.turns == ["server words"])
        #expect(model.messages.first?.voice?.fileURL == memoURL)
        #expect(model.messages.first?.delivery == .delivered)
    }

    @Test func bothPathsFailKeepTheMemoForTryAgain() async {
        let transport = CountingVoiceTransport(serverResult: .failure(RecognizerFailed()))
        let model = model(transport, transcription: VoiceTranscription(
            engine: { .parakeet }, apple: nil, parakeet: FakeRecognizer(.failure(RecognizerFailed())),
            parakeetReady: { true }))
        await model.sendVoiceMemo(memo()).value
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.voice?.transcript == .failed)
        #expect(model.messages.first?.delivery == .failed)
    }

    @Test func serverChoiceKeepsTheOldPath() async {
        let transport = CountingVoiceTransport()
        let local = FakeRecognizer(.success("x"))
        let model = model(transport, transcription: VoiceTranscription(
            engine: { .server }, apple: local, parakeet: local, parakeetReady: { true }))
        await model.sendVoiceMemo(memo()).value
        #expect(transport.uploads == 1)
        #expect(local.calls.isEmpty)
        #expect(transport.turns == ["server words"])
    }
}

// MARK: - Parakeet model store

/// A fake model download. The test drives the progress and the end.
private final class FakeDownloader: TranscriptionModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: Set<String> = []
    private var _starts = 0
    private var gate: CheckedContinuation<Void, any Error>?
    private var progress: (@Sendable (Double) -> Void)?
    var fail = false

    var starts: Int { lock.withLock { _starts } }
    var isWaiting: Bool { lock.withLock { gate != nil } }

    func isInstalled(at directory: URL) -> Bool { lock.withLock { installed.contains(directory.path) } }

    func download(to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    _starts += 1
                    self.progress = progress
                    gate = continuation
                }
            }
        } onCancel: {
            let pending = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                defer { gate = nil }
                return gate
            }
            pending?.resume(throwing: CancellationError())
        }
        lock.withLock { installed.insert(directory.path) }
    }

    func report(_ fraction: Double) {
        let handler = lock.withLock { progress }
        handler?(fraction)
    }

    func finish() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { gate = nil }
            return gate
        }
        if fail { pending?.resume(throwing: RecognizerFailed()) } else { pending?.resume() }
    }

    func markInstalled(_ directory: URL) { lock.withLock { _ = installed.insert(directory.path) } }
    func removeMark(_ directory: URL) { lock.withLock { _ = installed.remove(directory.path) } }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct TranscriptionModelStoreTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-\(UUID().uuidString)")
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func startsNotDownloadedAndShowsTheSize() {
        let store = TranscriptionModelStore(directory: directory(), downloader: FakeDownloader(),
                                            sizeBytes: 485_000_000)
        #expect(store.state == .notDownloaded)
        #expect(!store.isReady)
        #expect(store.downloadTitle == "Download (485 MB)")
    }

    @Test func installedModelIsReadyAtLaunch() {
        let dir = directory()
        let downloader = FakeDownloader()
        downloader.markInstalled(dir)
        let store = TranscriptionModelStore(directory: dir, downloader: downloader, sizeBytes: 1)
        #expect(store.state == .ready)
        #expect(store.isReady)
    }

    @Test func downloadShowsProgressThenReady() async {
        let downloader = FakeDownloader()
        let store = TranscriptionModelStore(directory: directory(), downloader: downloader, sizeBytes: 1)
        store.download()
        #expect(store.state == .downloading(0))
        await waitUntil { downloader.isWaiting }
        downloader.report(0.4)
        await waitUntil { store.state == .downloading(0.4) }
        #expect(store.state == .downloading(0.4))
        // A second tap while it downloads starts nothing new.
        store.download()
        downloader.finish()
        await waitUntil { store.state == .ready }
        #expect(store.state == .ready)
        #expect(store.isReady)
        #expect(downloader.starts == 1)
    }

    @Test func cancelStopsTheDownloadAndRemovesPartFiles() async throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let downloader = FakeDownloader()
        let store = TranscriptionModelStore(directory: dir, downloader: downloader, sizeBytes: 1)
        store.download()
        await waitUntil { downloader.isWaiting }
        store.cancel()
        #expect(store.state == .notDownloaded)
        await waitUntil { !FileManager.default.fileExists(atPath: dir.path) }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(!store.isReady)
    }

    @Test func failedDownloadShowsFailedAndCanTryAgain() async {
        let downloader = FakeDownloader()
        downloader.fail = true
        let store = TranscriptionModelStore(directory: directory(), downloader: downloader, sizeBytes: 1)
        store.download()
        await waitUntil { downloader.isWaiting }
        downloader.finish()
        await waitUntil { store.state == .failed }
        #expect(store.state == .failed)
        downloader.fail = false
        store.download()
        await waitUntil { downloader.isWaiting }
        downloader.finish()
        await waitUntil { store.state == .ready }
        #expect(store.state == .ready)
    }

    @Test func deleteRemovesTheModel() async throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let downloader = FakeDownloader()
        downloader.markInstalled(dir)
        let unloaded = Mutex(0)
        let store = TranscriptionModelStore(directory: dir, downloader: downloader, sizeBytes: 1,
                                            onDelete: { unloaded.withLock { $0 += 1 } })
        #expect(store.state == .ready)
        downloader.removeMark(dir)
        await store.delete()
        #expect(store.state == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(unloaded.withLock { $0 } == 1)
    }
}
