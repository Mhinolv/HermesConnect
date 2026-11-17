import Foundation
import Testing
@testable import HermesKit

// Issue #68: slash command suggestions while the owner types. No network: fake transports and sockets.

private let ready = GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef")
private let server = "hermes@vps.example:22"

private let serverCatalog = [
    SlashCatalogEntry(name: "model", aliases: ["m"], summary: "Switch the model"),
    SlashCatalogEntry(name: "help", summary: "Show the commands"),
    SlashCatalogEntry(name: "compress", summary: "Compress the context"),
    SlashCatalogEntry(name: "skills", summary: "Manage skills"),
    SlashCatalogEntry(name: "summarize", aliases: ["tldr"], summary: "Summarize this chat"),
]

/// A slash completion transport with scripted answers. It records each call.
final class FakeSlashCompletionTransport: SlashCompletionTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<GatewayClientEvent>.Continuation
    let events: AsyncStream<GatewayClientEvent>
    private var _catalogCalls = 0
    private var _completeTexts: [String] = []
    /// The answer of `commands.catalog`. The default is `serverCatalog`.
    var catalogAnswer: Result<CommandsCatalogResult, any Error> = .success(CommandsCatalogResult(
        pairs: serverCatalog.map { ["/" + $0.name, $0.summary] }, canon: ["/m": "/model", "/tldr": "/summarize"]))
    /// The answer of `complete.slash` for each text. A missing text fails as not connected.
    var completeAnswers: [String: SlashCompletionResult] = [:]

    init() {
        (events, continuation) = AsyncStream.makeStream(of: GatewayClientEvent.self)
    }

    var catalogCalls: Int { lock.withLock { _catalogCalls } }
    var completeTexts: [String] { lock.withLock { _completeTexts } }

    func send(_ item: GatewayClientEvent) { continuation.yield(item) }

    func commandsCatalog() async throws -> CommandsCatalogResult {
        let answer = lock.withLock {
            _catalogCalls += 1
            return catalogAnswer
        }
        return try answer.get()
    }

    func completeSlash(text: String) async throws -> SlashCompletionResult {
        let answer = lock.withLock {
            _completeTexts.append(text)
            return completeAnswers[text]
        }
        guard let answer else { throw GatewayError.notConnected }
        return answer
    }
}

@Suite struct SlashSuggestionFilterTests {
    @Test func thePanelShowsOnlyForASlashFirstAndNoNewline() {
        #expect(SlashSuggestionFilter.showsPanel(for: "/"))
        #expect(SlashSuggestionFilter.showsPanel(for: "/model gpt"))
        #expect(!SlashSuggestionFilter.showsPanel(for: ""))
        #expect(!SlashSuggestionFilter.showsPanel(for: " /model"))
        #expect(!SlashSuggestionFilter.showsPanel(for: "run /model"))
        #expect(!SlashSuggestionFilter.showsPanel(for: "/goal fix\nthen test"))
        #expect(SlashSuggestionFilter.commandQuery("/") == "")
        #expect(SlashSuggestionFilter.commandQuery("/Mo") == "Mo")
        #expect(SlashSuggestionFilter.commandQuery("/model ") == nil)
        #expect(SlashSuggestionFilter.commandQuery("hello") == nil)
    }

    @Test func rowsArePrefixMatchesThenContainsMatchesOnNamesAndAliases() {
        let catalog = SlashSuggestionFilter.merged(server: serverCatalog)
        // "s": skills and summarize start with it. "new" (alias "reset"), "usage" and "compress" contain it.
        let titles = SlashSuggestionFilter.rows(for: "s", in: catalog).map(\.title)
        #expect(titles == ["/skills", "/summarize", "/new", "/usage", "/compress"])
        // An alias match shows the command, after the name matches.
        #expect(SlashSuggestionFilter.rows(for: "tl", in: catalog).map(\.title) == ["/summarize"])
        #expect(SlashSuggestionFilter.rows(for: "m", in: catalog).map(\.title)
            == ["/model", "/compress", "/summarize"])
        #expect(SlashSuggestionFilter.rows(for: "MOD", in: catalog).first
            == SlashSuggestion(text: "/model", title: "/model", detail: "Switch the model"))
        #expect(SlashSuggestionFilter.rows(for: "zz", in: catalog).isEmpty)
    }

    @Test func aBareSlashListsTheCatalogInOrderUpToTheLimit() {
        let catalog = SlashSuggestionFilter.merged(server: serverCatalog)
        #expect(SlashSuggestionFilter.rows(for: "", in: catalog).map(\.title)
            == ["/new", "/usage", "/model", "/help", "/compress", "/skills", "/summarize"])
        let many = (0..<80).map { SlashCatalogEntry(name: "c\($0)") }
        #expect(SlashSuggestionFilter.rows(for: "", in: many).count == SlashSuggestionFilter.maxLocalRows)
    }

    @Test func localCommandsWinOverServerRowsOfTheSameNameOrAlias() {
        let server = [SlashCatalogEntry(name: "new", summary: "Server new"),
                      SlashCatalogEntry(name: "reset", summary: "Server reset"),
                      SlashCatalogEntry(name: "model", summary: "Switch the model")]
        let merged = SlashSuggestionFilter.merged(server: server)
        #expect(merged.map(\.name) == ["new", "usage", "model"])
        #expect(merged[0].summary == "Start a new chat")
        #expect(merged[0].aliases == ["reset", "clear"])
    }

    @Test func theCatalogResultGivesNamesAliasesAndDescriptions() {
        let result = CommandsCatalogResult(
            pairs: [["/model", "Switch the model"], ["/help", " Show the commands "], ["/model", "Again"], ["/"],
                    ["/plan", ""], ["/bad name", "x"], ["/solo"]],
            canon: ["/m": "/model", "/model": "/model", "/mdl": "/model", "/?": "/help"])
        #expect(SlashSuggestionFilter.entries(from: result) == [
            SlashCatalogEntry(name: "model", aliases: ["m", "mdl"], summary: "Switch the model"),
            SlashCatalogEntry(name: "help", aliases: ["?"], summary: "Show the commands"),
            SlashCatalogEntry(name: "plan", summary: ""),
            SlashCatalogEntry(name: "solo", summary: ""),
        ])
    }

    @Test func theCatalogDecodesTolerantly() throws {
        let json = #"""
        {"pairs":[["/model","Switch the model"],["/skill-a","A skill"],[1,2],"bad",[]],
         "canon":{"/m":"/model"},"sub":{},"commands":{},"categories":[],"skills":{},"skill_count":1,
         "warning":"","plugin_commands":{}}
        """#
        let result = try JSONDecoder().decode(CommandsCatalogResult.self, from: Data(json.utf8))
        #expect(result.pairs == [["/model", "Switch the model"], ["/skill-a", "A skill"]])
        #expect(result.canon == ["/m": "/model"])
        let empty = try JSONDecoder().decode(CommandsCatalogResult.self, from: Data("{}".utf8))
        #expect(empty == CommandsCatalogResult())
    }

    @Test func theCompletionDecodesTolerantly() throws {
        let json = #"""
        {"items":[{"text":"/model","display":"/model","meta":"Switch the model","kind":"command"},
                  {"display":"no text"},{"text":"/help"}],"replace_from":1}
        """#
        let result = try JSONDecoder().decode(SlashCompletionResult.self, from: Data(json.utf8))
        #expect(result.items == [SlashCompletionItem(text: "/model", display: "/model", meta: "Switch the model"),
                                 SlashCompletionItem(text: "/help")])
        #expect(result.replaceFrom == 1)
        let bare = try JSONDecoder().decode(SlashCompletionResult.self, from: Data(#"{"items":[]}"#.utf8))
        #expect(bare.replaceFrom == nil && bare.items.isEmpty)
    }

    @Test func serverRowsKeepServerOrderAndTakeTheCatalogDescriptionWhenMetaIsEmpty() {
        let result = SlashCompletionResult(items: [
            SlashCompletionItem(text: "/summarize", display: "/summarize", meta: ""),
            SlashCompletionItem(text: "/model", display: "", meta: "Pick a model"),
            SlashCompletionItem(text: "/model", display: "/model", meta: "dup"),
            SlashCompletionItem(text: "/tldr"),
            SlashCompletionItem(text: ""),
        ], replaceFrom: 1)
        let rows = SlashSuggestionFilter.rows(for: result, catalog: serverCatalog)
        #expect(rows == [
            SlashSuggestion(text: "/summarize", title: "/summarize", detail: "Summarize this chat"),
            SlashSuggestion(text: "/model", title: "/model", detail: "Pick a model"),
            SlashSuggestion(text: "/tldr", title: "/tldr", detail: "Summarize this chat"),
        ])
    }

    @Test func aTapReplacesFromReplaceFromAndAddsOneSpace() {
        let command = SlashSuggestion(text: "/model", title: "/model", detail: "")
        // Command rows replace the whole token, also when the server says column 1.
        #expect(SlashSuggestionFilter.apply(command, to: "/mo", replaceFrom: 1) == "/model ")
        #expect(SlashSuggestionFilter.apply(command, to: "/mo", replaceFrom: 0) == "/model ")
        // An argument row keeps the text before `replace_from`.
        let arg = SlashSuggestion(text: "gpt-5", title: "gpt-5", detail: "")
        #expect(SlashSuggestionFilter.apply(arg, to: "/model gp", replaceFrom: 7) == "/model gpt-5 ")
        // Columns count Unicode scalars, as in Python. An out-of-range column is clamped.
        #expect(SlashSuggestionFilter.apply(arg, to: "/n é", replaceFrom: 3) == "/n gpt-5 ")
        #expect(SlashSuggestionFilter.apply(arg, to: "/x", replaceFrom: 99) == "/xgpt-5 ")
    }

    @Test func theRowLabelIsTheCommandThenTheDescription() {
        #expect(SlashSuggestion(text: "/model", title: "/model", detail: "Switch the model").accessibilityLabel
            == "/model, Switch the model")
        #expect(SlashSuggestion(text: "/x", title: "/x", detail: "").accessibilityLabel == "/x")
    }
}

@Suite struct SlashCatalogCacheTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "slash-cache-\(UUID().uuidString)",
                                                         directoryHint: .isDirectory)
    }

    @Test func eachServerKeepsItsOwnCatalogOnDisk() {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSlashCatalogCacheStore(directory: directory)
        #expect(store.load(server: server) == nil)
        store.save(serverCatalog, server: server)
        store.save([SlashCatalogEntry(name: "other")], server: "hermes@other:22")

        let reopened = FileSlashCatalogCacheStore(directory: directory)
        #expect(reopened.load(server: server) == serverCatalog)
        #expect(reopened.load(server: "hermes@other:22") == [SlashCatalogEntry(name: "other")])
        #expect(ProtectedStorage.isExcludedFromBackup(directory))
        #expect(reopened.fileURL.lastPathComponent == "slash-commands.json")
    }

    @Test func theFileHoldsOnlyNamesAliasesAndDescriptions() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSlashCatalogCacheStore(directory: directory)
        store.save([SlashCatalogEntry(name: "model", aliases: ["m"], summary: "Switch the model")], server: server)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL))
        let json = try #require(object as? [String: Any])
        #expect(Set(json.keys) == ["version", "servers", "order"])
        let servers = try #require(json["servers"] as? [String: [[String: Any]]])
        let entry = try #require(servers[server]?.first)
        #expect(Set(entry.keys) == ["name", "aliases", "summary"])
    }

    @Test func aBrokenFileOrBadEntryLoadsAsMuchAsItCan() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileSlashCatalogCacheStore(directory: directory)
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.load(server: server) == nil)
        let json = #"{"servers":{"\#(server)":[{"name":"model"},{"summary":"no name"},{"name":""},"bad"]},"future":1}"#
        try Data(json.utf8).write(to: store.fileURL)
        #expect(store.load(server: server) == [SlashCatalogEntry(name: "model")])
        // A save after a broken file writes a good file.
        store.save(serverCatalog, server: server)
        #expect(FileSlashCatalogCacheStore(directory: directory).load(server: server) == serverCatalog)
    }

    @Test func theFileKeepsTheServersSavedLast() {
        var body = SlashCatalogCacheBody()
        for index in 0..<(SlashCatalogCacheBody.maxServers + 2) {
            body.put([SlashCatalogEntry(name: "c")], server: "s\(index)")
        }
        body.put([SlashCatalogEntry(name: "c")], server: "s3")
        #expect(body.servers.count == SlashCatalogCacheBody.maxServers)
        #expect(body.servers["s0"] == nil && body.servers["s1"] == nil)
        #expect(body.order.last == "s3")
    }

    @Test func theServerKeyNamesUserHostAndPort() {
        #expect(SlashCatalogServerKey.make(ServerProfile(host: " VPS.Example ", port: 2222)) == "hermes@vps.example:2222")
        #expect(SlashCatalogServerKey.make(ServerProfile(host: "a")) != SlashCatalogServerKey.make(ServerProfile(host: "b")))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SlashSuggestionModelTests {
    private func model(_ transport: FakeSlashCompletionTransport?, cache: InMemorySlashCatalogCacheStore =
                           InMemorySlashCatalogCacheStore(), key: String? = server) -> SlashSuggestionModel {
        let model = SlashSuggestionModel(transport: transport, cache: cache, serverKey: { key },
                                         debounce: .milliseconds(20))
        model.start()
        return model
    }

    private static let catalogResult = CommandsCatalogResult(
        pairs: serverCatalog.map { ["/" + $0.name, $0.summary] },
        canon: ["/m": "/model", "/tldr": "/summarize"])

    @Test func aConnectLoadsTheCatalogAndSavesItForTheServer() async throws {
        let transport = FakeSlashCompletionTransport()
        transport.catalogAnswer = .success(Self.catalogResult)
        let cache = InMemorySlashCatalogCacheStore()
        let suggestions = model(transport, cache: cache)
        #expect(!suggestions.hasCatalog)
        transport.send(.state(.connected(ready)))
        try await waitUntil { suggestions.hasCatalog }
        #expect(transport.catalogCalls == 1)
        #expect(cache.load(server: server) == serverCatalog)
        #expect(cache.load(server: "hermes@other:22") == nil)
    }

    @Test func skillsChangedLoadsTheCatalogAgain() async throws {
        let transport = FakeSlashCompletionTransport()
        transport.catalogAnswer = .success(Self.catalogResult)
        let suggestions = model(transport)
        transport.send(.state(.connected(ready)))
        try await waitUntil { suggestions.hasCatalog }
        transport.catalogAnswer = .success(CommandsCatalogResult(pairs: [["/deploy", "Deploy the site"]]))
        transport.send(.event(GatewayEvent(type: "skills.changed", kind: .other(nil))))
        try await waitUntil { transport.catalogCalls == 2 }
        suggestions.update(text: "/dep")
        try await waitUntil { suggestions.state.rows.map(\.title) == ["/deploy"] }
        // Another event type does not load it.
        transport.send(.event(GatewayEvent(type: "sessions.changed", kind: .sessionsChanged)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.catalogCalls == 2)
    }

    @Test func eachKeyFiltersAtOnceThenCompleteSlashReplacesTheRows() async throws {
        let transport = FakeSlashCompletionTransport()
        let cache = InMemorySlashCatalogCacheStore(servers: [server: serverCatalog])
        transport.completeAnswers["/s"] = SlashCompletionResult(items: [
            SlashCompletionItem(text: "/summarize", display: "/summarize", meta: "Summarize this chat"),
            SlashCompletionItem(text: "/skills", display: "/skills", meta: "Manage skills"),
        ], replaceFrom: 1)
        let suggestions = model(transport, cache: cache)
        transport.send(.state(.connected(ready)))
        try await waitUntil { transport.catalogCalls == 1 }

        suggestions.update(text: "/s")
        // At once, from the cached catalog. No server call yet.
        #expect(suggestions.state.rows.map(\.title) == ["/skills", "/summarize", "/new", "/usage", "/compress"])
        #expect(transport.completeTexts.isEmpty)
        // After the pause, the server rows in server order.
        try await waitUntil { suggestions.state.rows.map(\.title) == ["/summarize", "/skills"] }
        #expect(transport.completeTexts == ["/s"])
        #expect(suggestions.state == .rows(suggestions.state.rows, replaceFrom: 1))
        #expect(suggestions.accept(suggestions.state.rows[0], in: "/s") == "/summarize ")
    }

    @Test func fastKeysSendOneCallForTheLastText() async throws {
        let transport = FakeSlashCompletionTransport()
        let suggestions = model(transport, cache: InMemorySlashCatalogCacheStore(servers: [server: serverCatalog]))
        transport.send(.state(.connected(ready)))
        try await waitUntil { transport.catalogCalls == 1 }
        transport.completeAnswers["/mod"] = SlashCompletionResult(
            items: [SlashCompletionItem(text: "/model", display: "/model", meta: "Switch the model")], replaceFrom: 1)
        suggestions.update(text: "/m")
        suggestions.update(text: "/mo")
        suggestions.update(text: "/mod")
        try await waitUntil { transport.completeTexts == ["/mod"] }
        try await Task.sleep(for: .milliseconds(60))
        #expect(transport.completeTexts == ["/mod"])
        #expect(suggestions.state.rows.map(\.title) == ["/model"])
    }

    @Test func anAnswerForOldTextIsDropped() async throws {
        let transport = FakeSlashCompletionTransport()
        let suggestions = model(transport, cache: InMemorySlashCatalogCacheStore(servers: [server: serverCatalog]))
        transport.send(.state(.connected(ready)))
        try await waitUntil { transport.catalogCalls == 1 }
        transport.completeAnswers["/h"] = SlashCompletionResult(
            items: [SlashCompletionItem(text: "/help", display: "/help", meta: "Show the commands")], replaceFrom: 1)
        suggestions.update(text: "/h")
        try await waitUntil { transport.completeTexts == ["/h"] }
        suggestions.update(text: "hello")
        try await Task.sleep(for: .milliseconds(60))
        #expect(suggestions.state == .hidden)
    }

    @Test func offlineUsesTheCachedCatalogAndNoServerCall() async throws {
        let transport = FakeSlashCompletionTransport()
        let suggestions = model(transport, cache: InMemorySlashCatalogCacheStore(servers: [server: serverCatalog]))
        #expect(suggestions.hasCatalog)
        suggestions.update(text: "/mo")
        #expect(suggestions.state.rows.map(\.title) == ["/model"])
        suggestions.update(text: "/zz")
        #expect(suggestions.state == .noMatch)
        // An argument has no local rows, and there is no server call.
        suggestions.update(text: "/model g")
        #expect(suggestions.state == .hidden)
        try await Task.sleep(for: .milliseconds(60))
        #expect(transport.completeTexts.isEmpty)
        #expect(transport.catalogCalls == 0)
    }

    @Test func offlineWithNoCacheShowsTheLocalCommandsOnly() {
        let suggestions = model(FakeSlashCompletionTransport())
        suggestions.update(text: "/")
        #expect(suggestions.state.rows.map(\.title) == ["/new", "/usage"])
        suggestions.update(text: "/mod")
        #expect(suggestions.state == .noMatch)
        let none = model(nil)
        none.update(text: "/u")
        #expect(none.state.rows.map(\.title) == ["/usage"])
    }

    @Test func connectedWithNoCatalogYetShowsLoadingUntilTheCatalogComes() async throws {
        let transport = FakeSlashCompletionTransport()
        transport.catalogAnswer = .failure(GatewayError.timeout(method: "commands.catalog"))
        let suggestions = model(transport)
        transport.send(.state(.connected(ready)))
        try await waitUntil { transport.catalogCalls == 1 }
        suggestions.update(text: "/mod")
        #expect(suggestions.state == .loading)
        // A local match shows at once, also with no catalog.
        suggestions.update(text: "/new")
        #expect(suggestions.state.rows.map(\.title) == ["/new"])
        suggestions.update(text: "/mod")
        transport.catalogAnswer = .success(Self.catalogResult)
        transport.send(.event(GatewayEvent(type: "skills.changed", kind: .other(nil))))
        try await waitUntil { suggestions.state.rows.map(\.title) == ["/model"] }
    }

    @Test func aFailedCallOrAnEmptyAnswerEndsTheLoadingRow() async throws {
        let transport = FakeSlashCompletionTransport()
        transport.catalogAnswer = .failure(GatewayError.notConnected)
        let suggestions = model(transport)
        transport.send(.state(.connected(ready)))
        try await waitUntil { transport.catalogCalls == 1 }
        suggestions.update(text: "/zz")
        #expect(suggestions.state == .loading)
        try await waitUntil { suggestions.state == .noMatch }
        transport.completeAnswers["/qq"] = SlashCompletionResult(items: [], replaceFrom: 1)
        suggestions.update(text: "/qq")
        try await waitUntil { transport.completeTexts.contains("/qq") }
        try await waitUntil { suggestions.state == .noMatch }
    }

    @Test func afterASpaceNoItemsHideThePanelAndArgumentItemsShow() async throws {
        let transport = FakeSlashCompletionTransport()
        let suggestions = model(transport, cache: InMemorySlashCatalogCacheStore(servers: [server: serverCatalog]))
        transport.send(.state(.connected(ready)))
        try await waitUntil { transport.catalogCalls == 1 }
        suggestions.update(text: "/mo")
        let tapped = suggestions.accept(suggestions.state.rows[0], in: "/mo")
        #expect(tapped == "/model ")
        transport.completeAnswers["/model "] = SlashCompletionResult(items: [
            SlashCompletionItem(text: "gpt-5", display: "gpt-5", meta: "OpenAI"),
        ], replaceFrom: 7)
        transport.completeAnswers["/help "] = SlashCompletionResult(items: [], replaceFrom: 6)
        suggestions.update(text: tapped)
        // The command row stays until the server answers.
        #expect(suggestions.state.rows.map(\.title) == ["/model"])
        try await waitUntil { suggestions.state.rows.map(\.title) == ["gpt-5"] }
        #expect(suggestions.accept(suggestions.state.rows[0], in: "/model ") == "/model gpt-5 ")

        suggestions.update(text: "/help ")
        try await waitUntil { suggestions.state == .hidden }
    }

    @Test func textWithNoSlashOrANewlineOrAHideHidesThePanel() async throws {
        let suggestions = model(FakeSlashCompletionTransport(),
                                cache: InMemorySlashCatalogCacheStore(servers: [server: serverCatalog]))
        suggestions.update(text: "/")
        #expect(suggestions.state.isShown)
        suggestions.update(text: "")
        #expect(suggestions.state == .hidden)
        suggestions.update(text: "/model\nmore")
        #expect(suggestions.state == .hidden)
        suggestions.update(text: "hello /model")
        #expect(suggestions.state == .hidden)
        suggestions.update(text: "/he")
        #expect(suggestions.state.isShown)
        suggestions.hide()
        #expect(suggestions.state == .hidden)
        suggestions.update(text: "/he")
        #expect(suggestions.state.rows.map(\.title) == ["/help"])
    }

    @Test func anotherServerUsesItsOwnCache() {
        var key = server
        let cache = InMemorySlashCatalogCacheStore(servers: [server: serverCatalog,
                                                             "hermes@other:22": [SlashCatalogEntry(name: "deploy")]])
        let suggestions = SlashSuggestionModel(transport: nil, cache: cache, serverKey: { key })
        suggestions.update(text: "/mo")
        #expect(suggestions.state.rows.map(\.title) == ["/model"])
        key = "hermes@other:22"
        suggestions.update(text: "/de")
        #expect(suggestions.state.rows.map(\.title) == ["/deploy"])
        suggestions.update(text: "/mo")
        #expect(suggestions.state == .noMatch)
    }
}

// MARK: Wire

/// Builds clients on scripted sockets. No network.
private final class SlashSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [FakeGatewaySocket] = []

    func make(_ endpoint: GatewayEndpoint) -> GatewayClient {
        let socket = FakeGatewaySocket()
        lock.withLock { sockets.append(socket) }
        return GatewayClient(endpoint: endpoint, connector: FakeGatewayConnector(socket),
                             configuration: .init(heartbeatInterval: nil, readyTimeout: .seconds(5)))
    }

    func first() async throws -> FakeGatewaySocket {
        for _ in 0..<500 {
            if let socket = lock.withLock({ sockets.first }) { return socket }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FakeTimeout(what: "socket")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SlashCompletionWireTests {
    private func connected() async throws -> (LiveChatTransport, FakeGatewaySocket) {
        let sockets = SlashSockets()
        let transport = LiveChatTransport(makeClient: sockets.make)
        transport.setEndpoint(try GatewayEndpoint(port: 8123, token: String(repeating: "5e", count: 32)))
        let socket = try await sockets.first()
        socket.pushReady()
        socket.reply(to: try await socket.waitForRequest("client.capabilities"), result: "{}")
        for _ in 0..<1000 where transport.status != .ready { try await Task.sleep(for: .milliseconds(2)) }
        #expect(transport.status == .ready)
        return (transport, socket)
    }

    @Test func theCatalogCallSendsNoSessionAndDecodesTheAnswer() async throws {
        let (transport, socket) = try await connected()
        async let result = transport.commandsCatalog()
        let request = try await socket.waitForRequest("commands.catalog")
        #expect(request["params"] == .object([:]))
        socket.reply(to: request, result: #"{"pairs":[["/model","Switch the model"]],"canon":{"/m":"/model"}}"#)
        #expect(try await result == CommandsCatalogResult(pairs: [["/model", "Switch the model"]],
                                                          canon: ["/m": "/model"]))
    }

    @Test func theCompleteCallSendsTheTextAndDecodesTheAnswer() async throws {
        let (transport, socket) = try await connected()
        async let result = transport.completeSlash(text: "/mo")
        let request = try await socket.waitForRequest("complete.slash")
        #expect(request["params"] == .object(["text": .string("/mo")]))
        socket.reply(to: request, result: #"{"items":[{"text":"/model","display":"/model","meta":"Switch"}],"replace_from":1}"#)
        #expect(try await result == SlashCompletionResult(
            items: [SlashCompletionItem(text: "/model", display: "/model", meta: "Switch")], replaceFrom: 1))
    }

    @Test func theModelLoadsTheCatalogFromTheLiveLinkOnConnect() async throws {
        let sockets = SlashSockets()
        let transport = LiveChatTransport(makeClient: sockets.make)
        let cache = InMemorySlashCatalogCacheStore()
        let suggestions = SlashSuggestionModel(transport: transport, cache: cache, serverKey: { server })
        suggestions.start()
        transport.setEndpoint(try GatewayEndpoint(port: 8123, token: String(repeating: "5e", count: 32)))
        let socket = try await sockets.first()
        socket.pushReady()
        socket.reply(to: try await socket.waitForRequest("client.capabilities"), result: "{}")
        let request = try await socket.waitForRequest("commands.catalog")
        socket.reply(to: request, result: #"{"pairs":[["/model","Switch the model"]],"canon":{}}"#)
        try await waitUntil { suggestions.hasCatalog }
        #expect(cache.load(server: server) == [SlashCatalogEntry(name: "model", summary: "Switch the model")])
        // `skills.changed` from the server loads it again.
        socket.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"skills.changed","payload":{}}}"#)
        let second = try await socket.waitForRequest("commands.catalog", count: 2)
        socket.reply(to: second, result: #"{"pairs":[["/deploy","Deploy"]],"canon":{}}"#)
        try await waitUntil { cache.load(server: server)?.first?.name == "deploy" }
    }
}

/// Polls the main actor until `condition` holds. Fails after 2 s.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met")
}
