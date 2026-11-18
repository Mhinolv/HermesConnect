import Foundation
import Observation

/// What the WebRTC link reports. The app uses `stasel/WebRTC`. Tests use a fake.
public enum LiveModeLinkEvent: Sendable, Equatable {
    /// A text message on the `oai-events` data channel.
    case message(String)
    /// The remote audio track plays speech (or stops).
    case speaking(Bool)
    case connected
    /// ICE lost the path. It can come back. "Reconnecting…" shows for 10 s at most.
    case disconnected
    case failed
    /// The `oai-events` data channel closed, and the app did not close it (issue #109).
    case channelClosed
}

/// The WebRTC peer of one live session: a mic track and the `oai-events` data channel. Issue #98.
@MainActor
public protocol LiveModeConnection: AnyObject {
    var onEvent: (@MainActor (LiveModeLinkEvent) -> Void)? { get set }
    /// Opens the mic, adds the data channel, makes the offer and waits for ICE. Returns the local SDP unchanged.
    func makeOffer() async throws -> String
    func applyAnswer(_ sdp: String) async throws
    /// Sends one text message on the data channel. `false` if the channel is not open.
    @discardableResult func send(_ text: String) -> Bool
    func setMuted(_ muted: Bool)
    /// Stops the mic and closes the peer. No media flows after this.
    func close()
}

/// The reply of a delegated Hermes turn, as the chat shows it.
public enum LiveReplyProgress: Sendable, Equatable {
    case waiting
    case streaming(String)
    case done(String)
    case failed
}

/// The chat side of a live session: it sends each delegation as a Hermes turn and reads the reply.
@MainActor
public protocol LiveModeHermes: AnyObject {
    /// `prompt.submit` with surface `voice-live`. Returns the id of the owner bubble.
    func submitDelegation(prompt: String, voiceContext: String) async throws -> String
    func replyProgress(promptId: String) -> LiveReplyProgress
    /// `session.interrupt`: a new delegation replaces the turn that runs.
    func stopReply()
    /// Text turns of the chat, to seed the voice model.
    func liveHistory() -> [VoiceLiveHistoryItem]
}

public enum LiveModeEndReason: Sendable, Equatable {
    case hangUp, background, idle, phoneCall, modeChange
    /// `session.closed` from the server with this reason.
    case server(String)
}

/// One ended session. The chat shows the toast "Live Mode Ended, 4:12".
public struct LiveModeEnd: Sendable, Equatable {
    public var reason: LiveModeEndReason
    public var elapsedSeconds: Int
    /// A new value for each end, so the screen shows each toast once.
    public var serial: Int

    public var toast: String { "Live Mode Ended, \(LiveModeFormat.elapsed(elapsedSeconds))" }
}

public enum LiveModePhase: Sendable, Equatable {
    case idle
    case connecting
    case live
    /// A delegation runs in Hermes.
    case working
    case reconnecting
    /// "Live mode stopped". The session is closed. "Try Again" starts a new one.
    case failed
}

/// What the panel shows (design notes #98).
public enum LiveModeDisplay: Sendable, Equatable {
    case connecting, live, idleWarning, working(still: Bool), muted, reconnecting, failed

    public var label: String {
        switch self {
        case .connecting: "Connecting…"
        case .live: "Live. Speak any time."
        case .idleWarning: "Ending soon. Speak to continue."
        case .working(let still): still ? "Still working…" : "Hermes is working…"
        case .muted: "Muted"
        case .reconnecting: "Reconnecting…"
        case .failed: "Live mode stopped"
        }
    }
}

public enum LiveModeFormat {
    /// About $0.05 a minute of session time (owner decision on #98).
    public static let costCaption = "About $0.05 a minute"

    /// `m:ss`.
    public static func elapsed(_ seconds: Int) -> String {
        let value = max(seconds, 0)
        return "\(value / 60):" + String(format: "%02d", value % 60)
    }
}

/// One GPT-Live session (issue #98). It owns the WebRTC peer, the delegations and the end rules.
///
/// - The offer goes to the server unchanged. The OpenAI key stays on the server.
/// - Each `session.delegation.created` becomes `prompt.submit` (surface `voice-live`). The reply streams back
///   in whole sentences as `session.commentary.append`.
/// - The session ends on "End", background, a phone call, a mode change, and 60 s idle (warning at 45 s).
///   A link that stays down for 10 s ends it too. So no session runs on and bills the owner.
/// - The log gets ids, counts and states. Never transcript text, reply text or audio.
@MainActor @Observable
public final class LiveModeController {
    public private(set) var phase: LiveModePhase = .idle
    public private(set) var muted = false
    public private(set) var speaking = false
    /// Seconds since the link connected. It changes once a second, not on each tick.
    public private(set) var elapsedSeconds = 0
    public private(set) var idleWarning = false
    public private(set) var stillWorking = false
    /// The last session that ended (not a failure). The chat shows its toast.
    public private(set) var lastEnd: LiveModeEnd?
    /// The text for the failed state ("Try Again"). Never vendor text with secrets: the server text is short.
    public private(set) var failure: String?

    public static let idleWarningSeconds: TimeInterval = 45
    public static let idleEndSeconds: TimeInterval = 60
    public static let reconnectSeconds: TimeInterval = 10
    public static let stillWorkingSeconds: TimeInterval = 10
    /// The longest wait for the first connect (offer, answer and ICE).
    public static let connectSeconds: TimeInterval = 30

    @ObservationIgnored private let service: any LiveModeService
    @ObservationIgnored private weak var hermes: (any LiveModeHermes)?
    @ObservationIgnored private let makeConnection: @MainActor () -> any LiveModeConnection
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let autoTick: Bool
    @ObservationIgnored private let closeDelay: Duration
    @ObservationIgnored private var connection: (any LiveModeConnection)?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var endSerial = 0
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var connectedAt: Date?
    @ObservationIgnored private var lastActivity = Date.distantPast
    @ObservationIgnored private var reconnectSince: Date?
    @ObservationIgnored private var transcript: [LiveModeFragment] = []
    @ObservationIgnored private var delegation: Delegation?
    @ObservationIgnored private var eventCounter = 0
    @ObservationIgnored private let log = HermesLog(category: "live-mode")

    private struct Delegation {
        var id: String
        var promptId: String?
        var spokenCount = 0
        var submittedAt: Date
    }

    /// - Parameters:
    ///   - autoTick: `false` in tests. The test calls `tick()`.
    ///   - closeDelay: time for `session.close` to go out before the peer closes.
    public init(service: any LiveModeService, hermes: any LiveModeHermes,
                makeConnection: @escaping @MainActor () -> any LiveModeConnection,
                now: @escaping @MainActor () -> Date = { Date() }, autoTick: Bool = true,
                closeDelay: Duration = .milliseconds(500)) {
        self.service = service
        self.hermes = hermes
        self.makeConnection = makeConnection
        self.now = now
        self.autoTick = autoTick
        self.closeDelay = closeDelay
    }

    /// `true` while the panel shows (also in the failed state).
    public var isActive: Bool { phase != .idle }

    public var display: LiveModeDisplay? {
        switch phase {
        case .idle: nil
        case .connecting: .connecting
        case .reconnecting: .reconnecting
        case .failed: .failed
        case .working: .working(still: stillWorking)
        case .live: muted ? .muted : (idleWarning ? .idleWarning : .live)
        }
    }

    /// VoiceOver: "Live Mode, <state>, <elapsed>".
    public var accessibilityLabel: String {
        "Live Mode, \(display?.label ?? "Off"), \(LiveModeFormat.elapsed(elapsedSeconds))"
    }

    // MARK: Start and end

    /// Starts a session. "Try Again" in the failed state calls it too.
    public func start() {
        guard phase == .idle || phase == .failed else { return }
        if let connection { closeConnection(connection, sendClose: false) }
        epoch += 1
        let epoch = epoch
        phase = .connecting
        muted = false
        speaking = false
        elapsedSeconds = 0
        idleWarning = false
        stillWorking = false
        failure = nil
        connectedAt = nil
        reconnectSince = nil
        transcript = []
        delegation = nil
        lastActivity = now()
        let connection = makeConnection()
        self.connection = connection
        connection.onEvent = { [weak self, weak connection] event in
            guard let self, let connection, connection === self.connection else { return }
            self.handle(event)
        }
        log.info("live session starting")
        let service = service
        let log = log
        let history = hermes?.liveHistory() ?? []
        startTask = Task { [weak self] in
            var step = LiveModeStep.offer
            do {
                let offer = try await connection.makeOffer()
                guard let self, self.epoch == epoch else { connection.close(); return }
                step = .session
                log.info("live offer ready, session request sent")
                let answer = try await service.createVoiceLiveSession(offerSDP: offer, history: history)
                guard self.epoch == epoch else { connection.close(); return }
                log.info("live session request: HTTP 200")
                step = .answer
                try await connection.applyAnswer(answer.sdp)
                guard self.epoch == epoch else { connection.close(); return }
                log.info("live session answer applied")
            } catch {
                // The step and a code only. Never the SDP, a token or the server text.
                log.notice("live start failed at \(step.rawValue): \(Self.errorCode(error))")
                guard let self, self.epoch == epoch else { return }
                self.fail(Self.failureText(error, step: step))
            }
        }
        if autoTick { startTicker() }
    }

    /// Ends the session at once and shows the toast. No media flows after this.
    public func end(_ reason: LiveModeEndReason) {
        guard phase != .idle else { return }
        let seconds = currentElapsed()
        let wasFailed = phase == .failed
        teardown(sendClose: true)
        phase = .idle
        guard !wasFailed else { return }
        endSerial += 1
        lastEnd = LiveModeEnd(reason: reason, elapsedSeconds: seconds, serial: endSerial)
        log.info("live session ended: \(String(describing: reason)), \(seconds) s")
    }

    public func toggleMute() {
        guard phase != .idle, phase != .failed else { return }
        muted.toggle()
        connection?.setMuted(muted)
        send(.mute(muted, eventId: nextEventId(muted ? "mute" : "unmute")))
        lastActivity = now()
    }

    private func fail(_ text: String) {
        guard phase != .idle else { return }
        teardown(sendClose: true)
        failure = text
        phase = .failed
        log.notice("live session failed")
    }

    private func teardown(sendClose: Bool) {
        epoch += 1
        startTask?.cancel()
        startTask = nil
        tickTask?.cancel()
        tickTask = nil
        delegation = nil
        speaking = false
        idleWarning = false
        stillWorking = false
        if let connection { closeConnection(connection, sendClose: sendClose) }
        connection = nil
    }

    private func closeConnection(_ connection: any LiveModeConnection, sendClose: Bool) {
        connection.onEvent = nil
        if sendClose { connection.send(LiveModeClientEvent.close.json) }
        guard sendClose, closeDelay > .zero else { connection.close(); return }
        let delay = closeDelay
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            connection.close()
        }
    }

    /// The error line names the step that failed (issue #109).
    static func failureText(_ error: any Error, step: LiveModeStep) -> String {
        switch error {
        case VoiceLiveSessionError.unavailable(let detail), VoiceLiveSessionError.vendor(let detail),
             VoiceLiveSessionError.badOffer(let detail):
            return detail.flatMap { $0.isEmpty ? nil : $0 } ?? "The server could not start Live mode."
        case LiveModeError.microphoneDenied:
            return "Microphone Access Off"
        case LiveModeError.step(let failed, _):
            return stepText(failed)
        case HermesAPIError.http(let status) where step == .session:
            return "The server refused Live mode (HTTP \(status))."
        default:
            return stepText(step)
        }
    }

    private static func stepText(_ step: LiveModeStep) -> String {
        switch step {
        case .audioSession: "Could not start the microphone (audio session)."
        case .offer: "Could not start Live mode (WebRTC offer)."
        case .session: "Could not reach Hermes (session request)."
        case .answer: "Could not use the answer from OpenAI (SDP answer)."
        }
    }

    /// A code for the log: the HTTP status, else the error domain and code. Never error text.
    static func errorCode(_ error: any Error) -> String {
        switch error {
        case VoiceLiveSessionError.badOffer: return "HTTP 400"
        case VoiceLiveSessionError.vendor: return "HTTP 502"
        case VoiceLiveSessionError.unavailable: return "HTTP 503"
        case HermesAPIError.unauthorized: return "HTTP 401"
        case HermesAPIError.notFound: return "HTTP 404"
        case HermesAPIError.http(let status): return "HTTP \(status)"
        case LiveModeError.step(let step, let code): return "\(step.rawValue) \(code.map(String.init) ?? "none")"
        default:
            let error = error as NSError
            return "\(error.domain) \(error.code)"
        }
    }

    // MARK: Link events

    func handle(_ event: LiveModeLinkEvent) {
        switch event {
        case .connected:
            guard phase == .connecting || phase == .reconnecting else { return }
            if connectedAt == nil { connectedAt = now() }
            reconnectSince = nil
            phase = delegation == nil ? .live : .working
            lastActivity = now()
            log.info("live link connected")
        case .disconnected:
            guard phase == .live || phase == .working else { return }
            reconnectSince = now()
            phase = .reconnecting
            log.notice("live link lost, waiting")
        case .failed:
            // Before the first connect, ICE did not find a path to OpenAI.
            log.notice("live link failed, \(connectedAt == nil ? "before" : "after") connect")
            fail(connectedAt == nil ? "Could not reach OpenAI (ICE failed)." : "The connection to Live mode was lost.")
        case .channelClosed:
            log.notice("live data channel closed by the remote side")
            fail("The connection to Live mode was lost (data channel closed).")
        case .speaking(let value):
            speaking = value
            lastActivity = now()
            if value { idleWarning = false }
        case .message(let text):
            guard let event = LiveModeServerEvent.parse(text) else { return }
            handle(event)
        }
    }

    private func handle(_ event: LiveModeServerEvent) {
        switch event {
        case .started:
            log.info("live session started")
        case .transcript(let fragment):
            transcript.append(fragment)
            if transcript.count > 2_000 { transcript.removeFirst(transcript.count - 1_500) }
            lastActivity = now()
            idleWarning = false
        case .delegation(let id):
            delegate(id)
        case .error(let code, _):
            // Late appends after a close are expected.
            guard code != "context_injection_incomplete" else { return }
            log.notice("live vendor error: \(code ?? "none")")
        case .closed(let reason, _):
            if reason == "close_requested" { end(.hangUp) } else { end(.server(reason)) }
        case .other:
            break
        }
    }

    // MARK: Delegations

    private func delegate(_ id: String) {
        guard phase == .live || phase == .working, let hermes else { return }
        let (prompt, context) = LiveModeText.delegationPrompt(contextWindow())
        // A new request replaces the turn that runs, so the voice answers what the owner asked last.
        if delegation != nil { hermes.stopReply() }
        delegation = Delegation(id: id, submittedAt: now())
        stillWorking = false
        idleWarning = false
        phase = .working
        lastActivity = now()
        log.info("delegation \(id): \(prompt.count) characters")
        guard !prompt.isEmpty else {
            send(.thinking(delegationId: id, content: "Hermes did not get a request.", eventId: nextEventId("think")))
            finishDelegation()
            return
        }
        let epoch = epoch
        Task { [weak self] in
            do {
                let promptId = try await hermes.submitDelegation(prompt: prompt, voiceContext: context)
                guard let self, self.epoch == epoch, self.delegation?.id == id else { return }
                self.delegation?.promptId = promptId
            } catch {
                guard let self, self.epoch == epoch, self.delegation?.id == id else { return }
                self.log.notice("delegation \(id) not delivered")
                self.speak(id, "Sorry, I could not reach Hermes for that request.")
                self.finishDelegation()
            }
        }
    }

    private func finishDelegation() {
        delegation = nil
        stillWorking = false
        if phase == .working { phase = .live }
        lastActivity = now()
    }

    /// Sends the new whole sentences of the reply. The tail goes when the reply ends.
    private func pumpDelegation(at time: Date) {
        guard var current = delegation else { return }
        let still = time.timeIntervalSince(current.submittedAt) >= Self.stillWorkingSeconds
        if still != stillWorking { stillWorking = still }
        guard let promptId = current.promptId, let hermes else { return }
        switch hermes.replyProgress(promptId: promptId) {
        case .waiting:
            return
        case .streaming(let text):
            guard let end = LiveModeText.lastSentenceEnd(in: text) else { return }
            let count = text.distance(from: text.startIndex, to: end)
            guard count > current.spokenCount else { return }
            speak(current.id, String(text.dropFirst(current.spokenCount).prefix(count - current.spokenCount)))
            current.spokenCount = count
            delegation = current
        case .done(let text):
            let rest = String(text.dropFirst(current.spokenCount))
            let spoken = VoiceReplyText.spokenText(rest)
            if !spoken.isEmpty {
                speak(current.id, rest)
            } else if current.spokenCount == 0 {
                send(.thinking(delegationId: current.id, content: "Hermes finished that request without a spoken result.",
                               eventId: nextEventId("think")))
            }
            log.info("delegation \(current.id) answered: \(text.count) characters")
            finishDelegation()
        case .failed:
            speak(current.id, "Sorry, Hermes could not answer that request.")
            finishDelegation()
        }
    }

    /// `session.commentary.append` in chunks of 1,400 characters or fewer.
    private func speak(_ delegationId: String, _ text: String) {
        for chunk in LiveModeText.chunks(VoiceReplyText.spokenText(text)) {
            send(.commentary(delegationId: delegationId, content: chunk, eventId: nextEventId("say")))
        }
    }

    private func send(_ event: LiveModeClientEvent) {
        connection?.send(event.json)
    }

    private func nextEventId(_ prefix: String) -> String {
        eventCounter += 1
        return "\(prefix)_\(eventCounter)"
    }

    /// The recent transcript, oldest first: 5 minutes and 80 fragments at most.
    func contextWindow() -> [LiveModeFragment] {
        guard let last = transcript.last else { return [] }
        let floor = last.endMs - LiveModeProtocol.contextWindowMs
        return Array(transcript.filter { $0.endMs >= floor }.suffix(LiveModeProtocol.contextMaxFragments))
    }

    // MARK: Clock

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func currentElapsed() -> Int {
        guard let connectedAt else { return elapsedSeconds }
        return max(Int(now().timeIntervalSince(connectedAt)), 0)
    }

    /// Runs every 200 ms: the elapsed time, the reply stream, the idle and reconnect limits.
    public func tick() {
        let time = now()
        let seconds = currentElapsed()
        if seconds != elapsedSeconds { elapsedSeconds = seconds }
        switch phase {
        case .reconnecting:
            if let since = reconnectSince, time.timeIntervalSince(since) >= Self.reconnectSeconds {
                log.notice("live link did not come back in \(Int(Self.reconnectSeconds)) s")
                fail("The connection to Live mode was lost.")
            }
        case .live, .working:
            pumpDelegation(at: time)
            // Idle: no speech and no Hermes work.
            if delegation != nil || speaking {
                lastActivity = time
                if idleWarning { idleWarning = false }
                return
            }
            let quiet = time.timeIntervalSince(lastActivity)
            if quiet >= Self.idleEndSeconds {
                end(.idle)
                return
            }
            let warn = quiet >= Self.idleWarningSeconds
            if warn != idleWarning { idleWarning = warn }
        case .connecting:
            if time.timeIntervalSince(lastActivity) >= Self.connectSeconds {
                log.notice("live connect timed out")
                fail("Could not reach OpenAI (timed out).")
            }
        case .idle, .failed:
            break
        }
    }
}
