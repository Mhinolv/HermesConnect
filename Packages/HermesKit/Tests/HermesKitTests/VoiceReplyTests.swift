import Foundation
import Synchronization
import Testing
@testable import HermesKit

private let speakToken = String(repeating: "ef", count: 32)
private let audioBytes = Data("mp3-bytes".utf8)

private func event(_ json: String) throws -> GatewayClientEvent {
    .event(try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8)))
}

private func complete(_ text: String, status: String = "complete") throws -> GatewayClientEvent {
    let quoted = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    return try event(#"{"type":"message.complete","session_id":"s1","payload":{"text":\#(quoted),"status":"\#(status)"}}"#)
}

// MARK: - Speak text and data URL

@Suite struct VoiceReplyTextTests {
    @Test func dataURLDecodes() throws {
        let audio = try #require(SpokenAudio.decode(dataURL: "data:audio/ogg;base64,\(audioBytes.base64EncodedString())"))
        #expect(audio == SpokenAudio(data: audioBytes, mimeType: "audio/ogg"))
    }

    @Test(arguments: ["", "audio/mpeg;base64,AAAA", "data:audio/mpeg,AAAA", "data:audio/mpeg;base64,***",
                      "data:audio/mpeg;base64,"])
    func badDataURLIsRefused(_ value: String) {
        #expect(SpokenAudio.decode(dataURL: value) == nil)
    }

    @Test func spokenTextDropsCodeBlocksMediaTagsAndMarks() {
        let text = "Run **this** on the [server](https://example.com):\n```\nrm -rf build\n```\nMEDIA:/tmp/a.png\nDone."
        let spoken = VoiceReplyText.spokenText(text)
        #expect(!spoken.contains("rm -rf"))
        #expect(!spoken.contains("MEDIA:"))
        #expect(!spoken.contains("**"))
        #expect(!spoken.contains("https://"))
        #expect(spoken.hasPrefix("Run this on the server:"))
        #expect(spoken.hasSuffix("Done."))
    }

    @Test func codeOnlyReplyHasNothingToSpeak() {
        #expect(VoiceReplyText.spokenText("```\nls -la\n```").isEmpty)
        #expect(VoiceReplyText.spokenText("  \n").isEmpty)
    }

    @Test(arguments: [("audio/mpeg", "mp3"), ("audio/ogg", "ogg"), ("audio/wav", "wav"), ("audio/flac", "flac"),
                      ("audio/opus", "opus"), ("application/x-unknown", "mp3")])
    func fileExtensionFollowsTheMimeType(mime: String, ext: String) {
        #expect(VoiceReplyFiles.fileExtension(mimeType: mime) == ext)
    }

    @Test func saveWritesTheFileInTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "VoiceReplyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = try VoiceReplyFiles.save(SpokenAudio(data: audioBytes, mimeType: "audio/ogg"), in: folder)
        #expect(saved.fileURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(saved.fileURL.pathExtension == "ogg")
        #expect(try Data(contentsOf: saved.fileURL) == audioBytes)
        // Bytes that are not audio have no length. The bubble then shows 0:00.
        #expect(saved.duration == 0)
    }

    @Test func autoPlayIsOnByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "VoiceReplyTests-\(UUID().uuidString)"))
        #expect(VoiceReplySettings.autoPlay(defaults))
        defaults.set(false, forKey: VoiceReplySettings.autoPlayKey)
        #expect(!VoiceReplySettings.autoPlay(defaults))
    }
}

// MARK: - REST

private final class SpeakLoader: HTTPDataLoading, Sendable {
    private let requests = Mutex<[URLRequest]>([])
    let status: Int
    let body: String

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    var recorded: [URLRequest] { requests.withLock { $0 } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.withLock { $0.append(request) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                 headerFields: nil)!)
    }
}

@Suite struct SpeakRequestTests {
    private func client(_ loader: SpeakLoader) throws -> HermesRESTClient {
        HermesRESTClient(endpoint: try GatewayEndpoint(port: 8123, token: speakToken), loader: loader)
    }

    @Test func postsTheTextAndDecodesTheDataURL() async throws {
        let loader = SpeakLoader(body: #"{"ok":true,"data_url":"data:audio/mpeg;base64,\#(audioBytes.base64EncodedString())","mime_type":"audio/mpeg","provider":"edge"}"#)
        let audio = try await client(loader).speak(text: "  Done. The call is at 3.  ")
        #expect(audio == SpokenAudio(data: audioBytes, mimeType: "audio/mpeg"))

        let request = try #require(loader.recorded.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://127.0.0.1:8123/api/audio/speak")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == speakToken)
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["text": "Done. The call is at 3."])
    }

    @Test(arguments: [(500, HermesAPIError.http(status: 500)), (400, .http(status: 400)), (401, .unauthorized)])
    func serverErrors(status: Int, error: HermesAPIError) async throws {
        let loader = SpeakLoader(status: status, body: #"{"detail":"Speech synthesis failed"}"#)
        await #expect(throws: error) { try await client(loader).speak(text: "Hi") }
    }

    @Test(arguments: [#"{"ok":false}"#, #"{"ok":true}"#, #"{"ok":true,"data_url":"nope"}"#])
    func badAnswersAreInvalid(_ body: String) async throws {
        await #expect(throws: HermesAPIError.invalidResponse) { try await client(SpeakLoader(body: body)).speak(text: "Hi") }
    }

    @Test func emptyTextIsRefusedBeforeTheCall() async throws {
        let loader = SpeakLoader(body: "{}")
        await #expect(throws: VoiceMemoError.badClip) { try await client(loader).speak(text: " \n") }
        #expect(loader.recorded.isEmpty)
    }

    @MainActor @Test func liveTransportSpeaksOnTheEndpoint() async throws {
        let loader = SpeakLoader(body: #"{"ok":true,"data_url":"data:audio/mpeg;base64,\#(audioBytes.base64EncodedString())"}"#)
        let transport = LiveChatTransport(makeClient: { GatewayClient(endpoint: $0,
                                                                      connector: FakeGatewayConnector(FakeGatewaySocket())) },
                                          makeREST: { HermesRESTClient(endpoint: $0, loader: loader) })
        await #expect(throws: GatewayError.notConnected) { try await transport.speak(text: "Hi") }
        transport.setEndpoint(try GatewayEndpoint(port: 9002, token: speakToken))
        #expect(try await transport.speak(text: "Hi").data == audioBytes)
        #expect(loader.recorded.first?.url?.port == 9002)
    }
}

// MARK: - Chat view model

/// Scripted transcribe, voice turns and speak. No network.
private final class FakeSpeakTransport: ChatTransport, @unchecked Sendable {
    let events: AsyncStream<GatewayClientEvent> = AsyncStream { _ in }
    private let lock = NSLock()
    private var _spoken: [String] = []
    private var _transcribes = 0
    var speakResult: Result<SpokenAudio, any Error> = .success(SpokenAudio(data: audioBytes, mimeType: "audio/mpeg"))
    var transcript: Result<String, any Error> = .success("Remind me to call Sam")

    struct Failure: Error {}

    var spoken: [String] { lock.withLock { _spoken } }
    var transcribes: Int { lock.withLock { _transcribes } }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: "st1")
    }

    func resumeSession(storedId: String, source _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: storedId)
    }

    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? { 11 }
    func submitVoicePrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? { 12 }

    func transcribe(audio _: Data, mimeType _: String) async throws -> String {
        try lock.withLock {
            _transcribes += 1
            return transcript
        }.get()
    }

    func speak(text: String) async throws -> SpokenAudio {
        try lock.withLock {
            _spoken.append(text)
            return speakResult
        }.get()
    }

    func stopReply(sessionId _: String) async throws -> Bool { true }
    func history(sessionId _: String) async throws -> [TranscriptMessage] { [] }
}

private let replyURL = URL(fileURLWithPath: "/tmp/voice-reply-test/r1.mp3")
private let memoFile = URL(fileURLWithPath: "/tmp/voice-reply-test/m1.m4a")

private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw FakeTimeout(what: "condition")
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct VoiceReplyChatTests {
    private func model(_ transport: FakeSpeakTransport, cache: (any SessionCacheStore)? = nil,
                       storedSessionId: String? = nil) -> ChatViewModel {
        let counter = Mutex(0)
        return ChatViewModel(transport: transport, storedSessionId: storedSessionId, cache: cache,
                             redrawInterval: .seconds(60),
                             makeId: { counter.withLock { $0 += 1; return "m\($0)" } },
                             loadAudio: { _ in Data("m4a".utf8) }, removeAudio: { _ in },
                             saveSpeech: { _ in VoiceReplyAudio(fileURL: replyURL, duration: 24) })
    }

    private func memo() -> VoiceMemo {
        VoiceMemo(fileURL: memoFile, duration: 5, waveform: [0.4, 0.6])
    }

    /// A delivered voice memo and its reply. Returns the reply id.
    private func voiceTurn(_ vm: ChatViewModel, reply: String = "Done. The call is at **3**.",
                           status: String = "complete") async throws -> String {
        await vm.sendVoiceMemo(memo()).value
        vm.receive(try complete(reply, status: status))
        return try #require(vm.messages.last { $0.role == .assistant }?.id)
    }

    @Test func voiceTurnSpeaksTheFinalTextThenAsksForAutoPlay() async throws {
        let transport = FakeSpeakTransport()
        let vm = model(transport)
        let id = try await voiceTurn(vm)
        // The audio bubble shows at once with "Preparing audio…".
        #expect(vm.messages.last?.spokenReply == .preparing)
        #expect(vm.autoPlayReplyId == nil)
        let parts = ChatBubbleParts.parts(for: ChatTimeline.rows(for: vm.messages))
        #expect(parts.suffix(2).map(\.content) == [.text, .spokenReply])

        try await waitUntil { vm.messages.last?.spokenReply?.audio != nil }
        #expect(vm.messages.last?.spokenReply == .ready(VoiceReplyAudio(fileURL: replyURL, duration: 24)))
        #expect(transport.spoken == ["Done. The call is at 3."])
        #expect(vm.autoPlayReplyId == id)
    }

    @Test func textTurnDoesNotSpeak() async throws {
        let transport = FakeSpeakTransport()
        let vm = model(transport)
        await vm.send("What time is the call?")?.value
        vm.receive(try complete("At 3."))
        try await Task.sleep(for: .milliseconds(20))
        #expect(vm.messages.last?.spokenReply == nil)
        #expect(transport.spoken.isEmpty)
        #expect(ChatBubbleParts.parts(for: ChatTimeline.rows(for: vm.messages)).allSatisfy { $0.content == .text })
    }

    @Test(arguments: ["interrupted", "error"])
    func stoppedOrFailedReplyDoesNotSpeak(status: String) async throws {
        let transport = FakeSpeakTransport()
        let vm = model(transport)
        _ = try await voiceTurn(vm, reply: "Partial", status: status)
        try await Task.sleep(for: .milliseconds(20))
        #expect(vm.messages.last?.spokenReply == nil)
        #expect(transport.spoken.isEmpty)
    }

    @Test func codeOnlyReplyGetsNoAudioBubble() async throws {
        let transport = FakeSpeakTransport()
        let vm = model(transport)
        _ = try await voiceTurn(vm, reply: "```\nls -la\n```")
        #expect(vm.messages.last?.spokenReply == nil)
        #expect(transport.spoken.isEmpty)
    }

    @Test func failedSpeakShowsRetryAndRetryDoesNotAutoPlay() async throws {
        let transport = FakeSpeakTransport()
        transport.speakResult = .failure(FakeSpeakTransport.Failure())
        let vm = model(transport)
        let id = try await voiceTurn(vm)
        try await waitUntil { vm.messages.last?.spokenReply == .failed }
        #expect(ChatTimeline.rows(for: vm.messages).last?.footnote == .audioUnavailable)
        #expect(ChatRow.Footnote.audioUnavailable.text == "Audio unavailable. Tap to retry.")
        #expect(vm.autoPlayReplyId == nil)

        transport.speakResult = .success(SpokenAudio(data: audioBytes, mimeType: "audio/mpeg"))
        await vm.retrySpeech(id: id)?.value
        #expect(vm.messages.last?.spokenReply?.audio?.duration == 24)
        #expect(transport.spoken.count == 2)
        // The owner tapped retry: the screen plays only on a tap.
        #expect(vm.autoPlayReplyId == nil)
        // Ready audio is not spoken again.
        #expect(vm.retrySpeech(id: id) == nil)
    }

    @Test func historyMergeKeepsTheAudio() async throws {
        let transport = FakeSpeakTransport()
        let vm = model(transport)
        _ = try await voiceTurn(vm)
        try await waitUntil { vm.messages.last?.spokenReply?.audio != nil }
        let rows = [
            TranscriptMessage(role: "user", text: "Remind me to call Sam", rowId: 12),
            TranscriptMessage(role: "assistant", text: "Done. The call is at **3**.", rowId: 13),
        ]
        let merged = ChatHistory.messages(from: rows, reusing: vm.messages)
        #expect(merged.last?.spokenReply?.audio?.fileURL == replyURL)
        #expect(merged.first?.voice != nil)
    }

    @Test func audioBubbleLabelAndParts() {
        let reply = ChatMessage(id: "r", role: .assistant, text: "Hi", date: Date(), reply: .complete,
                                spokenReply: .ready(VoiceReplyAudio(fileURL: replyURL, duration: 24)))
        let parts = ChatBubbleParts.parts(for: ChatTimeline.rows(for: [reply]))
        #expect(parts.map(\.id) == ["r", "r#speech"])
        #expect(parts[0].row.hasTail == false)
        #expect(parts[1].row.hasTail)
        #expect(ChatBubbleParts.accessibilityLabel(for: parts[1]) == "Hermes voice reply, 0:24")
        #expect(ChatBubbleParts.spokenReplyLabel(.preparing) == "Hermes voice reply, Preparing audio")
    }

    // MARK: Cache follow-ups from #9

    @Test func failedMemoIsCachedAndTryAgainWorksAfterARelaunch() async throws {
        let transport = FakeSpeakTransport()
        transport.transcript = .failure(FakeSpeakTransport.Failure())
        let cache = InMemorySessionCacheStore()
        let vm = model(transport, cache: cache, storedSessionId: "st1")
        await vm.sendVoiceMemo(memo()).value
        #expect(vm.messages.last?.delivery == .failed)

        // A relaunch: a new model reads the cache.
        let file = FileSessionCacheStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "VoiceReplyTests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: file.directory) }
        file.saveTranscript(cache.loadTranscript(sessionId: "st1"), sessionId: "st1")
        transport.transcript = .success("Remind me to call Sam")
        let again = model(transport, cache: file, storedSessionId: "st1")
        let kept = try #require(again.messages.last)
        #expect(kept.voice?.fileURL == memoFile)
        #expect(kept.voice?.transcript == .failed)
        #expect(kept.delivery == .failed)
        await again.retrySend(id: kept.id)?.value
        #expect(again.messages.last?.delivery == .delivered)
        #expect(again.messages.last?.voice?.transcript == .done("Remind me to call Sam"))
    }

    @Test func memoInCacheBeforeTheUploadEnds() async throws {
        let transport = FakeSpeakTransport()
        let cache = InMemorySessionCacheStore()
        let vm = model(transport, cache: cache, storedSessionId: "st1")
        let task = vm.sendVoiceMemo(memo())
        #expect(cache.loadTranscript(sessionId: "st1").last?.voice?.fileURL == memoFile)
        await task.value
    }

    @Test func deleteDropsTheMemoFromTheCache() async throws {
        let transport = FakeSpeakTransport()
        transport.transcript = .failure(FakeSpeakTransport.Failure())
        let cache = InMemorySessionCacheStore()
        let vm = model(transport, cache: cache, storedSessionId: "st1")
        await vm.sendVoiceMemo(memo()).value
        let id = try #require(vm.messages.last?.id)
        vm.delete(id: id)
        #expect(cache.loadTranscript(sessionId: "st1").isEmpty)
    }

    @Test func historyMergeKeepsAFailedMemo() {
        var thread = ChatThread(messages: [
            ChatMessage(id: "f", role: .user, text: "", date: Date(), delivery: .failed,
                        voice: VoiceMemo(fileURL: memoFile, duration: 5, waveform: [], transcript: .failed)),
        ])
        thread.replaceHistory([ChatMessage(id: "h1", role: .user, text: "Older", date: Date(), delivery: .delivered)])
        #expect(thread.messages.map(\.id) == ["h1", "f"])
    }
}

// MARK: - Cache file

@Suite struct VoiceCacheFileTests {
    private func store() -> FileSessionCacheStore {
        FileSessionCacheStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "VoiceCacheFileTests-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    @Test func memosAndReplyAudioRoundTrip() throws {
        let cache = store()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let date = Date(timeIntervalSince1970: 1_763_290_000)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let memoURL = home.appending(path: "Library/Application Support/VoiceMemos/a.m4a")
        let replyFile = home.appending(path: "Library/Application Support/HermesConnect/VoiceReplies/b.mp3")
        let messages = [
            ChatMessage(id: "u1", role: .user, text: "Call Sam", date: date, delivery: .delivered, userRowId: 7,
                        voice: VoiceMemo(fileURL: memoURL, duration: 14, waveform: [0.25, 0.5],
                                         transcript: .done("Call Sam"))),
            ChatMessage(id: "a1", role: .assistant, text: "Done.", date: date, reply: .complete, promptId: "u1",
                        spokenReply: .ready(VoiceReplyAudio(fileURL: replyFile, duration: 3))),
            ChatMessage(id: "u2", role: .user, text: "", date: date, delivery: .failed,
                        voice: VoiceMemo(fileURL: memoURL, duration: 2, waveform: [], transcript: .empty)),
            ChatMessage(id: "u3", role: .user, text: "", date: date, delivery: .sending,
                        voice: VoiceMemo(fileURL: memoURL, duration: 9, waveform: [], transcript: .pending)),
            ChatMessage(id: "a2", role: .assistant, text: "Later", date: date, reply: .complete,
                        spokenReply: .preparing),
        ]
        cache.saveTranscript(messages, sessionId: "k")
        let loaded = FileSessionCacheStore(directory: cache.directory).loadTranscript(sessionId: "k")
        #expect(loaded.map(\.id) == ["u1", "a1", "u2", "u3", "a2"])
        #expect(loaded[0] == messages[0])
        #expect(loaded[1] == messages[1])
        #expect(loaded[2] == messages[2])
        // A memo that was still in "Transcribing…" reads as failed, with "Try Again".
        #expect(loaded[3].delivery == .failed)
        #expect(loaded[3].voice?.transcript == .failed)
        // A reply that was still in "Preparing audio…" reads as failed, with "Tap to retry".
        #expect(loaded[4].spokenReply == .failed)

        let raw = try String(contentsOf: cache.transcriptURL(sessionId: "k"), encoding: .utf8)
        #expect(raw.contains(#""version":2"#))
        #expect(!raw.contains(NSHomeDirectory()))
    }

    @Test func pathsFollowAMovedAppFolder() {
        let url = URL(fileURLWithPath: "/old/home/Library/VoiceMemos/a.m4a")
        let stored = CachedPath.encode(url, home: "/old/home")
        #expect(stored == "~/Library/VoiceMemos/a.m4a")
        #expect(CachedPath.decode(stored, home: "/new/home").path == "/new/home/Library/VoiceMemos/a.m4a")
        #expect(CachedPath.encode(URL(fileURLWithPath: "/tmp/x.m4a"), home: "/old/home") == "/tmp/x.m4a")
        #expect(CachedPath.decode("/tmp/x.m4a", home: "/new/home").path == "/tmp/x.m4a")
    }

    @Test func versionOneFileStillLoads() throws {
        let cache = store()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let url = cache.transcriptURL(sessionId: "k")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"body":[{"id":"u","role":"user","text":"Hi","date":1}]}"#.utf8).write(to: url)
        let loaded = cache.loadTranscript(sessionId: "k")
        #expect(loaded.count == 1)
        #expect(loaded[0].delivery == .delivered)
        #expect(loaded[0].voice == nil)
    }

    @Test func brokenVoiceEntryKeepsTheMessage() throws {
        let cache = store()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let url = cache.transcriptURL(sessionId: "k")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":2,"body":[{"id":"u","role":"user","text":"Hi","date":1,"voice":{"duration":"x"}}]}"#.utf8)
            .write(to: url)
        let loaded = cache.loadTranscript(sessionId: "k")
        #expect(loaded.map(\.text) == ["Hi"])
        #expect(loaded[0].voice == nil)
    }
}
