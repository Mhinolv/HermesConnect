import Foundation

/// The states of one spoken reply, for the #96 voice panel.
public enum StreamedSpeechState: Sendable, Equatable {
    /// The socket opens, or the server synthesizes the first sentence.
    case preparing
    /// Audio plays. `viaFallback` is `true` for the `POST /api/audio/speak` clip. The panel shows the same
    /// "Speaking" state for both, because a fallback is silent for the owner (#97 design notes).
    case speaking(viaFallback: Bool)
    /// All audio played, or the reply had no text to speak.
    case ended
    /// `stop()` ran (barge-in, "End", a call).
    case stopped
    case failed(SpeechStreamError)

    public var isFinal: Bool {
        switch self {
        case .preparing, .speaking: false
        case .ended, .stopped, .failed: true
        }
    }
}

/// Speaks one reply while it streams in (issue #97): `speak-stream` first, `POST /api/audio/speak` as the fallback.
///
/// 1. Call `append` with each reply delta, then `finish` when the reply is complete (`{"done":true}`).
/// 2. Read `states`, or wait with `waitUntilDone()`.
/// 3. Call `stop()` for barge-in. The player is silent when `stop()` returns.
/// End each speaker with `finish()` or `stop()`. Until then, the fallback waits for the rest of the text.
///
/// A `fallback` frame, or a drop before any audio, speaks the whole reply with the POST once the text is complete.
/// A drop after audio started plays what came, as the desktop app does. A refused token fails at once and
/// calls `onUnauthorized`. The text, the audio and the token never go to a log.
public actor StreamedSpeech {
    public typealias Opener = @Sendable () async throws -> SpeakStreamConnection
    public typealias FallbackSpeaker = @Sendable (String) async throws -> SpokenAudio

    /// Every state change, in order. The stream ends after the final state.
    public nonisolated let states: AsyncStream<StreamedSpeechState>
    public private(set) var state: StreamedSpeechState = .preparing

    private let open: Opener
    private let fallback: FallbackSpeaker
    private let player: any StreamedSpeechPlaying
    private let onUnauthorized: @Sendable () async -> Void
    private let statesContinuation: AsyncStream<StreamedSpeechState>.Continuation
    private let outbox: AsyncStream<Outbound>
    private let outboxContinuation: AsyncStream<Outbound>.Continuation
    private static let log = HermesLog(category: "voice")

    private enum Outbound: Sendable { case text(String), done }

    private var started = false
    private var text = ""
    private var textComplete = false
    private var textWaiters: [CheckedContinuation<Void, Never>] = []
    private var finalWaiters: [CheckedContinuation<StreamedSpeechState, Never>] = []
    private var connection: SpeakStreamConnection?
    private var tasks: [Task<Void, Never>] = []

    public init(open: @escaping Opener, fallback: @escaping FallbackSpeaker, player: any StreamedSpeechPlaying,
                onUnauthorized: @escaping @Sendable () async -> Void = {}) {
        self.open = open
        self.fallback = fallback
        self.player = player
        self.onUnauthorized = onUnauthorized
        (states, statesContinuation) = AsyncStream.makeStream(of: StreamedSpeechState.self)
        (outbox, outboxContinuation) = AsyncStream.makeStream(of: Outbound.self)
        statesContinuation.yield(.preparing)
    }

    /// Opens the socket. `append` and `finish` call it too, so a caller can skip it.
    /// Call it early (when the reply starts) to hide the connect time.
    public func start() {
        guard !started, !state.isFinal else { return }
        started = true
        tasks.append(Task { await self.run() })
    }

    /// One reply delta, as it is: the server strips Markdown per sentence.
    public func append(_ delta: String) {
        guard !delta.isEmpty, !textComplete, !state.isFinal else { return }
        start()
        text += delta
        outboxContinuation.yield(.text(delta))
    }

    /// The reply is complete: sends `{"done":true}`.
    public func finish() {
        guard !textComplete, !state.isFinal else { return }
        start()
        textComplete = true
        outboxContinuation.yield(.done)
        outboxContinuation.finish()
        wakeTextWaiters()
    }

    /// Barge-in. The player is silent at once. Then the socket sends `{"stop":true}` and closes.
    public func stop() async {
        guard !state.isFinal else { return }
        player.stop()
        settle(.stopped)
        outboxContinuation.finish()
        wakeTextWaiters()
        let connection = self.connection
        self.connection = nil
        await connection?.stop()
    }

    /// Waits for the final state.
    public func waitUntilDone() async -> StreamedSpeechState {
        if state.isFinal { return state }
        return await withCheckedContinuation { finalWaiters.append($0) }
    }

    // MARK: Run

    private func run() async {
        let connection: SpeakStreamConnection
        do {
            connection = try await open()
        } catch {
            await streamFailed(error, audioStarted: false)
            return
        }
        guard !state.isFinal else {
            connection.close()
            return
        }
        self.connection = connection
        let outbox = self.outbox
        tasks.append(Task {
            // One writer keeps the deltas in order. A send error shows up on the receive side.
            for await frame in outbox {
                switch frame {
                case .text(let delta): try? await connection.send(text: delta)
                case .done: try? await connection.finish()
                }
            }
        })
        await receive(from: connection)
    }

    private func receive(from connection: SpeakStreamConnection) async {
        var audioStarted = false
        var playerReady = false
        do {
            while true {
                let event = try await connection.next()
                guard !state.isFinal else { return }
                switch event {
                case .start(let sampleRate, _):
                    try player.begin(sampleRate: Double(sampleRate))
                    playerReady = true
                    Self.log.info("speak-stream start rate=\(sampleRate)")
                case .audio(let pcm):
                    if !playerReady {
                        try player.begin(sampleRate: Double(PCM16Samples.defaultSampleRate))
                        playerReady = true
                    }
                    player.enqueue(pcm)
                    if !audioStarted {
                        audioStarted = true
                        transition(.speaking(viaFallback: false))
                    }
                case .end:
                    close(connection)
                    await player.drain()
                    if !state.isFinal { Self.log.info("speak-stream end") }
                    settle(.ended)
                    return
                case .fallback:
                    close(connection)
                    Self.log.info("speak-stream fallback")
                    await speakWholeReply()
                    return
                }
            }
        } catch {
            close(connection)
            await streamFailed(error, audioStarted: audioStarted)
        }
    }

    private func streamFailed(_ error: any Error, audioStarted: Bool) async {
        guard !state.isFinal else { return }
        let reason = SpeechStreamError.from(error)
        Self.log.info("speak-stream dropped reason=\(reason) audio=\(audioStarted)")
        if reason == .unauthorized {
            fail(.unauthorized)
            return
        }
        if audioStarted {
            await player.drain()
            settle(.ended)
        } else {
            await speakWholeReply()
        }
    }

    /// The fallback: waits for the whole reply, then speaks it with `POST /api/audio/speak`.
    private func speakWholeReply() async {
        await waitForText()
        guard !state.isFinal else { return }
        let spoken = VoiceReplyText.spokenText(text)
        guard !spoken.isEmpty else {
            settle(.ended)
            return
        }
        do {
            let audio = try await fallback(spoken)
            guard !state.isFinal else { return }
            transition(.speaking(viaFallback: true))
            try await player.playClip(audio)
            settle(.ended)
        } catch {
            guard !state.isFinal else { return }
            fail(SpeechStreamError.from(error))
        }
    }

    // MARK: State

    private func close(_ connection: SpeakStreamConnection) {
        connection.close()
        if self.connection === connection { self.connection = nil }
    }

    private func fail(_ reason: SpeechStreamError) {
        Self.log.info("speech failed reason=\(reason)")
        settle(.failed(reason))
        if reason == .unauthorized {
            let onUnauthorized = self.onUnauthorized
            Task { await onUnauthorized() }
        }
    }

    private func transition(_ next: StreamedSpeechState) {
        guard !state.isFinal, state != next else { return }
        state = next
        statesContinuation.yield(next)
    }

    private func settle(_ final: StreamedSpeechState) {
        guard !state.isFinal else { return }
        state = final
        statesContinuation.yield(final)
        statesContinuation.finish()
        outboxContinuation.finish()
        wakeTextWaiters()
        let waiters = finalWaiters
        finalWaiters = []
        waiters.forEach { $0.resume(returning: final) }
    }

    private func waitForText() async {
        guard !textComplete, !state.isFinal else { return }
        await withCheckedContinuation { textWaiters.append($0) }
    }

    private func wakeTextWaiters() {
        let waiters = textWaiters
        textWaiters = []
        waiters.forEach { $0.resume() }
    }
}
