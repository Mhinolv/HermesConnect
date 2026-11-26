import Foundation
import Observation

/// The chat link to Hermes, as the chat screen shows it.
public enum ChatLinkStatus: Sendable, Equatable {
    /// No Hermes endpoint. The #4 bootstrap has not reported "Hermes ready".
    case notConnected
    case connecting
    case ready
    /// Hermes refused the token. The #4 bootstrap starts a new session ("Reconnecting").
    case reconnecting
    /// The new session was refused too. Sends fail until the owner retries.
    case failed
}

/// The release chat transport (issue #6, fix round 2). It follows the #4 endpoint:
/// a new endpoint gets a new `GatewayClient` (#5), and `nil` closes it.
///
/// - `events` forwards the events of the current client only. Each read of it is a new stream (issue #7).
/// - A stale token (close code 4401 or 4403, HTTP 401 or 403) asks `onStaleToken` for a new session once.
///   A second refusal before a good connect is `.failed`.
/// - A send on a dropped socket reconnects once when the reason allows it.
@MainActor @Observable
public final class LiveChatTransport: ChatTransport, SessionsTransport, ReceivedFileDownloading, VoiceStreamTransport,
    ServerRequestTransport {
    public private(set) var status: ChatLinkStatus = .notConnected

    /// Each read gives a new stream, so the session list and each chat read every event (issue #7).
    public nonisolated var events: AsyncStream<GatewayClientEvent> { broadcast.subscribe() }
    @ObservationIgnored private nonisolated let broadcast = GatewayEventBroadcast()
    @ObservationIgnored private let makeClient: @Sendable (GatewayEndpoint) -> GatewayClient
    @ObservationIgnored private let makeREST: @Sendable (GatewayEndpoint) -> HermesRESTClient
    @ObservationIgnored private var endpoint: GatewayEndpoint?
    @ObservationIgnored private var client: GatewayClient?
    @ObservationIgnored private var forwardTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// `true` after a renewal, until a connect succeeds.
    @ObservationIgnored private var renewed = false
    /// The app asks the #4 bootstrap for a new Hermes session (`AppModel.renewHermesSession`).
    @ObservationIgnored public var onStaleToken: (@MainActor () async -> Void)?
    /// Issue #178: the socket of a ready link closed for a reason that is not a stale token.
    /// The app gives it to the `LinkSupervisor`, which reconnects.
    @ObservationIgnored public var onDrop: (@MainActor () -> Void)?
    /// Issue #179: the socket is ready. The `LinkSupervisor` resets its retry wait when the link stays ready.
    @ObservationIgnored public var onReady: (@MainActor () -> Void)?
    /// Issue #179: the socket did not open, for a reason that is not a stale token. The SSH link can be up.
    /// The `LinkSupervisor` counts it as a failed connect try and retries after its wait.
    @ObservationIgnored public var onConnectFailed: (@MainActor () -> Void)?

    /// Issue #97: opens the `speak-stream` sockets on the same forward.
    @ObservationIgnored private let audioConnector: any GatewayWebSocketConnecting

    public init(makeClient: @escaping @Sendable (GatewayEndpoint) -> GatewayClient = { GatewayClient(endpoint: $0) },
                makeREST: @escaping @Sendable (GatewayEndpoint) -> HermesRESTClient = { HermesRESTClient(endpoint: $0) },
                audioConnector: any GatewayWebSocketConnecting = URLSessionGatewayConnector()) {
        self.makeClient = makeClient
        self.makeREST = makeREST
        self.audioConnector = audioConnector
    }

    /// `true` for errors that mean "the token is not valid any more".
    public nonisolated static func isStaleToken(_ error: any Error) -> Bool {
        switch error {
        case GatewayError.disconnected(let reason): return isStaleToken(reason)
        case HermesAPIError.unauthorized, HermesAPIError.http(status: 401), HermesAPIError.http(status: 403): return true
        default: return false
        }
    }

    public nonisolated static func isStaleToken(_ reason: GatewayDisconnectReason) -> Bool {
        reason == .unauthorized || reason == .forbidden
    }

    /// The app calls this when the #4 endpoint changes. The same endpoint again does nothing.
    public func setEndpoint(_ newEndpoint: GatewayEndpoint?) {
        guard newEndpoint != endpoint else { return }
        detach()
        endpoint = newEndpoint
        guard let newEndpoint else {
            // A renewal closes the old endpoint first. Keep "Reconnecting" until the new one comes.
            if status != .reconnecting, status != .failed { status = .notConnected }
            return
        }
        let client = makeClient(newEndpoint)
        self.client = client
        forwardTask = Task { [weak self] in
            for await item in client.events {
                self?.forward(item, from: client)
            }
        }
        startConnect(client)
    }

    /// "Not connected" tapped after `.failed`: ask for a new session again.
    public func retry() {
        guard status == .failed else { return }
        renewed = false
        staleToken()
    }

    private func detach() {
        forwardTask?.cancel()
        forwardTask = nil
        connectTask?.cancel()
        connectTask = nil
        if let old = client {
            client = nil
            Task { await old.disconnect() }
        }
    }

    private func startConnect(_ client: GatewayClient) {
        if status != .reconnecting { status = .connecting }
        connectTask = Task { [weak self] in
            do {
                try await client.connect()
                self?.connected(client)
            } catch {
                // A stale token shows up as a `.state(.disconnected)` event too. `forward` handles it.
                self?.connectFailed(client, error)
            }
        }
    }

    private func connected(_ client: GatewayClient) {
        guard client === self.client else { return }
        renewed = false
        status = .ready
        onReady?()
    }

    private func connectFailed(_ client: GatewayClient, _ error: any Error) {
        guard client === self.client, !Self.isStaleToken(error), status != .reconnecting, status != .failed else {
            return
        }
        status = .notConnected
        onConnectFailed?()
    }

    private func forward(_ item: GatewayClientEvent, from client: GatewayClient) {
        guard client === self.client else { return }
        broadcast.yield(item)
        guard case .state(.disconnected(let reason)) = item else { return }
        if Self.isStaleToken(reason) {
            staleToken()
        } else if status == .ready {
            status = .notConnected
            // Issue #178: a ready link died while the app is open. Before, nothing reconnected.
            onDrop?()
        }
    }

    private func staleToken() {
        guard !renewed else {
            status = .failed
            return
        }
        renewed = true
        status = .reconnecting
        let renew = onStaleToken
        Task { await renew?() }
    }

    // MARK: Link probe (issue #176)

    /// Issue #176: after a time in the background, test the link with one heartbeat call.
    /// Returns `true` only when the server answers in `timeout`. A dead SSH session can hang
    /// the call, so the time limit does not wait for the call to end.
    public func probe(timeout: Duration = .seconds(3)) async -> Bool {
        guard status == .ready, client != nil else { return false }
        let gate = ProbeGate()
        return await withCheckedContinuation { continuation in
            gate.start(continuation)
            Task { [weak self] in
                guard let self else { return gate.finish(false) }
                let answered: Bool
                do {
                    answered = try await self.readyClient().ping()
                } catch {
                    answered = false
                }
                gate.finish(answered)
            }
            Task {
                try? await Task.sleep(for: timeout)
                gate.finish(false)
            }
        }
    }

    // MARK: ChatTransport

    /// The current client, connected. A dropped socket reconnects once if the reason allows it.
    func readyClient() async throws -> GatewayClient {
        guard let client else { throw GatewayError.notConnected }
        if let connectTask { await connectTask.value }
        guard client === self.client else { throw GatewayError.notConnected }
        switch await client.state {
        case .connected:
            return client
        case .disconnected(let reason) where reason.shouldReconnect:
            do {
                try await client.connect()
                connected(client)
                return client
            } catch {
                throw GatewayError.notConnected
            }
        default:
            throw GatewayError.notConnected
        }
    }

    public func startSession(source: String, idempotencyKey: String) async throws -> ChatSessionRef {
        try await readyClient().startSession(source: source, idempotencyKey: idempotencyKey)
    }

    public func resumeSession(storedId: String, source: String) async throws -> ChatSessionRef {
        try await readyClient().resumeSession(storedId: storedId, source: source)
    }

    public func submitPrompt(sessionId: String, text: String, retryBeforeRowId: Int?) async throws -> Int? {
        try await readyClient().submitPrompt(sessionId: sessionId, text: text, retryBeforeRowId: retryBeforeRowId)
    }

    public func stopReply(sessionId: String) async throws -> Bool {
        try await readyClient().stopReply(sessionId: sessionId)
    }

    public func submitVoicePrompt(sessionId: String, text: String, retryBeforeRowId: Int?) async throws -> Int? {
        try await readyClient().submitVoicePrompt(sessionId: sessionId, text: text, retryBeforeRowId: retryBeforeRowId)
    }

    /// REST on the forwarded port. It needs the #4 endpoint, not the socket.
    /// A refused token asks for a new session once, as a socket refusal does.
    public func transcribe(audio: Data, mimeType: String) async throws -> String {
        guard let endpoint else { throw GatewayError.notConnected }
        do {
            return try await makeREST(endpoint).transcribe(audio: audio, mimeType: mimeType)
        } catch {
            if Self.isStaleToken(error), endpoint == self.endpoint, status == .ready { staleToken() }
            throw error
        }
    }

    /// Issue #10: REST on the forwarded port, as `transcribe`.
    public func speak(text: String) async throws -> SpokenAudio {
        guard let endpoint else { throw GatewayError.notConnected }
        do {
            return try await makeREST(endpoint).speak(text: text)
        } catch {
            if Self.isStaleToken(error), endpoint == self.endpoint, status == .ready { staleToken() }
            throw error
        }
    }

    /// Issue #64: one REST call on the forwarded port, as `transcribe`. A refused token asks for a new session once.
    func withREST<Output>(_ body: (HermesRESTClient) async throws -> Output) async throws -> Output {
        guard let endpoint else { throw GatewayError.notConnected }
        do {
            return try await body(makeREST(endpoint))
        } catch {
            if Self.isStaleToken(error), endpoint == self.endpoint, status == .ready { staleToken() }
            throw error
        }
    }

    public func history(sessionId: String) async throws -> [TranscriptMessage] {
        try await readyClient().history(sessionId: sessionId)
    }

    /// Issue #145: the replay after a reconnect, on the current socket.
    public func eventsSince(sessionId: String, lastSeen: Int) async throws -> SessionEventsSinceResult {
        try await readyClient().eventsSince(sessionId: sessionId, lastSeen: lastSeen)
    }

    /// Issue #12: `GET /api/fs/download` on the forwarded port, as `transcribe`. No new network path.
    public func downloadReceivedFile(path: String, storedSessionId: String?, maxBytes: Int?,
                                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let endpoint else { throw ReceivedFileError.offline }
        do {
            return try await makeREST(endpoint).downloadFile(path: path, storedSessionId: storedSessionId,
                                                             maxBytes: maxBytes, progress: progress)
        } catch {
            if Self.isStaleToken(error), endpoint == self.endpoint, status == .ready { staleToken() }
            throw error
        }
    }

    // MARK: VoiceStreamTransport (issue #97)

    public func voiceConfig() async throws -> VoiceClientConfig {
        try await withREST { try await $0.voiceConfig() }
    }

    public func voiceLiveStatus() async throws -> VoiceLiveStatus? {
        try await withREST { try await $0.voiceLiveStatus() }
    }

    public func createVoiceLiveSession(offerSDP: String, history: [VoiceLiveHistoryItem]) async throws
        -> VoiceLiveSessionAnswer {
        try await withREST { try await $0.createVoiceLiveSession(offerSDP: offerSDP, history: history) }
    }

    /// A speaker for one reply on the current endpoint: `speak-stream`, then `POST /api/audio/speak` as the
    /// fallback. A refused token asks for a new session once, as a socket refusal does.
    public func makeStreamedSpeech(player: any StreamedSpeechPlaying) throws -> StreamedSpeech {
        guard let endpoint else { throw SpeechStreamError.offline }
        let connector = audioConnector
        let rest = makeREST(endpoint)
        return StreamedSpeech(
            open: { try await SpeakStreamConnection.open(endpoint: endpoint, connector: connector) },
            fallback: { try await rest.speak(text: $0) },
            player: player,
            onUnauthorized: { [weak self] in await self?.speechRefused(endpoint) })
    }

    private func speechRefused(_ refused: GatewayEndpoint) {
        if refused == endpoint, status == .ready { staleToken() }
    }

    // MARK: ServerRequestTransport (issue #104)

    /// The answer goes on the current socket. The server takes it on any socket: approvals are not pinned
    /// (`server_requests.py:302-346`).
    public func answerApproval(requestId: JSONRPCID, choice: ApprovalChoice) async throws {
        try await readyClient().answerApproval(requestId: requestId, choice: choice)
    }

    public func rejectServerRequest(_ id: JSONRPCID, code: Int, message: String) async throws {
        try await readyClient().rejectServerRequest(id, code: code, message: message)
    }

    public func respondApproval(sessionId: String, choice: ApprovalChoice, requestId: String?) async throws -> Int {
        try await readyClient().respondApproval(sessionId: sessionId, choice: choice, requestId: requestId)
    }

    public func acknowledgeApproval(sessionId: String, requestId: String) async throws {
        try await readyClient().acknowledgeApproval(sessionId: sessionId, requestId: requestId)
    }

    public func pendingApprovals(sessionId: String) async throws -> [ApprovalRequest] {
        try await readyClient().pendingApprovals(sessionId: sessionId)
    }

    /// Issue #117: the value goes on the current socket and is not kept. It never goes to a log.
    public func answerValue(requestId: JSONRPCID, value: String) async throws {
        try await readyClient().answerValue(requestId: requestId, value: value)
    }

    public func answerClarify(requestId: JSONRPCID, answers: [String: String?]?, outcome: String) async throws {
        try await readyClient().answerClarify(requestId: requestId, answers: answers, outcome: outcome)
    }

    // MARK: SessionsTransport

    public func fetchSessions() async throws -> [SessionListItem] {
        try await readyClient().fetchSessions()
    }

    public func fetchMostRecentSessionId() async throws -> String? {
        try await readyClient().fetchMostRecentSessionId()
    }

    // MARK: CronTransport (issue #73)

    public func fetchCronJobs() async throws -> [CronJob] {
        try await cronREST { try await $0.cronJobs() }
    }

    public func fetchCronRuns(jobId: String, limit: Int) async throws -> [CronRun] {
        try await cronREST { try await $0.cronRuns(jobId: jobId, limit: limit) }
    }

    public func fetchRunTranscript(sessionId: String) async throws -> [TranscriptMessage] {
        try await cronREST {
            try await $0.messages(storedSessionId: sessionId, limit: CronAPI.transcriptLimit, order: "oldest").messages
        }
    }

    /// REST on the forwarded port, as `transcribe`. A refused token asks for a new session once.
    private func cronREST<Output>(_ body: (HermesRESTClient) async throws -> Output) async throws -> Output {
        guard let endpoint else { throw GatewayError.notConnected }
        do {
            return try await body(makeREST(endpoint))
        } catch {
            if Self.isStaleToken(error), endpoint == self.endpoint, status == .ready { staleToken() }
            throw error
        }
    }
}

/// Issue #176: resumes the probe once, with the first result (the answer or the time limit).
private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func start(_ continuation: CheckedContinuation<Bool, Never>) {
        let early: Bool? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func finish(_ value: Bool) {
        let waiting: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
