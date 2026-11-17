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
