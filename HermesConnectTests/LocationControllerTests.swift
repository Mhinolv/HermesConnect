import CoreLocation
import Foundation
import HermesKit
import Testing
import UIKit
@testable import HermesConnect

/// A fake Core Location manager. It records the calls and never asks iOS.
@MainActor
private final class FakeLocationManager: LocationManaging {
    weak var delegate: (any CLLocationManagerDelegate)?
    var authorizationStatus: CLAuthorizationStatus
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    var whenInUseRequests = 0
    var alwaysRequests = 0
    var locationRequests = 0
    var monitorsSignificantChanges = false
    var monitorsVisits = false
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters
    var distanceFilter: CLLocationDistance = kCLDistanceFilterNone
    var updatesLocation = false

    init(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
    }

    func requestWhenInUseAuthorization() { whenInUseRequests += 1 }
    func requestAlwaysAuthorization() { alwaysRequests += 1 }
    func startMonitoringSignificantLocationChanges() { monitorsSignificantChanges = true }
    func stopMonitoringSignificantLocationChanges() { monitorsSignificantChanges = false }
    func startMonitoringVisits() { monitorsVisits = true }
    func stopMonitoringVisits() { monitorsVisits = false }
    func requestLocation() { locationRequests += 1 }
    func startUpdatingLocation() { updatesLocation = true }
    func stopUpdatingLocation() { updatesLocation = false }
}

/// A fake iOS background-task runner. Tests fire the expiration handler by hand.
@MainActor
private final class FakeBackgroundTasks {
    private var next = 1
    private(set) var begun = 0
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private var handlers: [UIBackgroundTaskIdentifier: @MainActor () -> Void] = [:]

    var tasks: BackgroundTasks {
        BackgroundTasks(begin: { [self] onExpire in
            let id = UIBackgroundTaskIdentifier(rawValue: next)
            next += 1
            begun += 1
            handlers[id] = onExpire
            return id
        }, end: { [self] id in ended.append(id) })
    }

    /// iOS ran out of background time: call each open expiration handler, as iOS does.
    func expireAll() {
        for (id, handler) in handlers where !ended.contains(id) { handler() }
    }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func fix(_ lat: Double = 37.3349, at time: Date = t0, accuracy: Double = 10) -> LocationFix {
    LocationFix(latitude: lat, longitude: -122.009, horizontalAccuracy: accuracy, timestamp: time)!
}

@MainActor
@Suite struct LocationControllerTests {
    private struct Rig {
        let controller: LocationController
        let manager: FakeLocationManager
        /// The uploader of the migrated server (`serverID`).
        let uploader: ScriptedLocationUploader
        let store: InMemoryLocationStateStore
        let defaults: UserDefaults
        let servers: InMemoryServerListStore
        /// Issue #92: a second saved server ("Ouro"), with its own uploader. Sharing is off for it.
        let teamUploader: ScriptedLocationUploader
        var serverID: UUID { ServerProfile.legacyID }
        let teamID: UUID
    }

    /// One migrated server and one new team server. `enabled` sets the switch of the builds before issue #92,
    /// so the migrated server shares, as after an update.
    private func make(_ status: CLAuthorizationStatus = .notDetermined, enabled: Bool = false,
                      failure: LocationUploadError? = nil, defaults: UserDefaults? = nil,
                      store: InMemoryLocationStateStore = InMemoryLocationStateStore(),
                      background: BackgroundTasks = .none) -> Rig {
        let suite = defaults ?? UserDefaults(suiteName: "loc-\(UUID().uuidString)")!
        if enabled { suite.set(true, forKey: LocationController.enabledKey) }
        let manager = FakeLocationManager(status)
        let uploader = ScriptedLocationUploader(failure: failure)
        let teamUploader = ScriptedLocationUploader()
        let home = ServerProfile(id: ServerProfile.legacyID, host: "100.64.0.1", hostKey: .sample)
        let team = ServerProfile(host: "100.64.0.2", displayName: "Ouro", hostKey: .otherSample)
        let servers = InMemoryServerListStore(ServerList(servers: [home, team], activeID: home.id))
        let teamStore = InMemoryLocationStateStore()
        let sharing = LocationFanOut(servers: servers, settings: DefaultsLocationServerSettingsStore(defaults: suite),
                                     store: { $0 == home.id ? store : teamStore },
                                     uploader: { $0 == home.id ? uploader : teamUploader })
        let controller = LocationController(manager: manager, sharing: sharing,
                                            settings: DefaultsLocationServerSettingsStore(defaults: suite),
                                            servers: servers, defaults: suite, background: background)
        return Rig(controller: controller, manager: manager, uploader: uploader, store: store, defaults: suite,
                   servers: servers, teamUploader: teamUploader, teamID: team.id)
    }

    @Test func sharingIsOffByDefaultAndDoesNotMonitor() {
        let rig = make(.authorizedAlways)
        #expect(!rig.controller.isEnabled)
        #expect(!rig.manager.monitorsSignificantChanges)
        #expect(!rig.manager.monitorsVisits)
        #expect(rig.manager.delegate === rig.controller)
    }

    @Test func turnOnAsksWhenInUseThenAlways() {
        let rig = make()
        rig.controller.setSharing(true, server: rig.serverID)
        #expect(rig.controller.isEnabled)
        #expect(rig.manager.whenInUseRequests == 1)
        #expect(rig.manager.alwaysRequests == 0)
        rig.manager.authorizationStatus = .authorizedWhenInUse
        rig.controller.authorizationDidChange()
        #expect(rig.controller.access == .whileUsing)
        #expect(rig.manager.alwaysRequests == 1)
        #expect(rig.manager.monitorsSignificantChanges)
        #expect(rig.manager.monitorsVisits)
        // iOS asks for Always once. The app does not ask again.
        rig.controller.authorizationDidChange()
        #expect(rig.manager.alwaysRequests == 1)
        rig.manager.authorizationStatus = .authorizedAlways
        rig.controller.authorizationDidChange()
        #expect(rig.controller.access == .always)
        #expect(rig.manager.monitorsSignificantChanges)
    }

    @Test func turnOnWithAccessOffShowsTheAlertAndStaysOff() {
        let rig = make(.denied)
        // The server detail shows the alert when `setSharing` gives false.
        #expect(!rig.controller.setSharing(true, server: rig.serverID))
        #expect(!rig.controller.isSharing(server: rig.serverID))
        #expect(!rig.controller.isEnabled)
        #expect(rig.manager.whenInUseRequests == 0)
        #expect(!rig.manager.monitorsSignificantChanges)
        #expect(LocationController.Access(.restricted) == .off)
    }

    @Test func relaunchWithSharingOnStartsMonitoringAgain() {
        let rig = make(.authorizedAlways, enabled: true)
        #expect(rig.manager.monitorsSignificantChanges)
        #expect(rig.manager.monitorsVisits)
    }

    @Test func revokedAccessStopsMonitoring() {
        let rig = make(.authorizedAlways, enabled: true)
        rig.manager.authorizationStatus = .denied
        rig.controller.authorizationDidChange()
        #expect(rig.controller.access == .off)
        #expect(!rig.manager.monitorsSignificantChanges)
        #expect(!rig.manager.monitorsVisits)
    }

    @Test func aBackgroundFixIsSentWithoutOwnerAction() async {
        let rig = make(.authorizedAlways, enabled: true)
        rig.controller.received([fix(37.30, at: t0), fix(37.31, at: t0.addingTimeInterval(5))])
        await rig.controller.waitForUploads()
        // Only the newest fix of a batch goes.
        #expect(rig.uploader.payloads.count == 1)
        #expect(rig.store.load().lastSent == fix(37.31, at: t0.addingTimeInterval(5)))
        #expect(rig.controller.status.lastSentAt != nil)
    }

    @Test func eachUploadEndsItsBackgroundTaskOnce() async {
        let tasks = FakeBackgroundTasks()
        let rig = make(.authorizedAlways, enabled: true, background: tasks.tasks)
        rig.controller.received([fix()])
        await rig.controller.waitForUploads()
        #expect(tasks.begun == 1)
        #expect(tasks.ended.count == 1)
        // A late expiry after the end does nothing.
        tasks.expireAll()
        #expect(tasks.ended.count == 1)
    }

    @Test func expiryCancelsTheUploadEndsTheTaskAndKeepsTheFix() async throws {
        let tasks = FakeBackgroundTasks()
        let rig = make(.authorizedAlways, enabled: true, background: tasks.tasks)
        let started = AsyncStream<Void>.makeStream()
        rig.uploader.duringUpload = {
            started.continuation.yield()
            // A slow server: the upload waits until iOS takes the time away.
            try? await Task.sleep(for: .seconds(60))
        }
        rig.controller.received([fix()])
        for await _ in started.stream { break }
        #expect(tasks.ended.isEmpty)

        tasks.expireAll()
        // The handler ends the task before it returns, as iOS requires.
        #expect(tasks.ended.count == 1)
        await rig.controller.waitForUploads()
        #expect(tasks.ended.count == 1)
        #expect(rig.store.load().pending == fix())
        #expect(rig.store.load().lastSentAt == nil)
        #expect(rig.controller.status.waitingForConnection)

        // The next connect sends the kept fix.
        rig.uploader.duringUpload = nil
        rig.controller.didConnect(server: rig.serverID)
        await rig.controller.waitForUploads()
        #expect(rig.store.load().pending == nil)
        #expect(rig.store.load().lastSent == fix())
        #expect(tasks.ended.count == 2)
    }

    @Test func expiryOfAManualSendShowsNotDelivered() async {
        let tasks = FakeBackgroundTasks()
        let rig = make(.authorizedAlways, enabled: true, background: tasks.tasks)
        let started = AsyncStream<Void>.makeStream()
        rig.uploader.duringUpload = {
            started.continuation.yield()
            try? await Task.sleep(for: .seconds(60))
        }
        rig.controller.sendCurrentLocation()
        rig.controller.received([fix()])
        for await _ in started.stream { break }
        tasks.expireAll()
        await rig.controller.waitForUploads()
        #expect(rig.controller.manualSend == .notDelivered)
    }

    @Test func aFixWithSharingOffIsIgnored() async {
        let rig = make(.authorizedAlways)
        rig.controller.received([fix()])
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.isEmpty)
    }

    @Test func offlineKeepsTheFixAndSendsItOnConnect() async {
        let rig = make(.authorizedAlways, enabled: true, failure: .connection(.unreachable))
        rig.controller.received([fix()])
        await rig.controller.waitForUploads()
        #expect(rig.controller.status.waitingForConnection)
        #expect(LocationController.lastSentText(rig.controller.status, now: t0) == "Waiting for connection")
        rig.uploader.failure = nil
        rig.controller.didConnect(server: rig.serverID)
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.count == 2)
        #expect(!rig.controller.status.waitingForConnection)
        #expect(rig.controller.status.lastError == nil)
    }

    @Test func turnOffDropsTheWaitingFixAndStopsMonitoring() async {
        let rig = make(.authorizedAlways, enabled: true, failure: .timedOut)
        rig.controller.received([fix()])
        await rig.controller.waitForUploads()
        rig.controller.setSharing(false, server: rig.serverID)
        await rig.controller.waitForUploads()
        #expect(rig.store.load().pending == nil)
        #expect(!rig.manager.monitorsSignificantChanges)
        #expect(!rig.controller.isSharing(server: rig.serverID))
        #expect(DefaultsLocationServerSettingsStore(defaults: rig.defaults).load().sharingIDs.isEmpty)
    }

    @Test func approximatePrecisionIsSavedAndUsed() async throws {
        let rig = make(.authorizedAlways, enabled: true)
        rig.controller.setPrecision(.approximate)
        #expect(rig.defaults.string(forKey: LocationController.precisionKey) == "approximate")
        rig.controller.received([fix()])
        await rig.controller.waitForUploads()
        let payload = try #require(rig.uploader.payloads.first)
        let body = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(body["accuracy_m"] as? Double == 1000)
    }

    @Test func sendNowSendsOneFixWithoutTheRateLimit() async {
        let rig = make(.authorizedWhenInUse, enabled: true)
        rig.controller.sendCurrentLocation()
        #expect(rig.manager.locationRequests == 1)
        #expect(rig.controller.manualSend == .sending)
        rig.controller.received([fix()])
        await rig.controller.waitForUploads()
        #expect(rig.controller.manualSend == .sent)
        rig.controller.sendCurrentLocation()
        rig.controller.received([fix(at: t0.addingTimeInterval(10))])
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.count == 2)
        #expect(rig.teamUploader.payloads.isEmpty)
        // With sharing off, a later fix is not sent, and "Send Location Now" asks Core Location for nothing.
        rig.controller.setSharing(false, server: rig.serverID)
        rig.controller.received([fix(at: t0.addingTimeInterval(20))])
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.count == 2)
        rig.controller.sendCurrentLocation()
        #expect(rig.controller.manualSend != .sending)
        #expect(rig.manager.locationRequests == 2)
    }

    @Test func sendNowFailureShowsNotDelivered() async {
        let rig = make(.authorizedAlways, enabled: true, failure: .connection(.unreachable))
        rig.controller.sendCurrentLocation()
        rig.controller.received([fix()])
        await rig.controller.waitForUploads()
        #expect(rig.controller.manualSend == .notDelivered)
        let other = make(.authorizedAlways, enabled: true)
        other.controller.sendCurrentLocation()
        other.controller.locationFailed()
        #expect(other.controller.manualSend == .notDelivered)
    }

    @Test func sendNowWithAccessOffShowsTheAlert() {
        let rig = make(.denied)
        rig.controller.sendCurrentLocation()
        #expect(rig.controller.showsAccessOffAlert)
        #expect(rig.manager.locationRequests == 0)
    }

    @Test func sendNowAsksForAccessFirst() {
        let rig = make(enabled: true)
        rig.controller.sendCurrentLocation()
        #expect(rig.manager.whenInUseRequests == 1)
        rig.manager.authorizationStatus = .authorizedWhenInUse
        rig.controller.authorizationDidChange()
        #expect(rig.manager.locationRequests == 1)
    }

    // Issue #92: with no server that shares, "Send Location Now" asks iOS for nothing.
    @Test func sendNowWithNoSharingServerDoesNothing() {
        let rig = make()
        rig.controller.sendCurrentLocation()
        #expect(rig.manager.whenInUseRequests == 0)
        #expect(rig.manager.locationRequests == 0)
        #expect(rig.controller.manualSend == .idle)
    }

    @Test func promptShowsOnceAfterTheFirstConnect() {
        let suite = UserDefaults(suiteName: "loc-\(UUID().uuidString)")!
        let rig = make(defaults: suite)
        #expect(!rig.controller.wantsPrompt)
        rig.controller.didConnect(server: rig.serverID)
        #expect(rig.controller.wantsPrompt)
        rig.controller.closePrompt()
        #expect(!rig.controller.wantsPrompt)
        let again = make(defaults: suite)
        again.controller.didConnect(server: rig.serverID)
        #expect(!again.controller.wantsPrompt)
    }

    @Test func allowOnThePromptTurnsSharingOnAndAsks() {
        let rig = make()
        rig.controller.didConnect(server: rig.serverID)
        rig.controller.allowFromPrompt()
        #expect(!rig.controller.wantsPrompt)
        #expect(rig.controller.isEnabled)
        // Issue #92: only the connected server.
        #expect(rig.controller.isSharing(server: rig.serverID))
        #expect(!rig.controller.isSharing(server: rig.teamID))
        #expect(rig.manager.whenInUseRequests == 1)
    }

    @Test func promptDoesNotShowWhenAccessWasAlreadyAnswered() {
        let rig = make(.denied)
        rig.controller.didConnect(server: rig.serverID)
        #expect(!rig.controller.wantsPrompt)
    }

    @Test func reducedAccuracyIsReported() {
        let rig = make(.authorizedAlways)
        rig.manager.accuracyAuthorization = .reducedAccuracy
        rig.controller.authorizationDidChange()
        #expect(!rig.controller.isPreciseAllowed)
    }

    // MARK: Issue #51: fresh, accurate fixes

    @Test func appOpenRequestsANewFixAndSendsIt() async {
        let rig = make(.authorizedAlways, enabled: true)
        rig.controller.appDidBecomeActive()
        #expect(rig.manager.locationRequests == 1)
        rig.controller.received([fix()])
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.count == 1)
    }

    @Test func connectRequestsANewFixAndSendsItWithoutTheRateLimit() async {
        let rig = make(.authorizedAlways, enabled: true)
        // A coarse background fix went 10 s ago, so the rate limit holds the next nearby fix.
        rig.controller.received([fix(at: .now.addingTimeInterval(-10))])
        await rig.controller.waitForUploads()
        rig.controller.didConnect(server: rig.serverID)
        #expect(rig.manager.locationRequests == 1)
        rig.controller.received([fix(37.3350, at: .now)])
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.count == 2)
        // A later fix in the same place obeys the rate limit again.
        rig.controller.received([fix(37.3351, at: .now)])
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.count == 2)
    }

    // QA #53 risk 2: only a new, accurate fix answers the request. A cached or coarse update keeps the rate limit.

    @Test func aCachedUpdateOlderThanTheRequestDoesNotTakeTheFreshSlot() async {
        let rig = make(.authorizedAlways, enabled: true)
        rig.controller.received([fix(at: .now.addingTimeInterval(-10))])
        await rig.controller.waitForUploads()
        rig.controller.appDidBecomeActive()
        // `startUpdatingLocation` gives the cached location first.
        rig.controller.received([fix(37.3350, at: .now.addingTimeInterval(-60))])
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.count == 1)
        // The `requestLocation` answer still goes without the rate limit.
        rig.controller.received([fix(37.3351, at: .now)])
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.count == 2)
    }

    @Test func aCoarseUpdateDoesNotTakeTheFreshSlot() async {
        let rig = make(.authorizedAlways, enabled: true)
        rig.controller.received([fix(at: .now.addingTimeInterval(-10))])
        await rig.controller.waitForUploads()
        rig.controller.didConnect(server: rig.serverID)
        rig.controller.received([fix(37.3350, at: .now, accuracy: 101)])
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.count == 1)
        rig.controller.received([fix(37.3351, at: .now, accuracy: 100)])
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.count == 2)
    }

    @Test func openAndConnectRequestNothingWhenSharingIsOff() {
        let rig = make(.authorizedAlways)
        rig.controller.appDidBecomeActive()
        rig.controller.didConnect(server: rig.serverID)
        #expect(rig.manager.locationRequests == 0)
        #expect(!rig.manager.updatesLocation)
        let denied = make(.denied, enabled: true)
        denied.controller.appDidBecomeActive()
        denied.controller.didConnect(server: rig.serverID)
        #expect(denied.manager.locationRequests == 0)
        #expect(!denied.manager.updatesLocation)
    }

    @Test func aSavedFixOlderThanThirtyMinutesIsNotSentOnConnect() async {
        let old = fix(at: .now.addingTimeInterval(-86 * 60))
        let store = InMemoryLocationStateStore(LocationShareState(pending: old, lastError: "The server is not reachable."))
        let rig = make(.authorizedAlways, enabled: true, store: store)
        rig.controller.didConnect(server: rig.serverID)
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.isEmpty)
        #expect(rig.store.load().pending == nil)
        #expect(!rig.controller.status.waitingForConnection)
    }

    @Test func foregroundUsesFullAccuracyAndBackgroundOnlySignificantChangesAndVisits() {
        let rig = make(.authorizedAlways, enabled: true)
        // A launch in the background (by a location event) starts no continuous updates.
        #expect(!rig.manager.updatesLocation)
        #expect(rig.manager.monitorsSignificantChanges)
        #expect(rig.manager.monitorsVisits)

        rig.controller.appDidBecomeActive()
        #expect(rig.manager.updatesLocation)
        #expect(rig.manager.desiredAccuracy == kCLLocationAccuracyBest)
        #expect(rig.manager.distanceFilter == 50)
        #expect(rig.manager.monitorsSignificantChanges)
        #expect(rig.manager.monitorsVisits)

        rig.controller.appDidEnterBackground()
        #expect(!rig.manager.updatesLocation)
        #expect(rig.manager.monitorsSignificantChanges)
        #expect(rig.manager.monitorsVisits)
    }

    @Test func foregroundUpdatesFollowTheToggleAndAccess() {
        let rig = make(.authorizedAlways)
        rig.controller.appDidBecomeActive()
        #expect(!rig.manager.updatesLocation)
        rig.controller.setSharing(true, server: rig.serverID)
        #expect(rig.manager.updatesLocation)
        rig.manager.authorizationStatus = .denied
        rig.controller.authorizationDidChange()
        #expect(!rig.manager.updatesLocation)
        rig.manager.authorizationStatus = .authorizedWhenInUse
        rig.controller.authorizationDidChange()
        #expect(rig.manager.updatesLocation)
        rig.controller.setSharing(false, server: rig.serverID)
        #expect(!rig.manager.updatesLocation)
        #expect(!rig.manager.monitorsSignificantChanges)
    }

    @Test func accessTitlesMatchTheDesign() {
        #expect(LocationController.Access.always.title == "Always")
        #expect(LocationController.Access.whileUsing.title == "While Using")
        #expect(LocationController.Access.off.title == "Off")
        #expect(LocationController.Access.notDetermined.title == "Off")
    }

    // MARK: Issue #92: a setting for each server

    private func activate(_ rig: Rig, _ id: UUID) throws {
        var list = try rig.servers.load()
        list.activate(id: id)
        try rig.servers.save(list)
    }

    @Test func aSwitchToAServerWithSharingOffSendsItNoFix() async throws {
        let rig = make(.authorizedAlways, enabled: true)
        try activate(rig, rig.teamID)
        rig.controller.didConnect(server: rig.teamID)
        rig.controller.received([fix()])
        rig.controller.sendCurrentLocation()
        rig.controller.received([fix(at: t0.addingTimeInterval(10))])
        await rig.controller.waitForUploads()
        #expect(rig.teamUploader.payloads.isEmpty)
        #expect(rig.uploader.payloads.count == 2)
    }

    @Test func theMigratedServerKeepsSharingWithNoNewPrompt() {
        let suite = UserDefaults(suiteName: "loc-\(UUID().uuidString)")!
        suite.set(true, forKey: LocationController.promptShownKey)
        let rig = make(.authorizedAlways, enabled: true, defaults: suite)
        rig.controller.didConnect(server: rig.serverID)
        #expect(!rig.controller.wantsPrompt)
        #expect(rig.controller.isSharing(server: rig.serverID))
        #expect(!rig.controller.isSharing(server: rig.teamID))
        #expect(rig.manager.monitorsSignificantChanges)
        #expect(rig.manager.alwaysRequests == 0)
    }

    @Test func aNewServerStartsWithSharingOffAndCanTurnItOn() async {
        let rig = make(.authorizedAlways)
        #expect(!rig.controller.isSharing(server: rig.teamID))
        #expect(rig.controller.setSharing(true, server: rig.teamID))
        #expect(rig.controller.isEnabled)
        rig.controller.received([fix()])
        await rig.controller.waitForUploads()
        #expect(rig.teamUploader.payloads.count == 1)
        #expect(rig.uploader.payloads.isEmpty)
        #expect(rig.controller.status(server: rig.teamID).lastSentAt != nil)
        #expect(rig.controller.status(server: rig.serverID).lastSentAt == nil)
    }

    @Test func aGateWithNoLocationTurnsSharingOffWithNoLoop() async {
        let rig = make(.authorizedAlways)
        rig.teamUploader.failure = .connection(.gateError("location-off"))
        rig.controller.setSharing(true, server: rig.teamID)
        rig.controller.received([fix()])
        await rig.controller.waitForUploads()
        #expect(!rig.controller.isSharing(server: rig.teamID))
        #expect(!rig.controller.isEnabled)
        #expect(!rig.manager.monitorsSignificantChanges)
        #expect(rig.controller.status(server: rig.teamID).lastError == "This server does not accept location.")
        rig.controller.appDidBecomeActive()
        rig.controller.flush()
        rig.controller.received([fix(at: t0.addingTimeInterval(600))])
        await rig.controller.waitForUploads()
        #expect(rig.teamUploader.payloads.count == 1)
    }

    @Test func removeServerForgetsItsSetting() async throws {
        let rig = make(.authorizedAlways, enabled: true)
        var list = try rig.servers.load()
        list.remove(id: rig.serverID)
        try rig.servers.save(list)
        rig.controller.serverRemoved(rig.serverID)
        await rig.controller.waitForUploads()
        #expect(!rig.controller.isEnabled)
        #expect(!rig.manager.monitorsSignificantChanges)
        rig.controller.received([fix()])
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.isEmpty)
        #expect(rig.teamUploader.payloads.isEmpty)
    }

    @Test func sharedWithNamesTheServers() {
        #expect(LocationSettingsSection.sharedWithText([]) == "No Server")
        #expect(LocationSettingsSection.sharedWithText(["Home"]) == "Home")
        #expect(LocationSettingsSection.sharedWithText(["Home", "Lab"]) == "Home, Lab")
        #expect(LocationSettingsSection.sharedWithText(["A", "B", "C"]) == "3 Servers")
        let off = LocationShareStatus(lastError: "This server does not accept location.")
        #expect(ServerLocationSection.footer(isOn: false, status: off)
                == "This server does not get your location.\nLast error: This server does not accept location.")
        #expect(ServerLocationSection.footer(isOn: true, status: LocationShareStatus())
                == ServerLocationSection.onFooter)
    }

    @Test func lastSentText() {
        #expect(LocationController.lastSentText(LocationShareStatus(), now: t0) == "Never")
        #expect(LocationController.lastSentText(LocationShareStatus(lastSentAt: t0), now: t0.addingTimeInterval(20)) == "Just now")
        let text = LocationController.lastSentText(LocationShareStatus(lastSentAt: t0), now: t0.addingTimeInterval(300))
        #expect(text.contains("5"))
        #expect(text.contains("ago"))
    }

    @Test func coreLocationValuesBecomeAFix() throws {
        let location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2), altitude: 0,
                                  horizontalAccuracy: 8, verticalAccuracy: 1, course: -1, speed: -1, timestamp: t0)
        let value = try #require(LocationFix(location: location))
        #expect(value.latitude == 1)
        #expect(value.speed == nil)
        #expect(value.course == nil)
        let invalid = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2), altitude: 0,
                                 horizontalAccuracy: -1, verticalAccuracy: 1, timestamp: t0)
        #expect(LocationFix(location: invalid) == nil)
    }

    @Test func infoPlistHasBothLocationStrings() throws {
        let info = Bundle(for: PreviewLocationManager.self).infoDictionary ?? [:]
        let whenInUse = try #require(info["NSLocationWhenInUseUsageDescription"] as? String)
        let always = try #require(info["NSLocationAlwaysAndWhenInUseUsageDescription"] as? String)
        #expect(whenInUse == "Hermes sends your location to your own Hermes server so that your agent can answer location questions.")
        #expect(always == "Hermes sends your location in the background, when you move a long distance or arrive at a place.")
        // Significant-change and visit monitoring do not need the continuous background location mode.
        #expect((info["UIBackgroundModes"] as? [String])?.contains("location") != true)
    }
}
