import Foundation
import Testing
@testable import HermesKit

private let testToken = String(repeating: "0f", count: 32)

/// A connected client on a fake socket. No network.
private struct Harness {
    let client: GatewayClient
    let socket: FakeGatewaySocket
    let connector: FakeGatewayConnector
    let reader: EventReader
    let clock: ManualClock
    let ready: GatewayReady

    static func connect(heartbeat: Bool? = true,
                        configuration: GatewayClient.Configuration = .init(heartbeatInterval: nil)) async throws -> Harness {
        let socket = FakeGatewaySocket()
        let connector = FakeGatewayConnector(socket)
        let clock = ManualClock()
        let client = GatewayClient(endpoint: try GatewayEndpoint(port: 8123, token: testToken), connector: connector,
                                   configuration: configuration, now: { clock.now })
        let reader = EventReader(client)
        async let ready = client.connect()
        socket.pushReady(heartbeat: heartbeat)
        let capabilities = try await socket.waitForRequest("client.capabilities")
        socket.reply(to: capabilities, result: #"{"server_requests":["approval","clarify"],"declines_not_shown":true}"#)
        return Harness(client: client, socket: socket, connector: connector, reader: reader, clock: clock,
                       ready: try await ready)
    }
}

@Suite(.timeLimit(.minutes(1))) struct GatewayClientTests {
    // MARK: Handshake

    @Test func connectUsesTokenAndHandshakes() async throws {
        let harness = try await Harness.connect()
        let url = try #require(harness.connector.urls.first)
        #expect(url.absoluteString == "ws://127.0.0.1:8123/api/ws?token=\(testToken)")
        #expect(harness.ready.replayEpoch == "0123456789abcdef0123456789abcdef")
        #expect(harness.ready.heartbeat == true)
        #expect(harness.ready.skinName == "default")

        let capabilities = try await harness.socket.waitForRequest("client.capabilities")
        #expect(capabilities["jsonrpc"] == "2.0")
        #expect(capabilities["params"] == ["server_requests": true])

        #expect(try await harness.reader.nextState() == .connecting)
        #expect(try await harness.reader.nextState() == .connected(harness.ready))
        #expect(await harness.client.state == .connected(harness.ready))
    }

    @Test func oldServerWithoutCapabilitiesStillConnects() async throws {
        let socket = FakeGatewaySocket()
        let client = GatewayClient(endpoint: try GatewayEndpoint(port: 8123, token: testToken),
                                   connector: FakeGatewayConnector(socket), configuration: .init(heartbeatInterval: nil))
        async let ready = client.connect()
        socket.pushReady(heartbeat: nil)
        socket.replyError(to: try await socket.waitForRequest("client.capabilities"), code: -32601, message: "unknown method")
        _ = try await ready
        #expect(await client.heartbeatMethod == .legacyPing)
    }

    @Test func readyTimeoutDropsTheSocket() async throws {
        let socket = FakeGatewaySocket()
        let client = GatewayClient(endpoint: try GatewayEndpoint(port: 8123, token: testToken),
                                   connector: FakeGatewayConnector(socket),
                                   configuration: .init(heartbeatInterval: nil, readyTimeout: .milliseconds(50)))
        await #expect(throws: GatewayError.disconnected(.readyTimeout)) { try await client.connect() }
        #expect(await client.state == .disconnected(.readyTimeout))
        #expect(socket.closedCode == 1001)
    }

    @Test(arguments: [
        (GatewayWebSocketClosed(closeCode: 4401), GatewayDisconnectReason.unauthorized),
        (GatewayWebSocketClosed(httpStatus: 401), .unauthorized),
        (GatewayWebSocketClosed(closeCode: 4403), .forbidden),
        (GatewayWebSocketClosed(httpStatus: 403), .forbidden),
        (GatewayWebSocketClosed(closeCode: 1011), .closed(code: 1011)),
    ])
    func closeBeforeReadyMapsTheReason(closed: GatewayWebSocketClosed, reason: GatewayDisconnectReason) async throws {
        let socket = FakeGatewaySocket()
        let client = GatewayClient(endpoint: try GatewayEndpoint(port: 8123, token: testToken),
                                   connector: FakeGatewayConnector(socket), configuration: .init(heartbeatInterval: nil))
        socket.serverClose(closeCode: closed.closeCode, httpStatus: closed.httpStatus)
        await #expect(throws: GatewayError.disconnected(reason)) { try await client.connect() }
        #expect(await client.state == .disconnected(reason))
        #expect(reason.needsNewToken == (reason == .unauthorized || reason == .forbidden))
        #expect(!reason.shouldReconnect == (reason == .unauthorized || reason == .forbidden))
    }

    @Test func connectorFailureIsATransportDrop() async throws {
        let client = GatewayClient(endpoint: try GatewayEndpoint(port: 8123, token: testToken),
                                   connector: FakeGatewayConnector(error: GatewayWebSocketClosed(urlErrorCode: -1004)),
                                   configuration: .init(heartbeatInterval: nil))
        await #expect(throws: GatewayError.disconnected(.transportFailed(code: -1004))) { try await client.connect() }
        #expect(await client.state == .disconnected(.transportFailed(code: -1004)))
    }

    @Test func closeAfterConnectIsAnEventAndFailsPendingCalls() async throws {
        let harness = try await Harness.connect()
        let created = Task { try await harness.client.createSession() }
        _ = try await harness.socket.waitForRequest("session.create")
        harness.socket.serverClose(closeCode: 4401)
        await #expect(throws: GatewayError.disconnected(.unauthorized)) { try await created.value }
        #expect(try await harness.reader.nextState() == .connecting)
        #expect(try await harness.reader.nextState() == .connected(harness.ready))
        #expect(try await harness.reader.nextState() == .disconnected(.unauthorized))
    }

    @Test func reconnectWorksAfterADrop() async throws {
        let first = FakeGatewaySocket()
        let second = FakeGatewaySocket()
        let client = GatewayClient(endpoint: try GatewayEndpoint(port: 8123, token: testToken),
                                   connector: FakeGatewayConnector(first, second),
                                   configuration: .init(heartbeatInterval: nil))
        let reader = EventReader(client)
        async let one = client.connect()
        first.pushReady()
        first.reply(to: try await first.waitForRequest("client.capabilities"), result: "{}")
        _ = try await one
        first.serverClose(closeCode: 1006)
        while try await reader.nextState() != .disconnected(.closed(code: 1006)) {}

        async let two = client.connect()
        second.pushReady(epoch: "ffffffffffffffffffffffffffffffff")
        second.reply(to: try await second.waitForRequest("client.capabilities"), result: "{}")
        #expect(try await two.replayEpoch == "ffffffffffffffffffffffffffffffff")
        second.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"sessions.changed","payload":{}}}"#)
        #expect(try await reader.nextEvent() == .event(GatewayEvent(type: "sessions.changed", kind: .sessionsChanged)))
    }

    @Test func connectTwiceIsAnError() async throws {
        let harness = try await Harness.connect()
        await #expect(throws: GatewayError.alreadyConnected) { try await harness.client.connect() }
    }

    @Test func disconnectClosesTheSocket() async throws {
        let harness = try await Harness.connect()
        await harness.client.disconnect()
        #expect(harness.socket.closedCode == 1000)
        #expect(await harness.client.state == .disconnected(.clientClosed))
        await #expect(throws: GatewayError.notConnected) { try await harness.client.ping() }
    }

    // MARK: Heartbeat

    @Test func gatewayPingWhenReadyAdvertisesHeartbeat() async throws {
        let harness = try await Harness.connect(heartbeat: true)
        #expect(await harness.client.heartbeatMethod == .gatewayPing)
        async let alive = harness.client.ping()
        let ping = try await harness.socket.waitForRequest("gateway.ping")
        #expect(ping["params"] == [:])
        harness.socket.reply(to: ping, result: #"{"ok":true}"#)
        #expect(try await alive)
    }

    @Test func legacyPingWhenReadyHasNoHeartbeat() async throws {
        let harness = try await Harness.connect(heartbeat: nil)
        #expect(await harness.client.heartbeatMethod == .legacyPing)
        async let alive = harness.client.ping()
        harness.socket.reply(to: try await harness.socket.waitForRequest("ping"), result: #"{"pong":true}"#)
        #expect(try await alive)
        await harness.client.heartbeatTick()
        try await harness.socket.waitForRequest("ping", count: 2)
    }

    @Test func eitherPingMethodCanBeForced() async throws {
        let harness = try await Harness.connect(heartbeat: true)
        async let legacy = harness.client.ping(using: .legacyPing)
        harness.socket.reply(to: try await harness.socket.waitForRequest("ping"), result: #"{"pong":true}"#)
        #expect(try await legacy)
    }

    @Test func threeMissedPingsDropTheConnection() async throws {
        let harness = try await Harness.connect()
        for _ in 0..<3 { await harness.client.heartbeatTick() }
        try await harness.socket.waitForRequest("gateway.ping", count: 3)
        #expect(await harness.client.state == .connected(harness.ready))
        await harness.client.heartbeatTick()
        #expect(await harness.client.state == .disconnected(.heartbeatTimeout))
        #expect(harness.socket.closedCode == 1001)
        #expect(GatewayDisconnectReason.heartbeatTimeout.shouldReconnect)
    }

    @Test func pongResetsTheMissedCount() async throws {
        let harness = try await Harness.connect()
        await harness.client.heartbeatTick()
        await harness.client.heartbeatTick()
        let ping = try await harness.socket.waitForRequest("gateway.ping", count: 2)
        harness.socket.reply(to: ping, result: #"{"ok":true}"#)
        try await waitUntil { await harness.client.unansweredPingCount == 0 }
        for _ in 0..<3 { await harness.client.heartbeatTick() }
        #expect(await harness.client.state == .connected(harness.ready))
    }

    @Test func fortyFiveSecondsOfSilenceDropTheConnection() async throws {
        let harness = try await Harness.connect()
        harness.clock.advance(by: .seconds(44))
        await harness.client.heartbeatTick()
        #expect(await harness.client.state == .connected(harness.ready))
        harness.clock.advance(by: .seconds(1))
        await harness.client.heartbeatTick()
        #expect(await harness.client.state == .disconnected(.heartbeatTimeout))
    }

    @Test func inboundFramesKeepTheConnectionAlive() async throws {
        let harness = try await Harness.connect()
        harness.clock.advance(by: .seconds(40))
        harness.socket.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"cron.changed","payload":{}}}"#)
        _ = try await harness.reader.nextEvent()
        harness.clock.advance(by: .seconds(40))
        await harness.client.heartbeatTick()
        #expect(await harness.client.state == .connected(harness.ready))
    }

    @Test func heartbeatTimerSendsPings() async throws {
        let harness = try await Harness.connect(configuration: .init(heartbeatInterval: .milliseconds(10)))
        try await harness.socket.waitForRequest("gateway.ping", count: 2)
        await harness.client.disconnect()
    }

    // MARK: Events

    @Test func streamsTypedEventsInOrder() async throws {
        let harness = try await Harness.connect()
        for frame in GatewayFixtures.turn { harness.socket.push(frame) }

        guard case .event(let start) = try await harness.reader.nextEvent(), case .messageStart(let startPayload) = start.kind
        else { Issue.record("expected message.start"); return }
        #expect(start.sessionId == "s1")
        #expect(start.seq == 10)
        #expect(startPayload.turnId == "t1")

        guard case .event(let reasoning) = try await harness.reader.nextEvent(),
              case .reasoningDelta(let reasoningPayload) = reasoning.kind
        else { Issue.record("expected reasoning.delta"); return }
        #expect(reasoningPayload.text == "User greets.")

        var text = ""
        for expectedSeq in [12, 13] {
            guard case .event(let delta) = try await harness.reader.nextEvent(), case .messageDelta(let payload) = delta.kind
            else { Issue.record("expected message.delta"); return }
            #expect(delta.seq == expectedSeq)
            text += payload.text ?? ""
        }
        #expect(text == "Hello! How can I help?")

        guard case .event(let complete) = try await harness.reader.nextEvent(),
              case .messageComplete(let payload) = complete.kind
        else { Issue.record("expected message.complete"); return }
        #expect(payload.text == "Hello! How can I help?")
        #expect(payload.status == .complete)
        #expect(payload.usage?.total == 129)
    }

    @Test func nonJSONFramesAreIgnored() async throws {
        let harness = try await Harness.connect()
        harness.socket.push("not json")
        harness.socket.push(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}"#)
        harness.socket.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"error","payload":{"message":"boom"}}}"#)
        #expect(try await harness.reader.nextEvent()
            == .event(GatewayEvent(type: "error", kind: .error(GatewayErrorPayload(message: "boom")))))
    }

    // MARK: Requests

    @Test func createSessionSendsParamsAndDecodesResult() async throws {
        let harness = try await Harness.connect()
        async let created = harness.client.createSession(SessionCreateParams(source: "ios", idempotencyKey: "k1"))
        let request = try await harness.socket.waitForRequest("session.create")
        #expect(request["params"] == ["source": "ios", "idempotency_key": "k1"])
        harness.socket.reply(to: request, result: """
        {"session_id":"a1b2c3d4","stored_session_id":"20261116_120000_ab12","message_count":0,"messages":[],\
        "info":{"model":"gpt-x","cwd":"/home/hermes"}}
        """)
        let result = try await created
        #expect(result.sessionId == "a1b2c3d4")
        #expect(result.storedSessionId == "20261116_120000_ab12")
        #expect(result.info?["model"] == "gpt-x")
    }

    @Test func rpcErrorIsThrown() async throws {
        let harness = try await Harness.connect()
        let submitted = Task { try await harness.client.submitPrompt(PromptSubmitParams(sessionId: "gone", text: "Hi")) }
        let request = try await harness.socket.waitForRequest("prompt.submit")
        #expect(request["params"] == ["session_id": "gone", "text": "Hi"])
        harness.socket.replyError(to: request, code: 4001, message: "session not found")
        await #expect(throws: GatewayError.rpc(code: 4001, message: "session not found")) { try await submitted.value }
    }

    @Test func answersMatchRequestsOutOfOrder() async throws {
        let harness = try await Harness.connect()
        async let submitted = harness.client.submitPrompt(PromptSubmitParams(sessionId: "s1", text: "Hi", voiceTurn: true))
        async let interrupted = harness.client.interrupt(sessionId: "s1")
        let submit = try await harness.socket.waitForRequest("prompt.submit")
        let interrupt = try await harness.socket.waitForRequest("session.interrupt")
        #expect(submit["params"]?["voice_turn"] == true)
        harness.socket.reply(to: interrupt, result: #"{"status":"interrupted","interrupted":true}"#)
        harness.socket.reply(to: submit, result: #"{"status":"streaming","user_row_id":42}"#)
        let submitResult = try await submitted
        #expect(submitResult.status == .streaming)
        #expect(submitResult.userRowId == 42)
        #expect(try await interrupted.status == "interrupted")
    }

    @Test func resumeSendsStoredIdWithoutInlineImages() async throws {
        let harness = try await Harness.connect()
        async let snapshot = harness.client.resumeSession(
            SessionResumeParams(storedSessionId: "20261116_120000_ab12", source: "ios", omitMessages: true))
        let request = try await harness.socket.waitForRequest("session.resume")
        #expect(request["params"] == ["session_id": "20261116_120000_ab12", "source": "ios", "omit_messages": true,
                                      "inline_images": false])
        harness.socket.reply(to: request, result: GatewayFixtures.resumeResult)
        let result = try await snapshot
        #expect(result.sessionId == "e5f6a7b8")
        #expect(result.running == true)
        #expect(result.inflight?.assistant == "Partial")
        #expect(result.openRequests?.first?.method == "approval")
        #expect(result.messages.first?.rowId == 7)
    }

    @Test func listAndHistoryDecode() async throws {
        let harness = try await Harness.connect()
        async let list = harness.client.listSessions(SessionListParams(limit: 5))
        let listRequest = try await harness.socket.waitForRequest("session.list")
        #expect(listRequest["params"] == ["limit": 5])
        harness.socket.reply(to: listRequest, result: """
        {"sessions":[{"id":"k1","title":"Trip","preview":"Book it","started_at":1763290000.5,"message_count":4,\
        "source":"photon","_lineage_root_id":null}]}
        """)
        let rows = try await list
        #expect(rows.first?.source == "photon")
        #expect(rows.first?.startedAt == 1763290000.5)

        async let history = harness.client.sessionHistory(sessionId: "s1")
        harness.socket.reply(to: try await harness.socket.waitForRequest("session.history"), result: """
        {"count":2,"messages":[{"role":"user","text":"Hi","row_id":1},{"role":"assistant","text":"Hello","row_id":2,\
        "reasoning":"r"}]}
        """)
        let result = try await history
        #expect(result.count == 2)
        #expect(result.messages.last?.reasoning == "r")
    }

    /// Issue #7: `session.most_recent` and the list rows for the session list.
    @Test func mostRecentAndListItemsDecode() async throws {
        let harness = try await Harness.connect()
        async let recent = harness.client.fetchMostRecentSessionId()
        let request = try await harness.socket.waitForRequest("session.most_recent")
        #expect(request["params"] == [:])
        harness.socket.reply(to: request, result: #"{"session_id":"20261116_101500_ab12cd","title":"Trip","started_at":1763290000,"source":"ios"}"#)
        #expect(try await recent == "20261116_101500_ab12cd")

        async let none = harness.client.fetchMostRecentSessionId()
        harness.socket.reply(to: try await harness.socket.waitForRequest("session.most_recent", count: 2),
                             result: #"{"session_id":null,"title":null,"started_at":null,"source":null}"#)
        #expect(try await none == nil)

        async let list = harness.client.fetchSessions()
        harness.socket.reply(to: try await harness.socket.waitForRequest("session.list"), result: """
        {"sessions":[{"id":"k2","title":"","preview":"Daily digest","started_at":1763290100,"source":"cron"},        {"id":"k1","title":"Trip","preview":"Book it","started_at":1763290000,"message_count":4,"source":"ios"}]}
        """)
        let items = try await list
        #expect(items.map(\.id) == ["k2", "k1"])
        #expect(items[0].displayTitle == "Untitled")
        #expect(items[0].sourceBadge == SessionListItem.SourceBadge(symbol: "clock", text: "Cron"))
        #expect(items[1].sourceBadge == nil)
        #expect(items[1].startedAt == Date(timeIntervalSince1970: 1763290000))
    }

    @Test func eventsSinceDecodesReplayedEvents() async throws {
        let harness = try await Harness.connect()
        async let replay = harness.client.eventsSince(sessionId: "s1", lastSeen: 11)
        let request = try await harness.socket.waitForRequest("session.events.since")
        #expect(request["params"] == ["session_id": "s1", "last_seen": 11])
        harness.socket.reply(to: request, result: """
        {"events":[{"type":"message.delta","session_id":"s1","seq":12,"payload":{"text":"Hello","offset":0}}],\
        "latest_seq":12,"truncated":false,"count":1,"epoch":"e","open_requests":[]}
        """)
        let result = try await replay
        #expect(result.latestSeq == 12)
        #expect(result.events.first?.kind == .messageDelta(MessageDeltaPayload(text: "Hello", offset: 0)))
    }

    @Test func requestTimesOut() async throws {
        let harness = try await Harness.connect(configuration: .init(heartbeatInterval: nil, requestTimeout: .milliseconds(30)))
        await #expect(throws: GatewayError.timeout(method: "session.list")) { try await harness.client.listSessions() }
        #expect(await harness.client.state == .connected(harness.ready))
    }

    // MARK: Server requests

    @Test func approvalRequestIsSurfacedAndAnswered() async throws {
        let harness = try await Harness.connect()
        harness.socket.push(GatewayFixtures.approvalRequest)
        guard case .serverRequest(let request) = try await harness.reader.nextEvent(),
              case .approval(let approval) = request.kind
        else { Issue.record("expected an approval request"); return }
        #expect(request.id == .string("r-17"))
        #expect(request.sessionId == "s1")
        #expect(approval.requestId == "a1b2")
        #expect(approval.command == "rm -rf build/")
        #expect(approval.choices == [.once, .session, .always, .deny])
        #expect(approval.allowPermanent == true)

        try await harness.client.answerApproval(request, choice: .once)
        let answer = try #require(try await harness.socket.waitForSent { $0["id"] == "r-17" }.first)
        #expect(answer == ["jsonrpc": "2.0", "id": "r-17", "result": ["choice": "once"]])
    }

    @Test func unsupportedServerRequestIsRefusedAtOnce() async throws {
        let harness = try await Harness.connect()
        harness.socket.push(#"{"jsonrpc":"2.0","id":"r-9","method":"theme.pick","params":{"session_id":"s1"}}"#)
        let answer = try #require(try await harness.socket.waitForSent { $0["id"] == "r-9" }.first)
        #expect(answer["error"] == ["code": -32601, "message": "not supported"])
        #expect(answer["result"] == nil)
    }

    @Test func clarifyRequestKeepsRawParams() async throws {
        let harness = try await Harness.connect()
        harness.socket.push(#"""
        {"jsonrpc":"2.0","id":"r-3","method":"clarify","params":{"session_id":"s1","questions":[{"qid":"q1","question":"Which?","multi_select":false}]}}
        """#)
        guard case .serverRequest(let request) = try await harness.reader.nextEvent() else {
            Issue.record("expected a clarify request"); return
        }
        #expect(request.kind == .clarify)
        #expect(request.params["questions"]?.stringValue == nil)
        try await harness.client.respond(to: request.id, result: ["answers": ["q1": "A"], "outcome": "submitted"] as JSONValue)
        let answer = try #require(try await harness.socket.waitForSent { $0["id"] == "r-3" }.first)
        #expect(answer["result"]?["outcome"] == "submitted")
    }
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw FakeTimeout(what: "condition")
}

extension MessageDeltaPayload {
    init(text: String?, offset: Int?) {
        self.init(text: text, turnId: nil, segment: nil, offset: offset, rendered: nil)
    }
}
