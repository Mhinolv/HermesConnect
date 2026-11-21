import Foundation
import Observation

// Issue #96: voice mode, the hands-free loop of desktop `chained` mode:
// listen → transcript → `prompt.submit` voice turn → streamed reply → `speak-stream`, then listen again.
// The app always runs this flow, whatever `voice.voice_chat_mode` the server has (orchestrator decision).
// No UI here. The #101 Voice tab shows the state.

public enum VoiceModePauseReason: Sendable, Equatable {
    case call, background, lock
}

public enum VoiceModeEndReason: Sendable, Equatable {
    /// The owner tapped End.
    case end
    /// The owner said the single word "stop". It is not sent.
    case stopWord
    /// 30 s with no speech.
    case silence
}

public enum VoiceModeFailure: Error, Sendable, Equatable {
    /// iOS microphone access is off.
    case microphoneOff
    /// Issue #135: access is on, but the audio session or the microphone did not start. Try Again starts it again.
    case microphoneUnavailable
    /// No link to the server. A clip that did not get a transcript waits in the outbox.
    case offline
    /// The transcription or the Hermes turn failed.
    case turnFailed
    /// `speak-stream` and the `POST /api/audio/speak` fallback failed. The reply is in the thread.
    case speakFailed
}

/// The engine states for #101 (design notes table).
public enum VoiceModeState: Sendable, Equatable {
    case idle
    /// The microphone records. `level` is the mic level.
    case listening
    case transcribing
    /// The Hermes turn runs. `thinkingSeconds` counts up.
    case thinking
    /// The reply plays. `level` is the output level.
    case speaking
    /// Barge-in stops the reply. Listening follows at once.
    case interrupted
    case muted
    /// The microphone is closed and the reply is silent. `resume()` listens again.
    case paused(VoiceModePauseReason)
    case ended(VoiceModeEndReason)
    /// The microphone is closed. `resume()` tries again. `end()` exits.
    case error(VoiceModeFailure)

    /// `true` from `start` until `end`.
    public var isActive: Bool {
        switch self {
        case .idle, .ended: false
        default: true
        }
    }
}

/// How the chat took one voice turn.
public enum VoiceModeTurnResult: Sendable, Equatable {
    /// `prompt.submit` took the turn. `promptId` is the id of the memo bubble.
    case delivered(promptId: String)
    /// Offline: the memo waits in the outbox.
    case queued
    /// The server refused the turn. The memo shows "Not Delivered".
    case failed
}

/// The target chat of voice mode: the active chat, a new chat, or a chat that the owner picks.
/// `ChatViewModel` conforms. Each turn is a normal #9 memo bubble and a #10 reply in it.
@MainActor
public protocol VoiceModeChat: AnyObject {
    /// The #44 memo engines: on-device first, `POST /api/audio/transcribe` as the fallback.
    func transcribeVoiceClip(at url: URL) async throws -> String
    /// Adds the memo bubble with its transcript and sends it as a voice turn.
    func sendVoiceModeTurn(_ memo: VoiceMemo, transcript: String) async -> VoiceModeTurnResult
    func replyProgress(promptId: String) -> LiveReplyProgress
    /// The audio that played. The reply bubble shows it as its #10 voice reply.
    func attachVoiceModeAudio(_ audio: SpokenAudio, promptId: String)
    /// A clip with no transcript: the normal memo path keeps it (outbox when offline, "Try Again" on a failure).
    @discardableResult func sendVoiceMemo(_ memo: VoiceMemo) -> Task<Void, Never>
}

/// The limits of the loop. Tests make the times short.
public struct VoiceModeTuning: Sendable, Equatable {
    /// Issue #134: with no reply text this long after the turn is delivered, the local ack plays.
    public var ackDelaySeconds: TimeInterval = 1.5
    /// A level at or above this is speech.
    public var speechDecibels: Float = -40
    /// Speech must last this long before a clip counts as speech. A click does not.
    public var speechOnsetSeconds: TimeInterval = 0.15
    /// About 3 s of silence after speech ends a clip (server `silence_duration`).
    public var clipSilenceSeconds: TimeInterval = 3
    /// 30 s with no speech ends voice mode (orchestrator decision).
    public var idleEndSeconds: TimeInterval = 30
    /// The server `max_recording_seconds`.
    public var maxClipSeconds: TimeInterval = 120
    /// The microphone stays open while the reply plays, so the owner can talk over it.
    public var autoBargeIn = true
    /// Barge-in needs a louder level than a clip, so the reply echo does not stop the reply.
    public var bargeInDecibels: Float = -25
    public var bargeInSeconds: TimeInterval = 0.3
    /// 30 ticks a second: the levels for #101.
    public var tickInterval: Duration = .milliseconds(33)

    public init() {}
}

/// Issue #134: the voice of the quick ack. Nothing goes to the server.
/// Issue #139: the app uses `BundledAckVoice` (bundled clips), with the on-device voice (#121) as the fallback.
@MainActor
public protocol VoiceModeAckVoice: AnyObject {
    /// Says one line, and returns when it ends or `stop()` cuts it.
    func speak(_ line: String) async
    /// Stops the speech at once.
    func stop()
}

public enum VoiceModeText {
    /// Issue #134: the quick ack lines, in turn (design notes). In order, so no line follows itself.
    /// Issue #139: the same lines as `HermesConnect/Resources/AckClips/ack_lines.txt`, one bundled clip each.
    public static let ackLines = ["Checking now.", "One moment.", "On it.", "Just a moment.", "Let me check."]

    /// The single word "stop", with any case and punctuation.
    public static func isStopWord(_ transcript: String) -> Bool {
        transcript.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .trimmingCharacters(in: .whitespacesAndNewlines) == "stop"
    }
}

/// The voice mode engine (issue #96). One hands-free session at a time, for one target chat.
///
/// - Listen: the clip ends after about 3 s of silence that follows speech. 30 s with no speech ends the loop.
/// - The clip goes to the #44 engines (server whisper as the fallback). "stop" ends the loop and is not sent.
/// - The transcript goes as a voice turn in the target chat. The reply streams into `speak-stream` (#97).
/// - Barge-in sends `{"stop":true}` and listens again. A call, background or Lock pauses the loop and closes the mic.
/// - The log gets ids, counts and states. Never the clip, the transcript, the reply or the audio.
@MainActor @Observable
public final class VoiceModeController {
    public private(set) var state: VoiceModeState = .idle
    public private(set) var muted = false
    /// From 0 to 1: the mic level while listening, the output level while speaking, else 0.
    public private(set) var level: Float = 0
    /// Seconds since the turn went to Hermes. #101 shows "Still working…" after 10 s.
    public private(set) var thinkingSeconds = 0
    /// One more each time a clip ends on silence. #101 plays the soft tone.
    public private(set) var clipEndCount = 0
    /// One more on each barge-in.
    public private(set) var bargeInCount = 0
    /// Issue #134: the quick ack plays. The state stays `.thinking`. A tap or speech stops it.
    public private(set) var isAcking = false
    /// Issue #134: one more on each ack that starts.
    public private(set) var ackCount = 0
    /// Issue #149: the thinking sound plays. The state stays `.thinking`. A tap stops it.
    public private(set) var isPulsing = false

    public typealias SpeechFactory = @MainActor (any StreamedSpeechPlaying) async throws -> any VoiceModeSpeaking

    @ObservationIgnored private let microphone: any VoiceModeMicrophone
    @ObservationIgnored private let player: any StreamedSpeechPlaying
    @ObservationIgnored private let makeSpeech: SpeechFactory
    @ObservationIgnored private let makeClipURL: @MainActor () -> URL
    @ObservationIgnored private let removeFile: @MainActor (URL) -> Void
    @ObservationIgnored private let clock: @Sendable () -> TimeInterval
    @ObservationIgnored private let autoTick: Bool
    @ObservationIgnored public let tuning: VoiceModeTuning
    @ObservationIgnored private weak var chat: (any VoiceModeChat)?
    @ObservationIgnored private let ackVoice: (any VoiceModeAckVoice)?
    @ObservationIgnored private let thinkingSound: (any VoiceModeThinkingSound)?
    /// Issue #149: the "Thinking Sound" setting. Read at each turn, so a change applies at the next turn.
    @ObservationIgnored private let thinkingSoundOn: @MainActor () -> Bool
    /// One more on each ack start and stop. An ack of an older serial changes nothing when it ends.
    @ObservationIgnored private var ackSerial = 0

    /// One more on each start and end. A task of an older session changes nothing.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var clip: Clip?
    @ObservationIgnored private var turn: Turn?
    @ObservationIgnored private var turnSerial = 0
    @ObservationIgnored private var idleSince: TimeInterval = 0
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Issue #121: a Hermes prompt waits. The loop keeps the mic closed and the idle timer stops.
    @ObservationIgnored public private(set) var promptHold = false
    @ObservationIgnored private let log = HermesLog(category: "voice-mode")

    private struct Clip {
        var url: URL
        var startedAt: TimeInterval
        /// `true` for the clip that records while the reply plays (barge-in).
        var monitor: Bool
        var levels: [Float] = []
        var voiceSince: TimeInterval?
        var heardSpeech = false
        var lastVoiceAt: TimeInterval = 0
    }

    private enum SpeechCommand: Sendable {
        case append(String)
        case finish
    }

    private struct Turn {
        var id: Int
        var startedAt: TimeInterval
        var promptId: String?
        var tap: VoiceModeSpeechTap
        var speech: (any VoiceModeSpeaking)?
        var makingSpeech = false
        /// Issue #134: the reply text that went to the speaker. The text of an interim message comes first.
        var sentText = ""
        var finished = false
        /// Issue #134: when `prompt.submit` took the turn. The ack waits from here.
        var deliveredAt: TimeInterval?
        /// Issue #134: one ack per turn at most.
        var ackStarted = false
        /// Issue #149: the thinking sound started in this turn. It does not start again after a stop.
        var pulseStarted = false
        var commands: AsyncStream<SpeechCommand>.Continuation?
    }

    /// - Parameters:
    ///   - makeSpeech: a speaker for one reply. The app passes `VoiceStreamTransport.makeStreamedSpeech`.
    ///   - clock: seconds on a monotonic clock.
    ///   - autoTick: `false` in tests. The test calls `tick()`.
    ///   - ackVoice: issue #134, the on-device voice of the quick ack. `nil`: no ack.
    ///   - thinkingSound: issue #149, the loop while Hermes thinks. `nil`: no sound.
    ///   - thinkingSoundOn: issue #149, the "Thinking Sound" setting.
    public init(microphone: any VoiceModeMicrophone, player: any StreamedSpeechPlaying,
                makeSpeech: @escaping SpeechFactory,
                makeClipURL: @escaping @MainActor () -> URL,
                removeFile: @escaping @MainActor (URL) -> Void = { try? FileManager.default.removeItem(at: $0) },
                tuning: VoiceModeTuning = VoiceModeTuning(),
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                autoTick: Bool = true, ackVoice: (any VoiceModeAckVoice)? = nil,
                thinkingSound: (any VoiceModeThinkingSound)? = nil,
                thinkingSoundOn: @escaping @MainActor () -> Bool = { true }) {
        self.ackVoice = ackVoice
        self.thinkingSound = thinkingSound
        self.thinkingSoundOn = thinkingSoundOn
        self.microphone = microphone
        self.player = player
        self.makeSpeech = makeSpeech
        self.makeClipURL = makeClipURL
        self.removeFile = removeFile
        self.tuning = tuning
        self.clock = clock
        self.autoTick = autoTick
    }

    // MARK: Start and end

    /// Starts a hands-free session in `chat`. It asks for the microphone first when iOS has not asked yet.
    public func start(chat: any VoiceModeChat) async {
        guard !state.isActive, !starting else { return }
        starting = true
        defer { starting = false }
        epoch += 1
        let epoch = epoch
        self.chat = chat
        muted = false
        level = 0
        thinkingSeconds = 0
        clip = nil
        turn = nil
        switch microphone.access {
        case .granted:
            break
        case .denied:
            return setFailure(.microphoneOff)
        case .undetermined:
            let allowed = await microphone.requestAccess()
            guard self.epoch == epoch else { return }
            guard allowed else { return setFailure(.microphoneOff) }
        }
        guard activateSession() else { return setFailure(.microphoneUnavailable) }
        log.info("voice mode started")
        idleSince = clock()
        listen()
        if autoTick { startTicker() }
    }

    /// The End button. The microphone closes and the audio session is released.
    public func end() {
        end(.end)
    }

    private func end(_ reason: VoiceModeEndReason) {
        guard state.isActive else { return }
        epoch += 1
        promptHold = false
        silenceTurn()
        closeMicrophone()
        tickTask?.cancel()
        tickTask = nil
        deactivateSession()
        level = 0
        state = .ended(reason)
        log.info("voice mode ended: \(String(describing: reason))")
    }

    /// A call, background or Lock. The microphone closes and the reply stops. A turn in flight still goes to
    /// the chat, so its reply shows in the thread. A new reason replaces the old one (background, then Lock).
    public func pause(_ reason: VoiceModePauseReason) {
        guard state.isActive else { return }
        if case .paused = state {
            state = .paused(reason)
            return
        }
        silenceTurn()
        closeMicrophone()
        deactivateSession()
        level = 0
        state = .paused(reason)
        log.info("voice mode paused: \(String(describing: reason))")
    }

    /// Listens again after a pause or an error.
    public func resume() {
        switch state {
        case .paused, .error: break
        default: return
        }
        // Issue #121: a resume shows the prompt again. The prompt opens the mic after the answer.
        if microphone.access != .granted { return setFailure(.microphoneOff) }
        guard activateSession() else { return setFailure(.microphoneUnavailable) }
        idleSince = clock()
        listen()
        if autoTick, tickTask == nil { startTicker() }
    }

    public func toggleMute() {
        switch state {
        case .idle, .ended, .paused, .error: return
        default: break
        }
        muted.toggle()
        log.info("voice mode muted: \(muted)")
        if muted {
            switch state {
            case .listening:
                closeMicrophone()
                level = 0
                state = .muted
            case .speaking:
                closeMicrophone()
            case .thinking where isAcking:
                // Issue #134: the barge-in mic of the ack closes. The ack goes on.
                closeMicrophone()
            default:
                break
            }
        } else {
            switch state {
            case .muted:
                idleSince = clock()
                listen()
            case .speaking:
                startMonitor()
            case .thinking where isAcking:
                startMonitor()
            default:
                break
            }
        }
    }

    /// Barge-in: the reply stops (`{"stop":true}`) and the next listen turn opens. A tap on the ring calls it,
    /// and so does speech over the reply.
    public func bargeIn() {
        if state == .thinking, isAcking {
            // Issue #134: the ack stops. The Hermes turn goes on, and its reply plays when it comes.
            bargeInCount += 1
            stopAck()
            closeMicrophone()
            log.info("voice mode ack barge-in")
            return
        }
        if state == .thinking, isPulsing {
            // Issue #149: a tap stops the thinking sound for this turn. The Hermes turn goes on.
            stopPulse()
            log.info("voice mode thinking sound stopped by a tap")
            return
        }
        guard state == .speaking, let current = turn else { return }
        bargeInCount += 1
        turn = nil
        current.commands?.finish()
        // The clip of the barge-in monitor stays open: it holds the start of the owner's words.
        clip?.monitor = false
        state = .interrupted
        level = 0
        log.info("voice mode barge-in")
        let epoch = epoch
        Task { [weak self] in
            await current.speech?.stop()
            guard let self, self.epoch == epoch, self.state == .interrupted else { return }
            self.idleSince = self.clock()
            if self.clip != nil, !self.muted {
                self.state = .listening
            } else {
                self.listen()
            }
        }
    }

    /// Issue #101, Magic Tap: the clip ends now and goes to Hermes, with no wait for the silence.
    /// A clip with no speech gets no transcript, so listening starts again.
    public func sendClip() {
        guard state == .listening, let current = clip, !current.monitor else { return }
        endClip()
    }

    // MARK: Prompts (issue #121)

    /// A Hermes prompt waits: the mic closes, and the next listen turn waits for `releasePrompt()`. The Hermes turn
    /// waits on the server for the answer, so the reply does not stream meanwhile.
    public func holdForPrompt() {
        guard state.isActive, !promptHold else { return }
        promptHold = true
        stopAck()
        stopPulse()
        closeMicrophone()
        level = 0
        log.info("voice mode held for a prompt")
    }

    /// The prompt ended (answer or timeout): the loop goes on.
    public func releasePrompt() {
        guard promptHold else { return }
        promptHold = false
        log.info("voice mode prompt released")
        idleSince = clock()
        switch state {
        case .listening where clip == nil: listen()
        case .speaking: startMonitor()
        default: break
        }
    }

    // MARK: Clock

    private func startTicker() {
        tickTask?.cancel()
        let interval = tuning.tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// Runs 30 times a second: the levels, the silence rules, the reply stream and barge-in.
    public func tick() {
        let time = clock()
        switch state {
        case .listening:
            listenTick(time)
        case .thinking:
            // A small margin keeps whole seconds whole on a clock that adds 1/30 s steps.
            let seconds = max(0, Int(time - (turn?.startedAt ?? time) + 0.001))
            if seconds != thinkingSeconds { thinkingSeconds = seconds }
            pumpReply()
            guard state == .thinking else { return }
            if isAcking {
                monitorTick(time)
            } else {
                ackTick(time)
                pulseTick(time)
            }
        case .speaking:
            pumpReply()
            guard state == .speaking, let turn else { return }
            setLevel(turn.tap.level(at: time))
            monitorTick(time)
        default:
            break
        }
    }

    private func setLevel(_ value: Float) {
        if value != level { level = value }
    }

    // MARK: Listen

    private func listen() {
        if promptHold {
            // The mic opens after the prompt. No clip means no idle end meanwhile.
            closeMicrophone()
            level = 0
            state = .listening
            return
        }
        guard !muted else {
            closeMicrophone()
            level = 0
            state = .muted
            return
        }
        let url = makeClipURL()
        do {
            try microphone.startClip(url: url)
        } catch {
            return setFailure(.microphoneUnavailable)
        }
        clip = Clip(url: url, startedAt: clock(), monitor: false)
        state = .listening
    }

    private func listenTick(_ time: TimeInterval) {
        guard var current = clip else { return }
        let decibels = microphone.level()
        let value = VoiceWaveform.level(decibels: decibels)
        setLevel(value)
        current.levels.append(value)
        if decibels >= tuning.speechDecibels {
            let since = current.voiceSince ?? time
            current.voiceSince = since
            if time - since >= tuning.speechOnsetSeconds { current.heardSpeech = true }
            current.lastVoiceAt = time
        } else {
            current.voiceSince = nil
        }
        clip = current
        if current.heardSpeech {
            if time - current.lastVoiceAt >= tuning.clipSilenceSeconds || time - current.startedAt >= tuning.maxClipSeconds {
                endClip()
            }
        } else if time - idleSince >= tuning.idleEndSeconds {
            end(.silence)
        }
    }

    /// About 3 s of silence after speech: the clip goes to the transcript step.
    private func endClip() {
        guard let current = clip, let chat else { return }
        clip = nil
        let duration = microphone.stopClip()
        clipEndCount += 1
        level = 0
        state = .transcribing
        let memo = VoiceMemo(fileURL: current.url, duration: duration, waveform: VoiceWaveform.bars(from: current.levels))
        log.info("voice mode clip ended: \(Int(duration)) s")
        let epoch = epoch
        Task { [weak self] in await self?.runTurn(memo, chat: chat, epoch: epoch) }
    }

    private func runTurn(_ memo: VoiceMemo, chat: any VoiceModeChat, epoch: Int) async {
        let transcript: String
        do {
            transcript = try await chat.transcribeVoiceClip(at: memo.fileURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            guard self.epoch == epoch else { return removeFile(memo.fileURL) }
            // The owner never loses a recording: the normal memo path keeps the clip.
            chat.sendVoiceMemo(memo)
            log.notice("voice mode transcript failed")
            if state == .transcribing { setFailure(Outbox.isOffline(error, submitted: false) ? .offline : .turnFailed) }
            return
        }
        guard self.epoch == epoch else { return removeFile(memo.fileURL) }
        if VoiceModeText.isStopWord(transcript) {
            removeFile(memo.fileURL)
            return end(.stopWord)
        }
        if transcript.isEmpty {
            removeFile(memo.fileURL)
            log.info("voice mode clip had no speech")
            if state == .transcribing { listen() }
            return
        }
        idleSince = clock()
        var tracked: Int?
        if state == .transcribing {
            turnSerial += 1
            tracked = turnSerial
            turn = Turn(id: turnSerial, startedAt: clock(), tap: VoiceModeSpeechTap(player: player, clock: clock))
            thinkingSeconds = 0
            state = .thinking
        }
        var sent = memo
        sent.transcript = .done(transcript)
        let result = await chat.sendVoiceModeTurn(sent, transcript: transcript)
        guard self.epoch == epoch, let tracked, turn?.id == tracked, state == .thinking else { return }
        switch result {
        case .delivered(let promptId):
            turn?.promptId = promptId
            turn?.deliveredAt = clock()
            log.info("voice mode turn delivered: message \(promptId)")
            pumpReply()
        case .queued:
            turn = nil
            setFailure(.offline)
        case .failed:
            turn = nil
            setFailure(.turnFailed)
        }
    }

    // MARK: Reply

    /// Sends the new reply text to the speaker. The speaker opens with the first text.
    private func pumpReply() {
        guard var current = turn, let promptId = current.promptId, let chat else { return }
        let text: String
        let done: Bool
        switch chat.replyProgress(promptId: promptId) {
        case .waiting:
            return
        case .streaming(let streamed):
            text = streamed
            done = false
        case .done(let complete):
            text = complete
            done = true
        case .failed:
            silenceTurn()
            return setFailure(.turnFailed)
        }
        guard current.speech != nil else {
            if done, current.sentText.isEmpty, VoiceReplyText.spokenText(text).isEmpty {
                // Nothing to speak: listen again.
                turn = nil
                return afterReply()
            }
            guard !current.makingSpeech, !text.isEmpty else { return }
            current.makingSpeech = true
            turn = current
            openSpeech(for: current)
            return
        }
        guard !current.finished else { return }
        // Issue #134: by text, not by a character count. A final text that drops the interim text loses nothing.
        let delta = VoiceReplyText.unsent(in: text, after: current.sentText)
        if !delta.isEmpty {
            current.commands?.yield(.append(delta))
            current.sentText += delta
        }
        if done {
            current.finished = true
            current.commands?.yield(.finish)
            current.commands?.finish()
        }
        turn = current
    }

    private func openSpeech(for current: Turn) {
        let epoch = epoch
        let id = current.id
        let tap = current.tap
        let makeSpeech = self.makeSpeech
        Task { [weak self] in
            let speech: any VoiceModeSpeaking
            do {
                speech = try await makeSpeech(tap)
            } catch {
                guard let self, self.epoch == epoch, self.turn?.id == id else { return }
                self.turn = nil
                return self.setFailure(SpeechStreamError.from(error) == .offline ? .offline : .speakFailed)
            }
            guard let self, self.epoch == epoch, self.turn?.id == id else {
                await speech.stop()
                return
            }
            // One writer keeps the deltas in order.
            let (commands, continuation) = AsyncStream.makeStream(of: SpeechCommand.self)
            self.turn?.speech = speech
            self.turn?.commands = continuation
            Task {
                await speech.start()
                for await command in commands {
                    switch command {
                    case .append(let delta): await speech.append(delta)
                    case .finish: await speech.finish()
                    }
                }
            }
            Task { [weak self] in
                for await speechState in speech.states {
                    self?.speechChanged(speechState, turn: id, epoch: epoch)
                }
            }
            self.pumpReply()
        }
    }

    private func speechChanged(_ speechState: StreamedSpeechState, turn id: Int, epoch: Int) {
        guard self.epoch == epoch, turn?.id == id else { return }
        switch speechState {
        case .speaking:
            guard state == .thinking else { return }
            // Issue #134: the reply wins over the ack. The monitor clip of the ack stays for the reply.
            stopAck()
            // Issue #149: the thinking sound fades out under the reply.
            stopPulse()
            state = .speaking
            startMonitor()
        case .ended:
            finishTurn()
        case .failed(let reason):
            turn = nil
            log.notice("voice mode speech failed")
            setFailure(reason == .offline ? .offline : .speakFailed)
        case .preparing, .stopped:
            break
        }
    }

    /// The reply played to its end. The bubble gets the audio. Then the next listen turn opens.
    private func finishTurn() {
        guard let current = turn else { return }
        turn = nil
        if let promptId = current.promptId, let audio = current.tap.recordedAudio() {
            chat?.attachVoiceModeAudio(audio, promptId: promptId)
        }
        afterReply()
    }

    private func afterReply() {
        stopAck()
        stopPulse()
        closeMicrophone()
        idleSince = clock()
        level = 0
        listen()
    }

    // MARK: Quick ack (issue #134)

    /// About 1.5 s after the turn is delivered with no reply text: one short on-device line. One per turn.
    /// Reply text before the delay opens the speaker, so no ack plays. The mic listens for a barge-in meanwhile.
    private func ackTick(_ time: TimeInterval) {
        guard let ackVoice, !promptHold, var current = turn, !current.ackStarted,
              let deliveredAt = current.deliveredAt, current.speech == nil, !current.makingSpeech,
              time - deliveredAt >= tuning.ackDelaySeconds else { return }
        current.ackStarted = true
        turn = current
        let lines = VoiceModeText.ackLines
        let line = lines[ackCount % lines.count]
        ackCount += 1
        ackSerial += 1
        let serial = ackSerial
        isAcking = true
        log.info("voice mode ack")
        startMonitor()
        Task { [weak self] in
            await ackVoice.speak(line)
            self?.ackEnded(serial)
        }
    }

    private func ackEnded(_ serial: Int) {
        guard serial == ackSerial, isAcking else { return }
        isAcking = false
        // The turn still thinks: the monitor clip of the ack closes. A reply that plays keeps it.
        if state == .thinking, clip?.monitor == true { closeMicrophone() }
    }

    private func stopAck() {
        guard isAcking else { return }
        ackSerial += 1
        isAcking = false
        ackVoice?.stop()
    }

    // MARK: Thinking sound (issue #149)

    /// After the ack ends, the loop plays until the reply plays. With no ack voice, it starts at the ack delay.
    /// Reply text before the delay opens the speaker, so no ack and no loop play. One start per turn.
    private func pulseTick(_ time: TimeInterval) {
        guard let thinkingSound, !isPulsing, !isAcking, !promptHold, var current = turn, !current.pulseStarted,
              let deliveredAt = current.deliveredAt, time - deliveredAt >= tuning.ackDelaySeconds,
              current.ackStarted || (ackVoice == nil && current.speech == nil && !current.makingSpeech),
              thinkingSoundOn() else { return }
        current.pulseStarted = true
        turn = current
        isPulsing = true
        log.info("voice mode thinking sound")
        thinkingSound.start()
    }

    private func stopPulse() {
        guard isPulsing else { return }
        isPulsing = false
        thinkingSound?.stop()
    }

    // MARK: Barge-in monitor

    /// While the reply plays, the microphone records, so speech over the reply stops it.
    private func startMonitor() {
        guard tuning.autoBargeIn, !muted, !promptHold, clip == nil else { return }
        let url = makeClipURL()
        guard (try? microphone.startClip(url: url)) != nil else { return }
        clip = Clip(url: url, startedAt: clock(), monitor: true)
    }

    private func monitorTick(_ time: TimeInterval) {
        guard var current = clip, current.monitor else { return }
        let decibels = microphone.level()
        current.levels.append(VoiceWaveform.level(decibels: decibels))
        if decibels >= tuning.bargeInDecibels {
            let since = current.voiceSince ?? time
            current.voiceSince = since
            if time - since >= tuning.bargeInSeconds {
                // The owner talks: the kept clip already holds the start of the words.
                current.heardSpeech = true
                current.lastVoiceAt = time
                clip = current
                return bargeIn()
            }
        } else {
            current.voiceSince = nil
        }
        clip = current
    }

    // MARK: Helpers

    /// Stops the reply of the current turn at once. The Hermes turn goes on in the chat.
    private func silenceTurn() {
        stopAck()
        stopPulse()
        guard let current = turn else { return }
        turn = nil
        current.commands?.finish()
        if let speech = current.speech {
            Task { await speech.stop() }
        }
    }

    private func closeMicrophone() {
        guard clip != nil else { return }
        clip = nil
        microphone.discardClip()
    }

    private func setFailure(_ failure: VoiceModeFailure) {
        silenceTurn()
        closeMicrophone()
        level = 0
        state = .error(failure)
        log.notice("voice mode error: \(String(describing: failure))")
    }

    private func activateSession() -> Bool {
        guard !sessionActive else { return true }
        do {
            try microphone.activate()
        } catch {
            return false
        }
        sessionActive = true
        return true
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        sessionActive = false
        microphone.deactivate()
    }
}

extension VoiceModeController: VoicePromptHolding {}
