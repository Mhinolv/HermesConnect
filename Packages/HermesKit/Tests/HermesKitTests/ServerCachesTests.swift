import Foundation
import Testing
@testable import HermesKit

/// Issue #84: one cache folder for each server, and the migration of the flat cache.
@Suite struct ServerCachesTests {
    private let home = ServerProfile.legacyID
    private let lab = UUID(uuidString: "00000000-0000-0000-0000-000000000084")!

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "server-caches-\(UUID().uuidString)/HermesConnect/Cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func names(_ url: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
    }

    private let rows = [SessionListItem(id: "20261117_080000_home01", title: "Trip", messageCount: 4, isUnread: true),
                        SessionListItem(id: "20261117_080000_home02", title: "Digest", messageCount: 2, source: "cron")]

    private func message(_ id: String, _ text: String, _ delivery: ChatMessage.Delivery = .delivered,
                         at seconds: TimeInterval = 100) -> ChatMessage {
        ChatMessage(id: id, role: .user, text: text, date: Date(timeIntervalSince1970: seconds), delivery: delivery)
    }

    // MARK: Folders

    @Test func twoServersDoNotShareAnyFile() throws {
        let root = try makeRoot()
        let caches = ServerCaches(root: root, active: home)
        let cache = caches.sessions
        cache.saveSessions(rows)
        cache.saveTranscript([message("u1", "home text")], sessionId: rows[0].id)
        cache.saveDraft("home draft", sessionId: rows[0].id)
        cache.saveActiveSessionId(rows[0].id)
        caches.jobs.saveJobs([CronJob(id: "j1", name: "Digest", scheduleDisplay: "Daily")])

        caches.select(lab)
        #expect(cache.loadSessions().isEmpty)
        #expect(cache.loadTranscript(sessionId: rows[0].id).isEmpty)
        #expect(cache.loadDraft(sessionId: rows[0].id).isEmpty)
        #expect(cache.loadActiveSessionId() == nil)
        #expect(caches.jobs.loadJobs() == nil)
        cache.saveSessions([SessionListItem(id: "lab1")])
        FileSessionCacheStore.waitForWrites()

        #expect(names(root) == [home.uuidString, lab.uuidString])
        #expect(names(ServerCaches.folder(root: root, server: home)) == ["sessions.json", "state.json", "transcripts",
                                                                          "cron.json"])
        #expect(names(ServerCaches.folder(root: root, server: lab)) == ["sessions.json"])
        caches.select(home)
        #expect(cache.loadSessions() == rows)
        #expect(cache.loadDraft(sessionId: rows[0].id) == "home draft")
        #expect(cache.loadActiveSessionId() == rows[0].id)
    }

    @Test func removeDeletesOnlyThatFolder() throws {
        let root = try makeRoot()
        let caches = ServerCaches(root: root, active: home)
        caches.sessions.saveSessions(rows)
        caches.sessionStore(for: lab).saveSessions([SessionListItem(id: "lab1")])
        try Data("{}".utf8).write(to: root.appending(path: "slash-commands.json"))
        caches.remove(server: lab)
        #expect(names(root) == [home.uuidString, "slash-commands.json"])
        #expect(caches.sessions.loadSessions() == rows)
        #expect(caches.sessionStore(for: lab).loadSessions().isEmpty)
    }

    @Test func launchDeletesTheFoldersOfRemovedServersOnly() throws {
        let root = try makeRoot()
        let caches = ServerCaches(root: root, active: home)
        caches.sessions.saveSessions(rows)
        caches.sessionStore(for: lab).saveSessions([SessionListItem(id: "lab1")])
        try FileManager.default.createDirectory(at: root.appending(path: "not-a-server"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appending(path: "sessions.json"))
        caches.removeFolders(except: [home])
        #expect(names(root) == [home.uuidString, "not-a-server", "sessions.json"])
    }

    @Test func noActiveServerKeepsNothingOnDisk() throws {
        let root = try makeRoot()
        let caches = ServerCaches(root: root, active: nil)
        caches.sessions.saveSessions(rows)
        #expect(caches.sessions.loadSessions() == rows)
        #expect(names(root).isEmpty)
    }

    @Test func pinnedIsTheStoreOfTheServerThatWasActive() {
        let caches = ServerCaches(inMemory: home)
        let pinned = caches.sessions.pinned()
        caches.select(lab)
        pinned.saveDraft("late", sessionId: "s1")
        #expect(caches.sessionStore(for: home).loadDraft(sessionId: "s1") == "late")
        #expect(caches.sessions.loadDraft(sessionId: "s1").isEmpty)
    }

    // MARK: Migration

    /// The cache of the owner's phone today: one server, a full flat cache, a queued message, a parked chat
    /// of nothing. After the move, the folder of the legacy server has every file, and the root has none of them.
    private func writeFlatCache(_ root: URL) {
        let flat = FileSessionCacheStore(directory: root)
        flat.saveSessions(rows)
        flat.saveTranscript([message("u1", "hello"), message("u2", "queued one", .queued, at: 200)],
                            sessionId: rows[0].id)
        flat.saveOutbox(true, sessionId: rows[0].id)
        flat.saveTranscript([message("u3", "digest")], sessionId: rows[1].id)
        flat.saveDraft("half typed", sessionId: rows[0].id)
        flat.saveActiveSessionId(rows[0].id)
        FileCronJobCacheStore(directory: root).saveJobs([CronJob(id: "j1", name: "Digest", scheduleDisplay: "Daily")])
        // Issue #165: the saves go to the write queue. The flat files must be on disk before the test changes them.
        flat.flush()
        FileSessionCacheStore.waitForWrites()
    }

    @Test func migrationMovesTheFlatCacheToTheActiveServerWithNoLoss() throws {
        let root = try makeRoot()
        writeFlatCache(root)
        try Data("{\"version\":1,\"servers\":{},\"order\":[]}".utf8).write(to: root.appending(path: "slash-commands.json"))
        let report = ServerCacheMigration.run(root: root, active: home, servers: [home])
        #expect(report == .init(transcripts: 2, state: true, sessions: true, jobs: true, incomplete: false))
        #expect(names(root) == [home.uuidString, "slash-commands.json"], "an older build sees an empty cache")

        let caches = ServerCaches(root: root, active: home)
        let cache = caches.sessions
        #expect(cache.loadSessions() == rows)
        #expect(cache.loadTranscript(sessionId: rows[0].id).map(\.text) == ["hello", "queued one"])
        #expect(cache.loadTranscript(sessionId: rows[0].id).map(\.delivery) == [.delivered, .queued])
        #expect(cache.loadTranscript(sessionId: rows[1].id).map(\.text) == ["digest"])
        #expect(cache.outboxSessionIds() == [rows[0].id], "the queued message is in one outbox only")
        #expect(cache.loadDraft(sessionId: rows[0].id) == "half typed")
        #expect(cache.loadActiveSessionId() == rows[0].id)
        #expect(caches.jobs.loadJobs()?.map(\.id) == ["j1"])
    }

    @Test func aSecondRunDoesNothing() throws {
        let root = try makeRoot()
        writeFlatCache(root)
        ServerCacheMigration.run(root: root, active: home, servers: [home])
        let before = names(ServerCaches.folder(root: root, server: home))
        let again = ServerCacheMigration.run(root: root, active: home, servers: [home])
        #expect(!again.movedAnything)
        #expect(names(ServerCaches.folder(root: root, server: home)) == before)
        #expect(ServerCaches(root: root, active: home).sessions.outboxSessionIds() == [rows[0].id])
    }

    @Test func noFlatCacheIsANewInstall() throws {
        let root = try makeRoot()
        #expect(!ServerCacheMigration.run(root: root, active: home, servers: [home]).movedAnything)
        #expect(names(root).isEmpty)
    }

    /// A #83 build with two servers: the outbox of Lab and the parked new chat of Lab go to the Lab folder.
    @Test func theOutboxAndTheParkedNewChatOfAnotherServerGoToThatServer() throws {
        let root = try makeRoot()
        let flat = FileSessionCacheStore(directory: root)
        flat.saveSessions(rows)
        flat.saveTranscript([message("h1", "home queued", .queued)], sessionId: rows[0].id)
        flat.saveOutbox(true, sessionId: rows[0].id)
        flat.saveTranscript([message("l1", "lab queued", .queued)], sessionId: "20261117_090000_lab001")
        flat.saveOutbox(true, sessionId: "20261117_090000_lab001")
        let parked = SessionCache.parkedNewChatId(server: lab)
        flat.saveTranscript([message("l2", "lab new chat", .queued)], sessionId: parked)
        flat.saveDraft("lab draft", sessionId: parked)

        ServerCacheMigration.run(root: root, active: home, servers: [home, lab],
                                 outboxes: [lab: ["20261117_090000_lab001"]])
        let caches = ServerCaches(root: root, active: home)
        #expect(caches.sessions.outboxSessionIds() == [rows[0].id])
        #expect(caches.sessions.loadTranscript(sessionId: "20261117_090000_lab001").isEmpty)
        let labCache = caches.sessionStore(for: lab)
        #expect(labCache.outboxSessionIds().sorted() == [SessionCache.newChatId, "20261117_090000_lab001"].sorted())
        #expect(labCache.loadTranscript(sessionId: "20261117_090000_lab001").map(\.text) == ["lab queued"])
        #expect(labCache.loadTranscript(sessionId: SessionCache.newChatId).map(\.text) == ["lab new chat"])
        #expect(labCache.loadDraft(sessionId: SessionCache.newChatId) == "lab draft")
        #expect(labCache.loadSessions().isEmpty, "the list belongs to the active server")
    }

    @Test func aParkedNewChatOfARemovedServerNeverSends() throws {
        let root = try makeRoot()
        let flat = FileSessionCacheStore(directory: root)
        let parked = SessionCache.parkedNewChatId(server: UUID())
        flat.saveTranscript([message("x", "gone", .queued)], sessionId: parked)
        ServerCacheMigration.run(root: root, active: home, servers: [home])
        let cache = ServerCaches(root: root, active: home).sessions
        #expect(cache.outboxSessionIds().isEmpty)
        #expect(cache.loadTranscript(sessionId: SessionCache.newChatId).isEmpty)
        #expect(cache.loadTranscript(sessionId: parked).map(\.text) == ["gone"], "kept, but inert")
    }

    /// A downgrade: the older build wrote flat files after the move. They move again. The flat copy wins, but a
    /// queued message of the folder copy stays, and it is in the outbox once.
    @Test func flatFilesOfADowngradeMoveAgainAndKeepTheQueuedMessage() throws {
        let root = try makeRoot()
        let caches = ServerCaches(root: root, active: home)
        let folderCache = caches.sessions
        folderCache.saveTranscript([message("u1", "hello"), message("q1", "queued in the new build", .queued, at: 300)],
                                   sessionId: rows[0].id)
        folderCache.saveOutbox(true, sessionId: rows[0].id)
        folderCache.saveDraft("new build draft", sessionId: rows[1].id)

        let flat = FileSessionCacheStore(directory: root)
        flat.saveSessions([rows[0]])
        flat.saveTranscript([message("u1", "hello"), message("u9", "from the old build", at: 200)], sessionId: rows[0].id)
        flat.saveDraft("old build draft", sessionId: rows[0].id)
        // Issue #165: the draft write waits for the draft delay. An older build wrote it at once.
        flat.flush()

        let report = ServerCacheMigration.run(root: root, active: home, servers: [home])
        #expect(!report.incomplete)
        let cache = ServerCaches(root: root, active: home).sessions
        #expect(cache.loadTranscript(sessionId: rows[0].id).map(\.text)
            == ["hello", "from the old build", "queued in the new build"])
        #expect(cache.outboxSessionIds() == [rows[0].id])
        #expect(cache.loadDraft(sessionId: rows[0].id) == "old build draft")
        #expect(cache.loadDraft(sessionId: rows[1].id) == "new build draft")
        #expect(cache.loadSessions() == [rows[0]])
        #expect(names(root) == [home.uuidString])
    }

    @Test func aTranscriptThatDoesNotMoveKeepsTheStateForTheNextLaunch() throws {
        let root = try makeRoot()
        writeFlatCache(root)
        // A file in the way of the transcripts folder of the server: the move fails.
        let folder = ServerCaches.folder(root: root, server: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "transcripts"))
        let report = ServerCacheMigration.run(root: root, active: home, servers: [home])
        #expect(report.incomplete)
        #expect(!report.state, "the outbox index stays flat, so nothing sends from a half move")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "state.json").path))
        #expect(FileSessionCacheStore(directory: root).outboxSessionIds() == [rows[0].id])

        try FileManager.default.removeItem(at: folder.appending(path: "transcripts"))
        let again = ServerCacheMigration.run(root: root, active: home, servers: [home])
        #expect(!again.incomplete)
        #expect(ServerCaches(root: root, active: home).sessions.outboxSessionIds() == [rows[0].id])
    }

    /// A launch before the first unlock (Data Protection): the state file does not read. It must not count as
    /// empty, or the outbox and the drafts are lost.
    @Test func aStateFileThatDoesNotReadWaitsForTheNextLaunch() throws {
        let root = try makeRoot()
        writeFlatCache(root)
        let state = root.appending(path: "state.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: state.path) }
        let report = ServerCacheMigration.run(root: root, active: home, servers: [home])
        #expect(report.incomplete)
        #expect(FileManager.default.fileExists(atPath: state.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: state.path)
        #expect(!ServerCacheMigration.run(root: root, active: home, servers: [home]).incomplete)
        let cache = ServerCaches(root: root, active: home).sessions
        #expect(cache.outboxSessionIds() == [rows[0].id])
        #expect(cache.loadDraft(sessionId: rows[0].id) == "half typed")
        #expect(cache.loadSessions() == rows)
    }

    @Test func fileNamesAndKeysRoundTrip() {
        for key in ["20261117_080000_home01", SessionCache.newChatId, SessionCache.parkedNewChatId(server: lab), "é/.."] {
            #expect(ServerCacheMigration.key(fromFileName: ServerCacheMigration.fileName(for: key)) == key)
        }
        #expect(ServerCacheMigration.key(fromFileName: "zz.json") == nil)
        #expect(ServerCacheMigration.key(fromFileName: "abc.json") == nil)
        #expect(ServerCacheMigration.key(fromFileName: ".DS_Store") == nil)
        let store = FileSessionCacheStore(directory: URL(fileURLWithPath: "/tmp/x"))
        #expect(store.transcriptURL(sessionId: "s1").lastPathComponent == ServerCacheMigration.fileName(for: "s1"))
    }
}

/// Issue #84: the notification text, the tap route and the background rotation.
@Suite struct ServerNotificationTests {
    private let home = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let lab = UUID(uuidString: "00000000-0000-0000-0000-000000000084")!
    private let vps = UUID(uuidString: "00000000-0000-0000-0000-000000000085")!
    private let row = SessionListItem(id: "20261117_080000_lab001", title: "Build logs")

    @Test func oneServerKeepsTheChatTitleAndTheHermesSender() {
        let server = NotificationServer(id: home, name: "Home", showsName: false)
        let note = CatchUpNotification(session: row, reply: "Done.", showsPreview: false, server: server)
        #expect(note.title == "Build logs")
        #expect(note.body == CatchUpNotification.defaultBody)
        #expect(note.senderName == "Hermes")
        #expect(note.threadIdentifier == "\(home.uuidString)/\(row.id)")
        #expect(note.requestIdentifier == "reply-\(home.uuidString)/\(row.id)")
    }

    @Test func twoServersPutTheServerNameFirst() {
        let profile = ServerProfile(id: lab, host: "lab.example.com", displayName: "Lab")
        let server = NotificationServer(profile, serverCount: 2)
        let note = CatchUpNotification(session: row, reply: "  Done.  ", showsPreview: true, server: server)
        #expect(note.title == "Lab: Build logs")
        #expect(note.body == "Done.", "the body does not change")
        #expect(note.senderName == "Lab", "Siri announces the server name")
        #expect(note.serverID == lab)
        let untitled = CatchUpNotification(session: SessionListItem(id: "x"), reply: "", showsPreview: false,
                                           server: server)
        #expect(untitled.title == "Lab: Untitled")
    }

    @Test func noServerKeepsTheOldIdentifiers() {
        let note = CatchUpNotification(session: row, reply: "Done.", showsPreview: false)
        #expect(note.threadIdentifier == row.id)
        #expect(note.requestIdentifier == "reply-\(row.id)")
        #expect(note.serverID == nil)
    }

    @Test func theTapRoute() {
        let servers: Set<UUID> = [home, lab]
        #expect(NotificationRoute.resolve(sessionId: "s", serverID: home, activeID: home, servers: servers)
            == .open(sessionId: "s"))
        #expect(NotificationRoute.resolve(sessionId: "s", serverID: lab, activeID: home, servers: servers)
            == .switchThenOpen(server: lab, sessionId: "s"))
        #expect(NotificationRoute.resolve(sessionId: "s", serverID: vps, activeID: home, servers: servers) == .showList,
                "a removed server shows the Chats list")
        #expect(NotificationRoute.resolve(sessionId: "s", serverID: nil, activeID: home, servers: servers)
            == .open(sessionId: "s"), "a notification of an older build opens on the active server")
    }

    @Test func theRotationChecksEachOtherServerInTurn() {
        let servers = [home, lab, vps]
        #expect(BackgroundRotation.next(servers: [home], active: home, last: nil) == nil)
        #expect(BackgroundRotation.next(servers: servers, active: home, last: nil) == lab)
        #expect(BackgroundRotation.next(servers: servers, active: home, last: lab) == vps)
        #expect(BackgroundRotation.next(servers: servers, active: home, last: vps) == lab, "skips the active server")
        #expect(BackgroundRotation.next(servers: servers, active: lab, last: home) == vps)
        #expect(BackgroundRotation.next(servers: servers, active: lab, last: vps) == home)
        #expect(BackgroundRotation.next(servers: servers, active: home, last: UUID()) == lab, "a removed last server")
        // Each other server gets a turn.
        var last: UUID?
        var seen: [UUID] = []
        for _ in 0..<4 {
            last = BackgroundRotation.next(servers: servers, active: home, last: last)
            seen.append(last!)
        }
        #expect(seen == [lab, vps, lab, vps])
    }

    @Test func theEntryOfAServerThatIsNotActiveComesFromItsCachedRows() {
        let rows = [SessionListItem(id: "a", isUnread: true),
                    SessionListItem(id: "b", source: "cron", isUnread: true),
                    SessionListItem(id: "c")]
        let entry = ServerStateBook.Entry(cachedRows: rows, outbox: ["c", SessionCache.newChatId])
        #expect(entry == .init(unreadIds: ["a", "b"], unreadChats: 1, outboxIds: ["c"]))
    }
}

/// Issue #84: a background refresh of a server that is not active names it in each notification.
@Suite struct OtherServerCatchUpTests {
    @Test func theRefresherPutsTheServerNameInTheTitleAndSetsNoBadge() async throws {
        let cached = [SessionListItem(id: "s1", title: "Build logs", messageCount: 1)]
        let fresh = [SessionListItem(id: "s1", title: "Build logs", messageCount: 2)]
        let cache = InMemorySessionCacheStore(sessions: cached)
        let chats = FakeChatTransport()
        chats.transcript = [TranscriptMessage(role: "user", text: "hi"), TranscriptMessage(role: "assistant", text: "Done.")]
        let notifier = RecordingNotifier()
        let refresher = CatchUpRefresher(sessions: FakeSessionsTransport(rows: fresh), chats: chats, cache: cache,
                                         notifier: notifier)
        let server = NotificationServer(id: UUID(), name: "Lab", showsName: true)
        let result = try await refresher.run(showsPreview: false, server: server, setsBadge: false)
        #expect(result.notified == ["s1"])
        #expect(notifier.posted.map(\.title) == ["Lab: Build logs"])
        #expect(notifier.posted.map(\.serverID) == [server.id])
        #expect(notifier.badges.isEmpty, "the app sets the badge of all servers")
        #expect(cache.loadSessions().filter(\.isUnread).map(\.id) == ["s1"])
    }
}

private final class RecordingNotifier: LocalNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _posted: [CatchUpNotification] = []
    private var _badges: [Int] = []
    var posted: [CatchUpNotification] { lock.withLock { _posted } }
    var badges: [Int] { lock.withLock { _badges } }
    func post(_ notification: CatchUpNotification) async { lock.withLock { _posted.append(notification) } }
    func setBadge(_ count: Int) async { lock.withLock { _badges.append(count) } }
}
