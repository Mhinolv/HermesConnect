import Foundation
import Synchronization
import Testing
@testable import HermesKit

// MARK: - Capture rules

@Suite struct VoiceMemoCaptureTests {
    @Test func shortPressStartsHandsFreeRecording() {
        var capture = VoiceMemoCapture()
        let pressed = capture.press(at: 10)
        #expect(pressed)
        #expect(capture.phase == .pressed)
        #expect(capture.tick(now: 10.2, recorded: 0.2).isEmpty)
        #expect(capture.release(at: 10.25) == .startTapMode)
        #expect(capture.phase == .recording)
        // A release in tap mode does nothing. Send ends it.
        #expect(capture.release(at: 11) == nil)
        #expect(capture.send() == .send)
        #expect(capture.phase == .idle)
    }

    @Test func holdRecordsWhileHeldAndReleaseSends() {
        var capture = VoiceMemoCapture()
        capture.press(at: 0)
        #expect(capture.tick(now: 0.29, recorded: 0.29).isEmpty)
        #expect(capture.tick(now: 0.3, recorded: 0.3) == [.startHold])
        #expect(capture.phase == .holding)
        #expect(capture.release(at: 4) == .send)
        #expect(capture.phase == .idle)
    }

    @Test func releaseAfterTheThresholdSendsEvenBeforeATick() {
        var capture = VoiceMemoCapture()
        capture.press(at: 0)
        #expect(capture.release(at: 0.31) == .send)
    }

    @Test(arguments: [(-79.0, false), (-80.0, true), (-200.0, true), (30.0, false)])
    func slideLeftCancelsAHold(dx: Double, cancels: Bool) {
        var capture = VoiceMemoCapture()
        capture.press(at: 0)
        _ = capture.tick(now: 0.5, recorded: 0.5)
        #expect((capture.drag(dx: dx) == .cancel) == cancels)
        #expect(capture.phase == (cancels ? .idle : .holding))
    }

    @Test func slideProgressFollowsTheFinger() {
        var capture = VoiceMemoCapture()
        capture.press(at: 0)
        _ = capture.drag(dx: -40)
        #expect(capture.cancelProgress == 0.5)
        _ = capture.drag(dx: 20)
        #expect(capture.cancelProgress == 0)
    }

    @Test func slideInTapModeDoesNothing() {
        var capture = VoiceMemoCapture()
        capture.press(at: 0)
        _ = capture.release(at: 0.1)
        #expect(capture.drag(dx: -200) == nil)
        #expect(capture.phase == .recording)
    }

    @Test func warningAtNineThirtyOnceThenSendAtTen() {
        var capture = VoiceMemoCapture()
        capture.startTapMode()
        #expect(capture.tick(now: 0, recorded: 569.9).isEmpty)
        #expect(capture.tick(now: 0, recorded: 570) == [.warn])
        #expect(capture.tick(now: 0, recorded: 580).isEmpty)
        #expect(capture.tick(now: 0, recorded: 600) == [.send])
        #expect(capture.phase == .idle)
        #expect(capture.tick(now: 0, recorded: 601).isEmpty)
    }

    @Test func holdAlsoSendsAtTheLimit() {
        var capture = VoiceMemoCapture()
        capture.press(at: 0)
        #expect(capture.tick(now: 600, recorded: 600) == [.startHold, .send])
    }

    @Test func interruptionPausesAndKeepsTheClip() {
        var capture = VoiceMemoCapture()
        capture.press(at: 0)
        _ = capture.tick(now: 1, recorded: 1)
        #expect(capture.interrupt() == .pause)
        #expect(capture.phase == .paused)
        #expect(capture.interrupt() == nil)
        // A paused clip does not send by itself, and a release does nothing.
        #expect(capture.tick(now: 700, recorded: 600).isEmpty)
        #expect(capture.release(at: 700) == nil)
        #expect(capture.send() == .send)
    }

    @Test func touchCancelledByTheSystemPauses() {
        var capture = VoiceMemoCapture()
        capture.press(at: 0)
        #expect(capture.touchCancelled() == .pause)
        #expect(capture.cancel() == .cancel)
        #expect(capture.phase == .idle)
        #expect(capture.touchCancelled() == nil)
    }

    @Test func pressWhileActiveIsRefused() {
        var capture = VoiceMemoCapture()
        let first = capture.startTapMode()
        let again = capture.press(at: 0)
        let tapAgain = capture.startTapMode()
        #expect(first)
        #expect(!again)
        #expect(!tapAgain)
        #expect(capture.send() == .send)
        #expect(capture.send() == nil)
        #expect(capture.cancel() == nil)
    }

    @Test func voiceOverHearsEachMinute() {
        var capture = VoiceMemoCapture()
        capture.startTapMode()
        #expect(capture.tick(now: 0, recorded: 59, voiceOver: true).isEmpty)
        #expect(capture.tick(now: 0, recorded: 60, voiceOver: true) == [.announceMinutes(1)])
        #expect(capture.tick(now: 0, recorded: 61, voiceOver: true).isEmpty)
        #expect(capture.tick(now: 0, recorded: 120, voiceOver: false).isEmpty)
        #expect(capture.tick(now: 0, recorded: 180, voiceOver: true) == [.announceMinutes(3)])
    }
}

// MARK: - Format and waveform

@Suite struct VoiceMemoFormatTests {
    @Test(arguments: [(0.0, "0:00"), (12.7, "0:12"), (570, "9:30"), (600, "10:00"), (-3, "0:00"), (.nan, "0:00")])
    func duration(seconds: TimeInterval, text: String) {
        #expect(VoiceMemoFormat.duration(seconds) == text)
    }

    @Test func spokenDuration() {
        #expect(VoiceMemoFormat.spokenDuration(1) == "1 second")
        #expect(VoiceMemoFormat.spokenDuration(12) == "12 seconds")
        #expect(VoiceMemoFormat.spokenDuration(60) == "1 minute")
        #expect(VoiceMemoFormat.spokenDuration(125) == "2 minutes 5 seconds")
    }

    @Test func levelMapsDecibelsToZeroThroughOne() {
        #expect(VoiceWaveform.level(decibels: 0) == 1)
        #expect(VoiceWaveform.level(decibels: 6) == 1)
        #expect(VoiceWaveform.level(decibels: -25) == 0.5)
        #expect(VoiceWaveform.level(decibels: -50) == 0)
        #expect(VoiceWaveform.level(decibels: -160) == 0)
        #expect(VoiceWaveform.level(decibels: -.infinity) == 0)
    }

    @Test func barsTakeThePeakOfEachSlice() {
        #expect(VoiceWaveform.bars(from: [], count: 4) == [0, 0, 0, 0])
        #expect(VoiceWaveform.bars(from: [0.1, 0.9, 0.2, 0.4], count: 2) == [0.9, 0.4])
        // Fewer levels than bars: each level fills more than one bar.
        #expect(VoiceWaveform.bars(from: [0.5, 1], count: 4) == [0.5, 0.5, 1, 1])
        #expect(VoiceWaveform.bars(from: Array(repeating: 0.3, count: 1000)).count == VoiceMemoLimits.waveformBars)
        #expect(VoiceWaveform.bars(from: [2, -1], count: 2) == [1, 0])
    }
}

// MARK: - REST transcribe

private let voiceToken = String(repeating: "cd", count: 32)

private final class TranscribeLoader: HTTPDataLoading, Sendable {
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

@Suite struct TranscribeRequestTests {
    private func client(_ loader: TranscribeLoader) throws -> HermesRESTClient {
        HermesRESTClient(endpoint: try GatewayEndpoint(port: 8123, token: voiceToken), loader: loader)
    }

    @Test func postsTheClipAsADataURLAndTrimsTheTranscript() async throws {
        let loader = TranscribeLoader(body: #"{"ok":true,"transcript":"  Book a table for two  ","provider":"local"}"#)
        let audio = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
        let text = try await client(loader).transcribe(audio: audio)
        #expect(text == "Book a table for two")

        let request = try #require(loader.recorded.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://127.0.0.1:8123/api/audio/transcribe")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == voiceToken)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 120)
        let body = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
        #expect(body["mime_type"] == "audio/mp4")
        #expect(body["data_url"] == "data:audio/mp4;base64,\(audio.base64EncodedString())")
    }

    @Test func silenceIsAnEmptyTranscript() async throws {
        let loader = TranscribeLoader(body: #"{"ok":true,"transcript":"","provider":null}"#)
        #expect(try await client(loader).transcribe(audio: Data([1])) == "")
    }

    @Test(arguments: [(413, HermesAPIError.http(status: 413)), (400, .http(status: 400)), (401, .unauthorized)])
    func serverErrors(status: Int, error: HermesAPIError) async throws {
        let loader = TranscribeLoader(status: status, body: #"{"detail":"x"}"#)
        await #expect(throws: error) { try await client(loader).transcribe(audio: Data([1])) }
    }

    @Test func emptyOrOversizeClipIsRefusedBeforeTheUpload() async throws {
        let loader = TranscribeLoader(body: "{}")
        await #expect(throws: VoiceMemoError.badClip) { try await client(loader).transcribe(audio: Data()) }
        let big = Data(count: VoiceMemoLimits.maxUploadBytes + 1)
        await #expect(throws: VoiceMemoError.badClip) { try await client(loader).transcribe(audio: big) }
        #expect(loader.recorded.isEmpty)
        // Exactly 25 MiB is allowed.
        _ = try? await client(loader).transcribe(audio: Data(count: VoiceMemoLimits.maxUploadBytes))
        #expect(loader.recorded.count == 1)
    }
}

// MARK: - Chat view model

/// A transport with scripted transcribe and voice-turn answers. No network.
private final class FakeVoiceTransport: ChatTransport, @unchecked Sendable {
    struct Submit: Equatable {
        var text: String
        var voiceTurn: Bool
        var retryBeforeRowId: Int?
    }

    let events: AsyncStream<GatewayClientEvent>
    private let input: AsyncStream<GatewayClientEvent>.Continuation
    private let lock = NSLock()
    private var _submits: [Submit] = []
    private var _uploads: [(Data, String)] = []
    var transcript: Result<String, any Error> = .success("Remind me to call Sam")
    var failSubmit = false

    struct Failure: Error {}

    init() {
        (events, input) = AsyncStream.makeStream(of: GatewayClientEvent.self)
    }

    var submits: [Submit] { lock.withLock { _submits } }
    var uploads: [(Data, String)] { lock.withLock { _uploads } }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: "st1")
    }

    func resumeSession(storedId: String, source _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s2", storedId: storedId)
    }

    func submitPrompt(sessionId _: String, text: String, retryBeforeRowId: Int?) async throws -> Int? {
        try record(Submit(text: text, voiceTurn: false, retryBeforeRowId: retryBeforeRowId))
    }

    func submitVoicePrompt(sessionId _: String, text: String, retryBeforeRowId: Int?) async throws -> Int? {
        try record(Submit(text: text, voiceTurn: true, retryBeforeRowId: retryBeforeRowId))
    }

    private func record(_ submit: Submit) throws -> Int? {
        try lock.withLock {
            _submits.append(submit)
            if failSubmit { throw Failure() }
            return 40 + _submits.count
        }
    }

    func transcribe(audio: Data, mimeType: String) async throws -> String {
        let result = lock.withLock {
            _uploads.append((audio, mimeType))
            return transcript
        }
        return try result.get()
    }

    func stopReply(sessionId _: String) async throws -> Bool { true }
}

/// Only `ChatTransport`'s required calls: the voice calls use the defaults.
private struct TextOnlyTransport: ChatTransport {
    let events = AsyncStream<GatewayClientEvent> { _ in }
    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1")
    }
    func resumeSession(storedId _: String, source _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1")
    }
    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? { 1 }
    func stopReply(sessionId _: String) async throws -> Bool { false }
}

private final class RemovedFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.withLock { _urls } }
    func add(_ url: URL) { lock.withLock { _urls.append(url) } }
}

private let clip = Data("m4a-bytes".utf8)
private let memoURL = URL(fileURLWithPath: "/tmp/voice-test/m1.m4a")

private func memo() -> VoiceMemo {
    VoiceMemo(fileURL: memoURL, duration: 12.4, waveform: [0.2, 0.8, 0.5])
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct VoiceMemoChatTests {
    private func model(_ transport: any ChatTransport, removed: RemovedFiles = RemovedFiles(),
                       load: @escaping @Sendable (URL) throws -> Data = { _ in clip }) -> ChatViewModel {
        let counter = Mutex(0)
        return ChatViewModel(transport: transport, redrawInterval: .seconds(60),
                             makeId: { counter.withLock { $0 += 1; return "v\($0)" } },
                             loadAudio: load, removeAudio: { removed.add($0) })
    }

    @Test func bubbleShowsAtOnceThenTranscriptThenVoiceTurn() async throws {
        let transport = FakeVoiceTransport()
        let vm = model(transport)
        let task = vm.sendVoiceMemo(memo())
        let first = try #require(vm.messages.first)
        #expect(first.voice?.transcript == .pending)
        #expect(first.voice?.duration == 12.4)
        #expect(first.text.isEmpty)
        #expect(first.delivery == .sending)
        await task.value

        let sent = try #require(vm.messages.first)
        #expect(sent.voice?.transcript == .done("Remind me to call Sam"))
        #expect(sent.text == "Remind me to call Sam")
        #expect(sent.delivery == .delivered)
        #expect(sent.userRowId == 41)
        #expect(transport.uploads.map(\.0) == [clip])
        #expect(transport.uploads.map(\.1) == ["audio/mp4"])
        #expect(transport.submits == [.init(text: "Remind me to call Sam", voiceTurn: true, retryBeforeRowId: nil)])
        #expect(vm.isReplyActive)
        #expect(ChatTimeline.rows(for: vm.messages).first?.footnote == .delivered)
    }

    @Test func emptyTranscriptShowsNoSpeechAndSendsNoTurn() async {
        let transport = FakeVoiceTransport()
        transport.transcript = .success("  \n")
        let vm = model(transport)
        await vm.sendVoiceMemo(memo()).value
        #expect(vm.messages[0].voice?.transcript == .empty)
        #expect(vm.messages[0].delivery == .failed)
        #expect(transport.submits.isEmpty)
        #expect(!vm.isReplyActive)
        #expect(ChatTimeline.rows(for: vm.messages).first?.footnote == .noSpeech)
        #expect(ChatRow.Footnote.noSpeech.text == "No speech found.")
        #expect(ChatRow.Footnote.noSpeech.isError)
    }

    @Test func failedTranscribeKeepsTheMemoAndTryAgainTranscribesAgain() async {
        let transport = FakeVoiceTransport()
        transport.transcript = .failure(HermesAPIError.http(status: 500))
        let vm = model(transport)
        await vm.sendVoiceMemo(memo()).value
        #expect(vm.messages.count == 1)
        #expect(vm.messages[0].voice?.transcript == .failed)
        #expect(vm.messages[0].voice?.fileURL == memoURL)
        #expect(ChatTimeline.rows(for: vm.messages).first?.footnote == .notDelivered)
        #expect(transport.submits.isEmpty)

        transport.transcript = .success("Second try")
        let retry = vm.retrySend(id: vm.messages[0].id)
        #expect(vm.messages[0].voice?.transcript == .pending)
        #expect(vm.messages[0].delivery == .sending)
        await retry?.value
        #expect(transport.uploads.count == 2)
        #expect(transport.submits == [.init(text: "Second try", voiceTurn: true, retryBeforeRowId: nil)])
        #expect(vm.messages[0].delivery == .delivered)
    }

    @Test func unreadableFileFailsTheMemo() async {
        struct Missing: Error {}
        let transport = FakeVoiceTransport()
        let vm = model(transport, load: { _ in throw Missing() })
        await vm.sendVoiceMemo(memo()).value
        #expect(vm.messages[0].voice?.transcript == .failed)
        #expect(transport.uploads.isEmpty)
    }

    @Test func failedTurnKeepsTheTranscriptAndTryAgainDoesNotUploadAgain() async {
        let transport = FakeVoiceTransport()
        transport.failSubmit = true
        let vm = model(transport)
        await vm.sendVoiceMemo(memo()).value
        #expect(vm.messages[0].voice?.transcript == .done("Remind me to call Sam"))
        #expect(vm.messages[0].delivery == .failed)
        #expect(ChatTimeline.rows(for: vm.messages).first?.footnote == .notDelivered)

        transport.failSubmit = false
        await vm.retrySend(id: vm.messages[0].id)?.value
        #expect(transport.uploads.count == 1)
        #expect(transport.submits.map(\.voiceTurn) == [true, true])
        #expect(vm.messages[0].delivery == .delivered)
    }

    @Test func deleteRemovesTheAudioFile() async {
        let transport = FakeVoiceTransport()
        transport.transcript = .success("")
        let removed = RemovedFiles()
        let vm = model(transport, removed: removed)
        await vm.sendVoiceMemo(memo()).value
        vm.delete(id: vm.messages[0].id)
        #expect(vm.messages.isEmpty)
        #expect(removed.urls == [memoURL])
    }

    @Test func textSendsStayTextTurns() async {
        let transport = FakeVoiceTransport()
        let vm = model(transport)
        await vm.send("typed")?.value
        #expect(transport.submits == [.init(text: "typed", voiceTurn: false, retryBeforeRowId: nil)])
    }

    @Test func transportWithNoVoiceSupportFailsTheMemo() async {
        let vm = model(TextOnlyTransport())
        await vm.sendVoiceMemo(memo()).value
        #expect(vm.messages[0].voice?.transcript == .failed)
        #expect(vm.messages[0].delivery == .failed)
    }

    @Test func accessibilityLabelNamesTheMemo() async {
        let transport = FakeVoiceTransport()
        let vm = model(transport)
        let task = vm.sendVoiceMemo(memo())
        let pending = ChatTimeline.accessibilityLabel(for: ChatTimeline.rows(for: vm.messages)[0])
        #expect(pending.hasPrefix("You, Voice memo, 12 seconds, Transcribing, "))
        await task.value
        let done = ChatTimeline.accessibilityLabel(for: ChatTimeline.rows(for: vm.messages)[0])
        #expect(done.hasPrefix("You, Voice memo, 12 seconds, Remind me to call Sam, "))
    }
}

// MARK: - Live transport

private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw FakeTimeout(what: "condition")
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LiveVoiceTransportTests {
    @Test func voicePromptSetsVoiceTurn() async throws {
        let socket = FakeGatewaySocket()
        let endpoint = try GatewayEndpoint(port: 8123, token: voiceToken)
        let transport = LiveChatTransport(makeClient: {
            GatewayClient(endpoint: $0, connector: FakeGatewayConnector(socket),
                          configuration: .init(heartbeatInterval: nil, readyTimeout: .seconds(5)))
        })
        transport.setEndpoint(endpoint)
        socket.pushReady()
        socket.reply(to: try await socket.waitForRequest("client.capabilities"), result: "{}")
        try await waitUntil { transport.status == .ready }

        async let row = transport.submitVoicePrompt(sessionId: "live1", text: "Call Sam", retryBeforeRowId: nil)
        let submit = try await socket.waitForRequest("prompt.submit")
        #expect(submit["params"]?["voice_turn"]?.boolValue == true)
        #expect(submit["params"]?["text"]?.stringValue == "Call Sam")
        #expect(submit["params"]?["session_id"]?.stringValue == "live1")
        socket.reply(to: submit, result: #"{"status":"streaming","user_row_id":77}"#)
        #expect(try await row == 77)
    }

    @Test func transcribeUsesTheEndpointAndNeedsOne() async throws {
        let loader = TranscribeLoader(body: #"{"ok":true,"transcript":"hi"}"#)
        let transport = LiveChatTransport(makeClient: { GatewayClient(endpoint: $0,
                                                                      connector: FakeGatewayConnector(FakeGatewaySocket())) },
                                          makeREST: { HermesRESTClient(endpoint: $0, loader: loader) })
        await #expect(throws: GatewayError.notConnected) {
            try await transport.transcribe(audio: clip, mimeType: "audio/mp4")
        }
        transport.setEndpoint(try GatewayEndpoint(port: 9001, token: voiceToken))
        #expect(try await transport.transcribe(audio: clip, mimeType: "audio/mp4") == "hi")
        #expect(loader.recorded.first?.url?.port == 9001)
    }
}
