import Foundation
import Synchronization
import Testing
@testable import HermesKit

// Issue #96: the voice mode loop. Fakes for the microphone, the transcript, the chat and the speech.
// No test opens a real microphone or reaches a server.

private let voiceToken = String(repeating: "9a", count: 32)
private let tickSeconds = 1.0 / 30

final class FakeVoiceClock: @unchecked Sendable {
    private let value = Mutex<TimeInterval>(1_000)
    var now: TimeInterval { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

@MainActor
final class FakeVoiceMicrophone: VoiceModeMicrophone {
    var access: VoiceModeMicrophoneAccess = .granted
    var allowOnRequest = true
    var decibels: Float = -60
    var startError: (any Error)?
    var activateError: (any Error)?
    private(set) var requests = 0
    private(set) var started: [URL] = []
    private(set) var stops = 0
    private(set) var discards = 0
    private(set) var activations = 0
    private(set) var deactivations = 0
    private(set) var isOpen = false

    struct Failure: Error {}

    func requestAccess() async -> Bool {
        requests += 1
        access = allowOnRequest ? .granted : .denied
        return allowOnRequest
    }

    func activate() throws {
        if let activateError { throw activateError }
        activations += 1
    }
    func deactivate() { deactivations += 1 }

    func startClip(url: URL) throws {
        if let startError { throw startError }
        started.append(url)
        isOpen = true
    }

    func stopClip() -> TimeInterval {
        stops += 1
        isOpen = false
        return 4
    }

    func discardClip() {
        discards += 1
        isOpen = false
    }

    func level() -> Float { decibels }
}

/// A scripted target chat.
@MainActor
final class FakeVoiceChat: VoiceModeChat {
    var transcript: Result<String, any Error> = .success("What time is it")
    /// Holds `transcribeVoiceClip` until `answerTranscript()`.
    var holdTranscript = false
    var turnResult: VoiceModeTurnResult = .delivered(promptId: "p1")
    var holdTurn = false
    var progress: LiveReplyProgress = .waiting
    private(set) var transcribed: [URL] = []
    private(set) var turns: [(memo: VoiceMemo, transcript: String)] = []
    private(set) var attached: [SpokenAudio] = []
    private(set) var keptMemos: [VoiceMemo] = []
    private var transcriptWaiters: [CheckedContinuation<Void, Never>] = []
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []

    func transcribeVoiceClip(at url: URL) async throws -> String {
        transcribed.append(url)
        if holdTranscript { await withCheckedContinuation { transcriptWaiters.append($0) } }
        return try transcript.get()
    }

    func answerTranscript() {
        holdTranscript = false
        transcriptWaiters.forEach { $0.resume() }
        transcriptWaiters = []
    }

    func sendVoiceModeTurn(_ memo: VoiceMemo, transcript: String) async -> VoiceModeTurnResult {
        turns.append((memo, transcript))
        if holdTurn { await withCheckedContinuation { turnWaiters.append($0) } }
        return turnResult
    }

    func acceptTurn() {
        holdTurn = false
        turnWaiters.forEach { $0.resume() }
        turnWaiters = []
    }

    func replyProgress(promptId _: String) -> LiveReplyProgress { progress }

    func attachVoiceModeAudio(_ audio: SpokenAudio, promptId _: String) { attached.append(audio) }

    func sendVoiceMemo(_ memo: VoiceMemo) -> Task<Void, Never> {
        keptMemos.append(memo)
        return Task {}
    }
}

/// A speaker with scripted states. No socket, no audio.
final class FakeVoiceSpeech: VoiceModeSpeaking, @unchecked Sendable {
    let states: AsyncStream<StreamedSpeechState>
    private let continuation: AsyncStream<StreamedSpeechState>.Continuation
    private let lock = NSLock()
    private var _texts: [String] = []
    private var _finished = false
    private var _stops = 0

    init() {
        (states, continuation) = AsyncStream.makeStream(of: StreamedSpeechState.self)
    }

    var texts: [String] { lock.withLock { _texts } }
    var finished: Bool { lock.withLock { _finished } }
    var stops: Int { lock.withLock { _stops } }

    func start() async {}
    func append(_ delta: String) async { lock.withLock { _texts.append(delta) } }
    func finish() async { lock.withLock { _finished = true } }
    func stop() async {
        lock.withLock { _stops += 1 }
        continuation.yield(.stopped)
        continuation.finish()
    }

    func push(_ state: StreamedSpeechState) {
        continuation.yield(state)
        if state.isFinal { continuation.finish() }
    }
}

@MainActor
private func until(_ what: String = "condition", _ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<2000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw FakeTimeout(what: what)
}

private func pcm(_ samples: [Int16]) -> Data {
    var data = Data()
    for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
    return data
}

/// One engine with fakes. `speech` is the fake speaker that the engine gets for each reply.
@MainActor
private final class Rig {
    let clock = FakeVoiceClock()
    let microphone = FakeVoiceMicrophone()
    let chat = FakeVoiceChat()
    let player = FakeSpeechPlayer()
    private(set) var speeches: [FakeVoiceSpeech] = []
    private(set) var removed: [URL] = []
    var speechError: (any Error)?
    var engine: VoiceModeController!

    /// Issue #149: the "Thinking Sound" setting.
    var thinkingSoundOn = true

    init(tuning: VoiceModeTuning = VoiceModeTuning(), ackVoice: (any VoiceModeAckVoice)? = nil,
         thinkingSound: (any VoiceModeThinkingSound)? = nil) {
        var clips = 0
        let clock = clock
        engine = VoiceModeController(
            microphone: microphone, player: player,
            makeSpeech: { [weak self] _ in
                let speech = FakeVoiceSpeech()
                guard let self else { return speech }
                if let speechError { throw speechError }
                speeches.append(speech)
                return speech
            },
            makeClipURL: {
                clips += 1
                return URL(fileURLWithPath: "/tmp/voice-mode-test/clip\(clips).m4a")
            },
            removeFile: { [weak self] in self?.removed.append($0) },
            tuning: tuning, clock: { clock.now }, autoTick: false, ackVoice: ackVoice,
            thinkingSound: thinkingSound, thinkingSoundOn: { [weak self] in self?.thinkingSoundOn ?? true })
    }

    var speech: FakeVoiceSpeech? { speeches.last }

    /// Ticks for `seconds` at 30 a second with the mic at `decibels`.
    func run(_ seconds: TimeInterval, decibels: Float) {
        microphone.decibels = decibels
        let ticks = Int((seconds / tickSeconds).rounded())
        for _ in 0..<ticks {
            clock.advance(tickSeconds)
            engine.tick()
        }
    }

    /// Speech for 1 s, then 3 s of silence: the clip ends.
    func sayOneClip() {
        run(1, decibels: -20)
        run(3.1, decibels: -60)
    }

    /// A turn up to the speaking state, with the reply "It is noon." done.
    func reachSpeaking() async throws {
        await engine.start(chat: chat)
        sayOneClip()
        try await until("thinking") { engine.state == .thinking && chat.turns.count == 1 }
        chat.progress = .done("It is noon.")
        try await until("speech") {
            engine.tick()
            return speech != nil && speech!.finished
        }
        speech?.push(.speaking(viaFallback: false))
        try await until("speaking") { engine.state == .speaking }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct VoiceModeTests {
    @Test func stopWordIsTheSingleWordOnly() {
        #expect(VoiceModeText.isStopWord("stop"))
        #expect(VoiceModeText.isStopWord(" Stop. "))
        #expect(VoiceModeText.isStopWord("STOP!"))
        #expect(!VoiceModeText.isStopWord("stop the timer"))
        #expect(!VoiceModeText.isStopWord("Don't stop"))
        #expect(!VoiceModeText.isStopWord(""))
    }

    @Test func startListensAndEndReleasesTheMicrophone() async throws {
        let rig = Rig()
        #expect(rig.engine.state == .idle)
        await rig.engine.start(chat: rig.chat)
        #expect(rig.engine.state == .listening)
        #expect(rig.microphone.activations == 1)
        #expect(rig.microphone.isOpen)
        rig.run(0.2, decibels: -20)
        #expect(rig.engine.level > 0.5)

        rig.engine.end()
        #expect(rig.engine.state == .ended(.end))
        #expect(!rig.microphone.isOpen)
        #expect(rig.microphone.discards == 1)
        #expect(rig.microphone.deactivations == 1)
        #expect(rig.engine.level == 0)
        // Nothing runs after the end.
        rig.run(1, decibels: -20)
        #expect(rig.engine.state == .ended(.end))
        #expect(rig.chat.transcribed.isEmpty)
        // A second start is a new session.
        await rig.engine.start(chat: rig.chat)
        #expect(rig.engine.state == .listening)
    }

    @Test func aClipEndsAfterThreeSecondsOfSilenceAndGoesAsAVoiceTurn() async throws {
        let rig = Rig()
        await rig.engine.start(chat: rig.chat)
        // A click shorter than the onset is not speech.
        rig.run(0.07, decibels: -10)
        rig.run(5, decibels: -60)
        #expect(rig.engine.state == .listening)
        rig.run(1, decibels: -20)
        rig.run(2.9, decibels: -60)
        #expect(rig.engine.state == .listening)
        #expect(rig.engine.clipEndCount == 0)
        rig.run(0.15, decibels: -60)
        #expect(rig.engine.clipEndCount == 1)
        #expect(rig.microphone.stops == 1)
        #expect(!rig.microphone.isOpen)
        try await until { rig.chat.turns.count == 1 }
        #expect(rig.chat.transcribed == [URL(fileURLWithPath: "/tmp/voice-mode-test/clip1.m4a")])
        let turn = try #require(rig.chat.turns.first)
        #expect(turn.transcript == "What time is it")
        #expect(turn.memo.transcript == .done("What time is it"))
        #expect(turn.memo.duration == 4)
        #expect(turn.memo.waveform.count == VoiceMemoLimits.waveformBars)
        #expect(rig.engine.state == .thinking)
    }

    @Test func thirtySecondsOfSilenceEndsVoiceMode() async throws {
        let rig = Rig()
        await rig.engine.start(chat: rig.chat)
        rig.run(29.9, decibels: -60)
        #expect(rig.engine.state == .listening)
        rig.run(0.2, decibels: -60)
        #expect(rig.engine.state == .ended(.silence))
        #expect(!rig.microphone.isOpen)
        #expect(rig.microphone.deactivations == 1)
        #expect(rig.chat.transcribed.isEmpty)
    }

    @Test func theWordStopEndsVoiceModeAndIsNotSent() async throws {
        let rig = Rig()
        rig.chat.transcript = .success("Stop.")
        await rig.engine.start(chat: rig.chat)
        rig.sayOneClip()
        try await until { rig.engine.state == .ended(.stopWord) }
        #expect(rig.chat.turns.isEmpty)
        #expect(rig.removed == [URL(fileURLWithPath: "/tmp/voice-mode-test/clip1.m4a")])
        #expect(!rig.microphone.isOpen)
        #expect(rig.microphone.deactivations == 1)
    }

    @Test func aClipWithNoSpeechListensAgain() async throws {
        let rig = Rig()
        rig.chat.transcript = .success("  ")
        await rig.engine.start(chat: rig.chat)
        rig.sayOneClip()
        try await until { rig.engine.state == .listening && rig.microphone.started.count == 2 }
        #expect(rig.chat.turns.isEmpty)
        #expect(rig.removed.count == 1)
    }

    @Test func slowTurnReportsTranscribingThinkingAndSpeaking() async throws {
        let rig = Rig()
        rig.chat.holdTranscript = true
        rig.chat.holdTurn = true
        await rig.engine.start(chat: rig.chat)
        rig.sayOneClip()
        #expect(rig.engine.state == .transcribing)
        rig.run(2, decibels: -60)
        #expect(rig.engine.state == .transcribing)
        try await until { rig.chat.transcribed.count == 1 }
        rig.chat.answerTranscript()
        try await until { rig.engine.state == .thinking }
        // The server is slow: the elapsed seconds count up while the turn runs.
        rig.run(4, decibels: -60)
        #expect(rig.engine.thinkingSeconds == 4)
        rig.chat.acceptTurn()
        try await until { rig.chat.turns.count == 1 }
        rig.run(7, decibels: -60)
        #expect(rig.engine.state == .thinking)
        #expect(rig.engine.thinkingSeconds == 11)
        #expect(rig.speeches.isEmpty)

        rig.chat.progress = .streaming("It is ")
        try await until {
            rig.engine.tick()
            return rig.speech != nil
        }
        try await until { rig.speech?.texts == ["It is "] }
        rig.chat.progress = .done("It is noon.")
        rig.engine.tick()
        try await until { rig.speech?.finished == true }
        #expect(rig.speech?.texts == ["It is ", "noon."])
        #expect(rig.engine.state == .thinking)
        rig.speech?.push(.speaking(viaFallback: false))
        try await until { rig.engine.state == .speaking }
        // The barge-in monitor records while the reply plays.
        #expect(rig.microphone.isOpen)
        rig.speech?.push(.ended)
        try await until { rig.engine.state == .listening }
        #expect(rig.chat.attached.isEmpty) // The fake player got no PCM.
        #expect(rig.microphone.discards == 1)
        #expect(rig.microphone.started.count == 3)
    }

    @Test func speechOverTheReplyBargesInAndListens() async throws {
        let rig = Rig()
        try await rig.reachSpeaking()
        let monitor = try #require(rig.microphone.started.last)
        // The reply echo is quieter than the barge-in level.
        rig.run(2, decibels: -35)
        #expect(rig.engine.state == .speaking)
        rig.run(0.4, decibels: -15)
        #expect(rig.engine.bargeInCount == 1)
        try await until { rig.engine.state == .listening }
        #expect(rig.speech?.stops == 1)
        // The monitor clip stays: it holds the start of the owner's words.
        #expect(rig.microphone.started.last == monitor)
        #expect(rig.microphone.isOpen)
        rig.run(3.1, decibels: -60)
        try await until { rig.chat.turns.count == 2 }
        #expect(rig.chat.transcribed.last == monitor)
        #expect(rig.chat.attached.isEmpty)
    }

    @Test func aTapBargesInToo() async throws {
        let rig = Rig()
        try await rig.reachSpeaking()
        rig.engine.bargeIn()
        #expect(rig.engine.state == .interrupted)
        try await until { rig.engine.state == .listening }
        #expect(rig.speech?.stops == 1)
        #expect(rig.engine.bargeInCount == 1)
    }

    /// Issue #101: Magic Tap sends the clip with no wait for the silence. It does nothing in other states.
    @Test func sendClipEndsTheClipAtOnce() async throws {
        let rig = Rig()
        rig.engine.sendClip()
        #expect(rig.engine.state == .idle)
        await rig.engine.start(chat: rig.chat)
        rig.run(1, decibels: -20)
        rig.engine.sendClip()
        #expect(rig.engine.clipEndCount == 1)
        #expect(rig.engine.state == .transcribing)
        #expect(!rig.microphone.isOpen)
        try await until { rig.chat.turns.count == 1 }
        #expect(rig.engine.state == .thinking)
        rig.engine.sendClip()
        #expect(rig.engine.clipEndCount == 1)
    }

    @Test func aPhoneCallPausesPlaybackAndResumeListens() async throws {
        let rig = Rig()
        try await rig.reachSpeaking()
        rig.engine.pause(.call)
        #expect(rig.engine.state == .paused(.call))
        try await until { rig.speech?.stops == 1 }
        #expect(!rig.microphone.isOpen)
        #expect(rig.microphone.deactivations == 1)
        #expect(rig.engine.level == 0)
        // No silence end while paused.
        rig.run(40, decibels: -60)
        #expect(rig.engine.state == .paused(.call))
        rig.engine.pause(.lock)
        #expect(rig.engine.state == .paused(.lock))

        rig.engine.resume()
        #expect(rig.engine.state == .listening)
        #expect(rig.microphone.activations == 2)
        #expect(rig.microphone.isOpen)
    }

    @Test func aPauseWhileTranscribingStillSendsTheTurn() async throws {
        let rig = Rig()
        rig.chat.holdTranscript = true
        await rig.engine.start(chat: rig.chat)
        rig.sayOneClip()
        try await until { rig.chat.transcribed.count == 1 }
        rig.engine.pause(.background)
        rig.chat.answerTranscript()
        try await until { rig.chat.turns.count == 1 }
        // The reply shows in the thread. The engine stays paused and speaks nothing.
        rig.chat.progress = .done("It is noon.")
        rig.run(1, decibels: -60)
        #expect(rig.engine.state == .paused(.background))
        #expect(rig.speeches.isEmpty)
    }

    @Test func muteClosesTheMicrophone() async throws {
        let rig = Rig()
        await rig.engine.start(chat: rig.chat)
        rig.engine.toggleMute()
        #expect(rig.engine.muted)
        #expect(rig.engine.state == .muted)
        #expect(!rig.microphone.isOpen)
        rig.run(40, decibels: -10)
        #expect(rig.engine.state == .muted)
        rig.engine.toggleMute()
        #expect(rig.engine.state == .listening)
        #expect(rig.microphone.isOpen)
    }

    @Test func microphoneOffIsAnError() async throws {
        let rig = Rig()
        rig.microphone.access = .denied
        await rig.engine.start(chat: rig.chat)
        #expect(rig.engine.state == .error(.microphoneOff))
        #expect(rig.microphone.started.isEmpty)
        rig.engine.end()
        #expect(rig.engine.state == .ended(.end))

        let asked = Rig()
        asked.microphone.access = .undetermined
        asked.microphone.allowOnRequest = false
        await asked.engine.start(chat: asked.chat)
        #expect(asked.microphone.requests == 1)
        #expect(asked.engine.state == .error(.microphoneOff))

        let allowed = Rig()
        allowed.microphone.access = .undetermined
        await allowed.engine.start(chat: allowed.chat)
        #expect(allowed.engine.state == .listening)
    }

    /// Issue #135: with the permission on, a start failure is not "Microphone Off".
    @Test func startFailureWithPermissionIsNotMicrophoneOff() async throws {
        let rig = Rig()
        rig.microphone.startError = FakeVoiceMicrophone.Failure()
        await rig.engine.start(chat: rig.chat)
        #expect(rig.engine.state != .error(.microphoneOff))
        #expect(rig.engine.state == .error(.microphoneUnavailable))

        // Try Again opens the microphone when the start works again.
        rig.microphone.startError = nil
        rig.engine.resume()
        #expect(rig.engine.state == .listening)
        #expect(rig.microphone.isOpen)

        let session = Rig()
        session.microphone.activateError = FakeVoiceMicrophone.Failure()
        await session.engine.start(chat: session.chat)
        #expect(session.engine.state == .error(.microphoneUnavailable))
        session.microphone.activateError = nil
        session.engine.resume()
        #expect(session.engine.state == .listening)

        // Permission off after a pause: Microphone Off.
        rig.engine.pause(.background)
        rig.microphone.access = .denied
        rig.engine.resume()
        #expect(rig.engine.state == .error(.microphoneOff))
    }

    @Test func offlineTranscriptKeepsTheClipAsAMemo() async throws {
        let rig = Rig()
        rig.chat.transcript = .failure(URLError(.notConnectedToInternet))
        await rig.engine.start(chat: rig.chat)
        rig.sayOneClip()
        try await until { rig.engine.state == .error(.offline) }
        #expect(rig.chat.keptMemos.map(\.fileURL) == [URL(fileURLWithPath: "/tmp/voice-mode-test/clip1.m4a")])
        #expect(rig.removed.isEmpty)
        #expect(!rig.microphone.isOpen)
        rig.chat.transcript = .success("Hello")
        rig.engine.resume()
        #expect(rig.engine.state == .listening)
    }

    @Test func aQueuedOrRefusedTurnIsAnError() async throws {
        let queued = Rig()
        queued.chat.turnResult = .queued
        await queued.engine.start(chat: queued.chat)
        queued.sayOneClip()
        try await until { queued.engine.state == .error(.offline) }

        let refused = Rig()
        refused.chat.turnResult = .failed
        await refused.engine.start(chat: refused.chat)
        refused.sayOneClip()
        try await until { refused.engine.state == .error(.turnFailed) }

        let failedReply = Rig()
        await failedReply.engine.start(chat: failedReply.chat)
        failedReply.sayOneClip()
        try await until { failedReply.chat.turns.count == 1 }
        failedReply.chat.progress = .failed
        failedReply.engine.tick()
        #expect(failedReply.engine.state == .error(.turnFailed))
    }

    @Test func aSpeechFailureIsAnErrorAndAnEmptyReplyListensAgain() async throws {
        let rig = Rig()
        try await rig.reachSpeaking()
        rig.speech?.push(.failed(.server))
        try await until { rig.engine.state == .error(.speakFailed) }
        #expect(!rig.microphone.isOpen)

        let empty = Rig()
        await empty.engine.start(chat: empty.chat)
        empty.sayOneClip()
        try await until { empty.chat.turns.count == 1 }
        empty.chat.progress = .done("```\ncode\n```")
        empty.engine.tick()
        #expect(empty.engine.state == .listening)
        #expect(empty.speeches.isEmpty)
    }

    // MARK: Output tap

    @Test func tapLevelFollowsThePlayerScheduleAndMakesAWAV() throws {
        let clock = FakeVoiceClock()
        let player = FakeSpeechPlayer()
        let tap = VoiceModeSpeechTap(player: player, clock: { clock.now })
        try tap.begin(sampleRate: 1_000)
        let start = clock.now
        // 0.5 s loud, queued at once: it plays from now.
        tap.enqueue(pcm(Array(repeating: 16_000, count: 500)))
        #expect(tap.level(at: start + 0.1) > 0.8)
        #expect(tap.level(at: start + 0.6) == 0) // a gap: no audio yet
        clock.advance(1)
        tap.enqueue(pcm(Array(repeating: 500, count: 500)))
        let quiet = tap.level(at: start + 1.2)
        #expect(quiet > 0 && quiet < 0.3)
        #expect(tap.level(at: start + 2) == 0)
        #expect(player.chunks.count == 2)

        let wav = try #require(tap.recordedAudio())
        #expect(wav.mimeType == "audio/wav")
        #expect(wav.data.count == 44 + 2_000)
        #expect(wav.data.prefix(4) == Data("RIFF".utf8))
        #expect(wav.data[8..<16] == Data("WAVEfmt ".utf8))
        let rate = wav.data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 1_000)

        let empty = VoiceModeSpeechTap(player: player, clock: { clock.now })
        #expect(empty.recordedAudio() == nil)
        #expect(empty.level(at: clock.now) == 0)
    }
}

// MARK: - With the chat and speak-stream

/// Scripted transcribe and voice turns. Counts the #10 speak calls. No network.
private final class FakeVoiceModeTransport: ChatTransport, @unchecked Sendable {
    let events: AsyncStream<GatewayClientEvent> = AsyncStream { _ in }
    private let lock = NSLock()
    private var _voiceSubmits: [String] = []
    private var _spoken = 0

    private var _replay: SessionEventsSinceResult?

    var voiceSubmits: [String] { lock.withLock { _voiceSubmits } }
    var spoken: Int { lock.withLock { _spoken } }
    /// Issue #145: the answer of `session.events.since`. `nil` throws.
    var replay: SessionEventsSinceResult? {
        get { lock.withLock { _replay } }
        set { lock.withLock { _replay = newValue } }
    }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: "st1")
    }

    func resumeSession(storedId: String, source _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: storedId, running: true)
    }

    func eventsSince(sessionId _: String, lastSeen _: Int) async throws -> SessionEventsSinceResult {
        guard let replay else { throw ChatReplayError.unsupported }
        return replay
    }

    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? { 11 }

    func submitVoicePrompt(sessionId _: String, text: String, retryBeforeRowId _: Int?) async throws -> Int? {
        lock.withLock { _voiceSubmits.append(text) }
        return 12
    }

    func transcribe(audio _: Data, mimeType _: String) async throws -> String { "What time is it" }

    func speak(text _: String) async throws -> SpokenAudio {
        lock.withLock { _spoken += 1 }
        return SpokenAudio(data: Data([1]), mimeType: "audio/mpeg")
    }

    func stopReply(sessionId _: String) async throws -> Bool { true }
    private var _transcript: [TranscriptMessage] = []
    /// Issue #145: the `session.history` answer.
    var transcript: [TranscriptMessage] {
        get { lock.withLock { _transcript } }
        set { lock.withLock { _transcript = newValue } }
    }

    func history(sessionId _: String) async throws -> [TranscriptMessage] { transcript }
}

private func sentTextFrames(_ socket: FakeGatewaySocket) async throws -> [JSONValue] {
    try await socket.waitForSent { $0["text"] != nil }
}

private func sentFrames(_ socket: FakeGatewaySocket, count: Int) async throws -> [JSONValue] {
    try await socket.waitForSent(count: count) { _ in true }
}

private func sentStopFrames(_ socket: FakeGatewaySocket) async throws -> [JSONValue] {
    try await socket.waitForSent { $0["stop"]?.boolValue == true }
}

private func chatEvent(_ json: String) throws -> GatewayClientEvent {
    .event(try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8)))
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct VoiceModeChatTests {
    private final class Saved: @unchecked Sendable {
        let audio = Mutex<[SpokenAudio]>([])
    }

    @MainActor private struct Setup {
        let clock = FakeVoiceClock()
        let microphone = FakeVoiceMicrophone()
        let transport = FakeVoiceModeTransport()
        let socket = FakeGatewaySocket()
        let player = FakeSpeechPlayer()
        let saved = Saved()
        let vm: ChatViewModel
        let engine: VoiceModeController

        init() throws {
            let counter = Mutex(0)
            let saved = saved
            vm = ChatViewModel(transport: transport, redrawInterval: .seconds(60),
                               makeId: { counter.withLock { $0 += 1; return "m\($0)" } },
                               loadAudio: { _ in Data("m4a".utf8) }, removeAudio: { _ in },
                               saveSpeech: { audio in
                                   saved.audio.withLock { $0.append(audio) }
                                   return VoiceReplyAudio(fileURL: URL(fileURLWithPath: "/tmp/voice-mode-test/r.wav"),
                                                          duration: 1)
                               })
            let endpoint = try GatewayEndpoint(port: 9119, token: voiceToken)
            let connector = FakeGatewayConnector(socket)
            let clock = clock
            engine = VoiceModeController(
                microphone: microphone, player: player,
                makeSpeech: { tap in
                    StreamedSpeech(open: { try await SpeakStreamConnection.open(endpoint: endpoint, connector: connector) },
                                   fallback: { _ in throw SpeechStreamError.server }, player: tap)
                },
                makeClipURL: { URL(fileURLWithPath: "/tmp/voice-mode-test/c.m4a") }, removeFile: { _ in },
                clock: { clock.now }, autoTick: false)
        }

        func run(_ seconds: TimeInterval, decibels: Float) {
            microphone.decibels = decibels
            for _ in 0..<Int((seconds / tickSeconds).rounded()) {
                clock.advance(tickSeconds)
                engine.tick()
            }
        }
    }

    @Test func theReplyPlaysThroughSpeakStreamAndShowsInTheThread() async throws {
        let rig = try Setup()
        await rig.engine.start(chat: rig.vm)
        rig.run(1, decibels: -20)
        rig.run(3.1, decibels: -60)
        try await until { rig.transport.voiceSubmits == ["What time is it"] }
        try await until { rig.engine.state == .thinking && rig.vm.messages.first?.delivery == .delivered }
        // The #9 memo bubble shows with its transcript.
        let memo = try #require(rig.vm.messages.first)
        #expect(memo.voice?.transcript == .done("What time is it"))

        rig.vm.receive(try chatEvent(#"{"type":"message.start","session_id":"s1","payload":{"turn_id":"t1"}}"#))
        rig.vm.receive(try chatEvent(#"{"type":"message.delta","session_id":"s1","payload":{"text":"It is ","offset":0}}"#))
        try await until {
            rig.engine.tick()
            return !rig.socket.sent.isEmpty
        }
        let first = try await sentTextFrames(rig.socket)
        #expect(first.first?["text"]?.stringValue == "It is ")
        rig.vm.receive(try chatEvent(#"{"type":"message.complete","session_id":"s1","payload":{"text":"It is noon.","status":"complete"}}"#))
        rig.engine.tick()
        let frames = try await sentFrames(rig.socket, count: 3)
        #expect(frames[1]["text"]?.stringValue == "noon.")
        #expect(frames[2]["done"]?.boolValue == true)

        rig.socket.push(#"{"type":"start","sample_rate":1000,"channels":1}"#)
        rig.socket.pushBinary(pcm(Array(repeating: 12_000, count: 1_000)))
        try await until { rig.engine.state == .speaking }
        rig.engine.tick()
        #expect(rig.engine.level > 0.5)
        rig.socket.push(#"{"type":"end"}"#)
        try await until { rig.engine.state == .listening }

        // The reply is in the thread, with the audio that played as its voice reply. No second TTS call.
        let reply = try #require(rig.vm.messages.last)
        #expect(reply.role == .assistant)
        #expect(reply.text == "It is noon.")
        try await until { rig.vm.messages.last?.spokenReply?.audio != nil }
        #expect(rig.saved.audio.withLock { $0.first?.mimeType } == "audio/wav")
        #expect(rig.transport.spoken == 0)
        #expect(rig.vm.autoPlayReplyId == nil)
    }

    /// Issue #145: the socket drops while Hermes works. Hands-Free keeps "Thinking…", then speaks the resumed reply.
    /// The replay sends `seq` 2 again: the speaker gets each part of the text one time.
    @Test func handsFreeSpeaksTheResumedReplyOneTime() async throws {
        let rig = try Setup()
        await rig.engine.start(chat: rig.vm)
        rig.run(1, decibels: -20)
        rig.run(3.1, decibels: -60)
        try await until { rig.engine.state == .thinking && rig.vm.messages.first?.delivery == .delivered }
        rig.vm.receive(try chatEvent(#"{"type":"message.start","session_id":"s1","seq":1,"payload":{"turn_id":"t1"}}"#))
        rig.vm.receive(try chatEvent(#"{"type":"message.delta","session_id":"s1","seq":2,"payload":{"text":"It is ","offset":0}}"#))
        try await until {
            rig.engine.tick()
            return !rig.socket.sent.isEmpty
        }

        rig.vm.receive(.state(.disconnected(.heartbeatTimeout)))
        rig.engine.tick()
        #expect(rig.vm.isReattaching)
        #expect(rig.engine.state == .thinking)
        let display = VoiceTabDisplay.make(state: rig.engine.state, muted: false, thinkingSeconds: 0,
                                           reconnecting: rig.vm.isReattaching)
        #expect(display.title == "Thinking…")
        #expect(display.subtitle == "Reconnecting…")

        let decode = { (json: String) in try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8)) }
        let events = [
            try decode(#"{"type":"message.delta","session_id":"s1","seq":2,"payload":{"text":"It is ","offset":0}}"#),
            try decode(#"{"type":"message.delta","session_id":"s1","seq":3,"payload":{"text":"noon.","offset":6}}"#),
            try decode(#"{"type":"message.complete","session_id":"s1","seq":4,"payload":{"text":"It is noon.","status":"complete"}}"#),
        ]
        rig.transport.replay = SessionEventsSinceResult(events: events, latestSeq: 4, truncated: false, count: 3,
                                                        epoch: "e1", openRequests: [])
        rig.transport.transcript = [TranscriptMessage(role: "user", text: "What time is it", rowId: 12),
                                    TranscriptMessage(role: "assistant", text: "It is noon.", rowId: 13)]
        await rig.vm.open()
        #expect(!rig.vm.isReattaching)
        rig.engine.tick()
        let frames = try await sentFrames(rig.socket, count: 3)
        #expect(frames.compactMap { $0["text"]?.stringValue } == ["It is ", "noon."])
        #expect(frames[2]["done"]?.boolValue == true)
        #expect(rig.engine.state == .thinking)
        #expect(rig.transport.voiceSubmits == ["What time is it"])
    }

    @Test func bargeInSendsStopOnSpeakStream() async throws {
        let rig = try Setup()
        await rig.engine.start(chat: rig.vm)
        rig.run(1, decibels: -20)
        rig.run(3.1, decibels: -60)
        try await until { rig.engine.state == .thinking && rig.vm.messages.first?.delivery == .delivered }
        rig.vm.receive(try chatEvent(#"{"type":"message.delta","session_id":"s1","payload":{"text":"A long reply. ","offset":0}}"#))
        try await until {
            rig.engine.tick()
            return !rig.socket.sent.isEmpty
        }
        rig.socket.push(#"{"type":"start","sample_rate":1000,"channels":1}"#)
        rig.socket.pushBinary(pcm(Array(repeating: 12_000, count: 4_000)))
        try await until { rig.engine.state == .speaking }

        rig.run(0.4, decibels: -10)
        #expect(rig.engine.bargeInCount == 1)
        let stop = try await sentStopFrames(rig.socket)
        #expect(stop.count == 1)
        #expect(rig.player.stops >= 1)
        try await until { rig.engine.state == .listening }
        #expect(rig.microphone.isOpen)
    }

    /// Issue #134: an interim message, then the final message. `message.complete` carries the final text only.
    /// The speaker must get both messages in full, in order. `tickAfterFinalStart` ticks once inside the final.
    private func speakInterimThenFinal(tickAfterFinalStart: Bool, streamedInterim: Bool = true) async throws -> String {
        let rig = try Setup()
        await rig.engine.start(chat: rig.vm)
        rig.run(1, decibels: -20)
        rig.run(3.1, decibels: -60)
        try await until { rig.engine.state == .thinking && rig.vm.messages.first?.delivery == .delivered }
        rig.vm.receive(try chatEvent(#"{"type":"message.start","session_id":"s1","payload":{"turn_id":"t1"}}"#))
        if streamedInterim {
            rig.vm.receive(try chatEvent(#"{"type":"message.delta","session_id":"s1","payload":{"text":"Looking into it.","turn_id":"t1","segment":0,"offset":0}}"#))
            try await until {
                rig.engine.tick()
                return !rig.socket.sent.isEmpty
            }
            _ = try await sentTextFrames(rig.socket)
        }
        let streamed = streamedInterim ? "true" : "false"
        rig.vm.receive(try chatEvent(#"{"type":"message.interim","session_id":"s1","payload":{"text":"Looking into it.","already_streamed":\#(streamed),"turn_id":"t1","segment":0}}"#))
        rig.vm.receive(try chatEvent(#"{"type":"tool.start","session_id":"s1","payload":{"tool_id":"x1","name":"web_search"}}"#))
        rig.vm.receive(try chatEvent(#"{"type":"tool.complete","session_id":"s1","payload":{"tool_id":"x1","name":"web_search"}}"#))
        rig.vm.receive(try chatEvent(#"{"type":"message.delta","session_id":"s1","payload":{"text":"Here is the ","turn_id":"t1","segment":1,"offset":0}}"#))
        if tickAfterFinalStart {
            try await until {
                rig.engine.tick()
                return rig.socket.sent.contains { $0["text"]?.stringValue?.contains("Here is") == true }
            }
        }
        rig.vm.receive(try chatEvent(#"{"type":"message.delta","session_id":"s1","payload":{"text":"final report.","turn_id":"t1","segment":1,"offset":12}}"#))
        rig.vm.receive(try chatEvent(#"{"type":"message.complete","session_id":"s1","payload":{"text":"Here is the final report.","status":"complete"}}"#))
        try await until {
            rig.engine.tick()
            return rig.socket.sent.contains { $0["done"]?.boolValue == true }
        }
        let texts = try await sentTextFrames(rig.socket).compactMap { $0["text"]?.stringValue }
        rig.engine.end()
        return texts.joined()
    }

    @Test func anInterimThenAFinalMessageAreBothSpokenInFull() async throws {
        let spoken = try await speakInterimThenFinal(tickAfterFinalStart: false)
        #expect(spoken == "Looking into it.\n\nHere is the final report.")
    }

    @Test func noCharactersOfTheFinalMessageAreLostAfterAnInterimMessage() async throws {
        let spoken = try await speakInterimThenFinal(tickAfterFinalStart: true)
        #expect(spoken == "Looking into it.\n\nHere is the final report.")
    }

    @Test func anInterimThatDidNotStreamIsSpokenToo() async throws {
        let spoken = try await speakInterimThenFinal(tickAfterFinalStart: false, streamedInterim: false)
        #expect(spoken == "Looking into it.\n\nHere is the final report.")
    }

    /// Issue #134: Live mode reads the same progress by a character offset. The text only grows during the turn.
    @Test func theLiveReplyTextOnlyGrowsOverAnInterimMessage() async throws {
        let rig = try Setup()
        let memo = VoiceMemo(fileURL: URL(fileURLWithPath: "/tmp/voice-mode-test/x.m4a"), duration: 2, waveform: [])
        guard case .delivered(let promptId) = await rig.vm.sendVoiceModeTurn(memo, transcript: "Hi") else {
            Issue.record("not delivered")
            return
        }
        var seen: [String] = []
        func sample() {
            switch rig.vm.liveReplyProgress(promptId: promptId) {
            case .streaming(let text), .done(let text): seen.append(text)
            case .waiting, .failed: break
            }
        }
        rig.vm.receive(try chatEvent(#"{"type":"message.start","session_id":"s1","payload":{"turn_id":"t1"}}"#))
        rig.vm.receive(try chatEvent(#"{"type":"message.delta","session_id":"s1","payload":{"text":"Looking into it.","segment":0,"offset":0}}"#))
        sample()
        rig.vm.receive(try chatEvent(#"{"type":"message.interim","session_id":"s1","payload":{"text":"Looking into it.","already_streamed":true,"segment":0}}"#))
        sample()
        rig.vm.receive(try chatEvent(#"{"type":"message.delta","session_id":"s1","payload":{"text":"Here is the ","segment":1,"offset":0}}"#))
        sample()
        rig.vm.receive(try chatEvent(#"{"type":"message.complete","session_id":"s1","payload":{"text":"Here is the final report.","status":"complete"}}"#))
        sample()
        #expect(rig.vm.liveReplyProgress(promptId: promptId) == .done("Looking into it.\n\nHere is the final report."))
        for (before, after) in zip(seen, seen.dropFirst()) {
            #expect(after.hasPrefix(before), "\(before.debugDescription) -> \(after.debugDescription)")
        }
        // The bubble still shows the final text of `message.complete`.
        #expect(rig.vm.messages.last?.text == "Here is the final report.")
    }

    @Test func aVoiceModeTurnThatGoesLaterUsesTheNormalSpeakCall() async throws {
        let rig = try Setup()
        let memo = VoiceMemo(fileURL: URL(fileURLWithPath: "/tmp/voice-mode-test/x.m4a"), duration: 2, waveform: [])
        let result = await rig.vm.sendVoiceModeTurn(memo, transcript: "Hi")
        // "m1" is the session key of the model.
        #expect(result == .delivered(promptId: "m2"))
        rig.vm.receive(try chatEvent(#"{"type":"message.complete","session_id":"s1","payload":{"text":"Hello.","status":"complete"}}"#))
        // Voice mode speaks this reply, so the #10 speak call does not run.
        #expect(rig.vm.messages.last?.spokenReply == nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(rig.transport.spoken == 0)
        await rig.vm.saveVoiceModeAudio(SpokenAudio(data: Data([2]), mimeType: "audio/wav"), promptId: "m2")?.value
        #expect(rig.vm.messages.last?.spokenReply?.audio != nil)
        #expect(rig.vm.saveVoiceModeAudio(SpokenAudio(data: Data([2]), mimeType: "audio/wav"), promptId: "m2") == nil)
    }
}

/// Issue #121: a Hermes prompt holds the hands-free loop.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct VoiceModePromptHoldTests {
    @Test func aHoldClosesTheMicAndStopsTheIdleEndUntilTheRelease() async throws {
        let rig = Rig()
        await rig.engine.start(chat: rig.chat)
        #expect(rig.microphone.isOpen)
        rig.engine.holdForPrompt()
        #expect(rig.engine.promptHold)
        #expect(!rig.microphone.isOpen, "the mic closes while the card waits")
        // A card can wait 300 s. The 30 s idle end does not run.
        rig.run(40, decibels: -20)
        #expect(rig.engine.state == .listening)
        #expect(rig.engine.clipEndCount == 0, "no clip records while the card waits")
        rig.engine.releasePrompt()
        #expect(!rig.engine.promptHold)
        #expect(rig.microphone.isOpen, "the loop listens again after the answer")
        rig.run(29.9, decibels: -60)
        #expect(rig.engine.state == .listening, "the idle timer starts again at the release")
        rig.engine.end()
    }

    @Test func aTurnThatEndsWhileHeldListensOnlyAfterTheRelease() async throws {
        let rig = Rig()
        try await rig.reachSpeaking()
        rig.engine.holdForPrompt()
        #expect(!rig.microphone.isOpen, "no barge-in monitor while the card waits")
        rig.speech?.push(.ended)
        try await until("listening") { rig.engine.state == .listening }
        #expect(!rig.microphone.isOpen)
        rig.engine.releasePrompt()
        #expect(rig.microphone.isOpen)
        rig.engine.end()
        #expect(!rig.engine.promptHold)
    }

    @Test func aHoldDoesNothingWhenTheLoopIsOff() {
        let rig = Rig()
        rig.engine.holdForPrompt()
        #expect(!rig.engine.promptHold)
    }
}

/// Issue #134: the on-device ack voice. `speak` returns at `finishLine()` or `stop()`. No audio.
@MainActor
final class FakeAckVoice: VoiceModeAckVoice {
    private(set) var lines: [String] = []
    private(set) var stops = 0
    private var waiter: CheckedContinuation<Void, Never>?

    var isSpeaking: Bool { waiter != nil }

    func speak(_ line: String) async {
        lines.append(line)
        await withCheckedContinuation { waiter = $0 }
    }

    func stop() {
        stops += 1
        finishLine()
    }

    func finishLine() {
        waiter?.resume()
        waiter = nil
    }
}

/// Issue #134: the quick ack while the Hermes turn runs.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct VoiceModeAckTests {
    /// Up to the delivered turn, with no reply text yet. The ack delay starts here.
    private func reachDelivered(_ rig: Rig) async throws {
        await rig.engine.start(chat: rig.chat)
        rig.sayOneClip()
        try await until("thinking") { rig.engine.state == .thinking && rig.chat.turns.count == 1 }
        // `runTurn` sets the prompt id on the main actor after the send returns.
        try await Task.sleep(for: .milliseconds(5))
    }

    @Test func noReplyTextAfterTheDelayPlaysOneShortLocalAck() async throws {
        let ack = FakeAckVoice()
        let rig = Rig(ackVoice: ack)
        try await reachDelivered(rig)
        rig.run(1.4, decibels: -60)
        #expect(ack.lines.isEmpty)
        rig.run(0.2, decibels: -60)
        try await until("ack") { ack.isSpeaking }
        #expect(ack.lines == ["Checking now."])
        #expect(rig.engine.isAcking)
        // The ring stays in the working state.
        #expect(rig.engine.state == .thinking)
        // The mic listens for a barge-in while the ack plays.
        #expect(rig.microphone.isOpen)
        ack.finishLine()
        try await until("ack end") { !rig.engine.isAcking }
        #expect(!rig.microphone.isOpen)
        // One ack per turn, however long the turn runs.
        rig.run(20, decibels: -60)
        #expect(ack.lines.count == 1)
        #expect(rig.engine.ackCount == 1)
        #expect(rig.chat.transcribed.count == 1)
    }

    @Test func theNextTurnSaysTheNextLine() async throws {
        let ack = FakeAckVoice()
        let rig = Rig(ackVoice: ack)
        try await reachDelivered(rig)
        rig.run(1.6, decibels: -60)
        try await until("ack") { ack.isSpeaking }
        ack.finishLine()
        rig.chat.progress = .done("It is noon.")
        try await until("speech") {
            rig.engine.tick()
            return rig.speech?.finished == true
        }
        rig.speech?.push(.speaking(viaFallback: false))
        try await until { rig.engine.state == .speaking }
        rig.speech?.push(.ended)
        try await until { rig.engine.state == .listening }
        rig.chat.progress = .waiting
        rig.chat.turnResult = .delivered(promptId: "p2")
        rig.sayOneClip()
        try await until { rig.engine.state == .thinking && rig.chat.turns.count == 2 }
        try await Task.sleep(for: .milliseconds(5))
        rig.run(1.6, decibels: -60)
        try await until("second ack") { ack.lines.count == 2 }
        #expect(ack.lines == ["Checking now.", "One moment."])
    }

    @Test func replyTextWithinTheDelayPlaysNoAck() async throws {
        let ack = FakeAckVoice()
        let rig = Rig(ackVoice: ack)
        try await reachDelivered(rig)
        rig.run(0.5, decibels: -60)
        rig.chat.progress = .streaming("It is ")
        try await until("speech") {
            rig.engine.tick()
            return rig.speech?.texts == ["It is "]
        }
        // The speaker is slow to start: still no ack.
        rig.run(3, decibels: -60)
        #expect(ack.lines.isEmpty)
        #expect(!rig.engine.isAcking)
        #expect(rig.engine.ackCount == 0)
    }

    @Test func aTapStopsTheAckAndTheTurnGoesOn() async throws {
        let ack = FakeAckVoice()
        let rig = Rig(ackVoice: ack)
        try await reachDelivered(rig)
        rig.run(1.6, decibels: -60)
        try await until("ack") { ack.isSpeaking }
        rig.engine.bargeIn()
        #expect(ack.stops == 1)
        #expect(!rig.engine.isAcking)
        #expect(rig.engine.bargeInCount == 1)
        #expect(rig.engine.state == .thinking)
        #expect(!rig.microphone.isOpen)
        // The reply still plays when it comes.
        rig.chat.progress = .done("It is noon.")
        try await until("speech") {
            rig.engine.tick()
            return rig.speech?.finished == true
        }
        #expect(rig.speech?.texts == ["It is noon."])
        #expect(ack.lines.count == 1)
    }

    @Test func speechOverTheAckStopsItAndTheTurnGoesOn() async throws {
        let ack = FakeAckVoice()
        let rig = Rig(ackVoice: ack)
        try await reachDelivered(rig)
        rig.run(1.6, decibels: -60)
        try await until("ack") { ack.isSpeaking }
        rig.run(0.4, decibels: -15)
        #expect(ack.stops == 1)
        #expect(!rig.engine.isAcking)
        #expect(rig.engine.state == .thinking)
        #expect(rig.chat.transcribed.count == 1)
        rig.chat.progress = .done("It is noon.")
        try await until("speech") {
            rig.engine.tick()
            return rig.speech?.finished == true
        }
    }

    @Test func theReplyAudioStopsAnAckThatStillPlays() async throws {
        let ack = FakeAckVoice()
        let rig = Rig(ackVoice: ack)
        try await reachDelivered(rig)
        rig.run(1.6, decibels: -60)
        try await until("ack") { ack.isSpeaking }
        rig.chat.progress = .done("It is noon.")
        try await until("speech") {
            rig.engine.tick()
            return rig.speech?.finished == true
        }
        let monitor = rig.microphone.started.last
        rig.speech?.push(.speaking(viaFallback: false))
        try await until { rig.engine.state == .speaking }
        #expect(ack.stops == 1)
        #expect(!rig.engine.isAcking)
        // The monitor clip of the ack stays as the barge-in monitor of the reply.
        #expect(rig.microphone.isOpen)
        #expect(rig.microphone.started.last == monitor)
    }

    @Test func endAndPauseStopTheAck() async throws {
        let ack = FakeAckVoice()
        let rig = Rig(ackVoice: ack)
        try await reachDelivered(rig)
        rig.run(1.6, decibels: -60)
        try await until("ack") { ack.isSpeaking }
        rig.engine.pause(.call)
        #expect(ack.stops == 1)
        #expect(!rig.engine.isAcking)
        rig.engine.end()
        #expect(ack.stops == 1)
    }

    @Test func muteClosesTheBargeInMicOfTheAck() async throws {
        let ack = FakeAckVoice()
        let rig = Rig(ackVoice: ack)
        try await reachDelivered(rig)
        rig.run(1.6, decibels: -60)
        try await until("ack") { ack.isSpeaking }
        #expect(rig.microphone.isOpen)
        rig.engine.toggleMute()
        #expect(!rig.microphone.isOpen)
        #expect(rig.engine.isAcking)
        rig.run(0.5, decibels: -10)
        #expect(ack.stops == 0)
        rig.engine.toggleMute()
        #expect(rig.microphone.isOpen)
    }

    @Test func aPromptHoldStopsTheAckAndBlocksIt() async throws {
        let ack = FakeAckVoice()
        let rig = Rig(ackVoice: ack)
        try await reachDelivered(rig)
        rig.engine.holdForPrompt()
        rig.run(3, decibels: -60)
        #expect(ack.lines.isEmpty)
    }

    /// Issue #139: the bundled clip voice in the loop. Reply audio and a tap both stop the clip, and the
    /// lines rotate with no repeat of the last line.
    @Test func theBundledClipPlaysInTheLoopAndTheReplyAudioStopsIt() async throws {
        let player = FakeAckClipPlayer()
        let fallback = FakeAckVoice()
        let rig = Rig(ackVoice: BundledAckVoice(clipURL: { AckClipFiles.url($0) }, player: player, fallback: fallback))
        try await reachDelivered(rig)
        rig.run(1.6, decibels: -60)
        try await until("ack") { player.isPlaying }
        #expect(player.urls == [AckClipFiles.url("Checking now.")])
        rig.chat.progress = .done("It is noon.")
        try await until("speech") {
            rig.engine.tick()
            return rig.speech?.finished == true
        }
        rig.speech?.push(.speaking(viaFallback: false))
        try await until { rig.engine.state == .speaking }
        #expect(!player.isPlaying)
        #expect(!rig.engine.isAcking)
        #expect(fallback.lines.isEmpty, "no on-device voice when the clip plays")

        // The next turn: the next line, and a tap stops it.
        rig.speech?.push(.ended)
        try await until("listening") { rig.engine.state == .listening }
        rig.chat.progress = .waiting
        rig.chat.turnResult = .delivered(promptId: "p2")
        rig.sayOneClip()
        try await until("thinking") { rig.engine.state == .thinking && rig.chat.turns.count == 2 }
        try await Task.sleep(for: .milliseconds(5))
        rig.run(1.6, decibels: -60)
        try await until("second ack") { player.isPlaying }
        #expect(player.urls == [AckClipFiles.url("Checking now."), AckClipFiles.url("One moment.")])
        rig.engine.bargeIn()
        #expect(!player.isPlaying)
        #expect(!rig.engine.isAcking)
        #expect(rig.engine.state == .thinking)
        rig.engine.end()
    }

    @Test func noAckVoiceMeansNoAck() async throws {
        let rig = Rig()
        try await reachDelivered(rig)
        rig.run(3, decibels: -60)
        #expect(rig.engine.ackCount == 0)
        #expect(!rig.microphone.isOpen)
    }
}

/// Issue #149: the thinking sound. It counts starts and stops. No audio.
@MainActor
final class FakeThinkingSound: VoiceModeThinkingSound {
    private(set) var starts = 0
    private(set) var stops = 0
    var isPlaying: Bool { starts > stops }

    func start() { starts += 1 }
    func stop() { stops += 1 }
}

/// Issue #149: the soft heartbeat while Hermes thinks.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct VoiceModeThinkingSoundTests {
    private func reachDelivered(_ rig: Rig) async throws {
        await rig.engine.start(chat: rig.chat)
        rig.sayOneClip()
        try await until("thinking") { rig.engine.state == .thinking && rig.chat.turns.count == 1 }
        try await Task.sleep(for: .milliseconds(5))
    }

    /// Up to the end of the ack: the loop may start from here.
    private func reachAckEnd(_ rig: Rig, _ ack: FakeAckVoice) async throws {
        try await reachDelivered(rig)
        rig.run(1.6, decibels: -60)
        try await until("ack") { ack.isSpeaking }
        ack.finishLine()
        try await until("ack end") { !rig.engine.isAcking }
    }

    private func playReply(_ rig: Rig) async throws {
        rig.chat.progress = .done("It is noon.")
        try await until("speech") {
            rig.engine.tick()
            return rig.speech?.finished == true
        }
        rig.speech?.push(.speaking(viaFallback: false))
        try await until("speaking") { rig.engine.state == .speaking }
    }

    @Test func theLoopStartsAfterTheAckAndStopsWhenTheReplyPlays() async throws {
        let ack = FakeAckVoice()
        let sound = FakeThinkingSound()
        let rig = Rig(ackVoice: ack, thinkingSound: sound)
        try await reachDelivered(rig)
        rig.run(1.6, decibels: -60)
        try await until("ack") { ack.isSpeaking }
        // The loop does not play over the ack.
        rig.run(1, decibels: -60)
        #expect(sound.starts == 0)
        #expect(!rig.engine.isPulsing)
        ack.finishLine()
        try await until("ack end") { !rig.engine.isAcking }
        rig.run(0.1, decibels: -60)
        #expect(sound.starts == 1)
        #expect(rig.engine.isPulsing)
        #expect(rig.engine.state == .thinking)
        // One start, however long the turn runs.
        rig.run(10, decibels: -60)
        #expect(sound.starts == 1)
        try await playReply(rig)
        #expect(sound.stops == 1)
        #expect(!rig.engine.isPulsing)
    }

    @Test func theSettingOffPlaysNoLoop() async throws {
        let ack = FakeAckVoice()
        let sound = FakeThinkingSound()
        let rig = Rig(ackVoice: ack, thinkingSound: sound)
        rig.thinkingSoundOn = false
        try await reachAckEnd(rig, ack)
        rig.run(5, decibels: -60)
        #expect(sound.starts == 0)
        #expect(!rig.engine.isPulsing)
    }

    @Test func aTapStopsTheLoopForTheTurnAndTheTurnGoesOn() async throws {
        let ack = FakeAckVoice()
        let sound = FakeThinkingSound()
        let rig = Rig(ackVoice: ack, thinkingSound: sound)
        try await reachAckEnd(rig, ack)
        rig.run(0.1, decibels: -60)
        #expect(rig.engine.isPulsing)
        rig.engine.bargeIn()
        #expect(sound.stops == 1)
        #expect(!rig.engine.isPulsing)
        #expect(rig.engine.state == .thinking)
        rig.run(5, decibels: -60)
        #expect(sound.starts == 1)
        // The reply still plays when it comes.
        try await playReply(rig)
        #expect(rig.speech?.texts == ["It is noon."])
    }

    @Test func theEndAndAnErrorStopTheLoop() async throws {
        let ack = FakeAckVoice()
        let sound = FakeThinkingSound()
        let rig = Rig(ackVoice: ack, thinkingSound: sound)
        try await reachAckEnd(rig, ack)
        rig.run(0.1, decibels: -60)
        #expect(sound.isPlaying)
        rig.engine.end()
        #expect(!sound.isPlaying)
        #expect(!rig.engine.isPulsing)

        let ack2 = FakeAckVoice()
        let sound2 = FakeThinkingSound()
        let failing = Rig(ackVoice: ack2, thinkingSound: sound2)
        try await reachAckEnd(failing, ack2)
        failing.run(0.1, decibels: -60)
        #expect(sound2.isPlaying)
        failing.chat.progress = .failed
        failing.run(0.1, decibels: -60)
        #expect(failing.engine.state == .error(.turnFailed))
        #expect(!sound2.isPlaying)
    }

    @Test func replyTextWithinTheDelayPlaysNoLoop() async throws {
        let ack = FakeAckVoice()
        let sound = FakeThinkingSound()
        let rig = Rig(ackVoice: ack, thinkingSound: sound)
        try await reachDelivered(rig)
        rig.run(0.5, decibels: -60)
        rig.chat.progress = .streaming("It is ")
        try await until("speech") {
            rig.engine.tick()
            return rig.speech?.texts == ["It is "]
        }
        rig.run(3, decibels: -60)
        #expect(sound.starts == 0)
    }

    @Test func withNoAckVoiceTheLoopStartsAtTheAckDelay() async throws {
        let sound = FakeThinkingSound()
        let rig = Rig(thinkingSound: sound)
        try await reachDelivered(rig)
        rig.run(1.4, decibels: -60)
        #expect(sound.starts == 0)
        rig.run(0.2, decibels: -60)
        #expect(sound.starts == 1)
        try await playReply(rig)
        #expect(sound.stops == 1)
    }

    @Test func eachTurnPlaysTheLoopAgain() async throws {
        let ack = FakeAckVoice()
        let sound = FakeThinkingSound()
        let rig = Rig(ackVoice: ack, thinkingSound: sound)
        try await reachAckEnd(rig, ack)
        rig.run(0.1, decibels: -60)
        try await playReply(rig)
        rig.speech?.push(.ended)
        try await until { rig.engine.state == .listening }
        rig.chat.progress = .waiting
        rig.chat.turnResult = .delivered(promptId: "p2")
        rig.sayOneClip()
        try await until { rig.engine.state == .thinking && rig.chat.turns.count == 2 }
        try await Task.sleep(for: .milliseconds(5))
        rig.run(1.6, decibels: -60)
        try await until("second ack") { ack.lines.count == 2 && ack.isSpeaking }
        ack.finishLine()
        try await until("ack end") { !rig.engine.isAcking }
        rig.run(0.1, decibels: -60)
        #expect(sound.starts == 2)
    }

    @Test func theBundledLoopIsAShortMonoClip() throws {
        let url = AckClipFiles.directory.deletingLastPathComponent()
            .appending(path: "ThinkingSound/thinking-heartbeat.m4a")
        let buffer = try VoiceModeAckClips.decode(url)
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        #expect(seconds > 1.4 && seconds < 1.9, "\(seconds) s")
        #expect(buffer.format.channelCount == 1)
        #expect(try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) < 50_000)
        #expect(VoiceModeThinkingSoundSettings.resourceName == "thinking-heartbeat")
    }

    @Test func theSettingIsOnByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "thinking-sound-\(UUID().uuidString)"))
        #expect(VoiceModeThinkingSoundSettings.isOn(defaults))
        defaults.set(false, forKey: VoiceModeThinkingSoundSettings.key)
        #expect(!VoiceModeThinkingSoundSettings.isOn(defaults))
    }
}
