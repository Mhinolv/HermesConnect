import Foundation
import Testing
@testable import HermesKit

/// Issue #83, QA 90-1 defect 1: the new chat with no server row belongs to the server that was active.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct NewChatSlotSwitchTests {
    /// Server A: new chat, offline, one queued message in the new-chat slot. Then the owner switches to B.
    @Test func queuedNewChatMessageOfServerADoesNotShowOrSendOnServerB() async throws {
        let cache = InMemorySessionCacheStore()
        let offline = OutboxTransport(online: false)
        let a = SessionListModel(transport: FakeSessionsTransport(), chatTransport: offline, cache: cache)
        let chat = a.newChat(key: "new1")
        await chat.send("secret for A")?.value
        #expect(cache.outboxSessionIds().contains(SessionCache.newChatId), "precondition: slot outbox set")

        // Switch to B (same list model, as in the app).
        let state = a.serverState()
        #expect(state.outboxIds.isEmpty, "slot outbox is not tracked by the book (engineer caveat)")
        let online = OutboxTransport(online: true)
        let b = SessionListModel(transport: FakeSessionsTransport(), chatTransport: online, cache: cache)
        b.switchServer(carryingUnread: [], heldOutboxes: [])
        // The owner taps compose on B.
        let bChat = b.newChat(key: "new2")
        let texts = bChat.messages.map(\.text)
        #expect(texts.isEmpty, "server B new chat must not show A's queued message")
        await bChat.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(online.submits.isEmpty, "A's message must never be submitted to B")
    }

    /// The queued new chat of A waits under the parked key while B is active, then comes back and sends on A.
    @Test func theParkedNewChatOfServerAComesBackAndSendsOnlyOnA() async throws {
        let cache = InMemorySessionCacheStore()
        let serverA = UUID()
        let offline = OutboxTransport(online: false)
        let a = SessionListModel(transport: FakeSessionsTransport(), chatTransport: offline, cache: cache)
        let chat = a.newChat(key: "new1")
        await chat.send("for A")?.value
        cache.saveDraft("half typed", sessionId: SessionCache.newChatId)
        let parked = SessionCache.parkedNewChatId(server: serverA)

        // A to B: park the slot. Nothing of A is in the slot or in the outbox.
        let online = OutboxTransport(online: true)
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: online, cache: cache)
        sessions.switchServer(carryingUnread: [], heldOutboxes: [], parkNewChatAs: parked)
        #expect(!sessions.hasCachedNewChat)
        #expect(cache.loadDraft(sessionId: SessionCache.newChatId).isEmpty)
        #expect(!cache.outboxSessionIds().contains(parked), "a parked new chat never sends")
        #expect(cache.outboxSessionIds().isEmpty)
        sessions.receive(connected)
        let onB = sessions.newChat(key: "new2")
        await onB.open()
        try await Task.sleep(for: .milliseconds(150))
        #expect(onB.messages.isEmpty)
        #expect(online.submits.isEmpty)

        // B to A: the slot comes back with its draft and its outbox, and sends on the next connect.
        sessions.switchServer(carryingUnread: [], heldOutboxes: [], restoreNewChatFrom: parked)
        #expect(sessions.hasCachedNewChat)
        #expect(cache.loadDraft(sessionId: SessionCache.newChatId) == "half typed")
        #expect(cache.outboxSessionIds() == [SessionCache.newChatId])
        #expect(cache.loadTranscript(sessionId: parked).isEmpty, "the parked key is empty again")
        let back = sessions.newChat(key: "new3")
        #expect(back.messages.map(\.text) == ["for A"])
        await back.open()
        try await waitUntil { online.submits == ["for A"] }
    }

    @Test func aRemovedServerLosesItsParkedNewChat() async {
        let cache = InMemorySessionCacheStore()
        let parked = SessionCache.parkedNewChatId(server: UUID())
        let offline = OutboxTransport(online: false)
        let sessions = SessionListModel(transport: FakeSessionsTransport(), chatTransport: offline, cache: cache)
        await sessions.newChat(key: "new1").send("one")?.value
        sessions.switchServer(carryingUnread: [], heldOutboxes: [], parkNewChatAs: parked)
        #expect(cache.transcriptIds == [parked])
        sessions.removeParkedNewChat(parked)
        #expect(cache.transcriptIds.isEmpty)
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
