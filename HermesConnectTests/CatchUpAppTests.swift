import BackgroundTasks
import Foundation
import HermesKit
import Testing
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
        #expect(AppModel.foregroundAction(connection: connected, link: .ready, away: 20) == .reconnect)
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
