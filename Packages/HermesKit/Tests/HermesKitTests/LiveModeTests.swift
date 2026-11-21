import Foundation
import Synchronization
import Testing
@testable import HermesKit

// Issue #98: GPT-Live. Every test uses fakes. No test opens a real live session: each one costs money.

private let liveToken = String(repeating: "0f", count: 32)
/// A WebRTC offer as the peer makes it: CRLF line ends, and a CRLF at the end.
private let offer = "v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0 1\r\n"
    + "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:1\r\n"

@Suite struct LiveModeServiceTests {
    @Test func statusTextOfUnavailableAndOlderServers() {
        #expect(VoiceLiveStatus(mode: .chained, available: false, reason: " No OpenAI key ").unavailableText == "No OpenAI key")
        #expect(VoiceLiveStatus(mode: .chained, available: false).unavailableText == "Not available on this server")
        #expect(LiveModeStatusText.olderServer == "This Hermes version has no Live mode.")
    }

    @Test func delegationPromptUsesSurfaceVoiceLive() async throws {
        let socket = FakeGatewaySocket()
        let gateway = GatewayClient(endpoint: try GatewayEndpoint(port: 8123, token: liveToken),
                                    connector: FakeGatewayConnector(socket), configuration: .init(heartbeatInterval: nil))
        async let ready = gateway.connect()
        socket.pushReady()
        socket.reply(to: try await socket.waitForRequest("client.capabilities"), result: "{}")
        _ = try await ready

        async let row = gateway.submitLivePrompt(sessionId: "S", text: "What is on my calendar?",
                                                 voiceContext: "User: What is on my calendar?")
        let request = try await socket.waitForRequest("prompt.submit")
        #expect(request["params"] == ["session_id": "S", "text": "What is on my calendar?", "surface": "voice-live",
                                      "voice_turn": true, "voice_context": "User: What is on my calendar?"])
        socket.reply(to: request, result: #"{"status":"streaming","user_row_id":7}"#)
        #expect(try await row == 7)
    }

    /// Issue #147: a Live delegation is a voice turn, so the server uses its voice route. A text turn is not.
    @Test func delegationEncodesVoiceTurnAndTextTurnDoesNot() throws {
        func json(_ params: PromptSubmitParams) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return String(decoding: try encoder.encode(params), as: UTF8.self)
        }
        var live = PromptSubmitParams(sessionId: "S", text: "Hi", voiceTurn: true)
        live.surface = LiveModeProtocol.surface
        live.voiceContext = "User: Hi"
        let liveJSON = try json(live)
        #expect(liveJSON.contains(#""surface":"voice-live""#))
        #expect(liveJSON.contains(#""voice_turn":true"#))
        #expect(liveJSON.contains(#""voice_context":"User: Hi""#))
        #expect(!(try json(PromptSubmitParams(sessionId: "S", text: "Hi"))).contains("voice_turn"))
    }

    @Test func textTurnSendsNoVoiceTurn() async throws {
        let socket = FakeGatewaySocket()
        let gateway = GatewayClient(endpoint: try GatewayEndpoint(port: 8123, token: liveToken),
                                    connector: FakeGatewayConnector(socket), configuration: .init(heartbeatInterval: nil))
        async let ready = gateway.connect()
        socket.pushReady()
        socket.reply(to: try await socket.waitForRequest("client.capabilities"), result: "{}")
        _ = try await ready

        async let row = gateway.submitPrompt(sessionId: "S", text: "Typed", retryBeforeRowId: nil)
        let request = try await socket.waitForRequest("prompt.submit")
        #expect(request["params"] == ["session_id": "S", "text": "Typed"])
        socket.reply(to: request, result: #"{"status":"streaming","user_row_id":8}"#)
        #expect(try await row == 8)
    }
}

@Suite struct LiveModeEventTests {
    @Test func parsesServerEvents() {
        #expect(LiveModeServerEvent.parse(#"{"type":"session.started","session":{"id":"s"}}"#) == .started(sessionId: "s"))
        #expect(LiveModeServerEvent.parse(#"{"type":"session.input_transcript.delta","delta":"Hi","start_ms":1,"end_ms":2}"#)
                == .transcript(LiveModeFragment(speaker: .user, text: "Hi", startMs: 1, endMs: 2)))
        #expect(LiveModeServerEvent.parse(#"{"type":"session.output_transcript.delta","delta":"Yes"}"#)
                == .transcript(LiveModeFragment(speaker: .assistant, text: "Yes")))
        #expect(LiveModeServerEvent.parse(#"{"type":"session.delegation.created","delegation":{"id":"d1","type":"x","target":"y"}}"#)
                == .delegation(id: "d1"))
        #expect(LiveModeServerEvent.parse(#"{"type":"session.delegation.created","delegation":{}}"#)
                == .other("session.delegation.created"))
        #expect(LiveModeServerEvent.parse(#"{"type":"session.closed","reason":"idle_timeout","usage":{"seconds":61.5}}"#)
                == .closed(reason: "idle_timeout", usageSeconds: 61.5))
        #expect(LiveModeServerEvent.parse(#"{"type":"error","error":{"code":"bad","message":"Nope"}}"#)
                == .error(code: "bad", message: "Nope"))
        #expect(LiveModeServerEvent.parse("not json") == nil)
    }

    @Test func clientEventsAreTheVendorShape() throws {
        func object(_ event: LiveModeClientEvent) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(event.json.utf8)) as? [String: Any])
        }
        let say = try object(.commentary(delegationId: "d1", content: "It is sunny.", eventId: "say_1"))
        #expect(say["type"] as? String == "session.commentary.append")
        #expect(say["delegation_id"] as? String == "d1")
        #expect(say["content"] as? String == "It is sunny.")
        #expect(say["event_id"] as? String == "say_1")
        #expect(try object(.thinking(delegationId: "d1", content: "x", eventId: "t")) ["type"] as? String
                == "session.thinking.append")
        #expect(try object(.mute(true, eventId: "m"))["type"] as? String == "session.input_audio.mute")
        #expect(try object(.mute(false, eventId: "m"))["type"] as? String == "session.input_audio.unmute")
        #expect(LiveModeClientEvent.close.json == #"{"type":"session.close"}"#)
        let instruct = try object(.instructions(content: "Be brief.", eventId: "i"))
        #expect(instruct["delegation_id"] is NSNull)
    }

    @Test func chunksKeepSentencesUnderTheLimit() {
        #expect(LiveModeText.chunks("  ") == [])
        #expect(LiveModeText.chunks("One.\n Two.") == ["One. Two."])
        let chunks = LiveModeText.chunks("Aaaa. Bbbb. Cccc.", limit: 11)
        #expect(chunks == ["Aaaa. Bbbb.", "Cccc."])
        let long = LiveModeText.chunks(String(repeating: "x", count: 25), limit: 10)
        #expect(long.map(\.count) == [10, 10, 5])
        #expect(LiveModeText.chunks(String(repeating: "Word. ", count: 600)).allSatisfy { $0.count <= 1_400 })
    }

    @Test func lastSentenceEndNeedsASpaceAfterTheMark() {
        #expect(LiveModeText.lastSentenceEnd(in: "No end") == nil)
        #expect(LiveModeText.lastSentenceEnd(in: "Version 1.5 is out") == nil)
        let text = "First. Second! Third"
        let end = try? #require(LiveModeText.lastSentenceEnd(in: text))
        #expect(end.map { String(text[..<$0]) } == "First. Second!")
    }

    @Test func delegationPromptIsTheLastOwnerTurn() {
        let fragments = [LiveModeFragment(speaker: .user, text: "What is "), LiveModeFragment(speaker: .user, text: "the time?"),
                         LiveModeFragment(speaker: .assistant, text: "Let me check."),
                         LiveModeFragment(speaker: .user, text: " And  the weather? ")]
        let result = LiveModeText.delegationPrompt(fragments)
        #expect(result.prompt == "And the weather?")
        #expect(result.context == "User: What is the time?\nVoice assistant: Let me check.\nUser: And the weather?")
        #expect(LiveModeText.delegationPrompt([LiveModeFragment(speaker: .assistant, text: "Hi")]).prompt
                == "Voice assistant: Hi")
        #expect(LiveModeText.delegationPrompt([]).prompt == "")
    }

    @Test func historyKeepsTextTurnsNewestLast() {
        let date = Date(timeIntervalSince1970: 0)
        var memo = ChatMessage(id: "v", role: .user, text: "memo", date: date)
        memo.voice = VoiceMemo(fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), duration: 1, waveform: [])
        let messages = [ChatMessage(id: "1", role: .user, text: "Old", date: date), memo,
                        ChatMessage(id: "2", role: .assistant, text: "Reply", date: date),
                        ChatMessage(id: "3", role: .user, text: "   ", date: date)]
        let history = LiveModeText.history(messages)
        #expect(history == [VoiceLiveHistoryItem(role: .user, text: "Old"),
                            VoiceLiveHistoryItem(role: .assistant, text: "Reply")])
        #expect(LiveModeText.history(messages, maxMessages: 1) == [VoiceLiveHistoryItem(role: .assistant, text: "Reply")])
    }

    @Test func formats() {
        #expect(LiveModeFormat.elapsed(0) == "0:00")
        #expect(LiveModeFormat.elapsed(252) == "4:12")
        #expect(LiveModeFormat.elapsed(3_605) == "60:05")
        #expect(LiveModeEnd(reason: .hangUp, elapsedSeconds: 252, serial: 1).toast == "Live Mode Ended, 4:12")
    }
}

// MARK: - Controller

@MainActor
private final class FakeConnection: LiveModeConnection {
    var onEvent: (@MainActor (LiveModeLinkEvent) -> Void)?
    var sent: [String] = []
    var answers: [String] = []
    var muted: [Bool] = []
    var closed = false
    var offerError: (any Error)?

    func makeOffer() async throws -> String {
        if let offerError { throw offerError }
        return offer
    }

    func applyAnswer(_ sdp: String) async throws { answers.append(sdp) }

    func send(_ text: String) -> Bool {
        sent.append(text)
        return !closed
    }

    func setMuted(_ value: Bool) { muted.append(value) }
    var remoteHeld: [Bool] = []
    func setRemoteAudioHeld(_ held: Bool) { remoteHeld.append(held) }
    func close() { closed = true }

    func emit(_ event: LiveModeLinkEvent) { onEvent?(event) }
    func server(_ json: String) { onEvent?(.message(json)) }

    var sentTypes: [String] {
        sent.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["type"] as? String }
    }

    var commentary: [String] {
        sent.compactMap { text -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  object["type"] as? String == "session.commentary.append" else { return nil }
            return object["content"] as? String
        }
    }
}

private final class FakeLiveService: LiveModeService, @unchecked Sendable {
    let lock = NSLock()
    var offers: [String] = []
    var histories: [[VoiceLiveHistoryItem]] = []
    var error: (any Error)?

    func voiceLiveStatus() async throws -> VoiceLiveStatus? { VoiceLiveStatus(mode: .gptLive, available: true) }

    func createVoiceLiveSession(offerSDP sdp: String, history: [VoiceLiveHistoryItem]) async throws
        -> VoiceLiveSessionAnswer {
        try lock.withLock {
            offers.append(sdp)
            histories.append(history)
            if let error { throw error }
        }
        return VoiceLiveSessionAnswer(sessionId: "sess_1", sdp: "answer-sdp")
    }
}

@MainActor
private final class FakeHermes: LiveModeHermes {
    var submits: [(prompt: String, context: String)] = []
    var progress: [String: LiveReplyProgress] = [:]
    var stops = 0
    var failSubmit = false

    func submitDelegation(prompt: String, voiceContext: String) async throws -> String {
        submits.append((prompt, voiceContext))
        if failSubmit { throw LiveModeError.connectionFailed }
        return "p\(submits.count)"
    }

    func replyProgress(promptId: String) -> LiveReplyProgress { progress[promptId] ?? .waiting }
    func stopReply() { stops += 1 }
    func liveHistory() -> [VoiceLiveHistoryItem] { [VoiceLiveHistoryItem(role: .user, text: "Earlier")] }
}

@MainActor
@Suite struct LiveModeControllerTests {
    private final class Clock {
        var time = Date(timeIntervalSince1970: 1_000)
        func advance(_ seconds: TimeInterval) { time += seconds }
    }

    private struct Harness {
        let controller: LiveModeController
        let connection: FakeConnection
        let service: FakeLiveService
        let hermes: FakeHermes
        let clock: Clock
    }

    private func harness() -> Harness {
        let connection = FakeConnection()
        let service = FakeLiveService()
        let hermes = FakeHermes()
        let clock = Clock()
        let controller = LiveModeController(service: service, hermes: hermes, makeConnection: { connection },
                                            now: { clock.time }, autoTick: false, closeDelay: .zero)
        return Harness(controller: controller, connection: connection, service: service, hermes: hermes, clock: clock)
    }

    /// Starts a session and waits for the answer. The link then connects.
    private func live() async throws -> Harness {
        let h = harness()
        h.controller.start()
        #expect(h.controller.display == .connecting)
        for _ in 0..<200 where h.connection.answers.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(h.connection.answers == ["answer-sdp"])
        h.connection.emit(.connected)
        #expect(h.controller.phase == .live)
        return h
    }

    private func settle(_ until: () -> Bool) async throws {
        for _ in 0..<200 where !until() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func startSendsTheOfferUnchangedWithTheChatHistory() async throws {
        let h = try await live()
        #expect(h.service.offers == [offer])
        #expect(h.service.histories == [[VoiceLiveHistoryItem(role: .user, text: "Earlier")]])
        #expect(h.controller.display == .live)
        #expect(h.controller.display?.label == "Live. Speak any time.")
        h.clock.advance(65.4)
        h.connection.server(#"{"type":"session.input_transcript.delta","delta":"Hi"}"#)
        h.controller.tick()
        #expect(h.controller.elapsedSeconds == 65)
        #expect(h.controller.accessibilityLabel == "Live Mode, Live. Speak any time., 1:05")
    }

    @Test func eachDelegationSubmitsAndStreamsTheReplyAsCommentary() async throws {
        let h = try await live()
        h.connection.server(#"{"type":"session.input_transcript.delta","delta":"What is the weather?","end_ms":10}"#)
        h.connection.server(#"{"type":"session.delegation.created","delegation":{"id":"d1"}}"#)
        #expect(h.controller.display == .working(still: false))
        #expect(h.controller.display?.label == "Hermes is working…")
        try await settle { !h.hermes.submits.isEmpty }
        #expect(h.hermes.submits.first?.prompt == "What is the weather?")
        #expect(h.hermes.submits.first?.context == "User: What is the weather?")
        await Task.yield()

        h.hermes.progress["p1"] = .streaming("It is sunny. The high is")
        h.controller.tick()
        #expect(h.connection.commentary == ["It is sunny."])
        h.hermes.progress["p1"] = .streaming("It is sunny. The high is 20 degrees. Wind")
        h.controller.tick()
        #expect(h.connection.commentary == ["It is sunny.", "The high is 20 degrees."])
        h.hermes.progress["p1"] = .done("It is sunny. The high is 20 degrees. Wind is **light**.")
        h.controller.tick()
        #expect(h.connection.commentary == ["It is sunny.", "The high is 20 degrees.", "Wind is light."])
        #expect(h.controller.phase == .live)
        let say = try #require(h.connection.sent.last(where: { $0.contains("commentary") }))
        #expect(say.contains(#""delegation_id":"d1""#))
    }

    /// Issue #134: a final text that drops the interim text. Live mode speaks the rest and repeats nothing.
    @Test func aFinalTextWithoutTheInterimTextLosesNothing() async throws {
        let h = try await live()
        h.connection.server(#"{"type":"session.input_transcript.delta","delta":"Check the build.","end_ms":10}"#)
        h.connection.server(#"{"type":"session.delegation.created","delegation":{"id":"d1"}}"#)
        try await settle { !h.hermes.submits.isEmpty }
        await Task.yield()
        h.hermes.progress["p1"] = .streaming("Looking into it. Here is the")
        h.controller.tick()
        #expect(h.connection.commentary == ["Looking into it."])
        h.hermes.progress["p1"] = .done("Here is the final report.")
        h.controller.tick()
        #expect(h.connection.commentary == ["Looking into it.", "Here is the final report."])
        #expect(h.controller.phase == .live)
    }

    @Test func slowTurnSaysStillWorkingAndANewDelegationStopsTheOldTurn() async throws {
        let h = try await live()
        h.connection.server(#"{"type":"session.input_transcript.delta","delta":"Run the tests."}"#)
        h.connection.server(#"{"type":"session.delegation.created","delegation":{"id":"d1"}}"#)
        try await settle { !h.hermes.submits.isEmpty }
        h.clock.advance(11)
        h.controller.tick()
        #expect(h.controller.display == .working(still: true))
        #expect(h.controller.display?.label == "Still working…")
        h.connection.server(#"{"type":"session.delegation.created","delegation":{"id":"d2"}}"#)
        #expect(h.hermes.stops == 1)
        #expect(h.controller.display == .working(still: false))
    }

    @Test func failedSubmitOrReplySaysSorry() async throws {
        let h = try await live()
        h.hermes.failSubmit = true
        h.connection.server(#"{"type":"session.input_transcript.delta","delta":"Hello?"}"#)
        h.connection.server(#"{"type":"session.delegation.created","delegation":{"id":"d1"}}"#)
        try await settle { h.controller.phase == .live }
        #expect(h.connection.commentary == ["Sorry, I could not reach Hermes for that request."])

        h.hermes.failSubmit = false
        h.connection.server(#"{"type":"session.delegation.created","delegation":{"id":"d2"}}"#)
        try await settle { h.hermes.submits.count == 2 }
        await Task.yield()
        h.hermes.progress["p2"] = .failed
        h.controller.tick()
        #expect(h.connection.commentary.last == "Sorry, Hermes could not answer that request.")
        h.connection.server(#"{"type":"session.delegation.created","delegation":{"id":"d3"}}"#)
        try await settle { h.hermes.submits.count == 3 }
        await Task.yield()
        h.hermes.progress["p3"] = .done("```\ncode\n```")
        h.controller.tick()
        #expect(h.connection.sentTypes.last == "session.thinking.append")
    }

    @Test func idleWarnsAt45AndEndsAt60() async throws {
        let h = try await live()
        h.clock.advance(44)
        h.controller.tick()
        #expect(h.controller.display == .live)
        h.clock.advance(1)
        h.controller.tick()
        #expect(h.controller.display == .idleWarning)
        #expect(h.controller.display?.label == "Ending soon. Speak to continue.")
        // Speech resets the idle time.
        h.connection.server(#"{"type":"session.input_transcript.delta","delta":"Still here"}"#)
        #expect(h.controller.display == .live)
        h.clock.advance(59)
        h.controller.tick()
        #expect(h.controller.isActive)
        h.clock.advance(1)
        h.controller.tick()
        #expect(h.controller.phase == .idle)
        #expect(h.controller.lastEnd?.reason == .idle)
        #expect(h.controller.lastEnd?.toast == "Live Mode Ended, 1:45")
        #expect(h.connection.sentTypes.last == "session.close")
        #expect(h.connection.closed)
    }

    @Test func hermesWorkAndVoiceSpeechAreNotIdle() async throws {
        let h = try await live()
        h.connection.emit(.speaking(true))
        h.clock.advance(70)
        h.controller.tick()
        #expect(h.controller.isActive)
        h.connection.emit(.speaking(false))
        h.connection.server(#"{"type":"session.input_transcript.delta","delta":"Do it."}"#)
        h.connection.server(#"{"type":"session.delegation.created","delegation":{"id":"d1"}}"#)
        h.clock.advance(120)
        h.controller.tick()
        #expect(h.controller.phase == .working)
    }

    @Test func endOnHangUpBackgroundAndCallClosesThePeer() async throws {
        for reason in [LiveModeEndReason.hangUp, .background, .phoneCall, .modeChange] {
            let h = try await live()
            h.clock.advance(252)
            h.controller.end(reason)
            #expect(h.controller.phase == .idle)
            #expect(h.controller.lastEnd?.reason == reason)
            #expect(h.controller.lastEnd?.toast == "Live Mode Ended, 4:12")
            #expect(h.connection.sentTypes.last == "session.close")
            #expect(h.connection.closed)
            #expect(h.connection.onEvent == nil)
        }
    }

    @Test func endWhileConnectingClosesThePeer() async throws {
        let h = harness()
        h.controller.start()
        h.controller.end(.hangUp)
        #expect(h.connection.closed)
        #expect(h.controller.lastEnd?.toast == "Live Mode Ended, 0:00")
    }

    @Test func muteSendsTheEventAndShowsMuted() async throws {
        let h = try await live()
        h.controller.toggleMute()
        #expect(h.controller.display == .muted)
        #expect(h.connection.muted == [true])
        #expect(h.connection.sentTypes.last == "session.input_audio.mute")
        h.controller.toggleMute()
        #expect(h.controller.display == .live)
        #expect(h.connection.sentTypes.last == "session.input_audio.unmute")
    }

    @Test func linkDropReconnectsForTenSecondsAtMost() async throws {
        let h = try await live()
        h.connection.emit(.disconnected)
        #expect(h.controller.display == .reconnecting)
        h.clock.advance(5)
        h.connection.emit(.connected)
        #expect(h.controller.display == .live)
        h.connection.emit(.disconnected)
        h.clock.advance(10)
        h.controller.tick()
        #expect(h.controller.display == .failed)
        #expect(h.controller.display?.label == "Live mode stopped")
        #expect(h.connection.closed)
        #expect(h.controller.lastEnd == nil)
    }

    @Test func refusedSessionFailsAndTryAgainStartsANewSession() async throws {
        let h = harness()
        h.service.error = VoiceLiveSessionError.unavailable(detail: "No OpenAI key")
        h.controller.start()
        try await settle { h.controller.phase == .failed }
        #expect(h.controller.failure == "No OpenAI key")
        #expect(h.connection.closed)
        h.service.error = nil
        h.connection.closed = false
        h.controller.start()
        #expect(h.controller.phase == .connecting)
        try await settle { h.connection.answers.count == 1 }
        // "End" in the failed state hides the panel with no toast.
        h.controller.end(.hangUp)
        #expect(h.controller.lastEnd?.reason == .hangUp)
    }

    @Test func vendorRefusalWithNoDetailShowsADefault() async throws {
        let h = harness()
        h.service.error = VoiceLiveSessionError.vendor(detail: nil)
        h.controller.start()
        try await settle { h.controller.phase == .failed }
        #expect(h.controller.failure == "The server could not start Live mode.")
    }

    @Test func liveChatTransportIsTheLiveService() {
        // #97 owns the two calls. The engine uses them through `LiveModeService`.
        let service: (any LiveModeService)? = LiveChatTransport()
        #expect(service != nil)
    }

    @Test func micDeniedShowsTheMicText() async throws {
        let h = harness()
        h.connection.offerError = LiveModeError.microphoneDenied
        h.controller.start()
        try await settle { h.controller.phase == .failed }
        #expect(h.controller.failure == "Microphone Access Off")
        #expect(h.service.offers.isEmpty)
    }

    @Test func noConnectIn30SecondsFails() async throws {
        let h = harness()
        h.controller.start()
        try await settle { !h.connection.answers.isEmpty }
        h.clock.advance(30)
        h.controller.tick()
        #expect(h.controller.phase == .failed)
    }

    // MARK: Issue #109: a new start after each end

    @Test func threeStartAndEndCyclesInARowAllConnect() async throws {
        var made: [FakeConnection] = []
        let service = FakeLiveService()
        let controller = LiveModeController(service: service, hermes: FakeHermes(),
                                            makeConnection: { let next = FakeConnection(); made.append(next); return next },
                                            autoTick: false, closeDelay: .zero)
        for cycle in 1...3 {
            controller.start()
            let connection = try #require(made.last)
            try await settle { !connection.answers.isEmpty }
            connection.emit(.connected)
            #expect(controller.phase == .live, "cycle \(cycle)")
            controller.end(.hangUp)
            #expect(controller.phase == .idle)
            #expect(connection.closed)
            #expect(connection.sentTypes.last == "session.close")
        }
        #expect(made.count == 3)
        #expect(service.offers.count == 3)
        // A late event from an old peer does not touch the new session.
        controller.start()
        made[0].emit(.failed)
        #expect(controller.phase == .connecting)
    }

    @Test func tryAgainAfterAnICEFailureConnects() async throws {
        var made: [FakeConnection] = []
        let controller = LiveModeController(service: FakeLiveService(), hermes: FakeHermes(),
                                            makeConnection: { let next = FakeConnection(); made.append(next); return next },
                                            autoTick: false, closeDelay: .zero)
        controller.start()
        try await settle { made.last?.answers.isEmpty == false }
        made[0].emit(.failed)
        #expect(controller.phase == .failed)
        #expect(controller.failure == "Could not reach OpenAI (ICE failed).")
        #expect(made[0].closed)
        controller.start()
        try await settle { made.count == 2 && made[1].answers.isEmpty == false }
        made[1].emit(.connected)
        #expect(controller.phase == .live)
    }

    @Test func errorLineNamesTheFailedStep() async throws {
        let h = harness()
        h.connection.offerError = LiveModeError.step(.audioSession, code: 561_017_449)
        h.controller.start()
        try await settle { h.controller.phase == .failed }
        #expect(h.controller.failure == "Could not start the microphone (audio session).")
        #expect(h.service.offers.isEmpty)

        let lost = try await live()
        lost.connection.emit(.channelClosed)
        #expect(lost.controller.failure == "The connection to Live mode was lost (data channel closed).")

        let timeout = harness()
        timeout.controller.start()
        try await settle { !timeout.connection.answers.isEmpty }
        timeout.clock.advance(30)
        timeout.controller.tick()
        #expect(timeout.controller.failure == "Could not reach OpenAI (timed out).")

        #expect(LiveModeController.failureText(HermesAPIError.http(status: 500), step: .session)
                == "The server refused Live mode (HTTP 500).")
        #expect(LiveModeController.failureText(GatewayError.notConnected, step: .session)
                == "Could not reach Hermes (session request).")
        #expect(LiveModeController.failureText(LiveModeError.step(.answer, code: -1), step: .answer)
                == "Could not use the answer from OpenAI (SDP answer).")
    }

    @Test func logShowsTheFailedStepAndCodeButNoSDPOrToken() async throws {
        let entries = Mutex<[HermesLog.Entry]>([])
        let id = HermesLog.addObserver { entry in entries.withLock { $0.append(entry) } }
        defer { HermesLog.removeObserver(id) }
        let h = harness()
        h.service.error = HermesAPIError.http(status: 500)
        h.controller.start()
        try await settle { h.controller.phase == .failed }
        #expect(h.controller.failure == "The server refused Live mode (HTTP 500).")
        let lines = entries.withLock { $0 }.filter { $0.category == "live-mode" }.map(\.message)
        #expect(lines.contains("live start failed at session: HTTP 500"))
        #expect(!lines.contains { $0.contains("v=0") || $0.contains("answer-sdp") || $0.lowercased().contains("token") })
    }

    @Test func serverCloseEndsTheSession() async throws {
        let h = try await live()
        h.connection.server(#"{"type":"session.closed","reason":"max_duration","usage":{"seconds":30}}"#)
        #expect(h.controller.phase == .idle)
        #expect(h.controller.lastEnd?.reason == .server("max_duration"))
    }

    @Test func eventsOfAnOldConnectionAreIgnored() async throws {
        let h = try await live()
        let old = h.connection
        h.controller.end(.hangUp)
        old.emit(.connected)
        old.server(#"{"type":"session.delegation.created","delegation":{"id":"d1"}}"#)
        #expect(h.controller.phase == .idle)
        #expect(h.hermes.submits.isEmpty)
    }
}

// MARK: - Chat

@MainActor
@Suite struct LiveModeChatTests {
    private final class LiveTransport: ChatTransport, LiveDelegationTransport, @unchecked Sendable {
        let events: AsyncStream<GatewayClientEvent>
        let lock = NSLock()
        var live: [(String, String)] = []
        var plain: [String] = []
        var fail = false

        init() { events = AsyncStream { _ in } }

        func startSession(source: String, idempotencyKey: String) async throws -> ChatSessionRef {
            ChatSessionRef(liveId: "s1", storedId: "st1")
        }

        func resumeSession(storedId: String, source: String) async throws -> ChatSessionRef {
            ChatSessionRef(liveId: "s1", storedId: storedId)
        }

        func submitPrompt(sessionId: String, text: String, retryBeforeRowId: Int?) async throws -> Int? {
            lock.withLock { plain.append(text) }
            return 1
        }

        func submitLivePrompt(sessionId: String, text: String, voiceContext: String) async throws -> Int? {
            try lock.withLock {
                live.append((text, voiceContext))
                if fail { throw GatewayError.notConnected }
            }
            return 2
        }

        func stopReply(sessionId: String) async throws -> Bool { true }
        func history(sessionId: String) async throws -> [TranscriptMessage] { [] }
    }

    private func event(_ json: String) throws -> GatewayClientEvent {
        .event(try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8)))
    }

    @Test func delegationShowsAnOwnerBubbleAndTheReplyProgress() async throws {
        let transport = LiveTransport()
        let vm = ChatViewModel(transport: transport, redrawInterval: .seconds(60))
        let id = await vm.sendLiveDelegation("What is the weather?", voiceContext: "User: What is the weather?")
        #expect(transport.live.first?.0 == "What is the weather?")
        #expect(transport.live.first?.1 == "User: What is the weather?")
        #expect(transport.plain.isEmpty)
        #expect(vm.messages.first?.text == "What is the weather?")
        #expect(vm.messages.first?.role == .user)
        #expect(vm.messages.first?.delivery == .delivered)
        #expect(vm.liveReplyProgress(promptId: id) == .waiting)

        vm.receive(try event(#"{"type":"message.start","session_id":"s1","payload":{"turn_id":"t1"}}"#))
        vm.receive(try event(#"{"type":"message.delta","session_id":"s1","payload":{"text":"Sunny. ","offset":0}}"#))
        #expect(vm.liveReplyProgress(promptId: id) == .streaming("Sunny. "))
        vm.receive(try event(#"{"type":"message.complete","session_id":"s1","payload":{"text":"Sunny. 20 degrees.","status":"complete"}}"#))
        #expect(vm.liveReplyProgress(promptId: id) == .done("Sunny. 20 degrees."))
        #expect(vm.messages.last?.role == .assistant)
        #expect(vm.liveReplyProgress(promptId: "missing") == .failed)
    }

    @Test func failedDelegationIsNotQueued() async {
        let transport = LiveTransport()
        transport.fail = true
        let vm = ChatViewModel(transport: transport, redrawInterval: .seconds(60))
        let id = await vm.sendLiveDelegation("Hello", voiceContext: "")
        #expect(vm.messages.first?.delivery == .failed)
        #expect(vm.liveReplyProgress(promptId: id) == .failed)
    }
}

/// Issue #121: a Hermes prompt holds the live session.
extension LiveModeControllerTests {
    @Test func aPromptHoldsTheMicAndTheRemoteAudioAndStopsTheIdleTimer() async throws {
        let h = try await live()
        h.controller.holdForPrompt()
        #expect(h.controller.promptHold)
        #expect(h.connection.muted.last == true, "no speech goes to the live model while the card waits")
        #expect(h.connection.remoteHeld == [true])
        // A card can wait 300 s. The 60 s idle end does not run.
        for _ in 0..<30 {
            h.clock.advance(10)
            h.controller.tick()
        }
        #expect(h.controller.phase == .live)
        #expect(h.controller.display == .live, "no idle warning while the card waits")
        // A tap on Mute while held keeps the mic closed.
        h.controller.toggleMute()
        #expect(h.connection.muted.last == true)
        h.controller.toggleMute()
        #expect(h.connection.muted.last == true)
        h.controller.releasePrompt()
        #expect(!h.controller.promptHold)
        #expect(h.connection.muted.last == false, "the mic comes back after the answer")
        #expect(h.connection.remoteHeld == [true, false])
        h.clock.advance(44)
        h.controller.tick()
        #expect(h.controller.display == .live, "the idle timer starts again at the release")
        h.clock.advance(17)
        h.controller.tick()
        #expect(h.controller.lastEnd?.reason == .idle)
    }

    @Test func aReleaseKeepsTheOwnersMute() async throws {
        let h = try await live()
        h.controller.toggleMute()
        h.controller.holdForPrompt()
        h.controller.releasePrompt()
        #expect(h.connection.muted.last == true)
        h.controller.end(.hangUp)
        #expect(!h.controller.promptHold)
    }
}
