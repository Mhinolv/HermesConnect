import Foundation

/// The cache of the Jobs tab (issue #73): the job list and the run history of each job.
/// Offline, the Jobs tab shows the cached list. It is a separate file, so the session cache does not change.
public protocol CronJobCacheStore: Sendable {
    func loadJobs() -> [CronJob]?
    func saveJobs(_ jobs: [CronJob])
    func loadRuns(jobId: String) -> [CronRun]?
    func saveRuns(_ runs: [CronRun], jobId: String)
}

/// The JSON body of `cron.json`. Every key can be missing, and a bad row is dropped, so older and newer
/// files still load.
struct CronCacheBody: Codable, Equatable {
    static let formatVersion = 1

    var version: Int
    var jobs: [CronJob]?
    var runs: [String: [CronRun]]

    init(jobs: [CronJob]? = nil, runs: [String: [CronRun]] = [:]) {
        version = Self.formatVersion
        self.jobs = jobs
        self.runs = runs
    }

    private enum CodingKeys: String, CodingKey { case version, jobs, runs }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? Self.formatVersion
        jobs = (try? container.decodeIfPresent(LossyArray<CronJob>.self, forKey: .jobs))?.items
        let runs = (try? container.decodeIfPresent([String: LossyArray<CronRun>].self, forKey: .runs)) ?? [:]
        self.runs = runs.mapValues(\.items)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(jobs, forKey: .jobs)
        try container.encode(runs, forKey: .runs)
    }
}

/// `cron.json` next to the session cache, with the same `ProtectedStorage` rules (issue #18).
public final class FileCronJobCacheStore: CronJobCacheStore, @unchecked Sendable {
    public let directory: URL
    /// The run history of this many jobs stays in the file.
    static let maxJobsWithRuns = 30
    private let lock = NSLock()
    private var prepared = false

    public init(directory: URL) {
        self.directory = directory
    }

    /// The default location: `HermesConnect/Cache/cron.json` in Application Support.
    public static func applicationSupport() throws -> FileCronJobCacheStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return FileCronJobCacheStore(directory: base.appending(path: "HermesConnect/Cache", directoryHint: .isDirectory))
    }

    var fileURL: URL { directory.appending(path: "cron.json") }

    public func loadJobs() -> [CronJob]? { lock.withLock { read().jobs } }

    public func saveJobs(_ jobs: [CronJob]) {
        lock.withLock {
            var body = read()
            body.jobs = jobs
            let ids = Set(jobs.map(\.id))
            body.runs = body.runs.filter { ids.contains($0.key) }
            write(body)
        }
    }

    public func loadRuns(jobId: String) -> [CronRun]? { lock.withLock { read().runs[jobId] } }

    public func saveRuns(_ runs: [CronRun], jobId: String) {
        lock.withLock {
            var body = read()
            body.runs[jobId] = runs
            if body.runs.count > Self.maxJobsWithRuns {
                let keep = Set((body.jobs ?? []).prefix(Self.maxJobsWithRuns).map(\.id)).union([jobId])
                body.runs = body.runs.filter { keep.contains($0.key) }
            }
            write(body)
        }
    }

    /// Called with the lock held. A missing or broken file is an empty cache.
    private func read() -> CronCacheBody {
        guard let data = try? Data(contentsOf: fileURL),
              let body = try? JSONDecoder().decode(CronCacheBody.self, from: data) else { return CronCacheBody() }
        return body
    }

    /// Called with the lock held. The cache is optional: a failed write is dropped.
    private func write(_ body: CronCacheBody) {
        do {
            if !prepared {
                try ProtectedStorage.prepare(directory: directory)
                prepared = true
            }
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try JSONEncoder().encode(body).write(to: fileURL, options: ProtectedStorage.writeOptions)
        } catch {
            // The next save tries again.
        }
    }
}

/// A cache in memory, for tests, previews and the DEBUG demo.
public final class InMemoryCronJobCacheStore: CronJobCacheStore, @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [CronJob]?
    private var runs: [String: [CronRun]]

    public init(jobs: [CronJob]? = nil, runs: [String: [CronRun]] = [:]) {
        self.jobs = jobs
        self.runs = runs
    }

    public func loadJobs() -> [CronJob]? { lock.withLock { jobs } }
    public func saveJobs(_ jobs: [CronJob]) { lock.withLock { self.jobs = jobs } }
    public func loadRuns(jobId: String) -> [CronRun]? { lock.withLock { runs[jobId] } }
    public func saveRuns(_ runs: [CronRun], jobId: String) { lock.withLock { self.runs[jobId] = runs } }
}
