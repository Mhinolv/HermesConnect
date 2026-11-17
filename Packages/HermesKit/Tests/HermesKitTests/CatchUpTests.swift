import Foundation
import Testing
@testable import HermesKit

/// Records the notifications and the badge. No `UNUserNotificationCenter`.
final class FakeNotifier: LocalNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _posted: [CatchUpNotification] = []
    private var _badges: [Int] = []

    var posted: [CatchUpNotification] { lock.withLock { _posted } }
    var badges: [Int] { lock.withLock { _badges } }

    func post(_ notification: CatchUpNotification) async { lock.withLock { _posted.append(notification) } }
    func setBadge(_ count: Int) async { lock.withLock { _badges.append(count) } }
}

private func row(_ id: String, _ count: Int?, title: String? = nil, unread: Bool = false) -> SessionListItem {
    SessionListItem(id: id, title: title, messageCount: count, isUnread: unread)
}

/// Issue #15: the pure rules of the catch-up.
@Suite struct CatchUpRuleTests {
    @Test func moreMessagesOrANewRowIsNewContent() {
        let cached = [row("a", 4), row("b", 2), row("c", nil)]
        let fresh = [row("n", 1), row("b", 3), row("a", 4), row("c", nil), row("e", 0)]
        #expect(CatchUp.changedSessions(cached: cached, fresh: fresh) == ["n", "b"])
    }

    @Test func theFirstLoadIsNotNewContent() {
        #expect(CatchUp.changedSessions(cached: [], fresh: [row("a", 4)]).isEmpty)
    }

    @Test func fewerMessagesIsNotNewContent() {
        #expect(CatchUp.changedSessions(cached: [row("a", 6)], fresh: [row("a", 4)]).isEmpty)
    }

    @Test func onlyANewAssistantReplyIsNew() {
        let cached = [ChatMessage(id: "c1", role: .assistant, text: "Old", date: .distantPast, reply: .complete)]
        let answered = [TranscriptMessage(role: "user", text: "Hi", rowId: 1),
                        TranscriptMessage(role: "assistant", text: "Fresh reply", rowId: 2)]
        #expect(CatchUp.newReply(in: answered, cached: cached) == "Fresh reply")
        // The agent did not answer yet: the last row is the prompt.
        let waiting = [TranscriptMessage(role: "assistant", text: "Old", rowId: 1),
                       TranscriptMessage(role: "user", text: "And now?", rowId: 2)]
        #expect(CatchUp.newReply(in: waiting, cached: cached) == nil)
        // The cache already has the reply.
        #expect(CatchUp.newReply(in: [TranscriptMessage(role: "assistant", text: "Old", rowId: 1)], cached: cached) == nil)
        // Tool rows do not count.
        #expect(CatchUp.newReply(in: [TranscriptMessage(role: "tool", text: "ls", rowId: 1)], cached: []) == nil)
        #expect(CatchUp.newReply(in: [], cached: []) == nil)
    }

    @Test func dotsStayAndTheOpenSessionGetsNone() {
        let fresh = [row("a", 1), row("b", 1), row("c", 1), row("d", 1)]
        let marked = CatchUp.markUnread(fresh, unread: ["a", "d"], newContent: ["b", "d"], openSessionId: "d")
        #expect(marked.map(\.isUnread) == [true, true, false, false])
    }

    @Test func notificationHasNoMessageTextByDefault() {
        let session = row("k1", 3, title: "Trip plan")
        let plain = CatchUpNotification(session: session, reply: "The hotel is booked.", showsPreview: false)
        #expect(plain == CatchUpNotification(sessionId: "k1", title: "Trip plan", body: "New message from Hermes"))
        let long = String(repeating: "x", count: 150)
        let preview = CatchUpNotification(session: row("k2", 1), reply: "  \(long)  ", showsPreview: true)
        #expect(preview.title == "Untitled")
        #expect(preview.body == String(repeating: "x", count: 100))
        // An empty reply never gives an empty body.
        #expect(CatchUpNotification(session: session, reply: " ", showsPreview: true).body == "New message from Hermes")
    }

    @Test func previewIsOffWithNoSavedValue() throws {
        let defaults = try #require(UserDefaults(suiteName: "CatchUpRuleTests"))
        defaults.removePersistentDomain(forName: "CatchUpRuleTests")
        #expect(!NotificationSettings.showsPreview(defaults))
        defaults.set(true, forKey: NotificationSettings.showPreviewKey)
        #expect(NotificationSettings.showsPreview(defaults))
        defaults.removePersistentDomain(forName: "CatchUpRuleTests")
    }
}

/// Issue #15: the BGAppRefresh run with fakes for the gateway and the notification center.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CatchUpRefresherTests {
    private let reply = [TranscriptMessage(role: "user", text: "Remind me", rowId: 1),
                         TranscriptMessage(role: "assistant", text: "Done. Reminder set.", rowId: 2)]

    @Test func newReplyPostsANotificationSetsTheDotAndTheBadge() async throws {
        let cache = InMemorySessionCacheStore(sessions: [row("k1", 2, title: "Reminders"), row("k2", 4, unread: true)])
        let sessions = FakeSessionsTransport(rows: [row("k1", 4, title: "Reminders"), row("k2", 4)])
        let chats = FakeChatTransport()
        chats.transcript = reply
        let notifier = FakeNotifier()
        let refresher = CatchUpRefresher(sessions: sessions, chats: chats, cache: cache, notifier: notifier)

        let result = try await refresher.run(showsPreview: false)
        #expect(result == CatchUpResult(changed: ["k1"], notified: ["k1"], unreadCount: 2))
        #expect(chats.resumes == ["k1"])
        #expect(notifier.posted == [CatchUpNotification(sessionId: "k1", title: "Reminders",
                                                        body: "New message from Hermes")])
        #expect(notifier.badges == [2])
        #expect(cache.loadSessions().map(\.isUnread) == [true, true])
        #expect(cache.loadSessions().map(\.messageCount) == [4, 4])

        // A second run finds nothing new: no second notification.
        let again = try await refresher.run(showsPreview: false)
        #expect(again.notified.isEmpty)
        #expect(notifier.posted.count == 1)
    }

    @Test func previewOnPutsTheReplyInTheBody() async throws {
        let cache = InMemorySessionCacheStore(sessions: [row("k1", 2)])
        let sessions = FakeSessionsTransport(rows: [row("k1", 4)])
        let chats = FakeChatTransport()
        chats.transcript = reply
        let notifier = FakeNotifier()
        _ = try await CatchUpRefresher(sessions: sessions, chats: chats, cache: cache, notifier: notifier)
            .run(showsPreview: true)
        #expect(notifier.posted.map(\.body) == ["Done. Reminder set."])
    }

    @Test func aPromptWithNoReplyGetsTheDotButNoNotification() async throws {
        let cache = InMemorySessionCacheStore(sessions: [row("k1", 2)])
        let sessions = FakeSessionsTransport(rows: [row("k1", 3)])
        let chats = FakeChatTransport()
        chats.transcript = [TranscriptMessage(role: "user", text: "From the Mac", rowId: 1)]
        let notifier = FakeNotifier()
        let result = try await CatchUpRefresher(sessions: sessions, chats: chats, cache: cache, notifier: notifier)
            .run(showsPreview: false)
        #expect(result.notified.isEmpty)
        #expect(result.unreadCount == 1)
        #expect(notifier.posted.isEmpty)
    }

    @Test func historyFailureStillSetsTheDot() async throws {
        let cache = InMemorySessionCacheStore(sessions: [row("k1", 2)])
        let sessions = FakeSessionsTransport(rows: [row("k1", 3)])
        let chats = FakeChatTransport()
        chats.failHistory = true
        let notifier = FakeNotifier()
        let result = try await CatchUpRefresher(sessions: sessions, chats: chats, cache: cache, notifier: notifier)
            .run(showsPreview: false)
        #expect(result == CatchUpResult(changed: ["k1"], notified: [], unreadCount: 1))
    }

    @Test func listFailureChangesNothing() async {
        let cached = [row("k1", 2)]
        let cache = InMemorySessionCacheStore(sessions: cached)
        let sessions = FakeSessionsTransport(rows: [row("k1", 3)])
        sessions.fail = true
        let notifier = FakeNotifier()
        await #expect(throws: (any Error).self) {
            try await CatchUpRefresher(sessions: sessions, chats: FakeChatTransport(), cache: cache, notifier: notifier)
                .run(showsPreview: false)
        }
        #expect(cache.loadSessions() == cached)
        #expect(notifier.posted.isEmpty)
        #expect(notifier.badges.isEmpty)
    }

    @Test func atMostFiveSessionsAreFetched() async throws {
        let ids = (1...8).map { "k\($0)" }
        let cache = InMemorySessionCacheStore(sessions: ids.map { row($0, 1) })
        let sessions = FakeSessionsTransport(rows: ids.map { row($0, 2) })
        let chats = FakeChatTransport()
        chats.transcript = reply
        let result = try await CatchUpRefresher(sessions: sessions, chats: chats, cache: cache, notifier: FakeNotifier())
            .run(showsPreview: false)
        #expect(chats.resumes == Array(ids.prefix(5)))
        #expect(result.unreadCount == 8)
    }

    @Test func theOpenSessionIsSkipped() async throws {
        let cache = InMemorySessionCacheStore(sessions: [row("k1", 2)])
        let sessions = FakeSessionsTransport(rows: [row("k1", 4)])
        let chats = FakeChatTransport()
        chats.transcript = reply
        let notifier = FakeNotifier()
        let result = try await CatchUpRefresher(sessions: sessions, chats: chats, cache: cache, notifier: notifier)
            .run(showsPreview: false, openSessionId: "k1")
        #expect(result.changed.isEmpty)
        #expect(notifier.posted.isEmpty)
        #expect(chats.resumes.isEmpty)
    }
}

/// Issue #15: the session list and the chat after a foreground reconnect.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ForegroundReconcileTests {
    @Test func refreshMarksNewContentAndOpenClearsIt() async {
        let cache = InMemorySessionCacheStore(sessions: [row("k1", 2), row("k2", 2)])
        let transport = FakeSessionsTransport(rows: [row("k1", 4), row("k2", 5)])
        let list = SessionListModel(transport: transport, chatTransport: FakeChatTransport(), cache: cache)
        list.openSessionId = "k2"
        await list.refresh()
        #expect(list.sessions.map(\.isUnread) == [true, false])
        #expect(list.unreadCount == 1)
        list.markRead("k1")
        #expect(list.unreadCount == 0)
        #expect(cache.loadSessions().map(\.isUnread) == [false, false])
    }

    @Test func listCatchUpUpdatesTheRowsOnScreen() async throws {
        let cache = InMemorySessionCacheStore(sessions: [row("k1", 2)])
        let transport = FakeSessionsTransport(rows: [row("k1", 4)])
        let chats = FakeChatTransport()
        chats.transcript = [TranscriptMessage(role: "assistant", text: "Cron digest", rowId: 1)]
        let list = SessionListModel(transport: transport, chatTransport: chats, cache: cache)
        let notifier = FakeNotifier()
        let result = await list.catchUp(showsPreview: false, notifier: notifier)
        #expect(result?.notified == ["k1"])
        #expect(list.sessions.first?.isUnread == true)
        #expect(list.sessions.first?.messageCount == 4)
        // The next foreground refresh keeps the dot.
        await list.refresh()
        #expect(list.unreadCount == 1)
    }

    @Test func reopenAfterSuspendShowsTheMissedRepliesInOneUpdate() async throws {
        let transport = FakeChatTransport()
        transport.transcript = [TranscriptMessage(role: "user", text: "Hi", rowId: 2),
                                TranscriptMessage(role: "assistant", text: "Hello", rowId: 3)]
        let cache = InMemorySessionCacheStore()
        let chat = ChatViewModel(transport: transport, storedSessionId: "k1", cache: cache)
        await chat.open()
        #expect(chat.newMessageIds.isEmpty)
        #expect(chat.messages.map(\.text) == ["Hi", "Hello"])

        // The phone was suspended. The agent sent two more messages from a cron job.
        transport.transcript += [TranscriptMessage(role: "user", text: "Cron: digest", rowId: 4),
                                 TranscriptMessage(role: "assistant", text: "Your digest", rowId: 5)]
        // The app reconnects with a new client: only `.connected` comes, no `.disconnected`.
        chat.receive(.state(.connected(GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef"))))
        try await waitFor { chat.messages.count == 4 }
        #expect(chat.messages.map(\.text) == ["Hi", "Hello", "Cron: digest", "Your digest"])
        #expect(chat.newMessageIds == ["row-4", "row-5"])
        #expect(transport.resumes == ["k1", "k1"])
        #expect(!chat.isUpdating)
        chat.clearNewMessages()
        #expect(chat.newMessageIds.isEmpty)
    }

    @Test func updatingShowsWhileTheHistoryLoadsOverTheCache() async throws {
        let transport = FakeChatTransport()
        transport.transcript = [TranscriptMessage(role: "user", text: "Hi", rowId: 2),
                                TranscriptMessage(role: "assistant", text: "Hello", rowId: 3)]
        let cached = [ChatMessage(id: "c1", role: .user, text: "Hi", date: .distantPast, delivery: .delivered, userRowId: 2)]
        let chat = ChatViewModel(transport: transport, storedSessionId: "k1",
                                 cache: InMemorySessionCacheStore(transcripts: ["k1": cached]))
        let open = Task { await chat.open() }
        try await waitFor { chat.isUpdating || chat.messages.count == 2 }
        await open.value
        #expect(!chat.isUpdating)
        // A cache shows: "Updating…", never the full-screen loader.
        #expect(!chat.isLoadingHistory)
        #expect(chat.newMessageIds.count == 1)
    }

    @Test func aChatThatNeverOpenedDoesNotResumeOnConnect() async throws {
        let transport = FakeChatTransport()
        let chat = ChatViewModel(transport: transport, storedSessionId: "k1", cache: InMemorySessionCacheStore())
        chat.receive(.state(.connected(GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef"))))
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.resumes.isEmpty)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition not met")
    }
}
