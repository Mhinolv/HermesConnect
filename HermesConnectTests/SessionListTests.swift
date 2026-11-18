import Foundation
import HermesKit
import SwiftUI
import Testing
import UIKit
@testable import HermesConnect

/// Issue #7: the session list screen, the launch route and the draft in the composer.
@MainActor
@Suite struct SessionListTests {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 15)) ?? Date()

    private func sessions(_ rows: [SessionListItem] = [], active: String? = nil) -> SessionListModel {
        SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                         cache: InMemorySessionCacheStore(sessions: rows, activeSessionId: active))
    }

    @Test func rowTimeLooksLikeMessages() throws {
        let calendar = Calendar.current
        let today = try #require(calendar.date(byAdding: .hour, value: -2, to: now))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let threeDays = try #require(calendar.date(byAdding: .day, value: -3, to: now))
        let old = try #require(calendar.date(byAdding: .day, value: -30, to: now))
        #expect(SessionRowText.time(today, now: now) == today.formatted(date: .omitted, time: .shortened))
        #expect(SessionRowText.time(yesterday, now: now) == "Yesterday")
        #expect(SessionRowText.time(threeDays, now: now) == threeDays.formatted(.dateTime.weekday(.wide)))
        #expect(SessionRowText.time(old, now: now) == old.formatted(date: .numeric, time: .omitted))
    }

    @Test func rowLabelAddsUnreadAndTheSource() throws {
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let plain = SessionListItem(id: "1", title: "Trip", preview: "Book it", startedAt: yesterday, source: "ios")
        #expect(SessionRowText.accessibilityLabel(plain, now: now) == "Trip, Yesterday, Book it")
        let cron = SessionListItem(id: "2", title: nil, preview: "Digest", startedAt: yesterday, source: "cron",
                                   isUnread: true)
        #expect(SessionRowText.accessibilityLabel(cron, now: now) == "Unread, Untitled, Yesterday, Cron, Digest")
        let photon = SessionListItem(id: "3", title: "Dinner", source: "photon")
        #expect(SessionRowText.accessibilityLabel(photon, now: now) == "Dinner, iMessage")
        #expect(photon.sourceBadge?.symbol == "bubble.left")
    }

    @Test func overlayStates() {
        // First load with no cache: the placeholder rows, no overlay.
        #expect(SessionRowText.overlay(hasLoaded: false, total: 0, matches: 0, query: "") == nil)
        #expect(SessionRowText.overlay(hasLoaded: true, total: 0, matches: 0, query: "") == .noChats)
        #expect(SessionRowText.overlay(hasLoaded: true, total: 3, matches: 0, query: "zebra") == .noResults)
        #expect(SessionRowText.overlay(hasLoaded: true, total: 3, matches: 3, query: "") == nil)
        #expect(SessionRowText.overlay(hasLoaded: true, total: 3, matches: 0, query: "  ") == nil)
    }

    @Test func launchPushesTheCachedActiveSession() {
        #expect(ChatLaunch.cachedLaunchRoute(sessions(active: "k1")) == .session("k1"))
        #expect(ChatLaunch.cachedLaunchRoute(sessions()) == nil)
    }

    /// Issue #36: a new chat with a kept memo opens at launch, before the active session.
    @Test func launchOpensTheNewChatWithAKeptMemo() {
        let memo = ChatMessage(id: "m1", role: .user, text: "", date: now, delivery: .failed,
                               voice: VoiceMemo(fileURL: URL(fileURLWithPath: "/tmp/m1.m4a"), duration: 3, waveform: [],
                                                transcript: .failed))
        let cache = InMemorySessionCacheStore(transcripts: [SessionCache.newChatId: [memo]], activeSessionId: "k1")
        let list = SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(), cache: cache)
        let route = ChatLaunch.cachedLaunchRoute(list)
        #expect(route == .new(SessionCache.newChatId))
        #expect(list.newChat(key: SessionCache.newChatId).messages.map(\.id) == ["m1"])
    }

    /// QA #27 defect 1: after a dead id is dropped, the next launch shows the list, not a dead chat.
    @Test func droppedSessionIsNotTheLaunchRoute() {
        let list = sessions([SessionListItem(id: "dead1", title: "Gone")], active: "dead1")
        #expect(ChatLaunch.cachedLaunchRoute(list) == .session("dead1"))
        list.forget("dead1")
        #expect(ChatLaunch.cachedLaunchRoute(list) == nil)
        #expect(list.sessions.isEmpty)
    }

    @Test func listScreenRendersEveryState() throws {
        let rows = [
            SessionListItem(id: "k1", title: "Trip", preview: "Book it", startedAt: now, source: "ios"),
            SessionListItem(id: "k2", title: "Digest", preview: "3 issues", startedAt: now, source: "cron", isUnread: true),
        ]
        for (model, query) in [(sessions(rows), ""), (sessions(rows), "zebra"), (sessions(), "")] {
            let host = UIHostingController(rootView: NavigationStack {
                SessionListScreen(model: model, query: query)
            }.environment(AppModel.preview(setUp: true)))
            host.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            host.view.layoutIfNeeded()
            #expect(host.view.bounds.width == 402)
        }
    }

    @Test func composerRestoresAndSavesTheDraft() {
        let cache = InMemorySessionCacheStore()
        cache.saveDraft("Half a thought", sessionId: "k1")
        let model = ChatViewModel(transport: OfflineChatTransport(), storedSessionId: "k1", cache: cache)
        let controller = ChatViewController(model: model)
        controller.loadViewIfNeeded()
        #expect(controller.messageInputBar.inputTextView.text == "Half a thought")
        controller.inputBar(controller.messageInputBar, textViewTextDidChangeTo: "Half a thought, done")
        #expect(cache.loadDraft(sessionId: "k1") == "Half a thought, done")
    }

    @Test func chatModelsComeFromTheListModel() {
        let list = sessions([SessionListItem(id: "k1", title: "Trip")])
        #expect(list.chat(for: "k1") === list.chat(for: "k1"))
        #expect(list.chat(for: "k1").title == "Trip")
        #expect(list.newChat(key: "a").storedSessionId == nil)
    }
}

/// Issue #94: the "More" menu of the Chats list.
@MainActor
@Suite struct ChatsMoreMenuTests {
    @Test func theMenuTextsFollowTheDesignNotes() {
        #expect(ChatsMoreText.more == "More")
        #expect(ChatsMoreText.hint == "Shows chat actions.")
        #expect(ChatsMoreText.markAllRead == "Mark All as Read")
        #expect(ChatsMoreText.selectChats == "Select Chats")
        #expect(ChatsMoreText.announcement == "All chats marked as read")
    }

    @Test func theListRendersWithTheMenuOnAndOff() {
        let unread = [SessionListItem(id: "k1", title: "Trip", preview: "Book it", source: "ios", isUnread: true)]
        let cronOnly = [SessionListItem(id: "k2", title: "Digest", source: "cron", isUnread: true)]
        for rows in [unread, cronOnly] {
            let model = SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                                         cache: InMemorySessionCacheStore(sessions: rows))
            #expect(model.canMarkAllRead == (rows == unread))
            let host = UIHostingController(rootView: NavigationStack {
                SessionListScreen(model: model)
            }.environment(AppModel.preview(setUp: true)))
            host.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            host.view.layoutIfNeeded()
            #expect(host.view.bounds.width == 402)
        }
    }
}

/// Issue #95: the text of select mode and its partial-failure alert.
@MainActor
@Suite struct ChatSelectTests {
    @Test func theTitleAndTheArchiveLabelCountTheSelection() {
        #expect(ChatSelectText.title(0) == "Select Chats")
        #expect(ChatSelectText.title(3) == "3 Selected")
        #expect(ChatSelectText.archiveLabel(1) == "Archive 1 chat")
        #expect(ChatSelectText.archiveLabel(3) == "Archive 3 chats")
        #expect(ChatSelectText.announcement(3) == "3 chats archived")
        #expect(ChatSelectText.announcement(1) == "1 chat archived")
        #expect(ChatSelectText.selectAll == "Select All")
        #expect(ChatSelectText.deselectAll == "Deselect All")
    }

    @Test func theFailureAlertFollowsTheDesignNotes() {
        let some = BatchArchiveFailure(archived: 3, failed: 2)
        #expect(some.title == "Couldn't Archive 2 Chats")
        #expect(some.message == "3 chats were archived. The other 2 are back in the list.")
        let one = BatchArchiveFailure(archived: 1, failed: 1)
        #expect(one.title == "Couldn't Archive Chat")
        #expect(one.message == "1 chat was archived. The other chat is back in the list.")
        let none = BatchArchiveFailure(archived: 0, failed: 4)
        #expect(none.title == "Couldn't Archive 4 Chats")
        #expect(none.message == "No chats were archived. Try again later.")
    }

    @Test func theMenuStartsSelectModeOnlyWithChatRows() {
        let rows = [SessionListItem(id: "k1", title: "Trip", source: "ios")]
        for cached in [rows, []] {
            let model = SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                                         cache: InMemorySessionCacheStore(sessions: cached))
            let host = UIHostingController(rootView: NavigationStack {
                SessionListScreen(model: model)
            }.environment(AppModel.preview(setUp: true)))
            host.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            host.view.layoutIfNeeded()
            #expect(host.view.bounds.width == 402)
        }
    }
}

/// Issue #64: the texts and states of rename, archive and delete.
@MainActor
@Suite struct SessionActionsUITests {
    @Test func archivedRowShowsOnlyWithArchivedChatsAndNoSearch() {
        #expect(!SessionRowText.showsArchivedRow(count: 0, query: ""))
        #expect(SessionRowText.showsArchivedRow(count: 2, query: ""))
        #expect(SessionRowText.showsArchivedRow(count: 2, query: "  "))
        #expect(!SessionRowText.showsArchivedRow(count: 2, query: "trip"))
        #expect(SessionRowText.archivedLabel(1) == "Archived, 1 chat")
        #expect(SessionRowText.archivedLabel(3) == "Archived, 3 chats")
    }

    @Test func noChatsGivesWayToTheArchivedRow() {
        #expect(SessionRowText.overlay(hasLoaded: true, total: 0, matches: 0, query: "", archived: 0) == .noChats)
        #expect(SessionRowText.overlay(hasLoaded: true, total: 0, matches: 0, query: "", archived: 4) == nil)
        #expect(SessionRowText.overlay(hasLoaded: true, total: 0, matches: 0, query: "zebra", archived: 4) == .noChats)
    }

    @Test func saveIsOffForAnEmptyOrUnchangedTitle() {
        #expect(!SessionActionText.canSave("", current: "Trip"))
        #expect(!SessionActionText.canSave("   \n", current: "Trip"))
        #expect(!SessionActionText.canSave(" Trip ", current: "Trip"))
        #expect(SessionActionText.canSave("Trip to Denver", current: "Trip"))
        #expect(SessionActionText.canSave("Trip", current: ""))
    }

    @Test func renameStartsWithTheCurrentTitleAllSelected() {
        let state = SessionActionState()
        state.startRename(SessionActionTarget(SessionListItem(id: "k1", title: " Trip ")))
        #expect(state.renameTarget == SessionActionTarget(id: "k1", title: "Trip"))
        #expect(state.renameText == "Trip")
        #expect(state.renameSelection != nil)
        #expect(!state.canSave)
        state.renameText = "Trip to Denver"
        #expect(state.canSave)
    }

    @Test func dialogTextsMatchTheDesignNotes() {
        #expect(SessionActionText.renameTitle == "Rename Chat")
        #expect(SessionActionText.deleteTitle == "Delete This Chat?")
        #expect(SessionActionText.deleteMessage
            == "This deletes the chat on all your devices and apps, including Hermes on your Mac. You can't undo this.")
        #expect(SessionActionText.deleteButton == "Delete Chat")
        #expect(SessionActionText.failureTitle(.rename) == "Couldn't Rename Chat")
        #expect(SessionActionText.failureTitle(.archive) == "Couldn't Archive Chat")
        #expect(SessionActionText.failureTitle(.delete) == "Couldn't Delete Chat")
    }

    /// The offline transport has no session actions: the error alert shows and the row stays.
    @Test func aFailedActionShowsTheAlertAndKeepsTheRow() async throws {
        let rows = [SessionListItem(id: "k1", title: "Trip")]
        let model = SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                                     cache: InMemorySessionCacheStore(sessions: rows))
        let state = SessionActionState()
        state.deleteTarget = SessionActionTarget(rows[0])
        state.confirmDelete(model)
        #expect(state.deleteTarget == nil)
        for _ in 0..<200 where state.failure == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(state.failure?.title == "Couldn't Delete Chat")
        #expect(state.failure?.message == "Hermes is not connected. Try again when the connection is back.")
        #expect(model.sessions == rows)
    }
}
