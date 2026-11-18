import Foundation
import Testing
@testable import HermesKit

/// Issue #122: job runs are a history record. The app icon badge and the server menu dot count chats only.
@Suite struct JobBadgesTests {
    private let home = ServerProfile(host: "home.example.com", displayName: "Home")
    private let lab = ServerProfile(host: "lab.example.com", displayName: "Lab")

    private let rows = [SessionListItem(id: "c1", title: "Trip", isUnread: true),
                        SessionListItem(id: "r1", title: "Digest", source: "cron", isUnread: true),
                        SessionListItem(id: "r2", title: "Digest", source: "cron", isUnread: true)]

    @Test func theIconBadgeCountsOnlyTheUnreadChatsOfOtherServers() {
        var book = ServerStateBook()
        // A server with 1 unread chat and 2 unread cron runs.
        book.record(ServerStateBook.Entry(cachedRows: rows, outbox: []), for: lab.id)
        #expect(book.badgeCount(activeID: home.id, activeCount: 0) == 1)
        #expect(book.badgeCount(activeID: home.id, activeCount: 2) == 3)
        // An entry with only an unread cron run adds nothing.
        book.record(.init(unreadIds: ["r9"], unreadChats: 0), for: home.id)
        #expect(book.badgeCount(activeID: nil, activeCount: 0) == 1)
    }

    @Test func theServerMenuDotIgnoresUnreadCronRunsOfAnotherServer() {
        var book = ServerStateBook()
        let cronOnly = [SessionListItem(id: "r1", title: "Digest", source: "cron", isUnread: true)]
        book.record(ServerStateBook.Entry(cachedRows: cronOnly, outbox: []), for: lab.id)
        let list = ServerList(servers: [home, lab], activeID: home.id)
        let menu = ServerMenu(list: list, book: book, activeChats: 0)
        #expect(!menu.showsDot)
        #expect(menu.items.map(\.subtitle) == [nil, nil])
        #expect(!book.othersHaveUnread(activeID: home.id))

        book.record(ServerStateBook.Entry(cachedRows: rows, outbox: []), for: lab.id)
        #expect(ServerMenu(list: list, book: book, activeChats: 0).showsDot)
    }

    @Test func catchUpSetsABadgeOfUnreadChatsOnly() async throws {
        let cached = [SessionListItem(id: "c1", title: "Trip", messageCount: 2),
                      SessionListItem(id: "r1", title: "Digest", messageCount: 2, source: "cron")]
        let cache = InMemorySessionCacheStore(sessions: cached)
        let fresh = [SessionListItem(id: "c1", title: "Trip", messageCount: 4),
                     SessionListItem(id: "r1", title: "Digest", messageCount: 4, source: "cron")]
        let notifier = FakeNotifier()
        let result = try await CatchUpRefresher(sessions: FakeSessionsTransport(rows: fresh), chats: FakeChatTransport(),
                                                cache: cache, notifier: notifier)
            .run(showsPreview: false)
        #expect(result.unreadCount == 1)
        #expect(notifier.badges == [1])
    }

    @Test func savedBooksWithCronRunIdsStillLoad() throws {
        // A book saved before #122: unreadIds has the cron runs too.
        let json = #"{"entries":{"\#(lab.id.uuidString)":{"unreadIds":["c1","r1","r2"],"unreadChats":1}}}"#
        let book = try JSONDecoder().decode(ServerStateBook.self, from: Data(json.utf8))
        #expect(book.entry(for: lab.id).unreadIds == ["c1", "r1", "r2"])
        #expect(book.badgeCount(activeID: home.id, activeCount: 0) == 1)
    }
}
