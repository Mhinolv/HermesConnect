import Foundation
import Testing
@testable import HermesKit

/// Issue #83, QA 90-1 defect 1: the new chat with no server row belongs to the server that was active.
/// Issue #84: each server has its own cache folder, so the new-chat slot of each server is in its own folder.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct NewChatSlotSwitchTests {
    private let serverA = UUID()
    private let serverB = UUID()

    /// Server A: new chat, offline, one queued message in the new-chat slot. Then the owner switches to B.
    @Test func queuedNewChatMessageOfServerADoesNotShowOrSendOnServerB() async throws {
        let caches = ServerCaches(inMemory: serverA)
        let cache = caches.sessions
        let offline = OutboxTransport(online: false)
        let a = SessionListModel(transport: FakeSessionsTransport(), chatTransport: offline, cache: cache)
        let chat = a.newChat(key: "new1")
        await chat.send("secret for A")?.value
        #expect(cache.outboxSessionIds().contains(SessionCache.newChatId), "precondition: slot outbox set")

        // Switch to B (same cache, as in the app).
        let state = a.serverState()
        #expect(state.outboxIds.isEmpty, "slot outbox is not tracked by the book (engineer caveat)")
        let online = OutboxTransport(online: true)
        let b = SessionListModel(transport: FakeSessionsTransport(), chatTransport: online, cache: cache)
        caches.select(serverB)
        b.switchServer(carryingUnread: [])
        // The owner taps compose on B.
        let bChat = b.newChat(key: "new2")
        let texts = bChat.messages.map(\.text)
        #expect(texts.isEmpty, "server B new chat must not show A's queued message")
        await bChat.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(online.submits.isEmpty, "A's message must never be submitted to B")
    }

    /// The queued new chat of A waits in the folder of A while B is active, then comes back and sends on A.
    @Test func theNewChatOfServerAStaysInItsFolderAndSendsOnlyOnA() async throws {
        let caches = ServerCaches(inMemory: serverA)
        let cache = caches.sessions
        let offline = OutboxTransport(online: false)
        let a = SessionListModel(transport: FakeSessionsTransport(), chatTransport: offline, cache: cache)
        let chat = a.newChat(key: "new1")
        await chat.send("for A")?.value
        cache.saveDraft("half typed", sessionId: SessionCache.newChatId)

        // A to B: nothing of A is in the slot or in the outbox of B.
        let online = OutboxTransport(online: true)
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: online, cache: cache)
        caches.select(serverB)
        sessions.switchServer(carryingUnread: [])
        #expect(!sessions.hasCachedNewChat)
        #expect(cache.loadDraft(sessionId: SessionCache.newChatId).isEmpty)
        #expect(cache.outboxSessionIds().isEmpty)
        sessions.receive(connected)
        let onB = sessions.newChat(key: "new2")
        await onB.open()
        try await Task.sleep(for: .milliseconds(150))
        #expect(onB.messages.isEmpty)
        #expect(online.submits.isEmpty)

        // B to A: the slot comes back with its draft and its outbox, and sends on the next connect.
        caches.select(serverA)
        sessions.switchServer(carryingUnread: [])
        #expect(sessions.hasCachedNewChat)
        #expect(cache.loadDraft(sessionId: SessionCache.newChatId) == "half typed")
        #expect(cache.outboxSessionIds() == [SessionCache.newChatId])
        let back = sessions.newChat(key: "new3")
        #expect(back.messages.map(\.text) == ["for A"])
        await back.open()
        try await waitUntil { online.submits == ["for A"] }
    }

    @Test func aRemovedServerLosesItsNewChat() async {
        let caches = ServerCaches(inMemory: serverA)
        let offline = OutboxTransport(online: false)
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: offline,
                                        cache: caches.sessions)
        await sessions.newChat(key: "new1").send("one")?.value
        caches.select(serverB)
        sessions.switchServer(carryingUnread: [])
        caches.remove(server: serverA)
        #expect(caches.sessionStore(for: serverA).loadTranscript(sessionId: SessionCache.newChatId).isEmpty)
        #expect(caches.sessionStore(for: serverA).outboxSessionIds().isEmpty)
    }

    /// A chat of the old server can save its draft after the switch. The draft goes to its own server.
    @Test func aLateDraftOfTheOldServerStaysInItsFolder() async {
        let caches = ServerCaches(inMemory: serverA)
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: FakeChatTransport(),
                                        cache: caches.sessions)
        let old = sessions.chat(for: "20261117_080000_aaaa01")
        caches.select(serverB)
        sessions.switchServer(carryingUnread: [])
        old.updateDraft("typed during the switch")
        #expect(caches.sessionStore(for: serverA).loadDraft(sessionId: "20261117_080000_aaaa01")
            == "typed during the switch")
        #expect(caches.sessionStore(for: serverB).loadDraft(sessionId: "20261117_080000_aaaa01").isEmpty)
    }
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
