import Foundation
import Synchronization
import Testing
@testable import HermesKit

// Issue #94: "Mark All as Read" on the Chats list. Fakes only. No test connects to a server.

/// A sessions transport that records `PATCH unread` calls. Ids in `failures` throw their error. No network.
private final class ReadFakeTransport: SessionsTransport, SessionActionsTransport, Sendable {
    private struct State {
        var rows: [SessionListItem]
        var calls: [String] = []
        var failures: [String: any Error] = [:]
    }

    private let state: Mutex<State>
    let events: AsyncStream<GatewayClientEvent>
    let continuation: AsyncStream<GatewayClientEvent>.Continuation

    init(rows: [SessionListItem]) {
        state = Mutex(State(rows: rows))
        (events, continuation) = AsyncStream.makeStream()
    }

    var rows: [SessionListItem] {
        get { state.withLock { $0.rows } }
        set { state.withLock { $0.rows = newValue } }
    }

    var calls: [String] { state.withLock { $0.calls } }

    func fail(_ id: String, with error: (any Error)?) { state.withLock { $0.failures[id] = error } }

    func fetchSessions() async throws -> [SessionListItem] { rows }
    func fetchMostRecentSessionId() async throws -> String? { nil }

    func setSessionUnread(storedId: String, unread: Bool) async throws {
        let failure = state.withLock { state -> (any Error)? in
            state.calls.append("unread \(storedId) \(unread)")
            return state.failures[storedId]
        }
        if let failure { throw failure }
    }

    func renameSession(storedId _: String, title _: String) async throws {}
    func setSessionArchived(storedId _: String, archived _: Bool) async throws {}
    func closeSession(liveId _: String) async throws {}
    func deleteSession(storedId _: String) async throws {}
    func fetchArchivedSessions(limit _: Int) async throws -> ArchivedSessions { ArchivedSessions(sessions: [], total: 0) }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct MarkAllReadTests {
    /// Two unread chats, one read chat and one unread cron run.
    private let rows = [
        SessionListItem(id: "c3", title: "Trip", preview: "Book it", messageCount: 4, source: "ios", isUnread: true),
        SessionListItem(id: "cron_j1_1", title: "Digest", preview: "3 items", messageCount: 2, source: "cron",
                        isUnread: true),
        SessionListItem(id: "c2", title: "Dinner", preview: "7:30 PM", messageCount: 8, source: "photon",
                        isUnread: true),
        SessionListItem(id: "c1", title: "Logs", preview: "journalctl", messageCount: 6, source: "desktop"),
    ]

    private func freshRows() -> [SessionListItem] {
        rows.map { row in
            var row = row
            row.isUnread = false
            return row
        }
    }

    private func model(_ transport: ReadFakeTransport, cache: InMemorySessionCacheStore) -> SessionListModel {
        SessionListModel(transport: transport, chatTransport: FakeChatTransport(), cache: cache)
    }

    @Test func clearsEveryChatRowAlsoRowsThatTheSearchHides() async {
        let transport = ReadFakeTransport(rows: freshRows())
        let cache = InMemorySessionCacheStore(sessions: rows)
        let list = model(transport, cache: cache)
        #expect(list.filtered("Trip").map(\.id) == ["c3"])
        #expect(list.canMarkAllRead)
        #expect(list.markAllRead() == 2)
        #expect(list.chatRows.allSatisfy { !$0.isUnread })
        #expect(list.chatsUnreadCount == 0)
        #expect(!list.canMarkAllRead)
        // The cron run keeps its dot: the Jobs tab and its badge do not change.
        #expect(list.unreadCronRuns.map(\.id) == ["cron_j1_1"])
        #expect(list.unreadCount == 1)
        // The cache keeps the read state for the next launch.
        #expect(cache.loadSessions().filter(\.isUnread).map(\.id) == ["cron_j1_1"])
    }

    @Test func sendsUnreadFalseForEachClearedChatOnly() async {
        let transport = ReadFakeTransport(rows: freshRows())
        let list = model(transport, cache: InMemorySessionCacheStore(sessions: rows))
        list.markAllRead()
        await list.syncReadState()
        #expect(transport.calls == ["unread c3 false", "unread c2 false"])
        #expect(list.pendingReadSyncIds.isEmpty)
    }

    @Test func isOffWithNoUnreadChatAndOnTheFirstLoad() async {
        // Only a cron run is unread.
        let cronOnly = [rows[1], rows[3]]
        let transport = ReadFakeTransport(rows: cronOnly)
        let list = model(transport, cache: InMemorySessionCacheStore(sessions: cronOnly))
        #expect(!list.canMarkAllRead)
        #expect(list.markAllRead() == 0)
        await list.syncReadState()
        #expect(transport.calls.isEmpty)
        #expect(list.unreadCronRuns.count == 1)
        // No cache: the redacted rows show until the first answer.
        let empty = model(ReadFakeTransport(rows: rows), cache: InMemorySessionCacheStore())
        #expect(!empty.hasLoaded)
        #expect(!empty.canMarkAllRead)
    }

    @Test func theNextRefreshDoesNotBringTheDotsBack() async {
        let transport = ReadFakeTransport(rows: freshRows())
        let list = model(transport, cache: InMemorySessionCacheStore(sessions: rows))
        list.markAllRead()
        await list.refresh()
        #expect(list.chatsUnreadCount == 0)
        // New agent content gives the chat its dot again (issue #15).
        var newer = freshRows()
        newer[0].messageCount = 6
        transport.rows = newer
        await list.refresh()
        #expect(list.chatRows.filter(\.isUnread).map(\.id) == ["c3"])
    }

    @Test func theOpenChatStaysWithNoDot() async {
        let transport = ReadFakeTransport(rows: freshRows())
        let list = model(transport, cache: InMemorySessionCacheStore(sessions: rows))
        list.openChat(list.chat(for: "c2"))
        #expect(list.session(id: "c2")?.isUnread == false)
        list.markAllRead()
        await list.syncReadState()
        // Only the chat that still had the dot goes to the server.
        #expect(transport.calls == ["unread c3 false"])
        var newer = freshRows()
        newer[2].messageCount = 9
        transport.rows = newer
        await list.refresh()
        #expect(list.session(id: "c2")?.isUnread == false)
    }

    @Test func afterARelaunchTheChatsStayRead() async {
        let transport = ReadFakeTransport(rows: freshRows())
        let cache = InMemorySessionCacheStore(sessions: rows)
        model(transport, cache: cache).markAllRead()
        let relaunched = model(transport, cache: cache)
        #expect(relaunched.chatsUnreadCount == 0)
        await relaunched.refresh()
        #expect(relaunched.chatsUnreadCount == 0)
        #expect(relaunched.unreadCronRuns.count == 1)
    }

    @Test func theCarriedDotsOfASwitchGoTooButNotTheCronRuns() async {
        let transport = ReadFakeTransport(rows: freshRows())
        let cache = InMemorySessionCacheStore(sessions: freshRows())
        let list = model(transport, cache: cache)
        // The server book carries the dots of this server back (issue #83).
        list.switchServer(carryingUnread: ["c3", "c2", "cron_j1_1"])
        #expect(list.chatsUnreadCount == 2)
        list.markAllRead()
        await list.refresh()
        #expect(list.chatsUnreadCount == 0)
        #expect(list.unreadCronRuns.map(\.id) == ["cron_j1_1"])
        // The book entry of the active server has no unread chat now.
        let entry = list.serverState()
        #expect(entry.unreadChats == 0)
        #expect(entry.unreadIds == ["cron_j1_1"])
    }

    @Test func aRefusalKeepsTheChatReadAndIsNotSentAgain() async {
        let transport = ReadFakeTransport(rows: freshRows())
        transport.fail("c3", with: SessionActionError.refused(status: 404, detail: "Session not found"))
        let list = model(transport, cache: InMemorySessionCacheStore(sessions: rows))
        list.markAllRead()
        await list.syncReadState()
        #expect(list.session(id: "c3")?.isUnread == false)
        #expect(list.pendingReadSyncIds.isEmpty)
        await list.refresh()
        #expect(list.session(id: "c3")?.isUnread == false)
    }

    @Test func offlineClearsTheDotsAndSendsOnTheNextConnect() async {
        let transport = ReadFakeTransport(rows: freshRows())
        transport.fail("c3", with: GatewayError.notConnected)
        transport.fail("c2", with: GatewayError.notConnected)
        let list = model(transport, cache: InMemorySessionCacheStore(sessions: rows))
        #expect(list.markAllRead() == 2)
        await list.syncReadState()
        #expect(list.chatsUnreadCount == 0)
        #expect(list.pendingReadSyncIds == ["c3", "c2"])
        // The link comes back.
        transport.fail("c3", with: nil)
        transport.fail("c2", with: nil)
        list.receive(.state(.connected(GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef"))))
        while !list.pendingReadSyncIds.isEmpty { await Task.yield() }
        #expect(transport.calls.suffix(2) == ["unread c3 false", "unread c2 false"])
    }

    @Test func aServerSwitchDropsTheCallsOfTheOldServer() async {
        let transport = ReadFakeTransport(rows: freshRows())
        transport.fail("c3", with: GatewayError.notConnected)
        let list = model(transport, cache: InMemorySessionCacheStore(sessions: rows))
        list.markAllRead()
        await list.syncReadState()
        #expect(list.pendingReadSyncIds == ["c3"])
        list.switchServer(carryingUnread: [])
        #expect(list.pendingReadSyncIds.isEmpty)
    }

    @Test func onlyARefusalOfTheServerIsFinal() {
        #expect(ReadSync.isFinal(SessionActionError.refused(status: 404, detail: "x")))
        #expect(ReadSync.isFinal(SessionActionError.refused(status: 400, detail: "x")))
        #expect(ReadSync.isFinal(HermesAPIError.notFound))
        #expect(ReadSync.isFinal(HermesAPIError.http(status: 422)))
        #expect(!ReadSync.isFinal(SessionActionError.refused(status: 409, detail: "session_busy")))
        #expect(!ReadSync.isFinal(HermesAPIError.http(status: 429)))
        #expect(!ReadSync.isFinal(HermesAPIError.http(status: 503)))
        #expect(!ReadSync.isFinal(HermesAPIError.unauthorized))
        #expect(!ReadSync.isFinal(GatewayError.notConnected))
        #expect(!ReadSync.isFinal(URLError(.timedOut)))
    }
}
