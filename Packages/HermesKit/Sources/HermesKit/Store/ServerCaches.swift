import Foundation

/// Issue #84: one cache folder for each server, `HermesConnect/Cache/<server id>/`.
///
/// - Each folder has the files of `FileSessionCacheStore` (`sessions.json`, `state.json`, `transcripts/`) and
///   `cron.json`. So two servers never share a list, a transcript, a draft, an active id or an outbox.
/// - `sessions` and `jobs` follow the active server (`select`). The app gives them to the list models.
/// - `slash-commands.json` stays in `HermesConnect/Cache/`: it is keyed by server already (#68).
/// - With no active server (before setup), the stores keep nothing on disk.
public final class ServerCaches: @unchecked Sendable {
    /// `HermesConnect/Cache`. Nil for caches in memory (tests, previews).
    public let root: URL?
    /// The session cache of the active server. The app makes it once and gives it to the session list.
    public var sessions: ScopedSessionCacheStore { ScopedSessionCacheStore(caches: self) }
    /// The Jobs cache of the active server.
    public var jobs: ScopedCronJobCacheStore { ScopedCronJobCacheStore(caches: self) }

    private let lock = NSLock()
    private var active: UUID?
    private var sessionStores: [UUID: any SessionCacheStore] = [:]
    private var cronStores: [UUID: any CronJobCacheStore] = [:]
    private var noServerSessions: any SessionCacheStore = InMemorySessionCacheStore()
    private var noServerJobs: any CronJobCacheStore = InMemoryCronJobCacheStore()
    private let makeSessions: @Sendable (UUID) -> any SessionCacheStore
    private let makeJobs: @Sendable (UUID) -> any CronJobCacheStore

    /// The caches in files under `root`.
    public convenience init(root: URL, active: UUID? = nil) {
        self.init(root: root, active: active,
                  makeSessions: { FileSessionCacheStore(directory: ServerCaches.folder(root: root, server: $0)) },
                  makeJobs: { FileCronJobCacheStore(directory: ServerCaches.folder(root: root, server: $0)) })
    }

    /// Caches in memory, for tests, previews and the DEBUG demo. `seed` gives the first store of a server.
    public convenience init(inMemory active: UUID? = nil,
                            seed: [UUID: any SessionCacheStore] = [:], jobs: [UUID: any CronJobCacheStore] = [:]) {
        self.init(root: nil, active: active, makeSessions: { _ in InMemorySessionCacheStore() },
                  makeJobs: { _ in InMemoryCronJobCacheStore() })
        lock.withLock {
            sessionStores = seed
            cronStores = jobs
        }
    }

    private init(root: URL?, active: UUID?, makeSessions: @escaping @Sendable (UUID) -> any SessionCacheStore,
                 makeJobs: @escaping @Sendable (UUID) -> any CronJobCacheStore) {
        self.root = root
        self.active = active
        self.makeSessions = makeSessions
        self.makeJobs = makeJobs
    }

    /// The default location: `HermesConnect/Cache` in Application Support, the folder of the builds before #84.
    public static func applicationSupport(active: UUID? = nil) throws -> ServerCaches {
        try ServerCaches(root: defaultRoot(), active: active)
    }

    public static func defaultRoot() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appending(path: "HermesConnect/Cache", directoryHint: .isDirectory)
    }

    /// The cache folder of one server.
    public static func folder(root: URL, server: UUID) -> URL {
        root.appending(path: server.uuidString, directoryHint: .isDirectory)
    }

    /// The server that the scoped stores follow now.
    public var activeServer: UUID? { lock.withLock { active } }

    /// The app calls this when the active server changes, before the lists load again.
    public func select(_ server: UUID?) {
        lock.withLock { active = server }
    }

    /// The session cache of one server. Background refresh uses it for a server that is not active.
    public func sessionStore(for server: UUID?) -> any SessionCacheStore {
        lock.withLock {
            guard let server else { return noServerSessions }
            if let store = sessionStores[server] { return store }
            let store = makeSessions(server)
            sessionStores[server] = store
            return store
        }
    }

    /// The Jobs cache of one server.
    public func cronStore(for server: UUID?) -> any CronJobCacheStore {
        lock.withLock {
            guard let server else { return noServerJobs }
            if let store = cronStores[server] { return store }
            let store = makeJobs(server)
            cronStores[server] = store
            return store
        }
    }

    /// "Remove Server": delete the cache folder of that server. The caches of the other servers stay.
    public func remove(server: UUID) {
        lock.withLock {
            sessionStores[server] = nil
            cronStores[server] = nil
            if active == server {
                active = nil
                noServerSessions = InMemorySessionCacheStore()
                noServerJobs = InMemoryCronJobCacheStore()
            }
        }
        guard let root else { return }
        try? FileManager.default.removeItem(at: Self.folder(root: root, server: server))
    }

    /// Launch: delete the folders of servers that are not in the list any more. A chat of a removed server can
    /// save late, after the remove. Only folders with a server id as the name go. The flat files stay.
    public func removeFolders(except servers: Set<UUID>) {
        guard let root,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names {
            guard let id = UUID(uuidString: name), !servers.contains(id) else { continue }
            try? FileManager.default.removeItem(at: Self.folder(root: root, server: id))
        }
    }
}

/// Issue #84: the session cache of the active server. Each call goes to the store of `ServerCaches.activeServer`.
public final class ScopedSessionCacheStore: SessionCacheStore, @unchecked Sendable {
    private let caches: ServerCaches

    init(caches: ServerCaches) {
        self.caches = caches
    }

    private var store: any SessionCacheStore { caches.sessionStore(for: caches.activeServer) }

    public func pinned() -> any SessionCacheStore { store }
    public func loadSessions() -> [SessionListItem] { store.loadSessions() }
    public func saveSessions(_ sessions: [SessionListItem]) { store.saveSessions(sessions) }
    public func loadTranscript(sessionId: String) -> [ChatMessage] { store.loadTranscript(sessionId: sessionId) }
    public func saveTranscript(_ messages: [ChatMessage], sessionId: String) {
        store.saveTranscript(messages, sessionId: sessionId)
    }
    public func loadDraft(sessionId: String) -> String { store.loadDraft(sessionId: sessionId) }
    public func saveDraft(_ text: String, sessionId: String) { store.saveDraft(text, sessionId: sessionId) }
    public func loadActiveSessionId() -> String? { store.loadActiveSessionId() }
    public func saveActiveSessionId(_ id: String?) { store.saveActiveSessionId(id) }
    public func removeSession(sessionId: String) { store.removeSession(sessionId: sessionId) }
    public func outboxSessionIds() -> [String] { store.outboxSessionIds() }
    public func saveOutbox(_ hasQueued: Bool, sessionId: String) { store.saveOutbox(hasQueued, sessionId: sessionId) }
}

/// Issue #84: the Jobs cache of the active server.
public final class ScopedCronJobCacheStore: CronJobCacheStore, @unchecked Sendable {
    private let caches: ServerCaches

    init(caches: ServerCaches) {
        self.caches = caches
    }

    private var store: any CronJobCacheStore { caches.cronStore(for: caches.activeServer) }

    public func pinned() -> any CronJobCacheStore { store }
    public func loadJobs() -> [CronJob]? { store.loadJobs() }
    public func saveJobs(_ jobs: [CronJob]) { store.saveJobs(jobs) }
    public func loadRuns(jobId: String) -> [CronRun]? { store.loadRuns(jobId: jobId) }
    public func saveRuns(_ runs: [CronRun], jobId: String) { store.saveRuns(runs, jobId: jobId) }
}

/// Issue #84: moves the flat cache of the builds before #84 into the folder of its server. Silent, at launch,
/// before any list or chat reads the cache.
///
/// - Files move. They are not copied, so a queued message is in one place only and sends once (#39).
/// - The active server gets the list, the active id, the Jobs file and every transcript, with two exceptions
///   from #83: the outbox of another server goes to that server, and a parked new chat
///   (`#new-chat@<id>`) becomes the `#new-chat` of its server.
/// - Each step can run again. If a step fails, the files stay and the next launch tries again. `state.json`
///   (the outbox index) moves only after every transcript moved.
/// - A flat file that an older build wrote after the move (a downgrade) moves again and wins, but a queued
///   message in the folder copy stays.
public enum ServerCacheMigration {
    public struct Report: Sendable, Equatable {
        public var transcripts = 0
        public var state = false
        public var sessions = false
        public var jobs = false
        /// True when a step failed. The next launch tries again.
        public var incomplete = false

        public var movedAnything: Bool { transcripts > 0 || state || sessions || jobs }
    }

    static let flatFiles = ["sessions.json", "state.json", "cron.json", "transcripts"]

    /// True when `root` has files of the flat cache.
    public static func hasFlatCache(root: URL) -> Bool {
        flatFiles.contains { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }
    }

    /// - Parameters:
    ///   - active: the active server. It gets the flat cache.
    ///   - servers: every saved server.
    ///   - outboxes: the outbox of each server that is not active, from the #83 server book.
    @discardableResult
    public static func run(root: URL, active: UUID, servers: Set<UUID>, outboxes: [UUID: [String]] = [:]) -> Report {
        var report = Report()
        guard hasFlatCache(root: root) else { return report }
        let router = Router(active: active, servers: servers.union([active]), outboxes: outboxes)
        var touched: Set<UUID> = [active]
        var parked: Set<UUID> = []

        // 1. Transcripts.
        let flatTranscripts = root.appending(path: "transcripts", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: flatTranscripts.path)) ?? []
        for name in names.sorted() {
            let source = flatTranscripts.appending(path: name)
            let flatKey = key(fromFileName: name)
            let (server, key) = flatKey.map(router.route) ?? (active, nil)
            if let flatKey, flatKey != key, key == SessionCache.newChatId { parked.insert(server) }
            let folder = ServerCaches.folder(root: root, server: server)
            let target = folder.appending(path: "transcripts/\(key.map(fileName(for:)) ?? name)")
            touched.insert(server)
            if moveTranscript(from: source, to: target) { report.transcripts += 1 } else { report.incomplete = true }
        }
        if report.incomplete { return finish(report, root: root, touched: touched) }
        removeIfEmpty(flatTranscripts)

        // 2. The state: drafts, active id, outbox. Each server gets its part, merged into its own state.
        let flatStateURL = root.appending(path: "state.json")
        // A file that exists but does not read (Data Protection before the first unlock) stops the move here.
        let stateFiles = [flatStateURL] + (servers.union([active])).map { stateURL(root, $0) }
        guard stateFiles.allSatisfy(isReadable) else {
            report.incomplete = true
            return finish(report, root: root, touched: touched)
        }
        if FileManager.default.fileExists(atPath: flatStateURL.path) {
            let flat = read(CacheState.self, from: flatStateURL) ?? CacheState()
            var states: [UUID: CacheState] = [:]
            func state(_ server: UUID) -> CacheState {
                states[server] ?? read(CacheState.self, from: stateURL(root, server)) ?? CacheState()
            }
            for (draftKey, text) in flat.drafts.sorted(by: { $0.key < $1.key }) {
                let (server, key) = router.route(draftKey)
                var target = state(server)
                target.drafts[key] = text
                states[server] = target
            }
            for id in flat.outbox {
                let (server, key) = router.route(id)
                var target = state(server)
                if !target.outbox.contains(key) { target.outbox.append(key) }
                states[server] = target
            }
            if let id = flat.activeSessionId {
                var target = state(active)
                target.activeSessionId = id
                states[active] = target
            }
            // A parked new chat with queued messages sends again on its server (the #83 restore did the same).
            for server in parked {
                let url = ServerCaches.folder(root: root, server: server)
                    .appending(path: "transcripts/\(fileName(for: SessionCache.newChatId))")
                let messages = read([CachedMessage].self, from: url) ?? []
                guard messages.contains(where: \.queued) else { continue }
                var target = state(server)
                if !target.outbox.contains(SessionCache.newChatId) { target.outbox.append(SessionCache.newChatId) }
                states[server] = target
            }
            var wrote = true
            for (server, value) in states {
                touched.insert(server)
                wrote = write(value, to: stateURL(root, server)) && wrote
            }
            if wrote {
                try? FileManager.default.removeItem(at: flatStateURL)
                report.state = true
            } else {
                report.incomplete = true
            }
        }

        // 3. The list and the Jobs file belong to the active server. The flat file wins: it is the newer one.
        let folder = ServerCaches.folder(root: root, server: active)
        if let moved = replace(root.appending(path: "sessions.json"), with: folder.appending(path: "sessions.json")) {
            report.sessions = moved
            report.incomplete = report.incomplete || !moved
        }
        if let moved = replace(root.appending(path: "cron.json"), with: folder.appending(path: "cron.json")) {
            report.jobs = moved
            report.incomplete = report.incomplete || !moved
        }
        return finish(report, root: root, touched: touched)
    }

    private static func finish(_ report: Report, root: URL, touched: Set<UUID>) -> Report {
        for server in touched {
            let folder = ServerCaches.folder(root: root, server: server)
            if FileManager.default.fileExists(atPath: folder.path) { try? ProtectedStorage.prepare(directory: folder) }
        }
        return report
    }

    private static func stateURL(_ root: URL, _ server: UUID) -> URL {
        ServerCaches.folder(root: root, server: server).appending(path: "state.json")
    }

    /// Where each transcript key goes.
    struct Router {
        let active: UUID
        let servers: Set<UUID>
        /// The outbox ids of the servers that are not active.
        let owners: [String: UUID]

        init(active: UUID, servers: Set<UUID>, outboxes: [UUID: [String]]) {
            self.active = active
            self.servers = servers
            var owners: [String: UUID] = [:]
            for (server, ids) in outboxes.sorted(by: { $0.key.uuidString < $1.key.uuidString })
            where server != active && servers.contains(server) {
                for id in ids where owners[id] == nil { owners[id] = server }
            }
            self.owners = owners
        }

        /// The server and the key in its folder.
        func route(_ key: String) -> (UUID, String) {
            let prefix = SessionCache.newChatId + "@"
            if key.hasPrefix(prefix), let server = UUID(uuidString: String(key.dropFirst(prefix.count))) {
                // A parked new chat of a removed server stays inert in the active folder: it never sends.
                return servers.contains(server) ? (server, SessionCache.newChatId) : (active, key)
            }
            if let server = owners[key] { return (server, key) }
            return (active, key)
        }
    }

    /// The transcript file name of a key: the hex of its UTF-8 bytes (`FileSessionCacheStore.transcriptURL`).
    static func fileName(for key: String) -> String {
        key.utf8.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// The key of a transcript file name, or nil for a name that is not hex.
    static func key(fromFileName name: String) -> String? {
        guard name.hasSuffix(".json") else { return nil }
        let hex = Array(name.dropLast(5).utf8)
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(decoding: hex[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Move one transcript. If the target has a file (an older build wrote the flat file after a move), the flat
    /// messages win, and the queued messages and memos that were not delivered of the target stay.
    private static func moveTranscript(from source: URL, to target: URL) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.fileExists(atPath: target.path) else {
                try manager.moveItem(at: source, to: target)
                return true
            }
            guard isReadable(source), isReadable(target) else { return false }
            let flat = read([CachedMessage].self, from: source) ?? []
            let kept = read([CachedMessage].self, from: target) ?? []
            let ids = Set(flat.map(\.id))
            let extra = kept.filter { !ids.contains($0.id) && ($0.queued || ($0.notDelivered && $0.voice != nil)) }
            let merged = (flat + extra).enumerated()
                .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
            guard write(merged, to: target) else { return false }
            try manager.removeItem(at: source)
            return true
        } catch {
            return false
        }
    }

    /// Move `source` to `target`, and replace a file that is there. Nil when there is no `source`.
    private static func replace(_ source: URL, with target: URL) -> Bool? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return nil }
        do {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: target.path) {
                _ = try manager.replaceItemAt(target, withItemAt: source)
            } else {
                try manager.moveItem(at: source, to: target)
            }
            return true
        } catch {
            return false
        }
    }

    /// True when `url` is missing or its bytes read. A file that the system does not let the app read yet is
    /// not "empty": the move waits for the next launch.
    private static func isReadable(_ url: URL) -> Bool {
        !FileManager.default.fileExists(atPath: url.path) || (try? Data(contentsOf: url)) != nil
    }

    private static func removeIfEmpty(_ folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
        if names.isEmpty { try? FileManager.default.removeItem(at: folder) }
    }

    private static func read<Body: Codable>(_: Body.Type, from url: URL) -> Body? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(CacheFile<Body>.self, from: data).body
    }

    private static func write<Body: Codable>(_ body: Body, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(CacheFile(body)).write(to: url, options: ProtectedStorage.writeOptions)
            return true
        } catch {
            return false
        }
    }
}
