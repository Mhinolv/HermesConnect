import Foundation
import Observation

/// What a list of the Jobs tab shows (issue #73 design notes, "States").
public enum CronListState: Sendable, Equatable {
    /// The first load: 5 redacted rows.
    case loading
    /// The load failed and no list is cached: "Couldn't Load Jobs", the server message, "Try Again".
    case error(String)
    /// The server has no rows: "No Jobs" or "No Runs".
    case empty
    /// The search text matches no row.
    case noResults
    case rows

    /// Offline with a cached list shows the list, not the error. The title shows the connection status.
    static func make(hasLoaded: Bool, error: String?, total: Int, matches: Int, query: String) -> CronListState {
        guard hasLoaded else { return error.map(CronListState.error) ?? .loading }
        if total == 0 { return .empty }
        if matches == 0, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noResults }
        return .rows
    }
}

/// `true` for the items that refresh the cron lists: a connect, `cron.changed` and `sessions.changed`.
/// The server does not replay these events after a reconnect (docs/hermes-protocol.md 3.6).
enum CronRefreshTrigger {
    static func refreshes(on item: GatewayClientEvent) -> Bool {
        switch item {
        case .state(.connected): true
        case .event(let event): event.kind == .cronChanged || event.kind == .sessionsChanged
        default: false
        }
    }
}

/// The job list of the Jobs tab (issue #73). Read-only: no Run now, pause or resume (owner decision).
///
/// - The cached list shows at once. A failed load keeps it, so offline the tab shows the cached list.
/// - With no cache, a failed load shows the error with the server message.
@MainActor @Observable
public final class JobsModel {
    public private(set) var jobs: [CronJob]
    /// `true` after the first answer, or when the cache has a list (also an empty one).
    public private(set) var hasLoaded: Bool
    /// The message of the last failed load. A good load clears it.
    public private(set) var errorMessage: String?
    public private(set) var isRefreshing = false

    /// The run screen loads its transcript with it.
    @ObservationIgnored public let transport: any CronTransport
    @ObservationIgnored private let cache: any CronJobCacheStore
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(transport: any CronTransport, cache: any CronJobCacheStore) {
        self.transport = transport
        self.cache = cache
        let cached = cache.loadJobs()
        jobs = cached ?? []
        hasLoaded = cached != nil
    }

    public func filtered(_ query: String) -> [CronJob] {
        jobs.filter { $0.matches(query) }
    }

    public func job(id: String) -> CronJob? {
        jobs.first { $0.id == id }
    }

    public func state(query: String) -> CronListState {
        CronListState.make(hasLoaded: hasLoaded, error: errorMessage, total: jobs.count,
                           matches: filtered(query).count, query: query)
    }

    /// `GET /api/cron/jobs`. Calls at the same time share one request.
    public func refresh() async {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await load() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func load() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await transport.fetchCronJobs()
            errorMessage = nil
            hasLoaded = true
            guard fresh != jobs || cache.loadJobs() == nil else { return }
            jobs = fresh
            cache.saveJobs(fresh)
        } catch {
            errorMessage = CronErrorText.message(for: error)
        }
    }

    /// Refreshes on each connect, `cron.changed` and `sessions.changed` until the task ends.
    /// The Jobs list runs it while it is on the screen, and refreshes when it shows again.
    public func watch(_ events: AsyncStream<GatewayClientEvent>? = nil) async {
        for await item in events ?? transport.events where CronRefreshTrigger.refreshes(on: item) {
            await refresh()
        }
    }

    /// Issue #73: the job of a cron run session, or `nil`. A legacy run id is `cron_<job id>_<time>`.
    /// A `local-*` run id names no job: then the cached run history, then the job name as the title.
    public func job(forRun session: SessionListItem) -> CronJob? {
        if let job = jobs.first(where: { session.id.hasPrefix("cron_\($0.id)_") }) { return job }
        if let job = jobs.first(where: { cache.loadRuns(jobId: $0.id)?.contains { $0.id == session.id } == true }) {
            return job
        }
        let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        return jobs.first { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) == title }
    }

    /// Issue #73: the ids of the jobs with an unread run (blue dot on the job row).
    public func unreadJobIds(_ unreadRuns: [SessionListItem]) -> Set<String> {
        Set(unreadRuns.compactMap { job(forRun: $0)?.id })
    }

    /// The run history of one job. Each call gives a new model with the cached runs.
    public func runs(for job: CronJob) -> CronRunsModel {
        CronRunsModel(job: job, transport: transport, cache: cache)
    }
}

/// The job screen: the run history of one job, newest first (issue #73).
@MainActor @Observable
public final class CronRunsModel {
    public let jobId: String
    public private(set) var runs: [CronRun]
    public private(set) var hasLoaded: Bool
    public private(set) var errorMessage: String?
    public private(set) var isRefreshing = false

    @ObservationIgnored private let transport: any CronTransport
    @ObservationIgnored private let cache: any CronJobCacheStore
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(job: CronJob, transport: any CronTransport, cache: any CronJobCacheStore,
                limit: Int = CronAPI.runsLimit) {
        jobId = job.id
        self.transport = transport
        self.cache = cache
        self.limit = limit
        let cached = cache.loadRuns(jobId: job.id)
        runs = cached ?? []
        hasLoaded = cached != nil
    }

    public var state: CronListState {
        CronListState.make(hasLoaded: hasLoaded, error: errorMessage, total: runs.count, matches: runs.count, query: "")
    }

    public func refresh() async {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await load() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func load() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            // Newest first, also when the server order changes.
            let fresh = try await transport.fetchCronRuns(jobId: jobId, limit: limit)
                .enumerated()
                .sorted { ($0.element.startedAt ?? .distantPast, -$0.offset) > ($1.element.startedAt ?? .distantPast, -$1.offset) }
                .map(\.element)
            errorMessage = nil
            hasLoaded = true
            guard fresh != runs || cache.loadRuns(jobId: jobId) == nil else { return }
            runs = fresh
            cache.saveRuns(fresh, jobId: jobId)
        } catch {
            errorMessage = CronErrorText.message(for: error)
        }
    }

    public func watch(_ events: AsyncStream<GatewayClientEvent>? = nil) async {
        for await item in events ?? transport.events where CronRefreshTrigger.refreshes(on: item) {
            await refresh()
        }
    }
}

/// The output of one run for the read-only run screen (issue #73).
///
/// - An agent run loads its stored transcript with REST. It does not resume the session, so the run stays as it was.
/// - A script-only `cron_output:` run has no session. Its `preview` shows in one Hermes bubble.
@MainActor @Observable
public final class CronRunTranscriptModel {
    public let run: CronRun
    /// `nil` until the transcript loads.
    public private(set) var messages: [ChatMessage]?
    public private(set) var errorMessage: String?

    @ObservationIgnored private let transport: any CronTransport

    public init(run: CronRun, transport: any CronTransport) {
        self.run = run
        self.transport = transport
        if run.isOutputOnly { messages = Self.outputMessages(run) }
    }

    public func load() async {
        guard messages == nil else { return }
        do {
            let transcript = try await transport.fetchRunTranscript(sessionId: run.id)
            // A cron prompt is not a message that the owner sent: no "Delivered" under it.
            let shown = ChatHistory.messages(from: transcript, fallbackDate: run.startedAt ?? Date()).map { message in
                var message = message
                if message.role == .user { message.delivery = nil }
                return message
            }
            errorMessage = nil
            messages = shown.isEmpty ? Self.outputMessages(run) : shown
        } catch {
            errorMessage = CronErrorText.message(for: error)
        }
    }

    /// The `preview` (else the title) as one ended Hermes reply.
    static func outputMessages(_ run: CronRun) -> [ChatMessage] {
        let text = run.previewText
        guard !text.isEmpty else { return [] }
        return [ChatMessage(id: "\(run.id)#output", role: .assistant, text: text, date: run.startedAt ?? Date(),
                            reply: .complete)]
    }
}
