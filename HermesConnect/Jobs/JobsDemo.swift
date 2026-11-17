import Foundation
import HermesKit

/// Fixture jobs for previews and the DEBUG screenshots of the Jobs tab (issue #73).
///
/// DEBUG only: `HERMES_DEMO_JOBS` opens the Jobs tab with `HERMES_DEMO=list`.
/// Values: `list` (all statuses), `job` (job screen), `run` (run screen), `failed-run` (script-only failed run),
/// `empty`, `error`, `loading`. `HERMES_DEMO_SEARCH` also fills the search field.
@MainActor
enum JobsDemo {
    enum Scenario: String {
        case list
        case job
        case run
        case failedRun = "failed-run"
        case empty
        case error
        case loading
    }

    static var current: Scenario? {
        #if DEBUG
        ProcessInfo.processInfo.environment["HERMES_DEMO_JOBS"].flatMap(Scenario.init(rawValue:))
        #else
        nil
        #endif
    }

    /// The tab at launch: Jobs for a Jobs screenshot, else Chats.
    static var initialTab: RootTab { current == nil ? .chats : .jobs }

    static var search: String {
        guard current != nil else { return "" }
        return ChatLaunch.demoSearch
    }

    /// The screens that the demo pushes at launch.
    static var initialPath: [JobsRoute] {
        let jobs = jobs()
        switch current {
        case .job: return [.job(jobs[0])]
        case .run: return [.job(jobs[0]), .run(runs()[0], jobName: jobs[0].displayName)]
        case .failedRun: return [.job(jobs[0]), .run(runs()[1], jobName: jobs[0].displayName)]
        default: return []
        }
    }

    /// The DEBUG job list, or `nil` when no Jobs demo runs.
    static func makeJobs() -> JobsModel? {
        guard let scenario = current else { return nil }
        let transport = DemoCronTransport(scenario: scenario)
        let cache = InMemoryCronJobCacheStore(jobs: scenario == .list || scenario == .job ? jobs() : nil)
        return JobsModel(transport: transport, cache: cache)
    }

    /// One job of each status.
    nonisolated static func jobs(now: Date = Date()) -> [CronJob] {
        let hour: TimeInterval = 3600
        return [
            CronJob(id: "a1", name: "Morning Zillow new rental watch", state: "scheduled",
                    scheduleDisplay: "Every day at 8:00 AM", lastRunAt: now.addingTimeInterval(-2 * hour),
                    nextRunAt: now.addingTimeInterval(22 * hour), lastStatus: "ok"),
            CronJob(id: "b2", name: "Inbox digest", state: "scheduled", scheduleDisplay: "Every 2 hours",
                    lastRunAt: now.addingTimeInterval(-60), nextRunAt: now.addingTimeInterval(2 * hour),
                    latestExecution: .init(id: "e2", status: "running")),
            CronJob(id: "c3", name: "Backup check", state: "scheduled", scheduleDisplay: "Every 6 hours",
                    lastRunAt: now.addingTimeInterval(-5 * hour), nextRunAt: now.addingTimeInterval(hour),
                    lastStatus: "error", lastError: "Script exited with code 2: disk /mnt/backup is not mounted"),
            CronJob(id: "d4", name: "Weekly expense report", state: "paused", scheduleDisplay: "Mondays at 9:00 AM",
                    lastRunAt: now.addingTimeInterval(-6 * 24 * hour)),
            CronJob(id: "e5", name: "Passport renewal reminder", enabled: false, state: "completed",
                    scheduleDisplay: "Once on Nov 1 at 10:00 AM", lastRunAt: now.addingTimeInterval(-16 * 24 * hour)),
        ]
    }

    nonisolated static func runs(now: Date = Date()) -> [CronRun] {
        let day: TimeInterval = 24 * 3600
        return [
            CronRun(id: "cron_a1_demo_1", title: "Morning Zillow new rental watch",
                    preview: "3 new rentals match your search. The best one is a 2-bedroom on Elm St for $2,150.",
                    startedAt: now.addingTimeInterval(-7200), endedAt: now.addingTimeInterval(-7100), messageCount: 2),
            CronRun(id: "cron_output:a1:demo_2", title: "FAILED · Zillow returned HTTP 429 (too many requests)",
                    preview: "Traceback (most recent call last): requests.exceptions.HTTPError: 429 Client Error",
                    source: "cron_output", startedAt: now.addingTimeInterval(-day - 7200)),
            CronRun(id: "cron_a1_demo_3", title: "Morning Zillow new rental watch",
                    preview: "No new rentals today.", startedAt: now.addingTimeInterval(-2 * day - 7200), messageCount: 2),
        ]
    }

    nonisolated static let transcript = [
        TranscriptMessage(role: "user", text: "Check Zillow for new 2-bedroom rentals under $2,300 near downtown.", rowId: 1),
        TranscriptMessage(role: "assistant", text: """
        **3 new rentals** match your search:

        1. **412 Elm St**, 2 bd, $2,150. Available Dec 1.
        2. **88 Pine Ave**, 2 bd, $2,275. Parking included.
        3. **1520 Oak Blvd #4**, 2 bd, $2,295. In-unit laundry.

        The Elm St unit is the best value. Do you want me to ask for a tour?
        """, rowId: 2),
    ]
}

/// The DEBUG cron server of the Jobs demo. No network.
struct DemoCronTransport: CronTransport {
    let scenario: JobsDemo.Scenario
    let events: AsyncStream<GatewayClientEvent> = AsyncStream { _ in }

    func fetchCronJobs() async throws -> [CronJob] {
        switch scenario {
        case .loading:
            try await Task.sleep(for: .seconds(3600))
            return []
        case .empty:
            return []
        case .error:
            throw CronAPIError(status: 500, detail: "The cron scheduler is not running on this profile.")
        default:
            try await Task.sleep(for: .milliseconds(300))
            return JobsDemo.jobs()
        }
    }

    func fetchCronRuns(jobId _: String, limit _: Int) async throws -> [CronRun] {
        try await Task.sleep(for: .milliseconds(300))
        return JobsDemo.runs()
    }

    func fetchRunTranscript(sessionId _: String) async throws -> [TranscriptMessage] {
        try await Task.sleep(for: .milliseconds(200))
        return JobsDemo.transcript
    }
}
