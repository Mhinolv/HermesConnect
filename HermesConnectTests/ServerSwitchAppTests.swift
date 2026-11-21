import Foundation
import HermesKit
import Testing
import UserNotifications
@testable import HermesConnect

/// Issue #83: switch the active Hermes server. One server is connected at a time.
@MainActor
@Suite struct ServerSwitchAppTests {
    private struct Setup {
        let model: AppModel
        let store: InMemoryServerListStore
        let transport: ScriptedSSHTransport
        let defaults: UserDefaults
    }

    private func makeModel(_ servers: [ServerProfile], active: Int = 0,
                           defaults: UserDefaults? = nil) async -> Setup {
        let keyStore = KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: SoftwareKeyFactory())
        let store = InMemoryServerListStore(ServerList(servers: servers, activeID: servers[active].id))
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let serve = ServeBootstrap(loader: ScriptedHermesHTTP(),
                                   configuration: .init(serveTimeout: .seconds(5), healthAttempts: 1,
                                                        healthRetryDelay: .milliseconds(1)))
        let defaults = defaults ?? UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let model = AppModel(keyStore: keyStore, serverStore: store, defaults: defaults,
                             deviceName: "Test iPhone", transport: transport, serve: serve)
        await model.ensureKey()
        return Setup(model: model, store: store, transport: transport, defaults: defaults)
    }

    private let home = ServerProfile(host: "home.example.com", displayName: "Home", hostKey: .sample)
    private let lab = ServerProfile(host: "lab.example.com", displayName: "Lab", hostKey: .sample)
    private let vps = ServerProfile(host: "vps.example.com", displayName: "VPS", hostKey: .sample)

    @Test func aSwitchSavesTheIdClosesTheOldLinkThenConnectsTheNewServer() async throws {
        let setup = await makeModel([home, lab])
        await setup.model.connect()
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        let before = setup.transport.record.steps.count
        await setup.model.switchServer(to: lab.id)
        #expect(setup.model.profile?.id == lab.id)
        #expect(try setup.store.load().activeID == lab.id, "a relaunch keeps the choice")
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        let steps = Array(setup.transport.record.steps.dropFirst(before))
        #expect(steps == ["close forward", "close session", "connect"], "the old link closes before the new connect")
        #expect(setup.transport.record.closedSessions == 1, "no SSH channel of the old server stays open")
    }

    @Test func aFastDoubleSwitchEndsOnTheLastChoiceWithOneConnect() async throws {
        let setup = await makeModel([home, lab, vps])
        await setup.model.connect()
        let connects = setup.transport.record.connectAttempts
        let model = setup.model
        let first = Task { await model.switchServer(to: lab.id) }
        let second = Task { await model.switchServer(to: vps.id) }
        await first.value
        await second.value
        #expect(setup.model.profile?.id == vps.id)
        #expect(try setup.store.load().activeID == vps.id)
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(setup.transport.record.connectAttempts == connects + 1, "the first switch does not connect")
    }

    @Test func aSwitchDuringAConnectDropsTheOldResultAndClosesIt() async throws {
        let setup = await makeModel([home, lab])
        let model = setup.model
        let old = Task { await model.connect() }
        let switched = Task { await model.switchServer(to: lab.id) }
        await old.value
        await switched.value
        #expect(setup.model.profile?.id == lab.id)
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        let record = setup.transport.record
        #expect(record.closedSessions == record.connectAttempts - 1, "only the link of the new server stays open")
    }

    @Test func aSwitchToTheActiveServerOrAnUnknownIdDoesNothing() async throws {
        let setup = await makeModel([home, lab])
        await setup.model.connect()
        var changes = 0
        setup.model.onActiveServerChange = { _ in changes += 1 }
        await setup.model.switchServer(to: home.id)
        await setup.model.switchServer(to: UUID())
        #expect(changes == 0)
        #expect(setup.model.connection == .connected(gateVersion: "1"))
    }

    @Test func aNewHostKeyOnSwitchShowsTheTrustSheetAndAChangedKeyShowsTheError() async throws {
        let fresh = ServerProfile(host: "fresh.example.com")
        let moved = ServerProfile(host: "moved.example.com", hostKey: .otherSample)
        let setup = await makeModel([home, fresh, moved])
        await setup.model.connect()
        await setup.model.switchServer(to: fresh.id)
        #expect(setup.model.pendingTrust == .sample, "the same trust sheet as today")
        setup.model.cancelTrust()
        await setup.model.switchServer(to: moved.id)
        #expect(setup.model.connection == .hostKeyChanged(saved: .otherSample, received: .sample))
        #expect(setup.model.showsHostKeyError, "the same error screen as today")
        #expect(setup.transport.record.authentications == 1, "the app never authenticates to a changed key")
    }

    @Test func theHookRunsBeforeTheNewConnect() async throws {
        let setup = await makeModel([home, lab])
        await setup.model.connect()
        var seen: [ServerChange] = []
        var connectsAtHook = -1
        setup.model.onActiveServerChange = { change in
            seen.append(change)
            connectsAtHook = setup.transport.record.connectAttempts
        }
        await setup.model.switchServer(to: lab.id)
        #expect(seen == [ServerChange(from: home.id, to: lab.id)])
        #expect(connectsAtHook == 1, "the lists reset before the new server connects")
    }

    // MARK: Lists and outbox

    private struct Lists {
        let caches: ServerCaches
        let sessions: SessionListModel
        let jobs: JobsModel
        var removed: [UUID] = []
    }

    /// The lists of the app on the scoped caches (issue #84), attached to the model.
    private func attachLists(_ model: AppModel, seed: [UUID: any SessionCacheStore] = [:],
                             jobs: [UUID: any CronJobCacheStore] = [:],
                             onRemoved: @escaping @MainActor (ServerProfile) -> Void = { _ in }) -> Lists {
        let caches = ServerCaches(inMemory: model.profile?.id, seed: seed, jobs: jobs)
        let sessions = SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                                        cache: caches.sessions)
        let jobsModel = JobsModel(transport: OfflineCronTransport(), cache: caches.jobs)
        ServerSwitchGlue.attach(model: model, sessions: sessions, jobs: jobsModel, caches: caches, onRemoved: onRemoved)
        return Lists(caches: caches, sessions: sessions, jobs: jobsModel)
    }

    @Test func aSwitchKeepsTheUnreadAndOutboxOfTheOldServerInItsFolder() async throws {
        let setup = await makeModel([home, lab])
        let rows = [SessionListItem(id: "20261117_080000_home01", title: "Trip", isUnread: true),
                    SessionListItem(id: "20261117_080000_home02", title: "Digest", source: "cron", isUnread: true)]
        let homeCache = InMemorySessionCacheStore(sessions: rows)
        homeCache.saveOutbox(true, sessionId: "20261117_080000_home03")
        let lists = attachLists(setup.model, seed: [home.id: homeCache])
        #expect(lists.sessions.sessions == rows)
        #expect(setup.model.badgeCount(lists.sessions) == 1, "issue #122: the cron run is not counted")

        await setup.model.switchServer(to: lab.id)
        #expect(!lists.sessions.hasLoaded, "Lab has no cache: the redacted rows show")
        #expect(lists.caches.activeServer == lab.id)
        let kept = setup.model.serverBook.entry(for: home.id)
        #expect(kept.unreadIds == rows.map(\.id))
        #expect(kept.unreadChats == 1, "a cron run is not a chat")
        #expect(kept.outboxIds == ["20261117_080000_home03"])
        #expect(lists.caches.sessions.outboxSessionIds().isEmpty, "the Lab folder has no Home outbox")
        #expect(homeCache.outboxSessionIds() == ["20261117_080000_home03"])
        #expect(setup.model.badgeCount(lists.sessions) == 1, "the badge counts the chats of all servers")
        let menu = setup.model.serverMenu(activeChats: lists.sessions.chatsUnreadCount)
        #expect(menu.title() == "Lab")
        #expect(menu.items.map(\.subtitle) == ["1 unread", nil])
        #expect(menu.showsDot)

        // Back on Home: its list shows at once from its folder, with its dots and its outbox.
        await setup.model.switchServer(to: home.id)
        #expect(lists.sessions.hasLoaded)
        #expect(lists.sessions.sessions == rows)
        #expect(lists.caches.sessions.outboxSessionIds() == ["20261117_080000_home03"])
        #expect(!setup.model.serverMenu(activeChats: 0).showsDot)
    }

    @Test func theBookSurvivesARelaunch() async throws {
        let setup = await makeModel([home, lab])
        setup.model.recordServerState(.init(unreadIds: ["l1"], unreadChats: 1, outboxIds: ["l2"]), for: lab.id)
        let relaunched = await makeModel([home, lab], defaults: setup.defaults)
        #expect(relaunched.model.serverBook.entry(for: lab.id) == .init(unreadIds: ["l1"], unreadChats: 1, outboxIds: ["l2"]))
        let lists = attachLists(relaunched.model)
        #expect(lists.caches.activeServer == home.id, "a relaunch on Home reads only the Home folder")
    }

    /// Issue #94: "Mark All as Read" clears the active server only, and its book entry, so a relaunch keeps it.
    @Test func markAllReadDropsOnlyTheActiveCountAndItsBookEntry() async throws {
        let setup = await makeModel([home, lab])
        let rows = [SessionListItem(id: "h1", title: "Trip", isUnread: true),
                    SessionListItem(id: "h2", title: "Dinner", source: "photon", isUnread: true),
                    SessionListItem(id: "cron_j1_1", title: "Digest", source: "cron", isUnread: true)]
        let homeCache = InMemorySessionCacheStore(sessions: rows)
        // An old entry of Home (a switch away and back) and 3 unread chats on Lab.
        setup.model.recordServerState(.init(unreadIds: ["h1", "h2", "cron_j1_1"], unreadChats: 2), for: home.id)
        setup.model.recordServerState(.init(unreadIds: ["l1", "l2", "l3"], unreadChats: 3), for: lab.id)
        let lists = attachLists(setup.model, seed: [home.id: homeCache])
        #expect(lists.sessions.canMarkAllRead)
        #expect(setup.model.badgeCount(lists.sessions) == 5, "issue #122: 2 chats here, 3 on Lab, no cron run")

        #expect(lists.sessions.markAllRead() == 2)
        ServerSwitchGlue.recordActiveState(model: setup.model, sessions: lists.sessions)
        #expect(lists.sessions.chatsUnreadCount == 0, "the Chats tab badge")
        #expect(RootTab.jobs.badge(lists.sessions) == 0, "issue #122: the Jobs tab has no badge")
        #expect(setup.model.badgeCount(lists.sessions) == 3, "Lab keeps its 3")
        #expect(setup.model.serverBook.entry(for: home.id) == .init(unreadIds: ["cron_j1_1"], unreadChats: 0))
        #expect(setup.model.serverBook.entry(for: lab.id).unreadChats == 3)
        let menu = setup.model.serverMenu(activeChats: lists.sessions.chatsUnreadCount)
        #expect(menu.items.map(\.subtitle) == [nil, "3 unread"])

        // A relaunch carries only the cron run back.
        let relaunched = await makeModel([home, lab], defaults: setup.defaults)
        #expect(relaunched.model.serverBook.entry(for: home.id).unreadIds == ["cron_j1_1"])
        let again = attachLists(relaunched.model, seed: [home.id: homeCache])
        #expect(again.sessions.chatsUnreadCount == 0)
        #expect(!again.sessions.canMarkAllRead)
    }

    @Test func removeAnotherServerDeletesItsFolderAndCount() async throws {
        let setup = await makeModel([home, lab])
        let labCache = InMemorySessionCacheStore(sessions: [SessionListItem(id: "l1", isUnread: true)])
        labCache.saveOutbox(true, sessionId: "l2")
        var removed: [UUID] = []
        let lists = attachLists(setup.model, seed: [lab.id: labCache], onRemoved: { removed.append($0.id) })
        setup.model.recordServerState(.init(unreadIds: ["l1"], unreadChats: 1, outboxIds: ["l2"]), for: lab.id)
        try setup.model.removeServer(id: lab.id)
        #expect(setup.model.serverBook.entries.isEmpty)
        #expect(lists.caches.sessionStore(for: lab.id).outboxSessionIds().isEmpty,
                "the queued messages of a removed server never send")
        #expect(lists.caches.sessionStore(for: lab.id).loadSessions().isEmpty)
        #expect(removed == [lab.id], "the app drops its notifications and its slash catalog")
        #expect(setup.model.badgeCount(lists.sessions) == 0)
    }

    @Test func removeTheActiveServerSwitchesToTheFirstAndDeletesItsFolder() async throws {
        let setup = await makeModel([home, lab], active: 1)
        let labCache = InMemorySessionCacheStore(sessions: [SessionListItem(id: "l1")])
        labCache.saveOutbox(true, sessionId: "l2")
        let homeCache = InMemorySessionCacheStore(sessions: [SessionListItem(id: "h1")])
        var removed: [UUID] = []
        let lists = attachLists(setup.model, seed: [home.id: homeCache, lab.id: labCache],
                                onRemoved: { removed.append($0.id) })
        try setup.model.removeServer(id: lab.id)
        #expect(setup.model.profile?.id == home.id)
        #expect(lists.caches.activeServer == home.id)
        #expect(lists.sessions.sessions.map(\.id) == ["h1"], "the Home list shows at once")
        #expect(lists.caches.sessionStore(for: lab.id).outboxSessionIds().isEmpty)
        #expect(removed == [lab.id])
    }

    @Test func addServerSwitchesToAnEmptyFolder() async throws {
        let setup = await makeModel([home])
        let lists = attachLists(setup.model, seed: [home.id: InMemorySessionCacheStore(sessions: [SessionListItem(id: "h1")])])
        #expect(lists.sessions.hasLoaded)
        try setup.model.addServer(lab)
        #expect(setup.model.profile?.id == lab.id)
        #expect(lists.caches.activeServer == lab.id)
        #expect(!lists.sessions.hasLoaded)
        #expect(setup.model.serverMenu(activeChats: 0).title() == "Lab")
    }

    @Test func theFirstServerTakesItsOwnFolder() async throws {
        let keyStore = KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: SoftwareKeyFactory())
        let model = AppModel(keyStore: keyStore, serverStore: InMemoryServerListStore(),
                             defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                             deviceName: "Test iPhone", transport: ScriptedSSHTransport(hostKey: .sample))
        let lists = attachLists(model)
        #expect(lists.caches.activeServer == nil)
        try model.saveProfile(home)
        #expect(lists.caches.activeServer == home.id)
    }

    /// QA 90-1 defect 1: the queued new chat of Home never shows or sends on Lab, and comes back on Home.
    @Test func theNewChatSlotStaysWithItsServer() async throws {
        let setup = await makeModel([home, lab])
        let homeCache = InMemorySessionCacheStore()
        homeCache.saveTranscript([ChatMessage(id: "q1", role: .user, text: "for Home", date: .now, delivery: .queued)],
                                 sessionId: SessionCache.newChatId)
        homeCache.saveOutbox(true, sessionId: SessionCache.newChatId)
        let lists = attachLists(setup.model, seed: [home.id: homeCache])
        let sessions = lists.sessions

        await setup.model.switchServer(to: lab.id)
        #expect(!sessions.hasCachedNewChat, "launch on Lab does not open the Home new chat")
        #expect(lists.caches.sessions.outboxSessionIds().isEmpty)
        #expect(sessions.newChat(key: "lab").messages.isEmpty)

        await setup.model.switchServer(to: home.id)
        #expect(sessions.hasCachedNewChat)
        #expect(lists.caches.sessions.outboxSessionIds() == [SessionCache.newChatId])
        #expect(sessions.newChat(key: "home").messages.map(\.text) == ["for Home"])
    }

    /// The same entry with a new host: the old rows, outbox and new chat do not go to the new machine.
    @Test func aNewHostOnTheActiveEntryClearsItsRowsAndOutbox() async throws {
        let setup = await makeModel([home, lab])
        let homeCache = InMemorySessionCacheStore(sessions: [SessionListItem(id: "h1")])
        homeCache.saveOutbox(true, sessionId: "h2")
        let lists = attachLists(setup.model, seed: [home.id: homeCache])
        var moved = home
        moved.host = "new-home.example.com"
        try setup.model.updateServer(moved)
        #expect(lists.caches.activeServer == home.id)
        #expect(homeCache.outboxSessionIds().isEmpty)
        #expect(homeCache.loadSessions().isEmpty)
        #expect(!lists.sessions.hasLoaded)
    }

    // MARK: Launch (issue #84)

    /// The phone of the owner today: one legacy server and a full flat cache. Launch moves it, with no new
    /// connect setup, and the list shows the same rows.
    @Test func launchMovesTheFlatCacheToTheLegacyServerFolder() async throws {
        let legacy = ServerProfile(id: ServerProfile.legacyID, host: "home.example.com", hostKey: .sample)
        let setup = await makeModel([legacy])
        let root = FileManager.default.temporaryDirectory
            .appending(path: "launch-\(UUID().uuidString)/Cache", directoryHint: .isDirectory)
        let flat = FileSessionCacheStore(directory: root)
        let rows = [SessionListItem(id: "20261117_080000_home01", title: "Trip")]
        flat.saveSessions(rows)
        flat.saveTranscript([ChatMessage(id: "q1", role: .user, text: "queued", date: .now, delivery: .queued)],
                            sessionId: rows[0].id)
        flat.saveOutbox(true, sessionId: rows[0].id)
        ServerCacheSetup.prepare(root: root, model: setup.model)
        let caches = ServerCaches(root: root, active: setup.model.profile?.id)
        let sessions = SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                                        cache: caches.sessions)
        #expect(sessions.sessions == rows)
        #expect(caches.sessions.outboxSessionIds() == [rows[0].id], "the queued message sends once")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "state.json").path))
        #expect(FileManager.default.fileExists(atPath: ServerCaches.folder(root: root, server: ServerProfile.legacyID)
            .appending(path: "state.json").path))
        #expect(setup.model.pendingTrust == nil)
        #expect(try setup.store.load().servers.map(\.hostKey) == [.sample], "the pin stays: no new trust sheet")
    }

    @Test func launchWithNoServerLeavesTheFilesAsTheyAre() async throws {
        let keyStore = KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: SoftwareKeyFactory())
        let model = AppModel(keyStore: keyStore, serverStore: InMemoryServerListStore(),
                             defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                             deviceName: "Test iPhone", transport: ScriptedSSHTransport(hostKey: .sample))
        let root = FileManager.default.temporaryDirectory
            .appending(path: "launch-\(UUID().uuidString)/Cache", directoryHint: .isDirectory)
        FileSessionCacheStore(directory: root).saveSessions([SessionListItem(id: "x")])
        ServerCacheSetup.prepare(root: root, model: model)
        FileSessionCacheStore.waitForWrites()
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "sessions.json").path))
    }

    // MARK: Notifications (issue #84)

    @Test func aNotificationOfAnotherServerCarriesTheServerId() async throws {
        let note = CatchUpNotification(session: SessionListItem(id: "s1", title: "Build logs"), reply: "Done.",
                                       showsPreview: false, server: NotificationServer(lab, serverCount: 2))
        let request = LocalNotificationPoster.request(for: note)
        #expect(request.content.title == "Lab: Build logs")
        #expect(request.content.threadIdentifier == "\(lab.id.uuidString)/s1")
        #expect(request.identifier == "reply-\(lab.id.uuidString)/s1")
        #expect(request.content.userInfo[LocalNotificationPoster.serverIdKey] as? String == lab.id.uuidString)
        #expect(LocalNotificationPoster.serverID(in: request.content.userInfo) == lab.id)
        let intent = LocalNotificationPoster.messageIntent(for: note)
        #expect(intent.sender?.displayName == "Lab", "Siri announces the server name")
        #expect(intent.conversationIdentifier == "\(lab.id.uuidString)/s1")
    }

    @Test func aTapKeepsTheServerOfTheNotification() {
        let controller = NotificationController(center: FakeNotificationCenter(),
                                                defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        controller.open(userInfo: [LocalNotificationPoster.sessionIdKey: "s1",
                                   LocalNotificationPoster.serverIdKey: lab.id.uuidString])
        #expect(controller.pendingSessionId == "s1")
        #expect(controller.pendingServerId == lab.id)
        controller.open(userInfo: [LocalNotificationPoster.sessionIdKey: "s2"])
        #expect(controller.pendingServerId == nil, "a notification of an older build has no server")
    }

    @Test func removeServerRemovesItsDeliveredNotifications() async throws {
        let center = DeliveredCenter(delivered: ["reply-a": lab.id, "reply-b": home.id])
        let controller = NotificationController(center: center,
                                                defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        controller.removeDelivered(server: lab.id)
        for _ in 0..<100 where center.removed.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(center.removed == ["reply-a"])
    }

    @Test func theNotificationsFooterNamesTheBackgroundRefreshWithTwoOrMoreServers() {
        #expect(NotificationSettingsSection.footer(serverCount: 1) == NotificationSettingsSection.footer)
        #expect(NotificationSettingsSection.footer(serverCount: 2).hasSuffix(
            "Other servers check in when iOS runs a background refresh."))
    }

    // MARK: Background refresh (issue #84)

    @Test func theOtherServerIsSkippedWhileTheAppIsActive() async throws {
        let setup = await makeModel([home, lab])
        let lists = attachLists(setup.model)
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let notifications = NotificationController(center: FakeNotificationCenter(), defaults: defaults)
        _ = await BackgroundRefresh.run(model: setup.model, link: LiveChatTransport(), sessions: lists.sessions,
                                        notifications: notifications, caches: lists.caches, defaults: defaults,
                                        linkTimeout: .zero, isActive: { true })
        #expect(defaults.string(forKey: BackgroundRotation.lastServerKey) == nil)
        #expect(setup.model.profile?.id == home.id)
    }

    /// The app is in the background: the active link closes, then one other server connects, in turn.
    /// The active server stays active. Only one SSH link is open at a time.
    @Test func aBackgroundRunChecksOneOtherServerInTurnWithOneLinkAtATime() async throws {
        let setup = await makeModel([home, lab, vps])
        let lists = attachLists(setup.model)
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let notifications = NotificationController(center: FakeNotificationCenter(), defaults: defaults)
        await setup.model.connect()
        for expected in [lab.id, vps.id, lab.id] {
            _ = await BackgroundRefresh.run(model: setup.model, link: LiveChatTransport(), sessions: lists.sessions,
                                            notifications: notifications, caches: lists.caches, defaults: defaults,
                                            linkTimeout: .zero, isActive: { false })
            #expect(defaults.string(forKey: BackgroundRotation.lastServerKey) == expected.uuidString)
            #expect(setup.model.profile?.id == home.id, "the active server does not change")
            #expect(lists.caches.activeServer == home.id)
        }
        let record = setup.transport.record
        #expect(record.closedSessions == record.connectAttempts, "every link closed, one at a time")
        #expect(setup.model.connection == .idle)
    }

    @Test func aServerWithNoPinIsNeverConnectedInTheBackground() async throws {
        let fresh = ServerProfile(host: "fresh.example.com")
        let setup = await makeModel([home, fresh])
        let ok = await setup.model.withBackgroundLink(to: fresh.id) { _ in true }
        #expect(!ok)
        #expect(setup.transport.record.connectAttempts == 0)
        #expect(await setup.model.withBackgroundLink(to: home.id) { _ in true } == false, "never the active server")
    }

    @Test func oneServerKeepsTheHermesTitle() async throws {
        let setup = await makeModel([home])
        #expect(!setup.model.serverMenu(activeChats: 3).showsMenu)
        #expect(setup.model.serverMenu(activeChats: 3).title() == "Hermes")
    }
}

/// A notification center with delivered notifications of two servers.
private final class DeliveredCenter: NotificationCentering, @unchecked Sendable {
    private let lock = NSLock()
    private let delivered: [String: UUID]
    private var _removed: [String] = []
    var removed: [String] { lock.withLock { _removed } }

    init(delivered: [String: UUID]) {
        self.delivered = delivered
    }

    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization(options _: UNAuthorizationOptions) async throws -> Bool { true }
    func add(_: UNNotificationRequest) async throws {}
    func setBadgeCount(_: Int) async throws {}
    func deliveredIdentifiers(server: UUID) async -> [String] {
        delivered.filter { $0.value == server }.map(\.key).sorted()
    }
    func removeDelivered(identifiers: [String]) { lock.withLock { _removed.append(contentsOf: identifiers) } }
}
