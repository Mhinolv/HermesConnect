import Foundation
import Synchronization
import Testing
@testable import HermesKit

// Issue #64: rename, archive and delete of sessions. Fakes only. No test connects to a server.

private let token = String(repeating: "5e", count: 32)

/// Answers each request by its method and path, and records the requests. No network.
private final class ScriptedHTTP: HTTPDataLoading, Sendable {
    private let state = Mutex<(requests: [URLRequest], answers: [String: (Int, String)])>(([], [:]))

    /// `key` is "<METHOD> <path>", for example "PATCH /api/sessions/k1".
    func answer(_ key: String, status: Int = 200, body: String) {
        state.withLock { $0.answers[key] = (status, body) }
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }
    var keys: [String] { requests.map(Self.key) }

    /// The path stays percent-encoded, so "a%2Fb" is one id.
    private static func key(_ request: URLRequest) -> String {
        let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }
        return "\(request.httpMethod ?? "GET") \(path ?? "")"
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let key = Self.key(request)
        let answer = state.withLock { state -> (Int, String)? in
            state.requests.append(request)
            return state.answers[key]
        }
        let (status, body) = answer ?? (404, #"{"detail":"Not Found"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private func client(_ http: ScriptedHTTP) throws -> HermesRESTClient {
    HermesRESTClient(endpoint: try GatewayEndpoint(port: 8123, token: token), loader: http)
}

private func json(_ data: Data?) throws -> [String: Any] {
    let body = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

@Suite struct SessionActionsRESTTests {
    @Test func renameReadsTheSnapshotThenPatchesWithTheFence() async throws {
        let http = ScriptedHTTP()
        http.answer("GET /api/sessions/k1/mutation-snapshot",
                    body: #"{"session_id":"k1","exists":true,"runtime_revision":7,"runtime_generation":2}"#)
        http.answer("PATCH /api/sessions/k1", body: #"{"ok":true}"#)
        try await client(http).renameSession(storedSessionId: "k1", title: "Trip to Denver")

        #expect(http.keys == ["GET /api/sessions/k1/mutation-snapshot", "PATCH /api/sessions/k1"])
        let patch = http.requests[1]
        #expect(patch.value(forHTTPHeaderField: "X-Hermes-Session-Token") == token)
        #expect(patch.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try json(patch.httpBody)
        #expect(body["title"] as? String == "Trip to Denver")
        #expect(body["expected_revision"] as? Int == 7)
        #expect(body["expected_generation"] as? Int == 2)
        #expect((body["request_id"] as? String)?.count == 36)
        #expect(Set(body.keys) == ["title", "request_id", "expected_revision", "expected_generation"])
    }

    @Test func renameWithNoGenerationSendsNone() async throws {
        let http = ScriptedHTTP()
        http.answer("GET /api/sessions/k1/mutation-snapshot",
                    body: #"{"session_id":"k1","exists":true,"runtime_revision":0,"runtime_generation":null}"#)
        http.answer("PATCH /api/sessions/k1", body: #"{"ok":true}"#)
        try await client(http).renameSession(storedSessionId: "k1", title: "T")
        let body = try json(http.requests[1].httpBody)
        #expect(body["expected_generation"] == nil)
        #expect(body["expected_revision"] as? Int == 0)
    }

    @Test func renameOfAMissingSessionIsNotFoundWithNoPatch() async throws {
        let http = ScriptedHTTP()
        http.answer("GET /api/sessions/k1/mutation-snapshot",
                    body: #"{"session_id":"k1","exists":false,"runtime_revision":0,"runtime_generation":null}"#)
        await #expect(throws: HermesAPIError.notFound) {
            try await client(http).renameSession(storedSessionId: "k1", title: "T")
        }
        #expect(http.keys == ["GET /api/sessions/k1/mutation-snapshot"])
    }

    @Test func aRefusalCarriesTheServerText() async throws {
        let http = ScriptedHTTP()
        http.answer("GET /api/sessions/k1/mutation-snapshot",
                    body: #"{"session_id":"k1","exists":true,"runtime_revision":3,"runtime_generation":1}"#)
        http.answer("PATCH /api/sessions/k1", status: 409, body: #"{"detail":"revision_conflict"}"#)
        await #expect(throws: SessionActionError.refused(status: 409, detail: "revision_conflict")) {
            try await client(http).renameSession(storedSessionId: "k1", title: "T")
        }
        #expect(SessionActionError.message(for: SessionActionError.refused(status: 409, detail: "revision_conflict"))
            == "revision_conflict")
    }

    @Test func aStaleTokenStaysUnauthorized() async throws {
        let http = ScriptedHTTP()
        http.answer("GET /api/sessions/k1/mutation-snapshot", status: 401, body: #"{"detail":"Unauthorized"}"#)
        await #expect(throws: HermesAPIError.unauthorized) {
            try await client(http).renameSession(storedSessionId: "k1", title: "T")
        }
    }

    @Test func deleteSendsTheFenceInTheQuery() async throws {
        let http = ScriptedHTTP()
        http.answer("GET /api/sessions/a%2Fb/mutation-snapshot",
                    body: #"{"session_id":"a/b","exists":true,"runtime_revision":4,"runtime_generation":9}"#)
        http.answer("DELETE /api/sessions/a%2Fb", body: #"{"ok":true,"deleted_ids":["a/b"]}"#)
        try await client(http).deleteSession(storedSessionId: "a/b")
        let delete = try #require(http.requests.last)
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.absoluteString.contains("/api/sessions/a%2Fb?") == true)
        let items = query(delete)
        #expect(items["expected_revision"] == "4")
        #expect(items["expected_generation"] == "9")
        #expect(items["request_id"]?.count == 36)
    }

    /// QA #76 minor: a REST delete of an id that the server does not have is a success, like `session.delete` 4007.
    @Test func restDeleteOfAnAbsentSessionIsASuccess() async throws {
        let http = ScriptedHTTP()
        http.answer("GET /api/sessions/k1/mutation-snapshot",
                    body: #"{"session_id":"k1","exists":false,"runtime_revision":0,"runtime_generation":null}"#)
        try await client(http).deleteSession(storedSessionId: "k1")
        #expect(http.keys == ["GET /api/sessions/k1/mutation-snapshot"])
    }

    @Test func archivedQueryAsksForArchivedRowsOnly() async throws {
        let http = ScriptedHTTP()
        http.answer("GET /api/sessions", body: #"""
        {"sessions":[{"id":"k5","title":"Old trip","preview":"Done","source":"ios","started_at":1763290000,
        "message_count":4,"archived":true}],"total":12,"limit":100,"offset":0}
        """#)
        let page = try await client(http).sessions(SessionsQuery(limit: 100, order: .recent, archived: .only))
        #expect(query(http.requests[0])["archived"] == "only")
        #expect(page.total == 12)
        let item = SessionListItem(summary: page.sessions[0])
        #expect(item == SessionListItem(id: "k5", title: "Old trip", preview: "Done",
                                        startedAt: Date(timeIntervalSince1970: 1_763_290_000), messageCount: 4,
                                        source: "ios"))
        // The default query sends no `archived` item.
        #expect(SessionsQuery().queryItems.contains { $0.name == "archived" } == false)
    }
}

// MARK: LiveChatTransport

/// Builds clients on scripted sockets. No network.
private final class Sockets: @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [FakeGatewaySocket] = []

    func make(_ endpoint: GatewayEndpoint) -> GatewayClient {
        let socket = FakeGatewaySocket()
        lock.withLock { _sockets.append(socket) }
        return GatewayClient(endpoint: endpoint, connector: FakeGatewayConnector(socket),
                             configuration: .init(heartbeatInterval: nil, readyTimeout: .seconds(5)))
    }

    func first() async throws -> FakeGatewaySocket {
        for _ in 0..<500 {
            if let socket = lock.withLock({ _sockets.first }) { return socket }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FakeTimeout(what: "socket")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SessionActionsTransportTests {
    private func connected(http: ScriptedHTTP = ScriptedHTTP()) async throws -> (LiveChatTransport, FakeGatewaySocket) {
        let sockets = Sockets()
        let transport = LiveChatTransport(makeClient: sockets.make,
                                          makeREST: { HermesRESTClient(endpoint: $0, loader: http) })
        transport.setEndpoint(try GatewayEndpoint(port: 8123, token: token))
        let socket = try await sockets.first()
        socket.pushReady()
        socket.reply(to: try await socket.waitForRequest("client.capabilities"), result: "{}")
        for _ in 0..<1000 where transport.status != .ready { try await Task.sleep(for: .milliseconds(2)) }
        #expect(transport.status == .ready)
        return (transport, socket)
    }

    @Test func archiveAndUnarchiveSendTheStoredId() async throws {
        let (transport, socket) = try await connected()
        async let archived: Void = transport.setSessionArchived(storedId: "k1", archived: true)
        let request = try await socket.waitForRequest("session.archive")
        #expect(request["params"]?["session_id"]?.stringValue == "k1")
        #expect(request["params"]?["archived"]?.boolValue == true)
        socket.reply(to: request, result: #"{"archived":true,"session_key":"k1"}"#)
        try await archived

        async let unarchived: Void = transport.setSessionArchived(storedId: "k1", archived: false)
        let second = try await socket.waitForRequest("session.archive", count: 2)
        #expect(second["params"]?["archived"]?.boolValue == false)
        socket.reply(to: second, result: #"{"archived":false,"session_key":"k1"}"#)
        try await unarchived
    }

    @Test func closeSendsTheLiveId() async throws {
        let (transport, socket) = try await connected()
        async let closed: Void = transport.closeSession(liveId: "live7")
        let request = try await socket.waitForRequest("session.close")
        #expect(request["params"]?["session_id"]?.stringValue == "live7")
        socket.reply(to: request, result: #"{"closed":true,"messages":[]}"#)
        try await closed
    }

    @Test func deleteSendsTheStoredId() async throws {
        let (transport, socket) = try await connected()
        async let deleted: Void = transport.deleteSession(storedId: "k1")
        let request = try await socket.waitForRequest("session.delete")
        #expect(request["params"]?["session_id"]?.stringValue == "k1")
        socket.reply(to: request, result: #"{"deleted":"k1"}"#)
        try await deleted
    }

    @Test func deleteOfAMissingSessionIsASuccess() async throws {
        let (transport, socket) = try await connected()
        async let deleted: Void = transport.deleteSession(storedId: "k1")
        socket.replyError(to: try await socket.waitForRequest("session.delete"), code: 4007, message: "session not found")
        try await deleted
    }

    /// Live in another client of the server: the REST path deletes it, and the owner never sees 4023.
    @Test func deleteOfALiveSessionUsesTheRESTPath() async throws {
        let http = ScriptedHTTP()
        http.answer("GET /api/sessions/k1/mutation-snapshot",
                    body: #"{"session_id":"k1","exists":true,"runtime_revision":2,"runtime_generation":1}"#)
        http.answer("DELETE /api/sessions/k1", body: #"{"ok":true}"#)
        let (transport, socket) = try await connected(http: http)
        async let deleted: Void = transport.deleteSession(storedId: "k1")
        socket.replyError(to: try await socket.waitForRequest("session.delete"), code: 4023,
                          message: "cannot delete an active session")
        try await deleted
        #expect(http.keys == ["GET /api/sessions/k1/mutation-snapshot", "DELETE /api/sessions/k1"])
    }

    @Test func otherDeleteErrorsAreThrown() async throws {
        let (transport, socket) = try await connected()
        let deleted = Task { try await transport.deleteSession(storedId: "k1") }
        socket.replyError(to: try await socket.waitForRequest("session.delete"), code: 5036, message: "delete failed: disk")
        await #expect(throws: GatewayError.rpc(code: 5036, message: "delete failed: disk")) { try await deleted.value }
    }

    @Test func renameAndArchivedListUseREST() async throws {
        let http = ScriptedHTTP()
        http.answer("GET /api/sessions/k1/mutation-snapshot",
                    body: #"{"session_id":"k1","exists":true,"runtime_revision":1,"runtime_generation":1}"#)
        http.answer("PATCH /api/sessions/k1", body: #"{"ok":true}"#)
        http.answer("GET /api/sessions", body: #"{"sessions":[{"id":"k9","title":"Old"}],"total":3,"limit":1,"offset":0}"#)
        let (transport, _) = try await connected(http: http)
        try await transport.renameSession(storedId: "k1", title: "New")
        let archived = try await transport.fetchArchivedSessions(limit: 1)
        #expect(archived == ArchivedSessions(sessions: [SessionListItem(id: "k9", title: "Old")], total: 3))
        #expect(query(http.requests[2])["archived"] == "only")
        #expect(query(http.requests[2])["limit"] == "1")
    }

    @Test func noEndpointIsNotConnected() async throws {
        let transport = LiveChatTransport()
        await #expect(throws: GatewayError.notConnected) { try await transport.renameSession(storedId: "k1", title: "T") }
        await #expect(throws: GatewayError.notConnected) { try await transport.deleteSession(storedId: "k1") }
    }
}

// MARK: SessionListModel

/// A sessions transport with scripted session actions. No network.
private final class FakeActionsTransport: SessionsTransport, SessionActionsTransport, @unchecked Sendable {
    let events: AsyncStream<GatewayClientEvent>
    private let lock = NSLock()
    private var _rows: [SessionListItem]
    private var _calls: [String] = []
    var archived = ArchivedSessions(sessions: [], total: 0)
    var failure: (any Error)?
    /// The calls wait until `release()` while it is set.
    private var gate: CheckedContinuation<Void, Never>?
    private var holds = false

    init(rows: [SessionListItem]) {
        _rows = rows
        events = AsyncStream { _ in }
    }

    var rows: [SessionListItem] {
        get { lock.withLock { _rows } }
        set { lock.withLock { _rows = newValue } }
    }

    var calls: [String] { lock.withLock { _calls } }

    func hold() { lock.withLock { holds = true } }

    func release() {
        let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holds = false
            defer { self.gate = nil }
            return self.gate
        }
        gate?.resume()
    }

    private func record(_ call: String) async throws {
        lock.withLock { _calls.append(call) }
        if lock.withLock({ holds }) {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    guard holds else { return true }
                    gate = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        if let failure = lock.withLock({ failure }) { throw failure }
    }

    func fetchSessions() async throws -> [SessionListItem] { rows }
    func fetchMostRecentSessionId() async throws -> String? { nil }

    func renameSession(storedId: String, title: String) async throws { try await record("rename \(storedId) \(title)") }

    func setSessionArchived(storedId: String, archived: Bool) async throws {
        try await record(archived ? "archive \(storedId)" : "unarchive \(storedId)")
    }

    func closeSession(liveId: String) async throws { try await record("close \(liveId)") }
    func deleteSession(storedId: String) async throws { try await record("delete \(storedId)") }

    func fetchArchivedSessions(limit: Int) async throws -> ArchivedSessions {
        lock.withLock {
            ArchivedSessions(sessions: Array(archived.sessions.prefix(limit)), total: archived.total)
        }
    }
}

private struct Refused: Error {}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SessionListActionsTests {
    private let rows = [
        SessionListItem(id: "k3", title: "Newest", preview: "Latest", source: "ios"),
        SessionListItem(id: "k2", title: "Digest", preview: "3 items", source: "cron"),
        SessionListItem(id: "k1", title: "Trip", preview: "Book it", source: "photon"),
    ]

    private func model(_ transport: FakeActionsTransport, cache: InMemorySessionCacheStore? = nil,
                       chats: FakeChatTransport = FakeChatTransport()) -> SessionListModel {
        SessionListModel(transport: transport, chatTransport: chats,
                         cache: cache ?? InMemorySessionCacheStore(sessions: rows))
    }

    @Test func renameShowsAtOnceAndKeepsTheNewTitle() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let cache = InMemorySessionCacheStore(sessions: rows)
        let list = model(transport, cache: cache)
        let chat = list.chat(for: "k1")
        transport.hold()
        let task = Task { try await list.rename("k1", to: "  Denver trip \n") }
        while transport.calls.isEmpty { await Task.yield() }
        // The title shows before the server answers.
        #expect(list.session(id: "k1")?.title == "Denver trip")
        #expect(chat.title == "Denver trip")
        transport.release()
        try await task.value
        #expect(transport.calls == ["rename k1 Denver trip"])
        #expect(cache.loadSessions().first { $0.id == "k1" }?.title == "Denver trip")
    }

    @Test func aFailedRenamePutsTheOldTitleBack() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let cache = InMemorySessionCacheStore(sessions: rows)
        let list = model(transport, cache: cache)
        let chat = list.chat(for: "k1")
        transport.failure = GatewayError.rpc(code: 5007, message: "database is locked")
        await #expect(throws: GatewayError.rpc(code: 5007, message: "database is locked")) {
            try await list.rename("k1", to: "Denver trip")
        }
        #expect(list.session(id: "k1")?.title == "Trip")
        #expect(chat.title == "Trip")
        #expect(cache.loadSessions() == rows)
        #expect(SessionActionError.message(for: GatewayError.rpc(code: 5007, message: "database is locked"))
            == "database is locked")
    }

    @Test func anEmptyTitleIsRefusedWithNoCall() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let list = model(transport)
        await #expect(throws: SessionActionError.emptyTitle) { try await list.rename("k1", to: "  \n ") }
        #expect(transport.calls.isEmpty)
    }

    @Test func archiveRemovesTheRowAndCountsIt() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let cache = InMemorySessionCacheStore(sessions: rows)
        let list = model(transport, cache: cache)
        try await list.archive("k2")
        #expect(transport.calls == ["archive k2"])
        #expect(list.sessions.map(\.id) == ["k3", "k1"])
        #expect(cache.loadSessions().map(\.id) == ["k3", "k1"])
        #expect(list.archivedCount == 1)
    }

    /// QA #76 defect 1: launch and Ask Hermes must not open an archived chat.
    @Test func archiveClearsTheActiveSessionId() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let cache = InMemorySessionCacheStore(sessions: rows, activeSessionId: "k1")
        let list = model(transport, cache: cache)
        try await list.archive("k3")
        #expect(cache.loadActiveSessionId() == "k1")
        try await list.archive("k1")
        #expect(cache.loadActiveSessionId() == nil)
        #expect(list.cachedActiveSessionId == nil)
    }

    /// A failed archive keeps the active id.
    @Test func aFailedArchiveKeepsTheActiveSessionId() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let cache = InMemorySessionCacheStore(sessions: rows, activeSessionId: "k1")
        let list = model(transport, cache: cache)
        transport.failure = Refused()
        await #expect(throws: Refused.self) { try await list.archive("k1") }
        #expect(cache.loadActiveSessionId() == "k1")
    }

    @Test func aFailedArchivePutsTheRowBackInItsPlace() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let cache = InMemorySessionCacheStore(sessions: rows)
        let list = model(transport, cache: cache)
        transport.failure = Refused()
        await #expect(throws: Refused.self) { try await list.archive("k2") }
        #expect(list.sessions == rows)
        #expect(cache.loadSessions() == rows)
        #expect(list.archivedCount == 0)
    }

    /// A refresh while the archive call runs does not bring the row back.
    @Test func aRefreshDuringTheCallKeepsTheRowOut() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let list = model(transport)
        transport.hold()
        let task = Task { try await list.archive("k2") }
        while transport.calls.isEmpty { await Task.yield() }
        await list.refresh()
        #expect(list.sessions.map(\.id) == ["k3", "k1"])
        transport.rows = [rows[0], rows[2]]
        transport.release()
        try await task.value
        await list.refresh()
        #expect(list.sessions.map(\.id) == ["k3", "k1"])
    }

    @Test func deleteClosesTheLiveChatFirstThenDropsTheCache() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let chats = FakeChatTransport()
        let cache = InMemorySessionCacheStore(sessions: rows, transcripts: [
            "k1": [ChatMessage(id: "m1", role: .user, text: "Hi", date: Date(timeIntervalSince1970: 1_763_290_000), delivery: .delivered)],
            "k3": [ChatMessage(id: "m2", role: .user, text: "Hello", date: Date(timeIntervalSince1970: 1_763_290_000), delivery: .delivered)],
        ], activeSessionId: "k1")
        cache.saveDraft("half", sessionId: "k1")
        let list = model(transport, cache: cache, chats: chats)
        let chat = list.chat(for: "k1")
        await chat.open()
        #expect(chat.liveSessionId == "s2")

        try await list.delete("k1")
        #expect(transport.calls == ["close s2", "delete k1"])
        #expect(list.sessions.map(\.id) == ["k3", "k2"])
        #expect(cache.loadSessions().map(\.id) == ["k3", "k2"])
        #expect(cache.transcriptIds == ["k3"])
        #expect(cache.loadDraft(sessionId: "k1") == "")
        #expect(cache.loadActiveSessionId() == nil)
        // The chat model went away: the same id gives a new model.
        #expect(list.chat(for: "k1") !== chat)
    }

    @Test func deleteOfAChatThatIsNotLiveSkipsTheClose() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let list = model(transport)
        try await list.delete("k3")
        #expect(transport.calls == ["delete k3"])
        #expect(list.sessions.map(\.id) == ["k2", "k1"])
    }

    @Test func aFailedDeleteKeepsTheRowAndTheCache() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let cache = InMemorySessionCacheStore(sessions: rows, transcripts: ["k1": [ChatMessage(id: "m1", role: .user, text: "Hi", date: Date(timeIntervalSince1970: 1_763_290_000), delivery: .delivered)]],
                                              activeSessionId: "k1")
        let list = model(transport, cache: cache)
        let chat = list.chat(for: "k1")
        await chat.open()
        transport.failure = Refused()
        await #expect(throws: Refused.self) { try await list.delete("k1") }
        #expect(list.sessions == rows)
        #expect(cache.loadSessions() == rows)
        #expect(cache.transcriptIds == ["k1"])
        #expect(cache.loadActiveSessionId() == "k1")
        #expect(list.chat(for: "k1") === chat)
        // The live session closed. The next open resumes the stored id.
        #expect(chat.liveSessionId == nil)
    }

    @Test func archivedListLoadsUnarchivesAndDeletes() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let old = [SessionListItem(id: "a2", title: "Old 2"), SessionListItem(id: "a1", title: "Old 1")]
        transport.archived = ArchivedSessions(sessions: old, total: 2)
        let list = model(transport)
        await list.refresh()
        #expect(list.archivedCount == 2)
        #expect(!list.hasLoadedArchived)

        await list.refreshArchived()
        #expect(list.archivedSessions == old)
        #expect(list.hasLoadedArchived)

        try await list.delete("a1")
        #expect(list.archivedSessions.map(\.id) == ["a2"])
        #expect(list.archivedCount == 1)

        transport.rows = rows + [old[0]]
        transport.archived = ArchivedSessions(sessions: [], total: 0)
        try await list.unarchive("a2")
        #expect(transport.calls == ["delete a1", "unarchive a2"])
        #expect(list.archivedSessions.isEmpty)
        #expect(list.archivedCount == 0)
        #expect(list.sessions.map(\.id) == ["k3", "k2", "k1", "a2"])
    }

    @Test func aFailedUnarchivePutsTheArchivedRowBack() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let old = [SessionListItem(id: "a1", title: "Old 1")]
        transport.archived = ArchivedSessions(sessions: old, total: 1)
        let list = model(transport)
        await list.refreshArchived()
        transport.failure = Refused()
        await #expect(throws: Refused.self) { try await list.unarchive("a1") }
        #expect(list.archivedSessions == old)
        #expect(list.archivedCount == 1)
    }

    @Test func archiveAddsTheRowToALoadedArchivedList() async throws {
        let transport = FakeActionsTransport(rows: rows)
        let list = model(transport)
        await list.refreshArchived()
        try await list.archive("k1")
        #expect(list.archivedSessions.map(\.id) == ["k1"])
        #expect(list.archivedCount == 1)
    }

    @Test func aTransportWithNoActionsFailsEachAction() async throws {
        let list = SessionListModel(transport: FakeSessionsTransport(rows: rows), chatTransport: FakeChatTransport(),
                                    cache: InMemorySessionCacheStore(sessions: rows))
        await #expect(throws: SessionActionError.notSupported) { try await list.rename("k1", to: "T") }
        await #expect(throws: SessionActionError.notSupported) { try await list.archive("k1") }
        await #expect(throws: SessionActionError.notSupported) { try await list.delete("k1") }
        #expect(list.sessions == rows)
        #expect(list.archivedCount == 0)
    }

    /// #73 always hides cron runs. The filter hides other sources too.
    @Test func theFilterHidesSources() async throws {
        let list = model(FakeActionsTransport(rows: rows))
        #expect(list.filtered("").map(\.id) == ["k3", "k1"])
        list.filter = SessionListFilter(hiddenSources: ["photon"])
        #expect(list.filtered("").map(\.id) == ["k3"])
        #expect(list.filtered("Trip").map(\.id) == [])
    }
}

// MARK: Cache

@Suite struct SessionCacheRemoveTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "session-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func removeDropsTheTranscriptTheDraftAndTheActiveId() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionCacheStore(directory: directory)
        store.saveTranscript([ChatMessage(id: "m1", role: .user, text: "Hi", date: Date(timeIntervalSince1970: 1_763_290_000), delivery: .delivered)], sessionId: "k1")
        store.saveTranscript([ChatMessage(id: "m2", role: .user, text: "Yo", date: Date(timeIntervalSince1970: 1_763_290_000), delivery: .delivered)], sessionId: "k2")
        store.saveDraft("half", sessionId: "k1")
        store.saveDraft("other", sessionId: "k2")
        store.saveActiveSessionId("k1")

        store.removeSession(sessionId: "k1")
        #expect(!FileManager.default.fileExists(atPath: store.transcriptURL(sessionId: "k1").path))
        #expect(store.loadTranscript(sessionId: "k1").isEmpty)
        #expect(store.loadTranscript(sessionId: "k2").map(\.id) == ["m2"])
        #expect(store.loadDraft(sessionId: "k1") == "")
        #expect(store.loadDraft(sessionId: "k2") == "other")
        #expect(store.loadActiveSessionId() == nil)

        // Another session keeps the active id. A second remove does nothing.
        store.saveActiveSessionId("k2")
        store.removeSession(sessionId: "k1")
        #expect(store.loadActiveSessionId() == "k2")
    }

    /// Caches saved before issue #64 (version 4 and 5 files) still load, and a delete still drops their files.
    @Test(arguments: [4, 5])
    func olderCachesStillLoadAndDrop(version: Int) throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionCacheStore(directory: directory)
        try FileManager.default.createDirectory(at: store.transcriptURL(sessionId: "k1").deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"version":\#(version),"body":[{"id":"k1","title":"Trip"},{"id":"k2","title":"Plan","isUnread":true}]}"#.utf8)
            .write(to: store.sessionsURL)
        try Data(#"{"version":\#(version),"body":{"activeSessionId":"k1","drafts":{"k1":"half"}}}"#.utf8).write(to: store.stateURL)
        try Data(#"{"version":\#(version),"body":[{"id":"m1","role":"user","text":"Hi","date":1763290000}]}"#.utf8)
            .write(to: store.transcriptURL(sessionId: "k1"))

        #expect(store.loadSessions().map(\.id) == ["k1", "k2"])
        #expect(store.loadTranscript(sessionId: "k1").map(\.id) == ["m1"])
        #expect(store.loadDraft(sessionId: "k1") == "half")

        store.removeSession(sessionId: "k1")
        store.saveSessions(store.loadSessions().filter { $0.id != "k1" })
        let reopened = FileSessionCacheStore(directory: directory)
        #expect(reopened.loadSessions() == [SessionListItem(id: "k2", title: "Plan", isUnread: true)])
        #expect(reopened.loadTranscript(sessionId: "k1").isEmpty)
        #expect(reopened.loadDraft(sessionId: "k1") == "")
        #expect(reopened.loadActiveSessionId() == nil)
    }
}
