import Foundation
import Synchronization
import Testing
@testable import HermesKit

private let cronToken = String(repeating: "cd", count: 32)

/// Answers each path with a scripted status and body, and records the requests. No network.
private final class CronHTTPLoader: HTTPDataLoading, Sendable {
    private let requests = Mutex<[URLRequest]>([])
    private let routes: [String: (Int, String)]

    init(_ routes: [String: (Int, String)]) {
        self.routes = routes
    }

    var recorded: [URLRequest] { requests.withLock { $0 } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.withLock { $0.append(request) }
        let (status, body) = routes[request.url?.path ?? ""] ?? (404, #"{"detail":"Not Found"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

/// Scripted cron calls for the models. No network.
final class FakeCronTransport: CronTransport, @unchecked Sendable {
    struct Failure: Error {}

    let events: AsyncStream<GatewayClientEvent>
    let input: AsyncStream<GatewayClientEvent>.Continuation
    private let lock = NSLock()
    private var _jobs: [CronJob]
    private var _runs: [String: [CronRun]]
    private var _transcript: [TranscriptMessage]
    private var _error: (any Error)?
    private var _jobFetches = 0
    private var _runFetches: [String] = []
    private var _transcriptFetches: [String] = []

    init(jobs: [CronJob] = [], runs: [String: [CronRun]] = [:], transcript: [TranscriptMessage] = []) {
        _jobs = jobs
        _runs = runs
        _transcript = transcript
        (events, input) = AsyncStream.makeStream(of: GatewayClientEvent.self)
    }

    var jobs: [CronJob] {
        get { lock.withLock { _jobs } }
        set { lock.withLock { _jobs = newValue } }
    }

    var runs: [String: [CronRun]] {
        get { lock.withLock { _runs } }
        set { lock.withLock { _runs = newValue } }
    }

    var error: (any Error)? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    var jobFetches: Int { lock.withLock { _jobFetches } }
    var runFetches: [String] { lock.withLock { _runFetches } }
    var transcriptFetches: [String] { lock.withLock { _transcriptFetches } }

    func fetchCronJobs() async throws -> [CronJob] {
        let (jobs, error) = lock.withLock { () -> ([CronJob], (any Error)?) in
            _jobFetches += 1
            return (_jobs, _error)
        }
        if let error { throw error }
        return jobs
    }

    func fetchCronRuns(jobId: String, limit _: Int) async throws -> [CronRun] {
        let (runs, error) = lock.withLock { () -> ([CronRun], (any Error)?) in
            _runFetches.append(jobId)
            return (_runs[jobId] ?? [], _error)
        }
        if let error { throw error }
        return runs
    }

    func fetchRunTranscript(sessionId: String) async throws -> [TranscriptMessage] {
        let (transcript, error) = lock.withLock { () -> ([TranscriptMessage], (any Error)?) in
            _transcriptFetches.append(sessionId)
            return (_transcript, _error)
        }
        if let error { throw error }
        return transcript
    }
}

private let jobsJSON = #"""
[
  {"id":"a1","name":"Morning Zillow new rental watch","enabled":true,"state":"scheduled",
   "schedule":{"kind":"cron","expr":"0 8 * * *","display":"0 8 * * *"},"schedule_display":"Every day at 8:00 AM",
   "last_run_at":"2025-11-17T08:00:03.123456-05:00","next_run_at":"2025-11-18T08:00:00-05:00",
   "last_status":"ok","last_error":null,"latest_execution":{"id":"e1","status":"completed","claimed_at":"x"},
   "live_execution":null,"deliver":"local","prompt":"Check Zillow","new_server_field":{"nested":[1,2]}},
  {"id":"b2","name":"Backup check","enabled":true,"state":"scheduled","schedule":{"display":"every 6h"},
   "last_run_at":1763380800,"last_status":"error","last_error":"Script exited with code 2"},
  {"name":"no id, dropped"},
  {"id":"c3"}
]
"""#

private let runsJSON = #"""
{"runs":[
  {"id":"cron_a1_20261117_080003","title":"Morning Zillow new rental watch","preview":"3 new listings",
   "source":"cron","started_at":1763384403.5,"ended_at":1763384450,"is_active":false,"message_count":2,
   "scheduler_owned":false,"input_tokens":10},
  {"id":"cron_output:a1:2026-11-16_08-00-00","title":"FAILED · Script exited with code 2",
   "preview":"Traceback (most recent call last)","source":"cron_output","started_at":1763298000,
   "ended_at":1763298000,"is_active":false,"message_count":0}
],"limit":50}
"""#

@Suite struct CronRESTTests {
    private func client(_ loader: CronHTTPLoader) throws -> HermesRESTClient {
        HermesRESTClient(endpoint: try GatewayEndpoint(port: 8123, token: cronToken), loader: loader)
    }

    @Test func cronJobsSendsTheTokenAndDecodesEveryJobItCan() async throws {
        let loader = CronHTTPLoader(["/api/cron/jobs": (200, jobsJSON)])
        let jobs = try await client(loader).cronJobs()
        let request = try #require(loader.recorded.first)
        #expect(request.url?.path == "/api/cron/jobs")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == cronToken)
        // The row with no id is dropped. New server fields do not break the list.
        #expect(jobs.map(\.id) == ["a1", "b2", "c3"])
        let zillow = jobs[0]
        #expect(zillow.displayName == "Morning Zillow new rental watch")
        #expect(zillow.scheduleText == "Every day at 8:00 AM")
        #expect(zillow.status == .scheduled)
        let lastRun = try #require(zillow.lastRunAt).timeIntervalSince1970
        #expect(abs(lastRun - 1_763_384_403.123456) < 0.001)
        #expect(zillow.nextRunAt == Date(timeIntervalSince1970: 1_763_470_800))
        #expect(jobs[1].lastRunAt == Date(timeIntervalSince1970: 1_763_380_800))
        #expect(jobs[1].scheduleText == "every 6h")
        #expect(jobs[1].status == .failed("Script exited with code 2"))
        #expect(jobs[2].displayName == "Untitled Job")
        #expect(jobs[2].scheduleText.isEmpty)
    }

    @Test func cronRunsSendsTheLimitAndKeepsScriptOnlyRuns() async throws {
        let loader = CronHTTPLoader(["/api/cron/jobs/a1 b/runs": (200, runsJSON)])
        let runs = try await client(loader).cronRuns(jobId: "a1 b", limit: 50)
        let url = try #require(loader.recorded.first?.url)
        #expect(url.absoluteString.hasSuffix("/api/cron/jobs/a1%20b/runs?limit=50"))
        #expect(runs.map(\.id) == ["cron_a1_20261117_080003", "cron_output:a1:2026-11-16_08-00-00"])
        #expect(runs[0].startedAt == Date(timeIntervalSince1970: 1_763_384_403.5))
        #expect(runs[0].status == .done)
        #expect(!runs[0].isOutputOnly)
        #expect(runs[0].previewText == "3 new listings")
        #expect(runs[1].isOutputOnly)
        #expect(runs[1].status == .failed)
        #expect(runs[1].status.text == "Failed")
    }

    @Test func cronRunsCapsTheLimitAndRefusesAPathInTheId() async throws {
        let loader = CronHTTPLoader(["/api/cron/jobs/a1/runs": (200, #"{"runs":[]}"#)])
        #expect(try await client(loader).cronRuns(jobId: "a1", limit: 500).isEmpty)
        #expect(loader.recorded.first?.url?.query == "limit=100")
        _ = try? await client(loader).cronRuns(jobId: "../x", limit: 5)
        #expect(loader.recorded.last?.url?.absoluteString.hasSuffix("/api/cron/jobs/..%2Fx/runs?limit=5") == true)
        await #expect(throws: HermesAPIError.notFound) { try await client(loader).cronRuns(jobId: "") }
    }

    @Test func aRefusalKeepsTheServerMessage() async throws {
        let loader = CronHTTPLoader(["/api/cron/jobs": (500, #"{"detail":"jobs.json is locked"}"#),
                                     "/api/cron/jobs/x/runs": (502, "<html>"),
                                     "/api/cron/jobs/gone/runs": (404, "")])
        await #expect(throws: CronAPIError(status: 500, detail: "jobs.json is locked")) {
            try await client(loader).cronJobs()
        }
        await #expect(throws: HermesAPIError.http(status: 502)) { try await client(loader).cronRuns(jobId: "x") }
        await #expect(throws: HermesAPIError.notFound) { try await client(loader).cronRuns(jobId: "gone") }
        // FastAPI 404 with a detail keeps the detail ("Job not found").
        await #expect(throws: CronAPIError(status: 404, detail: "Not Found")) {
            try await client(loader).cronRuns(jobId: "unknown")
        }
        #expect(CronErrorText.message(for: CronAPIError(status: 500, detail: "jobs.json is locked"))
            == "jobs.json is locked")
        #expect(CronErrorText.message(for: GatewayError.notConnected) == "Hermes is not connected.")
        #expect(CronErrorText.message(for: HermesAPIError.http(status: 502)) == "Hermes answered with error 502.")
    }

    @Test func aStaleTokenOnACronCallIsUnauthorized() async throws {
        let loader = CronHTTPLoader(["/api/cron/jobs": (401, "{}")])
        await #expect(throws: HermesAPIError.unauthorized) { try await client(loader).cronJobs() }
    }

    /// Both endpoints through the app transport, with a fake socket and a fake HTTP loader.
    @MainActor @Test func liveTransportSendsBothEndpointsOnTheForwardedPort() async throws {
        let loader = CronHTTPLoader([
            "/api/cron/jobs": (200, jobsJSON),
            "/api/cron/jobs/a1/runs": (200, runsJSON),
            "/api/sessions/cron_a1_20261117_080003/messages": (200, #"""
            {"session_id":"cron_a1_20261117_080003","messages":[
              {"role":"user","content":"Check Zillow","timestamp":1763384403},
              {"role":"assistant","content":"3 new listings","timestamp":1763384450}],
             "pagination":{"limit":500,"offset":0,"order":"oldest","returned":2}}
            """#),
        ])
        let transport = LiveChatTransport(makeClient: { GatewayClient(endpoint: $0,
                                                                      connector: FakeGatewayConnector(FakeGatewaySocket())) },
                                          makeREST: { HermesRESTClient(endpoint: $0, loader: loader) })
        await #expect(throws: GatewayError.notConnected) { try await transport.fetchCronJobs() }
        transport.setEndpoint(try GatewayEndpoint(port: 9073, token: cronToken))
        #expect(try await transport.fetchCronJobs().count == 3)
        #expect(try await transport.fetchCronRuns(jobId: "a1", limit: 50).count == 2)
        let transcript = try await transport.fetchRunTranscript(sessionId: "cron_a1_20261117_080003")
        #expect(transcript.map(\.role) == ["user", "assistant"])
        let urls = loader.recorded.compactMap(\.url)
        #expect(urls.allSatisfy { $0.port == 9073 && $0.host == "127.0.0.1" })
        #expect(urls.last?.query?.contains("order=oldest") == true)
    }
}

@Suite struct CronJobStatusTests {
    @Test func everyStatusOfTheDesignNotes() {
        #expect(CronJob(id: "1").status == .scheduled)
        #expect(CronJob(id: "1", state: "scheduled").status.text == nil)
        #expect(CronJob(id: "1", latestExecution: .init(id: "e", status: "running")).status == .running)
        #expect(CronJob(id: "1", latestExecution: .init(id: "e", status: "claimed")).status == .running)
        #expect(CronJob(id: "1", state: "paused", liveExecution: .init(id: "e", status: "running")).status == .running)
        #expect(CronJob(id: "1", state: "paused").status == .paused)
        #expect(CronJob(id: "1", state: "paused", lastError: "boom").status == .paused)
        #expect(CronJob(id: "1", state: "completed").status == .off)
        #expect(CronJob(id: "1", state: "disabled").status == .off)
        #expect(CronJob(id: "1", enabled: false).status == .off)
        #expect(CronJob(id: "1", lastStatus: "error", lastError: "boom").status == .failed("boom"))
        #expect(CronJob(id: "1", lastError: "boom").status == .failed("boom"))
        // An old error after a good run does not show.
        #expect(CronJob(id: "1", lastStatus: "ok", lastError: "boom").status == .scheduled)
        #expect(CronJob(id: "1", lastError: "  ").status == .scheduled)
        #expect(CronJobStatus.failed("x").text == "Failed")
        #expect(CronJobStatus.off.text == "Off")
        #expect(CronJobStatus.scheduled.detailText == "Scheduled")
    }

    @Test func runStatusComesFromTheTitlePrefix() {
        #expect(CronRun(id: "r", title: "FAILED · boom").status == .failed)
        #expect(CronRun(id: "r", title: "CANCELLED · stop").status == .cancelled)
        #expect(CronRun(id: "r", title: "MISSED · x").status == .missed)
        #expect(CronRun(id: "r", title: "COMPLETED · ok").status == .done)
        #expect(CronRun(id: "r", title: "Morning", isActive: true).status == .running)
        #expect(CronRun(id: "r", title: "Morning").status == .done)
        #expect(CronRun(id: "r", title: "Title only").previewText == "Title only")
    }

    @Test(arguments: [
        ("2025-11-17T08:00:00-05:00", 1_763_384_400.0),
        ("2025-11-17T13:00:00Z", 1_763_384_400.0),
        ("2025-11-17T13:00:00.5+00:00", 1_763_384_400.5),
        ("2025-11-17T13:00:00.250000+0000", 1_763_384_400.25),
        ("1763384400", 1_763_384_400.0),
    ])
    func isoTimesFromPython(text: String, seconds: Double) throws {
        let date = try #require(CronDate.parse(text))
        #expect(abs(date.timeIntervalSince1970 - seconds) < 0.0001)
    }

    @Test func aTimeWithNoOffsetIsLocalAndBadTextIsNil() throws {
        let local = try #require(CronDate.parse("2026-11-17T08:00:00"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: local)
        #expect(parts == DateComponents(year: 2026, month: 11, day: 17, hour: 8, minute: 0))
        #expect(CronDate.parse("") == nil)
        #expect(CronDate.parse("tomorrow") == nil)
    }

    @Test func searchMatchesTheNameAndTheSchedule() {
        let job = CronJob(id: "1", name: "Morning Zillow", scheduleDisplay: "Every day at 8:00 AM")
        #expect(job.matches(""))
        #expect(job.matches("zillow"))
        #expect(job.matches("8:00"))
        #expect(!job.matches("backup"))
    }
}

@Suite struct CronCacheTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cron-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func jobsAndRunsRoundTripThroughTheFile() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCronJobCacheStore(directory: directory)
        #expect(store.loadJobs() == nil)
        let jobs = [CronJob(id: "a1", name: "Zillow", state: "scheduled", schedule: .init(display: "daily"),
                            scheduleDisplay: "Every day", lastRunAt: Date(timeIntervalSince1970: 1_763_384_403.5),
                            nextRunAt: Date(timeIntervalSince1970: 1_763_470_800), lastStatus: "ok",
                            latestExecution: .init(id: "e1", status: "completed")),
                    CronJob(id: "b2", lastError: "boom")]
        store.saveJobs(jobs)
        let runs = [CronRun(id: "cron_a1_1", title: "Zillow", preview: "3 new", startedAt: Date(timeIntervalSince1970: 1_763_384_403))]
        store.saveRuns(runs, jobId: "a1")
        let reopened = FileCronJobCacheStore(directory: directory)
        #expect(reopened.loadJobs() == jobs)
        #expect(reopened.loadRuns(jobId: "a1") == runs)
        #expect(reopened.loadRuns(jobId: "b2") == nil)
        // A job that left the list takes its runs with it.
        reopened.saveJobs([jobs[1]])
        #expect(FileCronJobCacheStore(directory: directory).loadRuns(jobId: "a1") == nil)
    }

    @Test func anOlderOrPartlyBrokenFileStillLoads() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // No version, no runs key, jobs with only the fields of an older build, and one broken row.
        try Data(#"{"jobs":[{"id":"a1","name":"Zillow","last_run_at":1763384403},{"name":"broken"},{"id":"b2"}]}"#.utf8)
            .write(to: directory.appending(path: "cron.json"))
        let store = FileCronJobCacheStore(directory: directory)
        let jobs = try #require(store.loadJobs())
        #expect(jobs.map(\.id) == ["a1", "b2"])
        #expect(jobs[0].lastRunAt == Date(timeIntervalSince1970: 1_763_384_403))
        #expect(jobs[0].latestExecution == nil)
        #expect(store.loadRuns(jobId: "a1") == nil)

        try Data("not json".utf8).write(to: directory.appending(path: "cron.json"))
        #expect(FileCronJobCacheStore(directory: directory).loadJobs() == nil)
    }

    @Test func runsOfManyJobsStayBounded() {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCronJobCacheStore(directory: directory)
        let jobs = (0..<40).map { CronJob(id: "j\($0)") }
        store.saveJobs(jobs)
        for job in jobs { store.saveRuns([CronRun(id: "r-\(job.id)")], jobId: job.id) }
        let kept = jobs.filter { store.loadRuns(jobId: $0.id) != nil }
        #expect(kept.count <= FileCronJobCacheStore.maxJobsWithRuns + 1)
        #expect(store.loadRuns(jobId: "j39") != nil)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct JobsModelTests {
    private let jobs = [CronJob(id: "a1", name: "Zillow", scheduleDisplay: "Every day"),
                        CronJob(id: "b2", name: "Backup", lastError: "boom")]

    @Test func firstLoadShowsLoadingThenTheJobs() async {
        let transport = FakeCronTransport(jobs: jobs)
        let cache = InMemoryCronJobCacheStore()
        let model = JobsModel(transport: transport, cache: cache)
        #expect(model.state(query: "") == .loading)
        await model.refresh()
        #expect(model.jobs == jobs)
        #expect(model.state(query: "") == .rows)
        #expect(model.state(query: "zebra") == .noResults)
        #expect(model.filtered("back").map(\.id) == ["b2"])
        #expect(cache.loadJobs() == jobs)
    }

    @Test func noJobsIsTheEmptyState() async {
        let model = JobsModel(transport: FakeCronTransport(), cache: InMemoryCronJobCacheStore())
        await model.refresh()
        #expect(model.state(query: "") == .empty)
    }

    @Test func offlineShowsTheCachedListAndNoError() async {
        let transport = FakeCronTransport(jobs: [])
        transport.error = GatewayError.notConnected
        let model = JobsModel(transport: transport, cache: InMemoryCronJobCacheStore(jobs: jobs))
        #expect(model.jobs == jobs)
        #expect(model.state(query: "") == .rows)
        await model.refresh()
        #expect(model.jobs == jobs)
        #expect(model.state(query: "") == .rows)
    }

    @Test func aFailureWithNoCacheShowsTheErrorAndTryAgainLoads() async {
        let transport = FakeCronTransport(jobs: jobs)
        transport.error = CronAPIError(status: 500, detail: "jobs.json is locked")
        let model = JobsModel(transport: transport, cache: InMemoryCronJobCacheStore())
        await model.refresh()
        #expect(model.state(query: "") == .error("jobs.json is locked"))
        transport.error = nil
        await model.refresh()
        #expect(model.state(query: "") == .rows)
        #expect(model.errorMessage == nil)
    }

    @Test func connectCronChangedAndSessionsChangedRefreshTheList() async throws {
        let transport = FakeCronTransport(jobs: jobs)
        let model = JobsModel(transport: transport, cache: InMemoryCronJobCacheStore())
        let watcher = Task { await model.watch() }
        defer { watcher.cancel() }
        transport.input.yield(.state(.connected(GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef"))))
        try await waitUntil { transport.jobFetches == 1 }
        transport.jobs = [jobs[0]]
        transport.input.yield(.event(GatewayEvent(type: "cron.changed", kind: .cronChanged)))
        try await waitUntil { model.jobs.map(\.id) == ["a1"] }
        transport.jobs = jobs
        transport.input.yield(.event(GatewayEvent(type: "sessions.changed", kind: .sessionsChanged)))
        try await waitUntil { model.jobs.count == 2 }
        // Other events do not refresh.
        let fetches = transport.jobFetches
        transport.input.yield(.event(GatewayEvent(type: "skin.changed", kind: .other(nil))))
        transport.input.yield(.state(.connecting))
        transport.input.yield(.event(GatewayEvent(type: "cron.changed", kind: .cronChanged)))
        try await waitUntil { transport.jobFetches == fetches + 1 }
        #expect(transport.jobFetches == fetches + 1)
    }

    @Test func aCronRunFindsItsJob() async {
        let cache = InMemoryCronJobCacheStore(runs: ["b2": [CronRun(id: "local-77")]])
        let model = JobsModel(transport: FakeCronTransport(jobs: jobs), cache: cache)
        await model.refresh()
        // Legacy id, then the cached runs, then the job name as the title.
        #expect(model.job(forRun: SessionListItem(id: "cron_a1_20261117_080003", source: "cron"))?.id == "a1")
        #expect(model.job(forRun: SessionListItem(id: "local-77", source: "cron"))?.id == "b2")
        #expect(model.job(forRun: SessionListItem(id: "local-88", title: "Backup", source: "cron"))?.id == "b2")
        #expect(model.job(forRun: SessionListItem(id: "local-99", title: "Other", source: "cron")) == nil)
        #expect(CronRun(session: SessionListItem(id: "cron_a1_1", title: "Zillow", source: "cron")).id == "cron_a1_1")
    }

    @Test func callsAtTheSameTimeShareOneRequest() async {
        let transport = FakeCronTransport(jobs: jobs)
        let model = JobsModel(transport: transport, cache: InMemoryCronJobCacheStore())
        async let first: Void = model.refresh()
        async let second: Void = model.refresh()
        _ = await (first, second)
        #expect(transport.jobFetches <= 2)
        #expect(model.jobs == jobs)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct CronRunsModelTests {
    private let job = CronJob(id: "a1", name: "Zillow")
    private let older = CronRun(id: "cron_a1_1", title: "Zillow", preview: "1 new",
                                startedAt: Date(timeIntervalSince1970: 1_763_298_000))
    private let newer = CronRun(id: "cron_a1_2", title: "FAILED · boom", preview: "Traceback",
                                startedAt: Date(timeIntervalSince1970: 1_763_384_400))

    @Test func runsShowNewestFirstAndGoToTheCache() async {
        let transport = FakeCronTransport(runs: ["a1": [older, newer]])
        let cache = InMemoryCronJobCacheStore()
        let model = CronRunsModel(job: job, transport: transport, cache: cache)
        #expect(model.state == .loading)
        await model.refresh()
        #expect(model.runs.map(\.id) == ["cron_a1_2", "cron_a1_1"])
        #expect(model.state == .rows)
        #expect(transport.runFetches == ["a1"])
        #expect(cache.loadRuns(jobId: "a1")?.map(\.id) == ["cron_a1_2", "cron_a1_1"])
    }

    @Test func emptyErrorAndOfflineStates() async {
        let empty = CronRunsModel(job: job, transport: FakeCronTransport(), cache: InMemoryCronJobCacheStore())
        await empty.refresh()
        #expect(empty.state == .empty)

        let failing = FakeCronTransport()
        failing.error = HermesAPIError.http(status: 500)
        let error = CronRunsModel(job: job, transport: failing, cache: InMemoryCronJobCacheStore())
        await error.refresh()
        #expect(error.state == .error("Hermes answered with error 500."))

        let cached = CronRunsModel(job: job, transport: failing,
                                   cache: InMemoryCronJobCacheStore(runs: ["a1": [newer]]))
        await cached.refresh()
        #expect(cached.state == .rows)
        #expect(cached.runs == [newer])
    }

    @Test func aReconnectRefreshesTheRuns() async throws {
        let transport = FakeCronTransport(runs: ["a1": [older]])
        let model = CronRunsModel(job: job, transport: transport, cache: InMemoryCronJobCacheStore())
        let watcher = Task { await model.watch() }
        defer { watcher.cancel() }
        transport.input.yield(.state(.connected(GatewayReady(replayEpoch: "0123456789abcdef0123456789abcdef"))))
        try await waitUntil { model.runs == [older] }
        transport.runs = ["a1": [older, newer]]
        transport.input.yield(.event(GatewayEvent(type: "sessions.changed", kind: .sessionsChanged)))
        try await waitUntil { model.runs.count == 2 }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct CronRunTranscriptTests {
    @Test func anAgentRunLoadsItsStoredTranscriptWithNoResume() async {
        let run = CronRun(id: "cron_a1_2", title: "Zillow", startedAt: Date(timeIntervalSince1970: 1_763_384_400))
        let transport = FakeCronTransport(transcript: [TranscriptMessage(role: "user", text: "Check Zillow", rowId: 1),
                                                       TranscriptMessage(role: "assistant", text: "**3** new", rowId: 2)])
        let model = CronRunTranscriptModel(run: run, transport: transport)
        #expect(model.messages == nil)
        await model.load()
        #expect(transport.transcriptFetches == ["cron_a1_2"])
        #expect(model.messages?.map(\.text) == ["Check Zillow", "**3** new"])
        #expect(model.messages?.map(\.role) == [.user, .assistant])
        // No "Delivered" under the cron prompt.
        #expect(model.messages?.first?.delivery == nil)
        let rows = ChatTimeline.rows(for: model.messages ?? [])
        #expect(rows.allSatisfy { $0.footnote != .delivered })
        await model.load()
        #expect(transport.transcriptFetches.count == 1)
    }

    @Test func aScriptOnlyRunShowsItsPreviewInOneHermesBubble() async {
        let run = CronRun(id: "cron_output:a1:2026-11-16_08-00-00", title: "FAILED · code 2",
                          preview: "Traceback (most recent call last)", source: "cron_output",
                          startedAt: Date(timeIntervalSince1970: 1_763_298_000))
        let transport = FakeCronTransport()
        let model = CronRunTranscriptModel(run: run, transport: transport)
        await model.load()
        #expect(transport.transcriptFetches.isEmpty)
        let message = model.messages?.first
        #expect(model.messages?.count == 1)
        #expect(message?.role == .assistant)
        #expect(message?.text == "Traceback (most recent call last)")
        #expect(message?.reply == .complete)
        #expect(message?.date == Date(timeIntervalSince1970: 1_763_298_000))
    }

    @Test func aFailedLoadShowsTheMessage() async {
        let transport = FakeCronTransport()
        transport.error = HermesAPIError.notFound
        let model = CronRunTranscriptModel(run: CronRun(id: "cron_gone"), transport: transport)
        await model.load()
        #expect(model.messages == nil)
        #expect(model.errorMessage == "Hermes does not have this job.")
    }
}

@MainActor
@Suite struct CronChatsFilterTests {
    @Test func aSessionCacheFromBeforeTheJobsTabLoadsWithNoCronRuns() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "old-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // The sessions.json format of the builds before #73 (format version 1, dates in seconds).
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"""
        {"version":1,"body":[
          {"id":"cron_a1_20261117_080003","title":"Morning Zillow new rental watch","preview":"3 new","startedAt":1763384403,"messageCount":2,"source":"cron","isUnread":true},
          {"id":"k1","title":"Trip","preview":"Book it","startedAt":1763290000,"messageCount":4,"source":"ios","isUnread":false}
        ]}
        """#.utf8).write(to: directory.appending(path: "sessions.json"))
        let cache = FileSessionCacheStore(directory: directory)
        #expect(cache.loadSessions().count == 2)
        let model = SessionListModel(transport: FakeSessionsTransport(), chatTransport: FakeChatTransport(), cache: cache)
        // The chats list hides the cron run. The model keeps it for catch-up, the app badge and the Jobs tab.
        #expect(model.filtered("").map(\.id) == ["k1"])
        #expect(model.chatRows.map(\.id) == ["k1"])
        #expect(model.sessions.count == 2)
        #expect(model.unreadCount == 1)
        #expect(model.chatsUnreadCount == 0)
        #expect(model.unreadCronRuns.map(\.id) == ["cron_a1_20261117_080003"])
        #expect(model.hasLoaded)
        model.markRead("cron_a1_20261117_080003")
        #expect(model.unreadCronRuns.isEmpty)
    }

    @Test func aRefreshKeepsCronRunsOutOfTheChatsListOnly() async {
        let rows = [SessionListItem(id: "cron_a1_1", title: "Zillow", messageCount: 2, source: "cron"),
                    SessionListItem(id: "k1", title: "Trip", messageCount: 4, source: "ios")]
        let model = SessionListModel(transport: FakeSessionsTransport(rows: rows), chatTransport: FakeChatTransport(),
                                     cache: InMemorySessionCacheStore(sessions: [rows[1]]))
        await model.refresh()
        #expect(model.sessions.map(\.id) == ["cron_a1_1", "k1"])
        #expect(model.filtered("").map(\.id) == ["k1"])
        #expect(model.filtered("zillow").isEmpty)
        // A new cron run with messages is new content: the blue dot, for the job row and the Jobs badge.
        #expect(model.unreadCronRuns.map(\.id) == ["cron_a1_1"])
        #expect(model.chatsUnreadCount == 0)
    }

    @Test func aNewCronRunPostsTheCatchUpNotification() async throws {
        let cache = InMemorySessionCacheStore(sessions: [SessionListItem(id: "k1", title: "Trip", messageCount: 4,
                                                                         source: "ios")])
        let run = SessionListItem(id: "cron_a1_20261117_080003", title: "Morning Zillow new rental watch",
                                  messageCount: 2, source: "cron")
        let sessions = FakeSessionsTransport(rows: [run, SessionListItem(id: "k1", title: "Trip", messageCount: 4,
                                                                          source: "ios")])
        let chats = FakeChatTransport()
        chats.transcript = [TranscriptMessage(role: "user", text: "Check Zillow", rowId: 1),
                            TranscriptMessage(role: "assistant", text: "3 new rentals match your search.", rowId: 2)]
        let notifier = FakeNotifier()
        let refresher = CatchUpRefresher(sessions: sessions, chats: chats, cache: cache, notifier: notifier)
        let result = try await refresher.run(showsPreview: false)
        #expect(result.notified == ["cron_a1_20261117_080003"])
        #expect(notifier.posted == [CatchUpNotification(sessionId: "cron_a1_20261117_080003",
                                                        title: "Morning Zillow new rental watch",
                                                        body: "New message from Hermes")])
        #expect(notifier.badges == [0], "issue #122: the notification posts, but the badge counts chats only")
        #expect(cache.loadSessions().first { $0.id == run.id }?.isUnread == true)
    }

    @Test func chatsDropsOnlyCronRuns() {
        let rows = [SessionListItem(id: "1", source: "cron"), SessionListItem(id: "2", source: "photon"),
                    SessionListItem(id: "3", source: nil), SessionListItem(id: "4", source: "ios")]
        #expect(SessionListItem.chats(rows).map(\.id) == ["2", "3", "4"])
    }
}

/// Polls the main actor until `condition` holds. Fails after 2 s.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met")
}
