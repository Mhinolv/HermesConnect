import Foundation
import Testing
@testable import HermesKit

/// Issue #16: the "Ask Hermes" App Shortcut. The owner decision (2026-11-16) says the text goes at once.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct AskHermesTests {
    // MARK: Request

    @Test func requestTrimsTheMessage() {
        #expect(AskHermesRequest(message: "  What is on my calendar?\n").text == "What is on my calendar?")
        #expect(AskHermesRequest(message: "Line 1\nLine 2").text == "Line 1\nLine 2")
    }

    @Test func emptyOrMissingMessageOnlyOpensTheChat() {
        #expect(AskHermesRequest(message: nil).text == nil)
        #expect(AskHermesRequest(message: "").text == nil)
        #expect(AskHermesRequest(message: " \n\t ").text == nil)
    }

    // MARK: Inbox

    @Test func nothingPendingGivesNoStep() {
        let inbox = AskHermesInbox()
        #expect(inbox.next(isSetUp: true, isLocked: false) == nil)
    }

    @Test func unlockedAndSetUpRunsTheRequestOnce() {
        let inbox = AskHermesInbox()
        let request = inbox.post(message: "Hello")
        #expect(inbox.pending == request)
        #expect(inbox.next(isSetUp: true, isLocked: false) == .run(request))
        #expect(inbox.pending == nil)
        #expect(inbox.next(isSetUp: true, isLocked: false) == nil)
    }

    @Test func appLockKeepsTheRequestUntilUnlock() {
        let inbox = AskHermesInbox()
        let request = inbox.post(message: "Hello")
        #expect(inbox.next(isSetUp: true, isLocked: true) == nil)
        #expect(inbox.pending == request)
        #expect(inbox.next(isSetUp: true, isLocked: false) == .run(request))
    }

    @Test func noSetupDropsTheText() {
        let inbox = AskHermesInbox()
        inbox.post(message: "Hello")
        #expect(inbox.next(isSetUp: false, isLocked: false) == .dropForSetup)
        #expect(inbox.pending == nil)
        // Also under App Lock: the text never waits for a setup.
        inbox.post(message: "Hello")
        #expect(inbox.next(isSetUp: false, isLocked: true) == .dropForSetup)
        #expect(inbox.pending == nil)
    }

    @Test func aNewerRunReplacesTheRequestThatWaits() {
        let inbox = AskHermesInbox()
        let first = inbox.post(message: "First")
        let second = inbox.post(message: "Second")
        #expect(first.id != second.id)
        #expect(inbox.next(isSetUp: true, isLocked: false) == .run(second))
    }

    // MARK: App Lock

    @Test func aLongBackgroundCountsAsLockedBeforeTheForegroundCall() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var policy = AppLockPolicy(isEnabled: true)
        #expect(policy.locks(at: start))
        policy.unlockSucceeded()
        #expect(!policy.locks(at: start))
        policy.didEnterBackground(at: start)
        // The shortcut can run before `willEnterForeground`. Five minutes away must lock it anyway.
        #expect(!policy.locks(at: start.addingTimeInterval(299)))
        #expect(policy.locks(at: start.addingTimeInterval(AppLockPolicy.relockInterval)))
        policy.setEnabled(false)
        #expect(!policy.locks(at: start.addingTimeInterval(10_000)))
    }

    // MARK: Run

    @Test func cachedSessionShowsAtOnceThenTheTextGoesWhenTheLinkIsReady() async throws {
        let chats = FakeChatTransport()
        let sessionsTransport = FakeSessionsTransport(mostRecent: "k9")
        let sessions = SessionListModel(transport: sessionsTransport, chatTransport: chats,
                                        cache: InMemorySessionCacheStore(activeSessionId: "k1"))
        var steps: [String] = []
        let task = await AskHermes.run(AskHermesRequest(message: "Remind me at 5"), sessions: sessions,
                                       linkReady: {
                                           steps.append("ready")
                                           return true
                                       },
                                       show: { steps.append("show \($0)") })
        await task?.value
        // The chat shows before the wait, so the owner sees "Connecting…" in the right session.
        #expect(steps == ["show session(\"k1\")", "ready"])
        #expect(chats.resumes == ["k1"])
        #expect(chats.submits == [.init(sessionId: "s2", text: "Remind me at 5", retryBeforeRowId: nil)])
        #expect(sessions.chat(for: "k1").messages.map(\.text) == ["Remind me at 5"])
        #expect(sessions.chat(for: "k1").messages.first?.delivery == .delivered)
    }

    @Test func noCacheUsesTheMostRecentSessionOfTheServer() async throws {
        let chats = FakeChatTransport()
        let sessions = SessionListModel(transport: FakeSessionsTransport(mostRecent: "k9"), chatTransport: chats,
                                        cache: InMemorySessionCacheStore())
        var shown: [AskHermesRoute] = []
        let task = await AskHermes.run(AskHermesRequest(message: "Hi"), sessions: sessions,
                                       linkReady: { true }, show: { shown.append($0) })
        await task?.value
        #expect(shown == [.session("k9")])
        #expect(chats.resumes == ["k9"])
        #expect(chats.submits.map(\.text) == ["Hi"])
    }

    @Test func noSessionAtAllStartsANewChat() async throws {
        let chats = FakeChatTransport()
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: chats,
                                        cache: InMemorySessionCacheStore())
        var shown: [AskHermesRoute] = []
        let task = await AskHermes.run(AskHermesRequest(message: "Hi"), sessions: sessions,
                                       linkReady: { true }, show: { shown.append($0) })
        await task?.value
        guard case .newChat(let key) = shown.first, shown.count == 1 else {
            Issue.record("expected one new chat, got \(shown)")
            return
        }
        // The route key gives the same model as the one that sent the text.
        #expect(sessions.newChat(key: key).messages.map(\.text) == ["Hi"])
        #expect(chats.starts.map(\.0) == [ChatSource.iOS])
        #expect(chats.submits.map(\.text) == ["Hi"])
    }

    // MARK: Cron runs (issue #78)

    /// An older build saved the cron run `cron_a1_1` as the active session. The newest chat is `k2`.
    private func cronActiveSessions(mostRecent: String? = nil, chats: FakeChatTransport,
                                    rows: [SessionListItem] = [SessionListItem(id: "cron_a1_1", source: "cron"),
                                                               SessionListItem(id: "k2", title: "Plans")])
        -> SessionListModel {
        SessionListModel(transport: FakeSessionsTransport(mostRecent: mostRecent), chatTransport: chats,
                         cache: InMemorySessionCacheStore(sessions: rows, activeSessionId: "cron_a1_1"))
    }

    @Test func theCachedActiveChatIsNeverACronRun() {
        let chats = FakeChatTransport()
        #expect(cronActiveSessions(chats: chats).cachedActiveChatId == nil)
        // No row in the cache: the legacy run id tells.
        let noRow = SessionListModel(transport: FakeSessionsTransport(), chatTransport: chats,
                                     cache: InMemorySessionCacheStore(activeSessionId: "cron_a1_20261117_080000"))
        #expect(noRow.cachedActiveChatId == nil)
        let chat = SessionListModel(transport: FakeSessionsTransport(), chatTransport: chats,
                                    cache: InMemorySessionCacheStore(sessions: [SessionListItem(id: "k1")],
                                                                     activeSessionId: "k1"))
        #expect(chat.cachedActiveChatId == "k1")
        #expect(chat.cachedActiveSessionId == "k1")
        let unknown = SessionListModel(transport: FakeSessionsTransport(), chatTransport: chats,
                                       cache: InMemorySessionCacheStore(activeSessionId: "dead1"))
        #expect(unknown.cachedActiveChatId == "dead1")
    }

    @Test func theMostRecentChatSkipsCronRunsAndPrefersTheServer() async {
        let chats = FakeChatTransport()
        #expect(await cronActiveSessions(mostRecent: "k9", chats: chats).mostRecentChatId() == "k9")
        #expect(await cronActiveSessions(chats: chats).mostRecentChatId() == "k2")
        let onlyCron = cronActiveSessions(chats: chats, rows: [SessionListItem(id: "cron_a1_1", source: "cron")])
        #expect(await onlyCron.mostRecentChatId() == nil)
    }

    @Test func aCachedCronRunIsSkippedForTheNewestChat() async throws {
        let chats = FakeChatTransport()
        let sessions = cronActiveSessions(chats: chats)
        var shown: [AskHermesRoute] = []
        let task = await AskHermes.run(AskHermesRequest(message: "Hi"), sessions: sessions,
                                       linkReady: { true }, show: { shown.append($0) })
        await task?.value
        #expect(shown == [.session("k2")])
        #expect(chats.resumes == ["k2"])
        #expect(chats.submits.map(\.text) == ["Hi"])
        #expect(sessions.chat(for: "cron_a1_1").messages.isEmpty)
    }

    @Test func aCachedCronRunUsesTheMostRecentChatOfTheServerFirst() async throws {
        let chats = FakeChatTransport()
        let sessions = cronActiveSessions(mostRecent: "k9", chats: chats)
        var shown: [AskHermesRoute] = []
        let task = await AskHermes.run(AskHermesRequest(message: "Hi"), sessions: sessions,
                                       linkReady: { true }, show: { shown.append($0) })
        await task?.value
        #expect(shown == [.session("k9")])
        #expect(chats.resumes == ["k9"])
    }

    @Test func aCachedCronRunWithNoChatStartsANewChat() async throws {
        let chats = FakeChatTransport()
        let sessions = cronActiveSessions(chats: chats, rows: [SessionListItem(id: "cron_a1_1", source: "cron")])
        var shown: [AskHermesRoute] = []
        let task = await AskHermes.run(AskHermesRequest(message: "Hi"), sessions: sessions,
                                       linkReady: { true }, show: { shown.append($0) })
        await task?.value
        guard case .newChat = shown.first, shown.count == 1 else {
            Issue.record("expected one new chat, got \(shown)")
            return
        }
        #expect(chats.resumes.isEmpty)
        #expect(chats.starts.map(\.0) == [ChatSource.iOS])
        #expect(chats.submits.map(\.text) == ["Hi"])
    }

    @Test func offlineStillShowsTheTextAsNotDelivered() async throws {
        let chats = FakeChatTransport()
        chats.failStart = true
        let transport = FakeSessionsTransport(mostRecent: "k9")
        let sessions = SessionListModel(transport: transport, chatTransport: chats, cache: InMemorySessionCacheStore())
        var shown: [AskHermesRoute] = []
        let task = await AskHermes.run(AskHermesRequest(message: "Hi"), sessions: sessions,
                                       linkReady: { false }, show: { shown.append($0) })
        await task?.value
        // No link: no `session.most_recent` call, a new chat, and the owner keeps the text with "Try Again".
        guard case .newChat(let key) = shown.first else {
            Issue.record("expected a new chat, got \(shown)")
            return
        }
        let chat = sessions.newChat(key: key)
        #expect(chat.messages.map(\.text) == ["Hi"])
        #expect(chat.messages.first?.delivery == .failed)
    }

    @Test func noTextOpensTheChatAndSendsNothing() async throws {
        let chats = FakeChatTransport()
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: chats,
                                        cache: InMemorySessionCacheStore(activeSessionId: "k1"))
        var shown: [AskHermesRoute] = []
        var waited = false
        let task = await AskHermes.run(AskHermesRequest(message: "   "), sessions: sessions,
                                       linkReady: {
                                           waited = true
                                           return true
                                       },
                                       show: { shown.append($0) })
        #expect(task == nil)
        #expect(shown == [.session("k1")])
        // Nothing to send, so the run does not wait for the link.
        #expect(!waited)
        #expect(chats.submits.isEmpty)
    }

    // MARK: Link wait

    @Test func waitEndsTrueWhenTheLinkIsReady() async {
        let link = LinkBox()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            link.status = .ready
        }
        let ready = await AskHermes.waitUntilReady(timeout: .seconds(5), poll: .milliseconds(5)) { link.status }
        #expect(ready)
    }

    @Test func waitEndsFalseWhenTheLinkFailsOrIsMissing() async {
        #expect(await AskHermes.waitUntilReady(timeout: .seconds(5), poll: .milliseconds(5)) { .failed } == false)
        #expect(await AskHermes.waitUntilReady(timeout: .seconds(5), poll: .milliseconds(5)) { nil } == false)
    }

    @Test func waitEndsFalseAtTheTimeout() async {
        let clock = ContinuousClock()
        let start = clock.now
        let ready = await AskHermes.waitUntilReady(timeout: .milliseconds(50), poll: .milliseconds(5)) {
            .notConnected
        }
        #expect(!ready)
        #expect(clock.now - start >= .milliseconds(50))
    }
}

@MainActor private final class LinkBox {
    var status: ChatLinkStatus? = .connecting
}
