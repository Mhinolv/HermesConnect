import Foundation
import HermesKit
import MessageKit
import SwiftUI
import Testing
import UIKit
@testable import HermesConnect

/// Issue #73: the Jobs tab text, its screens in every state, and the read-only run thread.
@MainActor
@Suite(.serialized) struct JobsTabTests {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 15)) ?? Date()

    private func render<Content: View>(_ view: Content) {
        let host = UIHostingController(rootView: NavigationStack { view }.environment(AppModel.preview(setUp: true)))
        host.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        host.view.layoutIfNeeded()
        #expect(host.view.bounds.width == 402)
    }

    @Test func rowTextShowsTheStatusThenTheSchedule() {
        let jobs = JobsDemo.jobs(now: now)
        #expect(JobsText.statusLine(jobs[0]) == "Every day at 8:00 AM")
        #expect(JobsText.statusLine(jobs[1]) == "Running · Every 2 hours")
        #expect(JobsText.statusLine(jobs[2]) == "Failed · Every 6 hours")
        #expect(JobsText.statusLine(jobs[3]) == "Paused · Mondays at 9:00 AM")
        #expect(JobsText.statusLine(jobs[4]) == "Off · Once on Nov 1 at 10:00 AM")
        #expect(JobsText.statusLine(CronJob(id: "x")) == "No schedule")
    }

    @Test func voiceOverReadsNameStatusScheduleAndLastRun() throws {
        let lastRun = try #require(Calendar.current.date(byAdding: .hour, value: -2, to: now))
        let job = CronJob(id: "a1", name: "Morning Zillow", state: "paused", scheduleDisplay: "Every day at 8:00 AM",
                          lastRunAt: lastRun)
        #expect(JobsText.accessibilityLabel(job, now: now)
            == "Morning Zillow, Paused, Every day at 8:00 AM, last run \(SessionRowText.time(lastRun, now: now))")
        let failed = CronJob(id: "b2", name: "Backup", lastError: "disk full")
        #expect(JobsText.accessibilityLabel(failed, now: now) == "Backup, Failed, disk full")
        #expect(JobsText.accessibilityLabel(CronJob(id: "c3"), now: now) == "Untitled Job, Scheduled")
    }

    @Test func runRowsDropTheStatusPrefixFromATitleOnlyPreview() {
        #expect(JobsText.runPreview(CronRun(id: "r", title: "FAILED · Zillow returned 429")) == "Zillow returned 429")
        #expect(JobsText.runPreview(CronRun(id: "r", title: "FAILED · x", preview: "Traceback")) == "Traceback")
        #expect(JobsText.runPreview(CronRun(id: "r", title: "Zillow · watch", preview: nil)) == "Zillow · watch")
        #expect(JobsText.dateTime(nil) == "Never")
        let run = CronRun(id: "r", title: "FAILED · boom", startedAt: now)
        #expect(JobsText.accessibilityLabel(run) == "\(JobsText.dateTime(now)), Failed, boom")
    }

    @Test func jobListRendersEveryState() async {
        let jobs = JobsDemo.jobs(now: now)
        let loaded = JobsModel(transport: OfflineCronTransport(), cache: InMemoryCronJobCacheStore(jobs: jobs))
        let empty = JobsModel(transport: OfflineCronTransport(), cache: InMemoryCronJobCacheStore(jobs: []))
        let loading = JobsModel(transport: OfflineCronTransport(), cache: InMemoryCronJobCacheStore())
        let failed = JobsModel(transport: OfflineCronTransport(), cache: InMemoryCronJobCacheStore())
        await failed.refresh()
        #expect(loaded.state(query: "") == .rows)
        #expect(empty.state(query: "") == .empty)
        #expect(loading.state(query: "") == .loading)
        #expect(failed.state(query: "") == .error("Hermes is not connected."))
        // Offline with a cache: the list, no error.
        await loaded.refresh()
        #expect(loaded.state(query: "") == .rows)
        for (model, query) in [(loaded, ""), (loaded, "zebra"), (empty, ""), (loading, ""), (failed, "")] {
            render(JobsListScreen(model: model, query: query))
        }
    }

    @Test func jobScreenAndRunScreenRender() {
        let jobs = JobsModel(transport: OfflineCronTransport(),
                             cache: InMemoryCronJobCacheStore(jobs: JobsDemo.jobs(now: now),
                                                              runs: ["a1": JobsDemo.runs(now: now)]))
        render(JobScreen(jobs: jobs, job: JobsDemo.jobs(now: now)[0]))
        render(JobScreen(jobs: jobs, job: JobsDemo.jobs(now: now)[2]))
        let output = JobsDemo.runs(now: now)[1]
        render(CronRunScreen(model: CronRunTranscriptModel(run: output, transport: OfflineCronTransport()),
                             jobName: "Morning Zillow"))
        render(CronRunScreen(model: CronRunTranscriptModel(run: JobsDemo.runs(now: now)[0], transport: OfflineCronTransport()),
                             jobName: "Morning Zillow"))
    }

    @Test func runThreadHasNoComposerAndNoTapbacks() async throws {
        let messages = [
            ChatMessage(id: "u1", role: .user, text: "Check Zillow", date: now, delivery: .delivered, userRowId: 1),
            ChatMessage(id: "a1", role: .assistant, text: "**3** new rentals", date: now, reply: .complete, promptId: "u1"),
        ]
        let model = ChatViewModel(transport: OfflineChatTransport(), title: "Zillow", messages: messages)
        let controller = ChatViewController(model: model, readOnly: true)
        controller.loadViewIfNeeded()
        #expect(controller.messageInputBar.superview == nil)
        // MessageKit puts the empty bar in place on the next main queue turn.
        try await Task.sleep(for: .milliseconds(300))
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        controller.messagesCollectionView.layoutIfNeeded()
        // The composer is not on the screen.
        #expect(controller.messageInputBar.superview == nil)
        #expect(!controller.messageInputBar.isDescendant(of: controller.view))
        #expect(controller.inputContainerView.bounds.height < 1)
        // No double-tap for the tapback capsule.
        let doubleTaps = (controller.messagesCollectionView.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTapsRequired == 2 }
        #expect(doubleTaps.isEmpty)
        controller.showTapbackPicker(messageId: "a1")
        #expect(controller.tapbackPicker == nil)
        // VoiceOver: "Copy", no "React".
        let cell = controller.collectionView(controller.messagesCollectionView,
                                             cellForItemAt: IndexPath(item: 0, section: 1))
        let names = (cell.accessibilityCustomActions ?? []).map(\.name)
        #expect(names.contains("Copy"))
        #expect(!names.contains { $0.hasPrefix("React") })
        // Long press: "Copy", no tapback row.
        let menu = controller.collectionView(controller.messagesCollectionView,
                                             contextMenuConfigurationForItemsAt: [IndexPath(item: 0, section: 1)],
                                             point: .zero)
        #expect(menu != nil)
    }

    @Test func chatThreadKeepsTheComposer() {
        let model = ChatViewModel(transport: OfflineChatTransport(), messages: [])
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(),
                                            voiceFolder: FileManager.default.temporaryDirectory)
        controller.loadViewIfNeeded()
        #expect(controller.messageInputBar.isDescendant(of: controller.view))
    }

    @Test func aNotificationTapOnACronRunOpensTheRunScreenInTheJobsTab() async {
        let run = SessionListItem(id: "cron_a1_20261117_080003", title: "Morning Zillow new rental watch",
                                  preview: "3 new rentals", startedAt: now, messageCount: 2, source: "cron", isUnread: true)
        let chat = SessionListItem(id: "k1", title: "Trip", startedAt: now, source: "ios", isUnread: true)
        let sessions = SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                                        cache: InMemorySessionCacheStore(sessions: [run, chat]))
        let jobs = JobsModel(transport: OfflineCronTransport(), cache: InMemoryCronJobCacheStore(jobs: JobsDemo.jobs(now: now)))
        let job = JobsDemo.jobs(now: now)[0]
        // The job screen, then the read-only run screen of that session.
        #expect(JobsRouting.path(forSession: run.id, sessions: sessions, jobs: jobs)
            == [.job(job), .run(CronRun(session: run), jobName: job.displayName)])
        // A chat opens as a chat.
        #expect(JobsRouting.path(forSession: "k1", sessions: sessions, jobs: jobs) == nil)
        #expect(JobsRouting.path(forSession: "unknown", sessions: sessions, jobs: jobs) == nil)
        // A cron run that the list does not have yet still opens read-only.
        #expect(JobsRouting.path(forSession: "cron_zz_1", sessions: sessions, jobs: jobs)
            == [.run(CronRun(id: "cron_zz_1", source: "cron"), jobName: "Untitled")])
        // Issue #122: the Chats tab counts chats. The Jobs tab has no badge for an unread run.
        #expect(RootTab.chats.badge(sessions) == 1)
        #expect(RootTab.jobs.badge(sessions) == 0)
        #expect(RootTab.voice.badge(sessions) == 0)
        // Job rows and run rows have no unread dot, and VoiceOver does not say "Unread".
        #expect(JobsText.accessibilityLabel(job, now: now).hasPrefix("Morning Zillow"))
        #expect(!JobsText.accessibilityLabel(CronRun(session: run)).contains("Unread"))
        // The chats list and the launch route skip the cron run.
        #expect(sessions.filtered("").map(\.id) == ["k1"])
        let launch = SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                                      cache: InMemorySessionCacheStore(sessions: [run], activeSessionId: run.id))
        #expect(ChatLaunch.cachedLaunchRoute(launch) == nil)
        render(JobsListScreen(model: jobs))
        render(JobScreen(jobs: jobs, job: job))
    }

    @Test func rootViewHasTheJobsTab() {
        _ = RootView(jobs: ChatLaunch.makeOfflineJobs())
        #expect(JobsDemo.initialTab == .chats)
        #expect(JobsDemo.initialPath.isEmpty)
    }
}
