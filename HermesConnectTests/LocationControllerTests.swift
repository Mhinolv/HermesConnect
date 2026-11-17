import CoreLocation
import Foundation
import HermesKit
import Testing
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
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func fix(_ lat: Double = 37.3349, at time: Date = t0) -> LocationFix {
    LocationFix(latitude: lat, longitude: -122.009, horizontalAccuracy: 10, timestamp: time)!
}

@MainActor
@Suite struct LocationControllerTests {
    private struct Rig {
        let controller: LocationController
        let manager: FakeLocationManager
        let uploader: ScriptedLocationUploader
        let store: InMemoryLocationStateStore
        let defaults: UserDefaults
    }

    private func make(_ status: CLAuthorizationStatus = .notDetermined, enabled: Bool = false,
                      failure: LocationUploadError? = nil, defaults: UserDefaults? = nil,
                      store: InMemoryLocationStateStore = InMemoryLocationStateStore()) -> Rig {
        let suite = defaults ?? UserDefaults(suiteName: "loc-\(UUID().uuidString)")!
        if enabled { suite.set(true, forKey: LocationController.enabledKey) }
        let manager = FakeLocationManager(status)
        let uploader = ScriptedLocationUploader(failure: failure)
        let sharing = LocationSharing(store: store, uploader: uploader)
        let controller = LocationController(manager: manager, sharing: sharing, defaults: suite)
        return Rig(controller: controller, manager: manager, uploader: uploader, store: store, defaults: suite)
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
        rig.controller.setEnabled(true)
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
        rig.controller.setEnabled(true)
        #expect(rig.controller.showsAccessOffAlert)
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
        rig.controller.didConnect()
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.count == 2)
        #expect(!rig.controller.status.waitingForConnection)
        #expect(rig.controller.status.lastError == nil)
    }

    @Test func turnOffDropsTheWaitingFixAndStopsMonitoring() async {
        let rig = make(.authorizedAlways, enabled: true, failure: .timedOut)
        rig.controller.received([fix()])
        await rig.controller.waitForUploads()
        rig.controller.setEnabled(false)
        await rig.controller.waitForUploads()
        #expect(rig.store.load().pending == nil)
        #expect(!rig.manager.monitorsSignificantChanges)
        #expect(rig.defaults.bool(forKey: LocationController.enabledKey) == false)
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
        let rig = make(.authorizedWhenInUse)
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
        // With sharing off, a later fix is not sent.
        rig.controller.received([fix(at: t0.addingTimeInterval(20))])
        await rig.controller.waitForUploads()
        #expect(rig.uploader.payloads.count == 2)
    }

    @Test func sendNowFailureShowsNotDelivered() async {
        let rig = make(.authorizedAlways, failure: .connection(.unreachable))
        rig.controller.sendCurrentLocation()
        rig.controller.received([fix()])
        await rig.controller.waitForUploads()
        #expect(rig.controller.manualSend == .notDelivered)
        let other = make(.authorizedAlways)
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
        let rig = make()
        rig.controller.sendCurrentLocation()
        #expect(rig.manager.whenInUseRequests == 1)
        rig.manager.authorizationStatus = .authorizedWhenInUse
        rig.controller.authorizationDidChange()
        #expect(rig.manager.locationRequests == 1)
        // The owner did not turn on automatic sharing, so the app does not ask for Always.
        #expect(rig.manager.alwaysRequests == 0)
    }

    @Test func promptShowsOnceAfterTheFirstConnect() {
        let suite = UserDefaults(suiteName: "loc-\(UUID().uuidString)")!
        let rig = make(defaults: suite)
        #expect(!rig.controller.wantsPrompt)
        rig.controller.didConnect()
        #expect(rig.controller.wantsPrompt)
        rig.controller.closePrompt()
        #expect(!rig.controller.wantsPrompt)
        let again = make(defaults: suite)
        again.controller.didConnect()
        #expect(!again.controller.wantsPrompt)
    }

    @Test func allowOnThePromptTurnsSharingOnAndAsks() {
        let rig = make()
        rig.controller.didConnect()
        rig.controller.allowFromPrompt()
        #expect(!rig.controller.wantsPrompt)
        #expect(rig.controller.isEnabled)
        #expect(rig.manager.whenInUseRequests == 1)
    }

    @Test func promptDoesNotShowWhenAccessWasAlreadyAnswered() {
        let rig = make(.denied)
        rig.controller.didConnect()
        #expect(!rig.controller.wantsPrompt)
    }

    @Test func reducedAccuracyIsReported() {
        let rig = make(.authorizedAlways)
        rig.manager.accuracyAuthorization = .reducedAccuracy
        rig.controller.authorizationDidChange()
        #expect(!rig.controller.isPreciseAllowed)
    }

    @Test func accessTitlesMatchTheDesign() {
        #expect(LocationController.Access.always.title == "Always")
        #expect(LocationController.Access.whileUsing.title == "While Using")
        #expect(LocationController.Access.off.title == "Off")
        #expect(LocationController.Access.notDetermined.title == "Off")
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
