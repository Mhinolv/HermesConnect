import BackgroundTasks
import Foundation
import HermesKit
import Testing
import UIKit
import UserNotifications
@testable import HermesConnect

/// A notification center with no system calls.
final class FakeNotificationCenter: NotificationCentering, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: UNAuthorizationStatus
    private var _requests: [UNAuthorizationOptions] = []
    private var _added: [UNNotificationRequest] = []
    private var _badges: [Int] = []

    /// How long `authorizationStatus()` takes. A real center answers over XPC, so it is not instant.
    private let statusDelay: Duration

    init(status: UNAuthorizationStatus = .notDetermined, statusDelay: Duration = .zero) {
        _status = status
        self.statusDelay = statusDelay
    }

    var requests: [UNAuthorizationOptions] { lock.withLock { _requests } }
    var added: [UNNotificationRequest] { lock.withLock { _added } }
    var badges: [Int] { lock.withLock { _badges } }

    func authorizationStatus() async -> UNAuthorizationStatus {
        if statusDelay > .zero { try? await Task.sleep(for: statusDelay) }
        return lock.withLock { _status }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        lock.withLock {
            _requests.append(options)
            _status = .authorized
        }
        return true
    }

    func add(_ request: UNNotificationRequest) async throws { lock.withLock { _added.append(request) } }
    func setBadgeCount(_ count: Int) async throws { lock.withLock { _badges.append(count) } }
}

/// Records the submitted requests. No `BGTaskScheduler`.
final class FakeTaskScheduler: BackgroundTaskScheduling {
    var submitted: [BGTaskRequest] = []
    func submit(_ request: BGTaskRequest) throws { submitted.append(request) }
    func cancel(taskRequestWithIdentifier _: String) {}
}

private func freshDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Issue #15: foreground reconcile, local notifications and the background refresh in the app.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CatchUpAppTests {
    @Test func foregroundReconnectsOnlyWhenTheConnectionCanBeDead() {
        let connected = AppModel.ConnectionState.connected(gateVersion: "1")
        #expect(AppModel.foregroundAction(connection: .idle, link: nil, away: 1) == .connect)
        #expect(AppModel.foregroundAction(connection: .offline(.unreachable), link: nil, away: 1) == .connect)
        // The owner cancelled the trust sheet: no new sheet on its own.
        #expect(AppModel.foregroundAction(connection: .offline(nil), link: nil, away: 600) == .none)
        #expect(AppModel.foregroundAction(connection: connected, link: .ready, away: 5) == .none)
        // Issue #176: a link that looks ready after a long time away gets one ping first.
        #expect(AppModel.foregroundAction(connection: connected, link: .ready, away: 20) == .probe)
        #expect(AppModel.foregroundAction(connection: connected, link: .connecting, away: 20) == .reconnect)
        #expect(AppModel.foregroundAction(connection: connected, link: .notConnected, away: 1) == .reconnect)
        #expect(AppModel.foregroundAction(connection: .connecting, link: nil, away: 600) == .none)
        #expect(AppModel.foregroundAction(connection: .startingHermes, link: nil, away: 600) == .none)
        // States that wait for the owner never reconnect on their own (pin and gate rules of #3 and #4).
        #expect(AppModel.foregroundAction(connection: .hostKeyChanged(saved: .sample, received: .otherSample),
                                          link: nil, away: 600) == .none)
        #expect(AppModel.foregroundAction(connection: .notStarted(.authenticationFailed), link: nil, away: 600) == .none)
    }

    /// The reconnect uses the normal connect: an unknown host key shows the trust sheet, it never authenticates.
    @Test func foregroundConnectKeepsThePinFlow() async {
        let model = AppModel.preview(setUp: true, hostKey: nil)
        await model.reconnectOnForeground(link: nil, away: 60)
        #expect(model.pendingTrust == .sample)
        #expect(model.hermesEndpoint == nil)
    }

    /// Issue #176: a probe is not run for a link that needs a connect. The pin flow stays.
    @Test func probeRunsOnlyForAReadyLink() async {
        let model = AppModel.preview(setUp: true, hostKey: nil)
        var probed = false
        await model.reconnectOnForeground(link: nil, away: 60, probe: { probed = true; return true })
        #expect(probed == false)
        #expect(model.pendingTrust == .sample)
    }

    /// Issue #176: a link that answers the ping is kept. A link that does not answer reconnects.
    @Test func probeKeepsALiveLinkAndReconnectsADeadOne() async {
        let model = AppModel.preview(setUp: true)
        model.previewConnection(.connected(gateVersion: "1"))
        await model.reconnectOnForeground(link: .ready, away: 60, probe: { true })
        #expect(model.connection == .connected(gateVersion: "1"))

        var probed = false
        await model.reconnectOnForeground(link: .ready, away: 60, probe: { probed = true; return false })
        #expect(probed)
        #expect(model.connection != .connected(gateVersion: "1"))
    }

    /// Issue #176: one background task while away. It ends on return or when iOS ends the time.
    @Test func linkKeeperHoldsOneTaskAndReleasesIt() {
        let app = FakeBackgroundTime()
        let keeper = LinkKeeper(application: app)
        keeper.hold()
        keeper.hold()
        #expect(app.begun == [LinkKeeper.taskName])
        #expect(keeper.isHolding)
        keeper.release()
        #expect(app.ended.count == 1)
        #expect(!keeper.isHolding)
        keeper.release()
        #expect(app.ended.count == 1)

        keeper.hold()
        app.expire()
        #expect(app.ended.count == 2)
        #expect(!keeper.isHolding)
    }

    @Test func updatingSubtitleShowsOnlyWhenConnected() {
        let connected = AppModel.ConnectionState.connected(gateVersion: "1")
        #expect(ChatLaunch.subtitle(link: .ready, connection: connected, updating: true) == .updating)
        #expect(ChatLaunch.subtitle(link: .ready, connection: connected, updating: false) == .connection)
        // "Offline" wins: the cached messages stay and the subtitle says "Offline".
        #expect(ChatLaunch.subtitle(link: .ready, connection: .offline(.unreachable), updating: true) == .connection)
        #expect(ChatLaunch.subtitle(link: .reconnecting, connection: connected, updating: true) == .reconnecting)
    }

    @Test func newMessagesPillText() {
        #expect(ChatNewMessages.title(1) == "1 New Message")
        #expect(ChatNewMessages.title(3) == "3 New Messages")
        #expect(ChatNewMessages.spoken(3) == "3 new messages")
    }

    @Test func notificationRequestUsesTheSessionAsTheThread() {
        let request = LocalNotificationPoster.request(
            for: CatchUpNotification(sessionId: "k1", title: "Trip plan", body: "New message from Hermes"))
        #expect(request.identifier == "reply-k1")
        #expect(request.trigger == nil)
        #expect(request.content.title == "Trip plan")
        #expect(request.content.body == "New message from Hermes")
        #expect(request.content.threadIdentifier == "k1")
        #expect(request.content.userInfo[LocalNotificationPoster.sessionIdKey] as? String == "k1")
    }

    @Test(arguments: [Duration.zero, .milliseconds(50)])
    func permissionIsAskedOnceAfterTheFirstReply(statusDelay: Duration) async throws {
        let center = FakeNotificationCenter(statusDelay: statusDelay)
        // One suite per case: the two cases can run at the same time.
        let defaults = freshDefaults("CatchUpAppTests.ask.\(statusDelay.components.attoseconds)")
        let controller = NotificationController(center: center, defaults: defaults)
        #expect(center.requests.isEmpty)
        controller.requestAfterFirstReply()
        // Wait for the end of the whole request. `requests` grows inside the center call, before the
        // controller reads the new status. A check at that point raced with `refreshStatus()`.
        try await waitFor { center.requests.count == 1 && controller.status == .authorized }
        #expect(center.requests == [[.alert, .sound, .badge]])
        #expect(controller.status == .authorized)
        controller.requestAfterFirstReply()
        try await Task.sleep(for: .milliseconds(30))
        #expect(center.requests.count == 1)
    }

    @Test func deniedPermissionIsNotAskedAgain() async throws {
        #expect(NotificationController.shouldAsk(status: .notDetermined, asked: false))
        #expect(!NotificationController.shouldAsk(status: .denied, asked: false))
        #expect(!NotificationController.shouldAsk(status: .notDetermined, asked: true))
        let center = FakeNotificationCenter(status: .denied)
        let controller = NotificationController(center: center, defaults: freshDefaults("CatchUpAppTests.denied"))
        await controller.refreshStatus()
        #expect(controller.status == .denied)
    }

    @Test func previewIsOffByDefaultAndTheToggleSavesIt() {
        let defaults = freshDefaults("CatchUpAppTests.preview")
        let controller = NotificationController(center: FakeNotificationCenter(), defaults: defaults)
        #expect(!controller.showsPreview)
        controller.showsPreview = true
        #expect(defaults.bool(forKey: NotificationSettings.showPreviewKey))
    }

    @Test func aTapOpensThatSession() {
        let controller = NotificationController(center: FakeNotificationCenter(),
                                                defaults: freshDefaults("CatchUpAppTests.tap"))
        controller.open(userInfo: [:])
        #expect(controller.pendingSessionId == nil)
        controller.open(userInfo: [LocalNotificationPoster.sessionIdKey: "k7"])
        #expect(controller.pendingSessionId == "k7")
    }

    @Test func backgroundRefreshIsScheduledFifteenMinutesOut() throws {
        let scheduler = FakeTaskScheduler()
        let now = Date(timeIntervalSince1970: 1_763_290_000)
        BackgroundRefresh.schedule(on: scheduler, now: now)
        let request = try #require(scheduler.submitted.first as? BGAppRefreshTaskRequest)
        #expect(request.identifier == BackgroundRefresh.identifier)
        #expect(request.earliestBeginDate == now.addingTimeInterval(15 * 60))
    }

    /// The task identifier is permitted, `fetch` is on, and there is no push entitlement for an APNs relay.
    @Test func infoPlistAllowsTheRefreshAndNoPush() {
        let info = Bundle(for: NotificationController.self).infoDictionary ?? [:]
        #expect((info["BGTaskSchedulerPermittedIdentifiers"] as? [String])?.contains(BackgroundRefresh.identifier) == true)
        #expect((info["UIBackgroundModes"] as? [String])?.contains("fetch") == true)
        #expect((info["UIBackgroundModes"] as? [String])?.contains("remote-notification") != true)
        #expect(info["aps-environment"] == nil)
    }

    @Test func backgroundRunWithNoSetupDoesNothing() async {
        let model = AppModel.preview(setUp: false)
        let link = LiveChatTransport()
        let sessions = ChatLaunch.makeOfflineSessions()
        let controller = NotificationController(center: FakeNotificationCenter(),
                                                defaults: freshDefaults("CatchUpAppTests.run"))
        let ok = await BackgroundRefresh.run(model: model, link: link, sessions: sessions, notifications: controller)
        #expect(!ok)
        #expect(model.connection == .idle)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition not met")
    }
}

/// Records the background tasks. No `UIApplication`.
@MainActor
final class FakeBackgroundTime: BackgroundTimeGranting {
    var begun: [String] = []
    var ended: [UIBackgroundTaskIdentifier] = []
    private var handler: (@MainActor @Sendable () -> Void)?
    private var next = 1

    func beginBackgroundTask(withName name: String?,
                             expirationHandler: (@MainActor @Sendable () -> Void)?) -> UIBackgroundTaskIdentifier {
        begun.append(name ?? "")
        handler = expirationHandler
        next += 1
        return UIBackgroundTaskIdentifier(rawValue: next)
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) { ended.append(identifier) }

    func expire() { handler?() }
}

/// A path monitor with no `NWPathMonitor` (issue #178).
@MainActor
final class FakeAppPathMonitor: NetworkPathMonitoring {
    private var onChange: (@MainActor (LinkPath) -> Void)?
    func start(_ onChange: @escaping @MainActor (LinkPath) -> Void) { self.onChange = onChange }
    func stop() { onChange = nil }
    func change(_ path: LinkPath = LinkPath(isSatisfied: true, interfaces: ["cellular"])) { onChange?(path) }
}

/// Issue #179: a chat socket that never opens (the server refuses the TCP connect).
struct RefusingGatewayConnector: GatewayWebSocketConnecting {
    func connect(to url: URL) async throws -> any GatewayWebSocket {
        throw GatewayWebSocketClosed(urlErrorCode: -1004)
    }
}

/// Issue #179: a retry clock that the test fires. `fire()` ends every wait at once.
@MainActor
final class AppRetryClock: RetryClock {
    private(set) var now = ContinuousClock.now
    private var sleepers: [CheckedContinuation<Void, any Error>] = []
    var sleeperCount: Int { sleepers.count }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { sleepers.append($0) }
    }

    /// End the waits that run now. A cancelled wait ends too: the supervisor then ignores it.
    func fire() {
        now = now + .seconds(30)
        let due = sleepers
        sleepers.removeAll()
        due.forEach { $0.resume() }
    }
}

/// Issue #178: reconnect when the link dies while the app is open. Fakes only: no network, SSH or `NWPathMonitor`.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LinkSupervisorAppTests {
    private struct Setup {
        let model: AppModel
        let transport: ScriptedSSHTransport
    }

    private func makeModel(hostKey: HostKey? = .sample) async -> Setup {
        let keyStore = KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: SoftwareKeyFactory())
        let store = InMemoryServerListStore(profile: ServerProfile(host: "vps.example.com", hostKey: hostKey))
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let serve = ServeBootstrap(loader: ScriptedHermesHTTP(),
                                   configuration: .init(serveTimeout: .seconds(5), healthAttempts: 1,
                                                        healthRetryDelay: .milliseconds(1)))
        let model = AppModel(keyStore: keyStore, serverStore: store,
                             defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                             deviceName: "Test iPhone", transport: transport, serve: serve)
        await model.ensureKey()
        return Setup(model: model, transport: transport)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition not met")
    }

    /// Regression for #178: a dead chat link showed "Connected". Now it shows "Reconnecting…".
    @Test func deadLinkNeverShowsConnected() {
        let connected = AppModel.ConnectionState.connected(gateVersion: "1")
        #expect(ChatLaunch.subtitle(link: .notConnected, connection: connected) == .reconnecting)
        #expect(ChatLaunch.subtitle(link: .ready, connection: connected) == .connection)
        // During the reconnect the connection goes idle, then connecting. The subtitle stays "Reconnecting…".
        for stage in [AppModel.ConnectionState.idle, .connecting, .startingHermes, connected] {
            #expect(ChatLaunch.subtitle(link: .notConnected, connection: stage, recovering: true) == .reconnecting)
        }
        // A failed reconnect is "Offline ↻". The owner states win too.
        #expect(ChatLaunch.subtitle(link: .notConnected, connection: .offline(.unreachable), recovering: true)
            == .connection)
        #expect(ChatLaunch.subtitle(link: .notConnected, connection: .hostKeyChanged(saved: .sample, received: .otherSample))
            == .connection)
        // No link yet (launch) is not a drop.
        #expect(ChatLaunch.subtitle(link: .notConnected, connection: .connecting) == .connection)
    }

    /// The server closes the SSH connection: the app reports it. A close from the app does not count.
    @Test func sshCloseOfTheActiveLinkIsReported() async throws {
        let setup = await makeModel()
        var closes = 0
        setup.model.onSessionClosed = { closes += 1 }
        await setup.model.connect()
        #expect(setup.model.connection == .connected(gateVersion: "1"))

        await setup.model.disconnect()
        try await Task.sleep(for: .milliseconds(30))
        #expect(closes == 0)

        await setup.model.connect()
        setup.transport.dropSessions()
        try await waitFor { closes == 1 }
    }

    /// The token stays, so the gate reuses the running Hermes. No new spawn.
    @Test func recoverLinkReconnectsAndKeepsTheToken() async {
        let setup = await makeModel()
        await setup.model.connect()
        #expect(setup.model.canRecoverLink)
        #expect(await setup.model.recoverLink())
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(!setup.model.isRecoveringLink)
        #expect(setup.transport.record.connectAttempts == 2)
        #expect(setup.transport.record.spawns == 1)
        #expect(setup.transport.record.reuses == 1)
    }

    /// The trust sheet and a changed host key wait for the owner. "Offline" waits for #179.
    @Test func statesThatWaitForTheOwnerDoNotRecover() async {
        let unknown = await makeModel(hostKey: nil)
        await unknown.model.connect()
        #expect(unknown.model.pendingTrust == .sample)
        #expect(!unknown.model.canRecoverLink)
        #expect(await unknown.model.recoverLink() == false)
        #expect(unknown.transport.record.connectAttempts == 1)

        let changed = await makeModel(hostKey: .otherSample)
        await changed.model.connect()
        #expect(!changed.model.canRecoverLink)

        let offline = await makeModel()
        offline.transport.connectFailure = .unreachable
        await offline.model.connect()
        #expect(!offline.model.canRecoverLink)
    }

    /// End to end: an SSH drop in the foreground reconnects with no action from the owner.
    @Test func sshDropInTheForegroundReconnects() async throws {
        let setup = await makeModel()
        let link = LiveChatTransport()
        let monitor = FakeAppPathMonitor()
        let supervisor = ChatLaunch.makeSupervisor(model: setup.model, link: link, monitor: monitor)
        await setup.model.connect()
        // Background: nothing happens. The #176 check handles the return.
        setup.transport.dropSessions()
        try await Task.sleep(for: .milliseconds(30))
        #expect(setup.transport.record.connectAttempts == 1)

        supervisor.setForeground(true)
        await setup.model.connect()
        let before = setup.transport.record.connectAttempts
        setup.transport.dropSessions()
        try await waitFor { setup.transport.record.connectAttempts == before + 1 }
        try await waitFor { setup.model.connection == .connected(gateVersion: "1") && !setup.model.isRecoveringLink }
        #expect(supervisor.lastOutcome == .reconnected(succeeded: true))

        // A path change on a link that is not ready reconnects too (the probe needs a ready link).
        monitor.change()
        try await waitFor { setup.transport.record.connectAttempts == before + 2 }
        supervisor.stop()
    }

    /// Regression for #179 (QA #211 risk 2): SSH and serve connected, but the chat socket did not open.
    /// The subtitle stayed "Reconnecting…" and nothing retried. Now it is a failed try: "Offline", then a retry.
    @Test func chatSocketFailureAfterAGoodConnectIsAFailedTry() async throws {
        let setup = await makeModel()
        let link = LiveChatTransport(makeClient: {
            GatewayClient(endpoint: $0, connector: RefusingGatewayConnector(),
                          configuration: .init(heartbeatInterval: nil, readyTimeout: .seconds(1)))
        })
        let clock = AppRetryClock()
        let supervisor = ChatLaunch.makeSupervisor(model: setup.model, link: link, monitor: FakeAppPathMonitor(),
                                                   clock: clock)
        supervisor.setForeground(true)
        await setup.model.connect()
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        // The root gives the endpoint to the link (`onChange(of: hermesEndpoint)`).
        link.setEndpoint(setup.model.hermesEndpoint)
        try await waitFor { link.status == .notConnected }
        try await waitFor { setup.model.connection == .offline(.unreachable) }
        #expect(ChatLaunch.subtitle(link: link.status, connection: setup.model.connection) != .reconnecting)
        // The link closed ("Offline"), and the next try waits 2 s.
        #expect(setup.model.hermesEndpoint == nil)
        #expect(supervisor.retryAt.map { $0 - clock.now } == .seconds(2))
        try await waitFor { clock.sleeperCount > 0 }
        clock.fire()
        try await waitFor { setup.model.connection == .connected(gateVersion: "1") }
        #expect(setup.transport.record.connectAttempts == 2)
        supervisor.stop()
    }

    /// Issue #179, criteria 1 and 3: a network failure retries after the wait. A refused key, a changed
    /// host key and the trust sheet never start a wait.
    @Test func onlyNetworkFailuresRetry() async throws {
        let offline = await makeModel()
        let clock = AppRetryClock()
        let supervisor = ChatLaunch.makeSupervisor(model: offline.model, link: LiveChatTransport(),
                                                   monitor: FakeAppPathMonitor(), clock: clock)
        supervisor.setForeground(true)
        offline.transport.connectFailure = .unreachable
        await offline.model.connect()
        #expect(offline.model.connection == .offline(.unreachable))
        #expect(offline.model.canRetryConnect)
        #expect(supervisor.retryAt.map { $0 - clock.now } == .seconds(2))
        // The try fails too: the wait doubles.
        try await waitFor { clock.sleeperCount > 0 }
        clock.fire()
        try await waitFor { offline.transport.record.connectAttempts == 2 && supervisor.retryAt != nil }
        #expect(supervisor.retryAt.map { $0 - clock.now } == .seconds(4))
        // The server answers: the next try connects.
        offline.transport.connectFailure = nil
        try await waitFor { clock.sleeperCount > 0 }
        clock.fire()
        try await waitFor { offline.model.connection == .connected(gateVersion: "1") }
        #expect(supervisor.retryAt == nil)
        supervisor.stop()

        // A refused key, a changed host key, the trust sheet and its "Cancel".
        let refused = await makeModel()
        refused.transport.connectFailure = .authenticationFailed
        let changed = await makeModel(hostKey: .otherSample)
        let unknown = await makeModel(hostKey: nil)
        for setup in [refused, changed, unknown] {
            var reports = 0
            setup.model.onConnectFailed = { reports += 1 }
            await setup.model.connect()
            #expect(reports == 0)
            #expect(!setup.model.canRetryConnect)
        }
        #expect(refused.model.connection == .notStarted(.authenticationFailed))
        #expect(changed.model.connection == .hostKeyChanged(saved: .otherSample, received: .sample))
        #expect(unknown.model.pendingTrust == .sample)
        unknown.model.cancelTrust()
        #expect(unknown.model.connection == .offline(nil))
        #expect(!unknown.model.canRetryConnect)
    }

    /// Issue #179: "Offline" after a cancelled trust sheet waits for a tap. A connected link is not "Offline".
    @Test func canRetryConnectNeedsANetworkFailure() async {
        let setup = await makeModel()
        #expect(!setup.model.canRetryConnect)
        await setup.model.connect()
        #expect(!setup.model.canRetryConnect)
        await setup.model.abandonLink()
        #expect(setup.model.connection == .offline(.unreachable))
        #expect(setup.model.hermesEndpoint == nil)
        #expect(setup.model.canRetryConnect)
        setup.model.previewConnection(.offline(nil))
        #expect(!setup.model.canRetryConnect)
        // `abandonLink` acts only on a connected link.
        await setup.model.abandonLink()
        #expect(setup.model.connection == .offline(nil))
    }

    @Test func reconnectIsAnnouncedOneTimeForEachDrop() {
        let start = ContinuousClock.now
        #expect(ReconnectAnnouncement.shouldPost(now: start, last: nil))
        #expect(!ReconnectAnnouncement.shouldPost(now: start + .seconds(1), last: start))
        #expect(ReconnectAnnouncement.shouldPost(now: start + .seconds(6), last: start))
    }
}
