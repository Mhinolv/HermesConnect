import Foundation
import Testing
@testable import HermesKit

/// Issue #83: the server book, the server menu, and the reset of the lists on a server switch.
@Suite struct ServerStateBookTests {
    private let home = UUID()
    private let lab = UUID()
    private let vps = UUID()

    @Test func theBadgeCountsTheLiveActiveServerAndTheKeptCountsOfTheOthers() {
        var book = ServerStateBook()
        book.record(.init(unreadIds: ["h1", "h2"], unreadChats: 2), for: home)
        book.record(.init(unreadIds: ["l1", "l2", "l3"], unreadChats: 2), for: lab)
        // The active server uses the live count, not its old entry.
        #expect(book.badgeCount(activeID: home, activeCount: 5) == 8)
        #expect(book.badgeCount(activeID: vps, activeCount: 1) == 6)
        #expect(book.badgeCount(activeID: nil, activeCount: 0) == 5)
    }

    @Test func theDotShowsOnlyForUnreadChatsOfAnotherServer() {
        var book = ServerStateBook()
        book.record(.init(unreadIds: ["h1"], unreadChats: 1), for: home)
        #expect(!book.othersHaveUnread(activeID: home))
        #expect(book.othersHaveUnread(activeID: lab))
        // An unread cron run alone is not an unread chat.
        book.record(.init(unreadIds: ["cron_1"], unreadChats: 0), for: lab)
        #expect(!book.othersHaveUnread(activeID: home))
    }

    @Test func outboxIdsLeaveOutTheActiveServer() {
        var book = ServerStateBook()
        book.record(.init(outboxIds: ["h1"]), for: home)
        book.record(.init(outboxIds: ["l1", "l2"]), for: lab)
        #expect(book.outboxIds(except: home) == ["l1", "l2"])
        #expect(book.outboxIds(except: lab) == ["h1"])
        #expect(book.outboxIds(except: nil) == ["h1", "l1", "l2"])
    }

    @Test func anEmptyEntryAndARemovedServerLeaveTheBook() {
        var book = ServerStateBook()
        let first = book.record(.init(unreadIds: ["h1"], unreadChats: 1), for: home)
        let again = book.record(.init(unreadIds: ["h1"], unreadChats: 1), for: home)
        #expect(first)
        #expect(!again, "no change")
        book.record(.init(), for: home)
        #expect(book.entries.isEmpty)
        book.record(.init(outboxIds: ["l1"]), for: lab)
        book.record(.init(outboxIds: ["v1"]), for: vps)
        book.keep(only: [vps])
        #expect(Array(book.entries.keys) == [vps])
    }

    @Test func theBookRoundTripsAndBadDataLoadsEmpty() throws {
        var book = ServerStateBook()
        book.record(.init(unreadIds: ["h1"], unreadChats: 1, outboxIds: ["h2"]), for: home)
        let data = try JSONEncoder().encode(book)
        #expect(try JSONDecoder().decode(ServerStateBook.self, from: data) == book)
        // A future or broken file: bad keys and missing fields do not fail the launch.
        let odd = Data(#"{"entries":{"not-a-uuid":{"unreadChats":2},"\#(lab.uuidString)":{"unreadChats":-4}},"x":1}"#.utf8)
        let decoded = try JSONDecoder().decode(ServerStateBook.self, from: odd)
        #expect(decoded.entries == [lab: .init()])
        #expect(try JSONDecoder().decode(ServerStateBook.self, from: Data("{}".utf8)) == ServerStateBook())
    }
}

@Suite struct ServerMenuTests {
    private let home = ServerProfile(host: "home.example.com", displayName: "Home")
    private let lab = ServerProfile(host: "lab.example.com")

    @Test func oneServerHasNoMenuAndTheTitleStaysHermes() {
        let menu = ServerMenu(list: ServerList(servers: [home]), book: ServerStateBook(), activeChats: 2)
        #expect(!menu.showsMenu)
        #expect(menu.title() == "Hermes")
        #expect(menu.title(default: "Jobs") == "Jobs")
    }

    @Test func twoServersShowTheActiveNameEveryServerAndTheCheckmark() {
        var book = ServerStateBook()
        book.record(.init(unreadIds: ["l1", "l2", "l3"], unreadChats: 3), for: lab.id)
        // The book of the active server is old: the live count wins.
        book.record(.init(unreadIds: ["h9"], unreadChats: 9), for: home.id)
        let menu = ServerMenu(list: ServerList(servers: [home, lab], activeID: home.id), book: book, activeChats: 0)
        #expect(menu.showsMenu)
        #expect(menu.title() == "Home")
        #expect(menu.title(default: "Jobs") == "Home")
        #expect(menu.items.map(\.name) == ["Home", "lab.example.com"], "the name, else the host")
        #expect(menu.items.map(\.isActive) == [true, false])
        #expect(menu.items.map(\.subtitle) == [nil, "3 unread"])
        #expect(menu.showsDot)
        #expect(menu.items[0].accessibilityLabel == "Home, selected")
        #expect(menu.items[1].accessibilityLabel == "lab.example.com, 3 unread")
        #expect(menu.titleAccessibilityLabel() == "Home, server, unread on other servers")
        #expect(ServerMenu.switchAnnouncement("Lab") == "Switched to Lab")
    }

    @Test func unreadChatsOfTheActiveServerShowNoDot() {
        let menu = ServerMenu(list: ServerList(servers: [home, lab], activeID: lab.id), book: ServerStateBook(),
                              activeChats: 4)
        #expect(menu.title() == "lab.example.com")
        #expect(menu.items[1].accessibilityLabel == "lab.example.com, 4 unread, selected")
        #expect(!menu.showsDot)
        #expect(menu.titleAccessibilityLabel() == "lab.example.com, server")
    }
}

/// `session.list` waits until the test releases it: the answer of the old server comes after a switch.
private final class HeldSessionsTransport: SessionsTransport, @unchecked Sendable {
    let events: AsyncStream<GatewayClientEvent> = AsyncStream { _ in }
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var _rows: [SessionListItem]

    init(rows: [SessionListItem]) { _rows = rows }

    var rows: [SessionListItem] {
        get { lock.withLock { _rows } }
        set { lock.withLock { _rows = newValue } }
    }

    var isHolding: Bool { lock.withLock { gate != nil } }

    func release() {
        let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { self.gate = nil }
            return self.gate
        }
        gate?.resume()
    }

    func fetchSessions() async throws -> [SessionListItem] {
        let answer = rows
        await withCheckedContinuation { continuation in lock.withLock { gate = continuation } }
        return answer
    }

    func fetchMostRecentSessionId() async throws -> String? { nil }
}

private let connected = GatewayClientEvent.state(.connected(GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef")))

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("the condition did not become true")
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SessionListServerSwitchTests {
    private let homeRows = [
        SessionListItem(id: "20261117_080000_home01", title: "Trip", messageCount: 4, isUnread: true),
        SessionListItem(id: "20261117_080000_home02", title: "Digest", messageCount: 2),
    ]
    private let labRows = [SessionListItem(id: "20261117_090000_lab001", title: "Build logs", messageCount: 3)]

    private let home = UUID()
    private let lab = UUID()

    @Test func aSwitchShowsTheRedactedRowsThenOnlyTheNewServerRows() async {
        let caches = ServerCaches(inMemory: home,
                                  seed: [home: InMemorySessionCacheStore(sessions: homeRows, activeSessionId: homeRows[0].id)])
        let cache = caches.sessions
        let transport = FakeSessionsTransport(rows: homeRows)
        let sessions = SessionListModel(transport: transport, chatTransport: FakeChatTransport(), cache: cache)
        #expect(sessions.hasLoaded)
        caches.select(lab)
        sessions.switchServer(carryingUnread: [])
        #expect(!sessions.hasLoaded, "Lab has no cache: the redacted rows show")
        #expect(sessions.sessions.isEmpty)
        #expect(cache.loadActiveSessionId() == nil, "launch does not open a chat of the old server")
        transport.rows = labRows
        await sessions.refresh()
        #expect(sessions.sessions.map(\.id) == labRows.map(\.id))
        #expect(sessions.unreadCount == 0, "the first load of a server is not new content")
        #expect(caches.sessionStore(for: lab).loadSessions().map(\.id) == labRows.map(\.id))
        #expect(caches.sessionStore(for: home).loadSessions() == homeRows, "the Home folder does not change")
        #expect(caches.sessionStore(for: home).loadActiveSessionId() == homeRows[0].id)
    }

    /// Issue #84: a switch back shows the list of the server at once, from its cache.
    @Test func aSwitchBackShowsTheCachedRowsAndTheActiveIdAtOnce() async {
        let caches = ServerCaches(inMemory: lab, seed: [
            home: InMemorySessionCacheStore(sessions: homeRows, activeSessionId: homeRows[1].id),
            lab: InMemorySessionCacheStore(sessions: labRows),
        ])
        let sessions = SessionListModel(transport: FakeSessionsTransport(rows: labRows),
                                        chatTransport: FakeChatTransport(), cache: caches.sessions)
        caches.select(home)
        sessions.switchServer(carryingUnread: [homeRows[1].id])
        #expect(sessions.hasLoaded)
        #expect(sessions.sessions.map(\.id) == homeRows.map(\.id))
        #expect(sessions.sessions.filter(\.isUnread).map(\.id) == homeRows.map(\.id),
                "the cached dot and the dot of the book")
        #expect(sessions.cachedActiveSessionId == homeRows[1].id, "the last open chat of Home comes back")
    }

    @Test func aLateAnswerOfTheOldServerIsDropped() async throws {
        let transport = HeldSessionsTransport(rows: homeRows)
        let sessions = SessionListModel(transport: transport, chatTransport: FakeChatTransport(),
                                        cache: InMemorySessionCacheStore())
        let old = Task { await sessions.refresh() }
        try await waitUntil { transport.isHolding }
        sessions.switchServer(carryingUnread: [])
        transport.release()
        await old.value
        #expect(sessions.sessions.isEmpty)
        #expect(!sessions.hasLoaded)
        transport.rows = labRows
        let fresh = Task { await sessions.refresh() }
        try await waitUntil { transport.isHolding }
        transport.release()
        await fresh.value
        #expect(sessions.sessions.map(\.id) == labRows.map(\.id))
    }

    @Test func theBlueDotsOfAServerComeBackWhenItIsActiveAgain() async {
        let transport = FakeSessionsTransport(rows: labRows)
        let caches = ServerCaches(inMemory: lab, seed: [lab: InMemorySessionCacheStore(sessions: labRows)])
        let sessions = SessionListModel(transport: transport, chatTransport: FakeChatTransport(), cache: caches.sessions)
        let kept = ServerStateBook.Entry(unreadIds: [homeRows[0].id], unreadChats: 1)
        caches.select(home)
        sessions.switchServer(carryingUnread: kept.unreadIds)
        // Before the first load the book entry stays as it was.
        #expect(sessions.serverState(fallback: kept) == kept)
        transport.rows = homeRows.map { var row = $0; row.isUnread = false; return row }
        await sessions.refresh()
        #expect(sessions.sessions.filter(\.isUnread).map(\.id) == [homeRows[0].id])
        #expect(sessions.serverState(fallback: .init()) == kept)
    }

    @Test func aBackgroundCatchUpKeepsTheCarriedDots() async {
        let transport = FakeSessionsTransport(rows: homeRows.map { var row = $0; row.isUnread = false; return row })
        let cache = InMemorySessionCacheStore()
        let sessions = SessionListModel(transport: transport, chatTransport: FakeChatTransport(), cache: cache)
        sessions.switchServer(carryingUnread: [homeRows[1].id])
        await sessions.catchUp(showsPreview: false, notifier: SilentNotifier())
        #expect(sessions.sessions.filter(\.isUnread).map(\.id) == [homeRows[1].id])
        #expect(cache.loadSessions().filter(\.isUnread).map(\.id) == [homeRows[1].id])
    }

    @Test func chatsOfTheOldServerStopAndNeverResumeOnTheNewServer() async throws {
        let chats = FakeChatTransport()
        let caches = ServerCaches(inMemory: home, seed: [home: InMemorySessionCacheStore(sessions: homeRows)])
        let sessions = SessionListModel(transport: FakeSessionsTransport(rows: homeRows), chatTransport: chats,
                                        cache: caches.sessions)
        let old = sessions.chat(for: homeRows[0].id)
        sessions.openChat(old)
        caches.select(lab)
        sessions.switchServer(carryingUnread: [])
        #expect(sessions.openSessionId == nil)
        chats.input.yield(connected)
        try await Task.sleep(for: .milliseconds(100))
        #expect(chats.resumes.isEmpty, "the old chat does not resume on the new server")
        #expect(sessions.chat(for: homeRows[0].id) !== old, "a new chat model, if the id comes back")
    }

    @Test func theOutboxOfAnotherServerWaitsForItsOwnServer() async throws {
        let caches = ServerCaches(inMemory: home)
        let stored = homeRows[0].id
        let offline = OutboxTransport(online: false)
        let chat = ChatViewModel(transport: offline, storedSessionId: stored, cache: caches.sessions.pinned(),
                                 redrawInterval: .zero)
        await chat.send("one")?.value
        #expect(caches.sessionStore(for: home).outboxSessionIds() == [stored])

        // The owner switched from Home to Lab: the Home outbox is in the Home folder.
        let online = OutboxTransport(online: true)
        let sessions = SessionListModel(transport: FakeSessionsTransport(rows: labRows), chatTransport: online,
                                        cache: caches.sessions)
        caches.select(lab)
        sessions.switchServer(carryingUnread: [])
        #expect(sessions.serverState().outboxIds.isEmpty, "Lab has no outbox of its own")
        sessions.receive(connected)
        try await Task.sleep(for: .milliseconds(150))
        #expect(online.submits.isEmpty, "a queued message never goes to another server")
        #expect(caches.sessionStore(for: home).outboxSessionIds() == [stored])

        // Back on Home: the outbox sends on the next connect.
        caches.select(home)
        sessions.switchServer(carryingUnread: [])
        sessions.receive(connected)
        try await waitUntil { online.submits == ["one"] }
    }

    /// A new host on the same entry: the rows, the active id, the outbox and the new chat of the old host go.
    @Test func aNewHostDropsTheRowsTheActiveIdTheOutboxAndTheNewChat() async {
        let cache = InMemorySessionCacheStore(sessions: homeRows, activeSessionId: homeRows[0].id)
        let offline = OutboxTransport(online: false)
        let chat = ChatViewModel(transport: offline, storedSessionId: homeRows[1].id, cache: cache, redrawInterval: .zero)
        await chat.send("one")?.value
        cache.saveTranscript([ChatMessage(id: "q", role: .user, text: "new", date: .now, delivery: .queued)],
                             sessionId: SessionCache.newChatId)
        cache.saveOutbox(true, sessionId: SessionCache.newChatId)
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: offline, cache: cache)
        sessions.switchServer(carryingUnread: [], newHost: true)
        #expect(!sessions.hasLoaded)
        #expect(cache.loadSessions().isEmpty)
        #expect(cache.loadActiveSessionId() == nil)
        #expect(cache.outboxSessionIds().isEmpty, "nothing sends to the new host")
        #expect(!sessions.hasCachedNewChat)
        #expect(cache.loadTranscript(sessionId: homeRows[1].id).map(\.text) == ["one"], "the queued text stays")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct JobsServerSwitchTests {
    private let homeJobs = [CronJob(id: "j1", name: "Morning digest", scheduleDisplay: "Every day at 8:00 AM")]
    private let home = UUID()
    private let lab = UUID()

    @Test func aSwitchShowsTheLoadingRowsThenTheNewServerJobs() async {
        let transport = FakeCronTransport(jobs: homeJobs)
        let caches = ServerCaches(inMemory: home, jobs: [home: InMemoryCronJobCacheStore(jobs: homeJobs)])
        let jobs = JobsModel(transport: transport, cache: caches.jobs)
        #expect(jobs.state(query: "") == .rows)
        caches.select(lab)
        jobs.switchServer()
        #expect(jobs.state(query: "") == .loading, "Lab has no cache yet")
        transport.jobs = []
        await jobs.refresh()
        #expect(jobs.state(query: "") == .empty)
        #expect(caches.cronStore(for: lab).loadJobs() == [])
        #expect(caches.cronStore(for: home).loadJobs() == homeJobs, "the Home jobs stay in the Home folder")

        // Issue #84: back on Home, the cached jobs show at once.
        caches.select(home)
        jobs.switchServer()
        #expect(jobs.state(query: "") == .rows)
        #expect(jobs.jobs == homeJobs)
    }
}

/// A notifier that posts nothing.
private struct SilentNotifier: LocalNotifying {
    func post(_: CatchUpNotification) async {}
    func setBadge(_: Int) async {}
}
