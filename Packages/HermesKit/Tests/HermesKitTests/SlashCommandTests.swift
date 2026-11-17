import Foundation
import Testing
@testable import HermesKit

/// A chat transport with slash calls (issue #67). The chat calls go to a `FakeChatTransport`. No network.
final class FakeSlashTransport: ChatTransport, SlashCommandTransport, @unchecked Sendable {
    struct Dispatch: Equatable {
        var sessionId: String
        var name: String
        var arg: String?
    }

    let chats = FakeChatTransport()
    private let lock = NSLock()
    private var _execs: [String] = []
    private var _dispatches: [Dispatch] = []
    private var _usages: [String] = []
    /// The answers of `slash.exec`, in order. A missing answer is `{"output":"(no output)"}`.
    var execAnswers: [Result<SlashExecResult, any Error>] = []
    var dispatchAnswer: Result<SlashExecResult, any Error> = .failure(GatewayError.rpc(code: 4018, message: "not a quick/plugin/bundle/skill command: foo"))
    var usageAnswer: Result<SessionUsage, any Error> = .success(SessionUsage(calls: 3, input: 1200, output: 340, total: 1540))

    var execs: [String] { lock.withLock { _execs } }
    var dispatches: [Dispatch] { lock.withLock { _dispatches } }
    var usages: [String] { lock.withLock { _usages } }

    var events: AsyncStream<GatewayClientEvent> { chats.events }

    func startSession(source: String, idempotencyKey: String) async throws -> ChatSessionRef {
        try await chats.startSession(source: source, idempotencyKey: idempotencyKey)
    }

    func resumeSession(storedId: String, source: String) async throws -> ChatSessionRef {
        try await chats.resumeSession(storedId: storedId, source: source)
    }

    func submitPrompt(sessionId: String, text: String, retryBeforeRowId: Int?) async throws -> Int? {
        try await chats.submitPrompt(sessionId: sessionId, text: text, retryBeforeRowId: retryBeforeRowId)
    }

    func stopReply(sessionId: String) async throws -> Bool { true }

    func history(sessionId: String) async throws -> [TranscriptMessage] {
        try await chats.history(sessionId: sessionId)
    }

    func execSlash(sessionId _: String, command: String) async throws -> SlashExecResult {
        let answer: Result<SlashExecResult, any Error>? = lock.withLock {
            _execs.append(command)
            return execAnswers.isEmpty ? nil : execAnswers.removeFirst()
        }
        return try answer?.get() ?? SlashExecResult(output: "(no output)")
    }

    func dispatchCommand(sessionId: String, name: String, arg: String?) async throws -> SlashExecResult {
        let answer = lock.withLock {
            _dispatches.append(Dispatch(sessionId: sessionId, name: name, arg: arg))
            return dispatchAnswer
        }
        return try answer.get()
    }

    func sessionUsage(sessionId: String) async throws -> SessionUsage {
        let answer = lock.withLock {
            _usages.append(sessionId)
            return usageAnswer
        }
        return try answer.get()
    }
}

private let useDispatch = GatewayError.rpc(code: 4018, message: "skill command: use command.dispatch for /work")

@Suite struct SlashCommandParseTests {
    @Test func commandsAndProse() {
        #expect(SlashCommand("/new") == SlashCommand("  /new  "))
        #expect(SlashCommand("/Usage")?.name == "usage")
        #expect(SlashCommand("/model gpt-x")?.arg == "gpt-x")
        #expect(SlashCommand("/goal fix it\n  then test")?.arg == "fix it\n  then test")
        #expect(SlashCommand("/")?.name == "")
        #expect(SlashCommand("/usr/local is a path") == nil)
        #expect(SlashCommand("//new") == nil)
        #expect(SlashCommand("run /clean") == nil)
        #expect(SlashCommand("hello") == nil)
    }

    @Test func localCatalog() {
        #expect(SlashCommandCatalog.localAction(for: "new") == .newChat)
        #expect(SlashCommandCatalog.localAction(for: "reset") == .newChat)
        #expect(SlashCommandCatalog.localAction(for: "clear") == .newChat)
        #expect(SlashCommandCatalog.localAction(for: "usage") == .usage)
        #expect(SlashCommandCatalog.localAction(for: "model") == nil)
    }

    @Test func outcomes() {
        #expect(SlashOutcome(SlashExecResult(output: "ok")) == .output("ok"))
        #expect(SlashOutcome(SlashExecResult(output: "", warning: "w")) == .output("warning: w\n(no output)"))
        #expect(SlashOutcome(SlashExecResult(output: "o", type: .plugin)) == .output("o"))
        #expect(SlashOutcome(SlashExecResult(type: .send, message: "m", display: "/work x"))
            == .send(message: "m", display: "/work x", notice: nil))
        #expect(SlashOutcome(SlashExecResult(type: .send)) == nil)
        #expect(SlashOutcome(SlashExecResult(type: .skill)) == nil)
        #expect(SlashOutcome(SlashExecResult(type: .prefill, message: "draft")) == .prefill(message: "draft", notice: nil))
        #expect(SlashOutcome(SlashExecResult(type: .alias, target: "model")) == .alias(target: "model"))
    }

    @Test func resultDecodingIsTolerant() throws {
        let json = #"{"type":"teleport","output":"x","display":5}"#
        let result = try JSONDecoder().decode(SlashExecResult.self, from: Data(json.utf8))
        #expect(result.type == nil)
        #expect(result.output == "x")
        #expect(result.display == nil)
    }

    @Test func usageDecodingAndText() throws {
        let json = #"{"calls":1,"input":1200.0,"output":340,"total":1540,"credits_lines":[" Credits: 12 ", ""]}"#
        let usage = try JSONDecoder().decode(SessionUsage.self, from: Data(json.utf8))
        #expect(usage == SessionUsage(calls: 1, input: 1200, output: 340, total: 1540, creditsLines: [" Credits: 12 ", ""]))
        #expect(usage.text(locale: Locale(identifier: "en_US"))
            == "Usage: 1 call · 1,200 in / 340 out · 1,540 total\nCredits: 12")
        let empty = try JSONDecoder().decode(SessionUsage.self, from: Data("{}".utf8))
        #expect(empty == SessionUsage())
    }

    @Test func outputTextDropsANSIColors() {
        let raw = "\u{1B}[1;31mUnknown command: /foo\u{1B}[0m\n"
        #expect(SlashOutputText.clean(raw) == "Unknown command: /foo")
        #expect(SlashOutputText.isUnknownCommand(SlashOutputText.clean(raw)))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SlashCommandChatTests {
    private func model(_ transport: any ChatTransport) -> ChatViewModel {
        let counter = Counter()
        return ChatViewModel(transport: transport, redrawInterval: .seconds(60), makeId: { counter.next() })
    }

    @Test func newPushesANewChatAndSendsNothing() async {
        let transport = FakeSlashTransport()
        let vm = model(transport)
        await vm.send("/new")?.value
        #expect(vm.newChatRequest != nil)
        #expect(vm.messages.isEmpty)
        #expect(transport.chats.submits.isEmpty)
        #expect(transport.execs.isEmpty)
        let request = vm.newChatRequest!
        vm.clearNewChatRequest(request)
        #expect(vm.newChatRequest == nil)
        await vm.send("/reset")?.value
        #expect(vm.newChatRequest != nil)
    }

    @Test func usageShowsACardAndTheModelGetsNoTurn() async {
        let transport = FakeSlashTransport()
        let vm = model(transport)
        await vm.send("/usage")?.value
        #expect(transport.usages == ["s1"])
        #expect(transport.chats.submits.isEmpty)
        #expect(transport.execs.isEmpty)
        #expect(vm.messages.count == 1)
        let card = vm.messages[0].command
        #expect(card?.command == "/usage")
        #expect(card?.isError == false)
        #expect(card?.output.hasPrefix("Usage: 3 calls") == true)
        #expect(vm.turn == .idle)
        #expect(vm.composerFill == nil)
    }

    @Test func usageErrorShowsARedCardAndKeepsTheText() async {
        let transport = FakeSlashTransport()
        transport.usageAnswer = .failure(GatewayError.rpc(code: 4001, message: "session not found"))
        let vm = model(transport)
        await vm.send("/usage")?.value
        #expect(vm.messages.first?.command == ChatCommandCard(command: "/usage", output: "session not found", isError: true))
        #expect(vm.composerFill?.text == "/usage")
        #expect(vm.composerFill?.reason == .restore)
    }

    @Test func execOutputShowsACard() async {
        let transport = FakeSlashTransport()
        transport.execAnswers = [.success(SlashExecResult(output: "\u{1B}[32mModel: gpt-x\u{1B}[0m"))]
        let vm = model(transport)
        await vm.send("/model gpt-x")?.value
        #expect(transport.execs == ["/model gpt-x"])
        #expect(transport.dispatches.isEmpty)
        #expect(transport.chats.submits.isEmpty)
        #expect(vm.messages.map(\.command) == [ChatCommandCard(command: "/model", output: "Model: gpt-x")])
        #expect(vm.composerFill == nil)
    }

    @Test func error4018DispatchesAndASendSubmitsTheMessage() async {
        let transport = FakeSlashTransport()
        transport.execAnswers = [.failure(useDispatch)]
        transport.dispatchAnswer = .success(SlashExecResult(type: .send, message: "Load the skill body",
                                                            display: "/work fix the leak"))
        let vm = model(transport)
        await vm.send("/work fix the leak")?.value
        #expect(transport.dispatches == [.init(sessionId: "s1", name: "work", arg: "fix the leak")])
        #expect(transport.chats.submits.map(\.text) == ["Load the skill body"])
        #expect(vm.messages.map(\.text) == ["/work fix the leak"])
        #expect(vm.messages[0].delivery == .delivered)
    }

    @Test func skillWithNoDisplayShowsTheTypedText() async {
        let transport = FakeSlashTransport()
        transport.execAnswers = [.failure(useDispatch)]
        transport.dispatchAnswer = .success(SlashExecResult(type: .skill, message: "Skill body",
                                                            notice: "Skill loaded"))
        let vm = model(transport)
        await vm.send("/work")?.value
        #expect(transport.dispatches == [.init(sessionId: "s1", name: "work", arg: nil)])
        #expect(transport.chats.submits.map(\.text) == ["Skill body"])
        #expect(vm.messages.map(\.text) == ["Skill loaded", "/work"])
        #expect(vm.messages[0].command != nil)
        #expect(vm.messages[1].role == .user)
    }

    @Test func aFailedCommandSendRetriesWithTheMessage() async {
        let transport = FakeSlashTransport()
        transport.execAnswers = [.success(SlashExecResult(type: .send, message: "Seed prompt"))]
        transport.chats.failSubmit = true
        let vm = model(transport)
        await vm.send("/prompt plan")?.value
        #expect(vm.messages.last?.delivery == .failed)
        transport.chats.failSubmit = false
        await vm.retrySend(id: vm.messages.last!.id)?.value
        #expect(transport.chats.submits.map(\.text) == ["Seed prompt", "Seed prompt"])
        #expect(vm.messages.last?.text == "/prompt plan")
    }

    @Test func prefillFillsTheComposerAndSendsNothing() async {
        let transport = FakeSlashTransport()
        transport.execAnswers = [.success(SlashExecResult(type: .prefill, message: "Draft text"))]
        let vm = model(transport)
        await vm.send("/draft")?.value
        #expect(vm.composerFill?.text == "Draft text")
        #expect(vm.composerFill?.reason == .prefill)
        #expect(transport.chats.submits.isEmpty)
        #expect(vm.messages.isEmpty)
    }

    @Test func unknownCommandFromDispatchShowsTheErrorAndKeepsTheText() async {
        let transport = FakeSlashTransport()
        transport.execAnswers = [.failure(GatewayError.rpc(code: 4018, message: "x"))]
        let vm = model(transport)
        await vm.send("/foo bar")?.value
        #expect(vm.messages.map(\.command) == [ChatCommandCard(command: "/foo", output: "Unknown command: /foo",
                                                               isError: true)])
        #expect(vm.composerFill?.text == "/foo bar")
        #expect(vm.composerFill?.reason == .restore)
        #expect(transport.chats.submits.isEmpty)
    }

    @Test func unknownCommandFromTheWorkerIsAnErrorCard() async {
        let transport = FakeSlashTransport()
        transport.execAnswers = [.success(SlashExecResult(output: "\u{1B}[1;31mUnknown command: foo\u{1B}[0m"))]
        let vm = model(transport)
        await vm.send("/foo")?.value
        #expect(vm.messages.first?.command?.output == "Unknown command: /foo")
        #expect(vm.messages.first?.command?.isError == true)
        #expect(vm.composerFill?.text == "/foo")
    }

    @Test func serverErrorShowsTheServerMessage() async {
        let transport = FakeSlashTransport()
        transport.execAnswers = [.failure(GatewayError.rpc(code: 5030, message: "slash worker timed out"))]
        let vm = model(transport)
        await vm.send("/compress")?.value
        #expect(vm.messages.first?.command == ChatCommandCard(command: "/compress", output: "slash worker timed out",
                                                             isError: true))
        #expect(vm.composerFill?.text == "/compress")
    }

    @Test func offlineCommandShowsAnErrorCard() async {
        let transport = FakeSlashTransport()
        transport.chats.failStart = true
        let vm = model(transport)
        await vm.send("/model")?.value
        #expect(vm.messages.first?.command?.output == "Hermes is not connected.")
        #expect(vm.composerFill?.text == "/model")
    }

    @Test func aliasRunsTheTarget() async {
        let transport = FakeSlashTransport()
        transport.execAnswers = [.success(SlashExecResult(type: .alias, target: "model")),
                                 .success(SlashExecResult(output: "Model: x"))]
        let vm = model(transport)
        await vm.send("/m x")?.value
        #expect(transport.execs == ["/m x", "/model x"])
        #expect(vm.messages.first?.command == ChatCommandCard(command: "/m", output: "Model: x"))
    }

    @Test func aliasToNewPushesANewChat() async {
        let transport = FakeSlashTransport()
        transport.execAnswers = [.success(SlashExecResult(type: .alias, target: "new"))]
        let vm = model(transport)
        await vm.send("/fresh")?.value
        #expect(vm.newChatRequest != nil)
    }

    @Test func aTransportWithNoSlashCallsShowsAnError() async {
        let transport = FakeChatTransport()
        let vm = model(transport)
        await vm.send("/model")?.value
        #expect(vm.messages.first?.command?.output == "Commands are not available.")
        #expect(transport.submits.isEmpty)
    }

    @Test func attachmentsAndProseStillSend() async {
        let transport = FakeSlashTransport()
        let vm = model(transport)
        await vm.send("/usr/local is full")?.value
        #expect(transport.chats.submits.map(\.text) == ["/usr/local is full"])
        #expect(transport.execs.isEmpty)
    }

    @Test func historyMergeKeepsTheCardInItsPlace() async {
        let transport = FakeSlashTransport()
        let counter = Counter()
        let vm = ChatViewModel(transport: transport, storedSessionId: "k1", redrawInterval: .seconds(60),
                               now: { Date(timeIntervalSince1970: 1_000) }, makeId: { counter.next() })
        await vm.send("/usage")?.value
        func row(_ role: String, _ text: String, _ id: Int, _ time: Double) -> TranscriptMessage {
            var message = TranscriptMessage(role: role, text: text, rowId: id)
            message.timestamp = time
            return message
        }
        transport.chats.transcript = [row("user", "before", 1, 900), row("assistant", "reply", 2, 950),
                                      row("user", "after", 3, 1_100)]
        await vm.open()
        #expect(vm.messages.map { $0.command != nil } == [false, false, true, false])
        #expect(vm.messages.last?.text == "after")
    }

    @Test func siriDoesNotSendASlashCommand() async {
        let chats = FakeChatTransport()
        let sessions = SessionListModel(transport: FakeSessionsTransport(rows: []), chatTransport: chats,
                                        cache: InMemorySessionCacheStore())
        let outcome = await SiriAsk.run(text: " /new ", sessions: sessions, timeout: .seconds(1)) { _ in true }
        #expect(outcome == .slashCommand)
        #expect(outcome.dialog == "Open the app to run slash commands.")
        #expect(chats.submits.isEmpty)
        #expect(chats.starts.isEmpty)
    }
}

@Suite(.timeLimit(.minutes(1))) struct SlashCommandWireTests {
    private func connected() async throws -> (GatewayClient, FakeGatewaySocket) {
        let socket = FakeGatewaySocket()
        let client = GatewayClient(endpoint: try GatewayEndpoint(port: 8123, token: String(repeating: "0f", count: 32)),
                                   connector: FakeGatewayConnector(socket), configuration: .init(heartbeatInterval: nil))
        async let ready = client.connect()
        socket.pushReady()
        socket.reply(to: try await socket.waitForRequest("client.capabilities"), result: "{}")
        _ = try await ready
        return (client, socket)
    }

    @Test func slashExecDispatchAndUsageParams() async throws {
        let (client, socket) = try await connected()
        let slash: any SlashCommandTransport = client
        let exec = Task { try await slash.execSlash(sessionId: "S", command: "/work fix") }
        let first = try await socket.waitForRequest("slash.exec")
        #expect(first["params"] == ["session_id": "S", "command": "/work fix"])
        socket.replyError(to: first, code: 4018, message: "skill command")
        await #expect(throws: GatewayError.rpc(code: 4018, message: "skill command")) { try await exec.value }

        async let dispatch = slash.dispatchCommand(sessionId: "S", name: "work", arg: "fix")
        let second = try await socket.waitForRequest("command.dispatch")
        #expect(second["params"] == ["session_id": "S", "name": "work", "arg": "fix"])
        socket.reply(to: second, result: #"{"type":"skill","name":"work","message":"body","display":"/work fix"}"#)
        #expect(try await dispatch == SlashExecResult(type: .skill, message: "body", display: "/work fix"))

        async let usage = slash.sessionUsage(sessionId: "S")
        let third = try await socket.waitForRequest("session.usage")
        #expect(third["params"] == ["session_id": "S"])
        socket.reply(to: third, result: #"{"calls":2,"input":10,"output":5,"total":15}"#)
        #expect(try await usage == SessionUsage(calls: 2, input: 10, output: 5, total: 15))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> String { lock.withLock { value += 1; return "c\(value)" } }
}
