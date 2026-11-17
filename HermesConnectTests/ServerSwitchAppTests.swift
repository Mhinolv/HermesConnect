import Foundation
import HermesKit
import Testing
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

    @Test func aSwitchResetsTheListsAndKeepsTheUnreadAndOutboxOfTheOldServer() async throws {
        let setup = await makeModel([home, lab])
        let rows = [SessionListItem(id: "20261117_080000_home01", title: "Trip", isUnread: true),
                    SessionListItem(id: "20261117_080000_home02", title: "Digest", source: "cron", isUnread: true)]
        let cache = InMemorySessionCacheStore(sessions: rows)
        cache.saveOutbox(true, sessionId: "20261117_080000_home03")
        let sessions = SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                                        cache: cache)
        let jobs = ChatLaunch.makeOfflineJobs()
        ServerSwitchGlue.attach(model: setup.model, sessions: sessions, jobs: jobs)
        #expect(setup.model.badgeCount(activeUnread: sessions.unreadCount) == 2)

        await setup.model.switchServer(to: lab.id)
        #expect(!sessions.hasLoaded, "the redacted rows show")
        let kept = setup.model.serverBook.entry(for: home.id)
        #expect(kept.unreadIds == rows.map(\.id))
        #expect(kept.unreadChats == 1, "a cron run is not a chat")
        #expect(kept.outboxIds == ["20261117_080000_home03"])
        #expect(sessions.heldOutboxIds == ["20261117_080000_home03"])
        #expect(setup.model.badgeCount(activeUnread: sessions.unreadCount) == 2, "the badge counts all servers")
        let menu = setup.model.serverMenu(activeChats: sessions.chatsUnreadCount)
        #expect(menu.title() == "Lab")
        #expect(menu.items.map(\.subtitle) == ["1 unread", nil])
        #expect(menu.showsDot)

        // Back on Home: its outbox is free again and its dots come back on the next load.
        await setup.model.switchServer(to: home.id)
        #expect(sessions.heldOutboxIds.isEmpty)
        #expect(!setup.model.serverMenu(activeChats: 0).showsDot)
    }

    @Test func theBookSurvivesARelaunch() async throws {
        let setup = await makeModel([home, lab])
        setup.model.recordServerState(.init(unreadIds: ["l1"], unreadChats: 1, outboxIds: ["l2"]), for: lab.id)
        let relaunched = await makeModel([home, lab], defaults: setup.defaults)
        #expect(relaunched.model.serverBook.entry(for: lab.id) == .init(unreadIds: ["l1"], unreadChats: 1, outboxIds: ["l2"]))
        let sessions = ChatLaunch.makeOfflineSessions()
        ServerSwitchGlue.attach(model: relaunched.model, sessions: sessions, jobs: ChatLaunch.makeOfflineJobs())
        #expect(sessions.heldOutboxIds == ["l2"], "a relaunch on Home never sends the Lab outbox")
    }

    @Test func removeAnotherServerDropsItsOutboxAndCount() async throws {
        let setup = await makeModel([home, lab])
        let cache = InMemorySessionCacheStore()
        cache.saveOutbox(true, sessionId: "l2")
        let sessions = SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                                        cache: cache)
        setup.model.recordServerState(.init(unreadIds: ["l1"], unreadChats: 1, outboxIds: ["l2"]), for: lab.id)
        ServerSwitchGlue.attach(model: setup.model, sessions: sessions, jobs: ChatLaunch.makeOfflineJobs())
        try setup.model.removeServer(id: lab.id)
        #expect(setup.model.serverBook.entries.isEmpty)
        #expect(cache.outboxSessionIds().isEmpty, "the queued messages of a removed server never send")
        #expect(sessions.heldOutboxIds.isEmpty)
        #expect(setup.model.badgeCount(activeUnread: 0) == 0)
    }

    @Test func removeTheActiveServerSwitchesToTheFirstAndDropsItsOutbox() async throws {
        let setup = await makeModel([home, lab], active: 1)
        let cache = InMemorySessionCacheStore()
        cache.saveOutbox(true, sessionId: "l2")
        let sessions = SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                                        cache: cache)
        ServerSwitchGlue.attach(model: setup.model, sessions: sessions, jobs: ChatLaunch.makeOfflineJobs())
        try setup.model.removeServer(id: lab.id)
        #expect(setup.model.profile?.id == home.id)
        #expect(cache.outboxSessionIds().isEmpty)
    }

    @Test func addServerSwitchesAndResetsTheLists() async throws {
        let setup = await makeModel([home])
        let sessions = SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                                        cache: InMemorySessionCacheStore(sessions: [SessionListItem(id: "h1")]))
        ServerSwitchGlue.attach(model: setup.model, sessions: sessions, jobs: ChatLaunch.makeOfflineJobs())
        try setup.model.addServer(lab)
        #expect(setup.model.profile?.id == lab.id)
        #expect(!sessions.hasLoaded)
        #expect(setup.model.serverMenu(activeChats: 0).title() == "Lab")
    }

    @Test func oneServerKeepsTheHermesTitle() async throws {
        let setup = await makeModel([home])
        #expect(!setup.model.serverMenu(activeChats: 3).showsMenu)
        #expect(setup.model.serverMenu(activeChats: 3).title() == "Hermes")
    }
}
