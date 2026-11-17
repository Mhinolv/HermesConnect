import CoreLocation
import Foundation
import HermesKit
import Observation
import UIKit

/// The calls that `LocationController` makes on Core Location. `CLLocationManager` is the real one. Tests use a fake.
@MainActor
protocol LocationManaging: AnyObject {
    var delegate: (any CLLocationManagerDelegate)? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var accuracyAuthorization: CLAccuracyAuthorization { get }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }
    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    func startMonitoringSignificantLocationChanges()
    func stopMonitoringSignificantLocationChanges()
    func startMonitoringVisits()
    func stopMonitoringVisits()
    func requestLocation()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

extension CLLocationManager: LocationManaging {}

/// Starts and ends an iOS background task around one upload, so that the upload can finish in the background.
struct BackgroundTasks {
    /// Start a task. iOS calls `onExpire` on the main thread if the time runs out first.
    /// `onExpire` must end the task before it returns, or iOS ends the app.
    var begin: @MainActor (_ onExpire: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    var end: @MainActor (UIBackgroundTaskIdentifier) -> Void

    static let live = BackgroundTasks(
        begin: { onExpire in
            UIApplication.shared.beginBackgroundTask(withName: "location-upload") {
                MainActor.assumeIsolated { onExpire() }
            }
        },
        end: { if $0 != .invalid { UIApplication.shared.endBackgroundTask($0) } }
    )
    static let none = BackgroundTasks(begin: { _ in .invalid }, end: { _ in })
}

/// Automatic location sharing (issue #13, research.md D4).
///
/// When sharing is on and iOS gives access, Core Location reports significant location changes and visits.
/// These also wake the app after iOS ended it. Each fix goes to `LocationSharing`, which sends it through the
/// gate `location` command. The controller never logs a fix.
///
/// Issue #51: in the foreground, full-accuracy updates also run (`kCLLocationAccuracyBest`, every 50 m).
/// App open and connect each request one new fix, which goes without the rate limit. The background uses only
/// significant changes and visits (battery). The app has no `location` background mode.
@MainActor @Observable
final class LocationController: NSObject {
    /// The access that iOS gives. Settings > Location > Access.
    enum Access: Equatable {
        case notDetermined
        case off
        case whileUsing
        case always

        var title: String {
            switch self {
            case .notDetermined, .off: "Off"
            case .whileUsing: "While Using"
            case .always: "Always"
            }
        }

        var allowsUpdates: Bool { self == .whileUsing || self == .always }

        init(_ status: CLAuthorizationStatus) {
            switch status {
            case .authorizedAlways: self = .always
            case .authorizedWhenInUse: self = .whileUsing
            case .notDetermined: self = .notDetermined
            default: self = .off
            }
        }
    }

    /// The state of a "Send Location Now" tap.
    enum ManualSend: Equatable {
        case idle
        case sending
        case sent
        case notDelivered
    }

    private(set) var access: Access
    /// False when the owner turned off Precise Location for Hermes in iOS Settings.
    private(set) var isPreciseAllowed: Bool
    /// Settings > Location > "Share Location Automatically". Off until the owner turns it on.
    private(set) var isEnabled: Bool
    private(set) var precision: LocationPrecision
    private(set) var status = LocationShareStatus()
    private(set) var manualSend: ManualSend = .idle
    /// True while the "Location Access Off" alert shows.
    var showsAccessOffAlert = false
    /// True when the "Share Your Location" sheet should show (after the first successful connect).
    private(set) var wantsPrompt = false

    @ObservationIgnored private let manager: any LocationManaging
    @ObservationIgnored private let sharing: LocationSharing
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let background: BackgroundTasks
    /// The owner tapped "Send Location Now". The next fix goes at once, without the rate limit.
    @ObservationIgnored private var oneShotPending = false
    /// When the app asked for a new fix on open or on connect. The first fix that answers it goes without the
    /// rate limit (`answersFreshRequest`). Nil when no request waits.
    @ObservationIgnored private var freshRequestedAt: Date?
    /// True while the app is active. A launch in the background (by a location event) starts as false.
    @ObservationIgnored private var isForeground = false
    /// The uploads that run now. Tests wait for them.
    @ObservationIgnored private var uploads: [UUID: Task<Void, Never>] = [:]
    /// The iOS background task of each upload. An entry is removed when the task ends, so it ends only once.
    @ObservationIgnored private var backgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]

    static let enabledKey = "locationSharingEnabled"
    static let precisionKey = "locationPrecision"
    static let promptShownKey = "locationPromptShown"
    static let alwaysAskedKey = "locationAlwaysAsked"
    /// The distance filter of the foreground updates, in meters.
    static let foregroundDistanceFilter: CLLocationDistance = 50
    /// A fix less accurate than this does not answer a fresh request (QA #53 risk 2).
    static let freshFixAccuracy: CLLocationAccuracy = 100
    /// A fresh request ends after this time. Then the rate limit applies again.
    static let freshRequestWindow: TimeInterval = 120

    init(manager: any LocationManaging, sharing: LocationSharing, defaults: UserDefaults = .standard,
         background: BackgroundTasks = .none) {
        self.manager = manager
        self.sharing = sharing
        self.defaults = defaults
        self.background = background
        access = Access(manager.authorizationStatus)
        isPreciseAllowed = manager.accuracyAuthorization == .fullAccuracy
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        precision = defaults.string(forKey: Self.precisionKey).flatMap(LocationPrecision.init(rawValue:)) ?? .precise
        super.init()
        manager.delegate = self
        // `requestLocation` and the foreground updates use this. Significant changes and visits do not.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = Self.foregroundDistanceFilter
        // After a relaunch in the background, monitoring must start again to get the event that woke the app.
        updateMonitoring()
        Task { await refreshStatus() }
    }

    /// The app on a device. Each upload loads the saved profile and the device key, so it also works after a
    /// relaunch in the background. It opens its own SSH connection with the pinned host key.
    static func live() -> LocationController {
        let profiles = try? FileServerProfileStore.applicationSupport()
        let keys = KeychainDeviceKeyStore.system()
        let uploader = GateLocationUploader(connector: HostConnector(transport: CitadelSSHTransport())) {
            guard let profile = try? profiles?.load(), let key = try? keys.loadKey() else { return nil }
            return LocationCredentials(profile: profile, key: key)
        }
        let store: any LocationStateStore = (try? FileLocationStateStore.applicationSupport()) ?? InMemoryLocationStateStore()
        return LocationController(manager: CLLocationManager(), sharing: LocationSharing(store: store, uploader: uploader),
                                  background: .live)
    }

    // MARK: Owner actions

    /// The "Share Location Automatically" toggle.
    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            updateMonitoring()
            run { sharing, _ in await sharing.discardPending() }
            return
        }
        if access == .off {
            showsAccessOffAlert = true
            return
        }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        if access == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        updateMonitoring()
        askForAlwaysIfNeeded()
    }

    func setPrecision(_ precision: LocationPrecision) {
        self.precision = precision
        defaults.set(precision.rawValue, forKey: Self.precisionKey)
    }

    /// "Allow Location Access" on the "Share Your Location" sheet.
    func allowFromPrompt() {
        closePrompt()
        setEnabled(true)
    }

    /// "Not Now" on the sheet, or a swipe down. The sheet does not show again.
    func closePrompt() {
        wantsPrompt = false
        defaults.set(true, forKey: Self.promptShownKey)
    }

    /// The app connected to Hermes. The first time, ask the owner about location. Then request a new fix and
    /// send the waiting fix.
    func didConnect() {
        if !defaults.bool(forKey: Self.promptShownKey), access == .notDetermined, !isEnabled {
            wantsPrompt = true
        }
        requestFreshFix()
        flush()
    }

    /// The app is active: start the full-accuracy updates, request a new fix, and send the waiting fix.
    func appDidBecomeActive() {
        isForeground = true
        updateMonitoring()
        requestFreshFix()
        flush()
    }

    /// The app is in the background: only significant changes and visits run.
    func appDidEnterBackground() {
        isForeground = false
        updateMonitoring()
    }

    /// Send the waiting fix, if the rate limit allows it. `LocationSharing` drops a fix older than 30 min.
    func flush() {
        run { sharing, precision in _ = await sharing.flush(precision: precision) }
    }

    /// "Send Location Now": get one fix and send it once, without the rate limit.
    func sendCurrentLocation() {
        switch access {
        case .off:
            showsAccessOffAlert = true
        case .notDetermined:
            oneShotPending = true
            manualSend = .sending
            manager.requestWhenInUseAuthorization()
        case .whileUsing, .always:
            oneShotPending = true
            manualSend = .sending
            manager.requestLocation()
        }
    }

    // MARK: Core Location events (the delegate calls these, tests call them directly)

    func authorizationDidChange() {
        access = Access(manager.authorizationStatus)
        isPreciseAllowed = manager.accuracyAuthorization == .fullAccuracy
        updateMonitoring()
        askForAlwaysIfNeeded()
        if oneShotPending {
            switch access {
            case .whileUsing, .always: manager.requestLocation()
            case .off:
                oneShotPending = false
                manualSend = .idle
                showsAccessOffAlert = true
            case .notDetermined: break
            }
        }
    }

    func received(_ fixes: [LocationFix]) {
        guard let latest = fixes.max(by: { $0.timestamp < $1.timestamp }) else { return }
        let fresh = answersFreshRequest(latest)
        if fresh || oneShotPending { freshRequestedAt = nil }
        if oneShotPending {
            oneShotPending = false
            run { [weak self] sharing, precision in
                let result = await sharing.submit(latest, precision: precision, force: true)
                self?.manualSend = result == .sent ? .sent : .notDelivered
            }
        } else if isEnabled {
            run { sharing, precision in _ = await sharing.submit(latest, precision: precision, force: fresh) }
        }
    }

    /// Core Location could not get a fix. Only a "Send Location Now" tap shows it.
    func locationFailed() {
        guard oneShotPending else { return }
        oneShotPending = false
        manualSend = .notDelivered
    }

    // MARK: Private

    private var monitors: Bool { isEnabled && access.allowsUpdates }

    private func updateMonitoring() {
        if monitors {
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()
        }
        if monitors, isForeground {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
    }

    /// Ask Core Location for one new full-accuracy fix (issue #51). Only when automatic sharing is on.
    private func requestFreshFix() {
        guard monitors else { return }
        freshRequestedAt = Date()
        manager.requestLocation()
    }

    /// True if `fix` answers the waiting fresh request. A cached update from `startUpdatingLocation` (older than
    /// the request) or a coarse fix does not, so the accurate `requestLocation` answer still skips the rate limit.
    private func answersFreshRequest(_ fix: LocationFix) -> Bool {
        guard let requestedAt = freshRequestedAt else { return false }
        if Date().timeIntervalSince(requestedAt) > Self.freshRequestWindow {
            freshRequestedAt = nil
            return false
        }
        return fix.timestamp >= requestedAt && fix.horizontalAccuracy <= Self.freshFixAccuracy
    }

    /// iOS shows the "Always" question once. Ask after the owner gave "While Using".
    private func askForAlwaysIfNeeded() {
        guard isEnabled, access == .whileUsing, !defaults.bool(forKey: Self.alwaysAskedKey) else { return }
        defaults.set(true, forKey: Self.alwaysAskedKey)
        manager.requestAlwaysAuthorization()
    }

    /// Run one upload step inside an iOS background task, then update the status for Settings.
    ///
    /// If iOS ends the background time first, the expiration handler cancels the upload (the SSH connection
    /// closes) and ends the task at once. `LocationSharing` keeps the fix as unsent, so the next connect sends it.
    private func run(_ work: @escaping @MainActor (LocationSharing, LocationPrecision) async -> Void) {
        let sharing = sharing
        let precision = precision
        let id = UUID()
        backgroundTasks[id] = background.begin { [weak self] in self?.expire(id) }
        // The task runs on the main actor, so it starts after `uploads[id]` is set.
        uploads[id] = Task { [weak self] in
            await work(sharing, precision)
            await self?.refreshStatus()
            self?.endBackgroundTask(id)
            self?.uploads[id] = nil
        }
    }

    /// The iOS expiration handler: cancel the upload and end the background task now.
    private func expire(_ id: UUID) {
        uploads[id]?.cancel()
        endBackgroundTask(id)
    }

    private func endBackgroundTask(_ id: UUID) {
        guard let task = backgroundTasks.removeValue(forKey: id) else { return }
        background.end(task)
    }

    private func refreshStatus() async {
        status = await sharing.status
    }

    /// Wait for the uploads that run now. For tests.
    func waitForUploads() async {
        while let upload = uploads.values.first {
            await upload.value
        }
    }
}

extension LocationController: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { authorizationDidChange() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.compactMap(LocationFix.init(location:))
        MainActor.assumeIsolated { received(fixes) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let fix = LocationFix(visitLatitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude,
                              horizontalAccuracy: visit.horizontalAccuracy, arrival: visit.arrivalDate,
                              departure: visit.departureDate, now: Date())
        MainActor.assumeIsolated { received(fix.map { [$0] } ?? []) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated { locationFailed() }
    }
}

extension LocationFix {
    /// A fix from Core Location. A negative accuracy means that the location is not valid.
    init?(location: CLLocation) {
        self.init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                  horizontalAccuracy: location.horizontalAccuracy, timestamp: location.timestamp,
                  speed: location.speed, course: location.course)
    }
}

extension LocationController {
    /// "Last Sent" in Settings: "Waiting for connection", a relative time, or "Never".
    static func lastSentText(_ status: LocationShareStatus, now: Date) -> String {
        if status.waitingForConnection { return "Waiting for connection" }
        guard let sent = status.lastSentAt else { return "Never" }
        if now.timeIntervalSince(sent) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: sent, relativeTo: now)
    }

    /// A controller with a fake location manager and fake uploads, for previews and screenshots.
    static func preview(access: CLAuthorizationStatus = .authorizedAlways, precise: Bool = true, enabled: Bool = true,
                        state: LocationShareState = LocationShareState()) -> LocationController {
        let defaults = UserDefaults(suiteName: "preview-location") ?? .standard
        defaults.removePersistentDomain(forName: "preview-location")
        defaults.set(enabled, forKey: enabledKey)
        let manager = PreviewLocationManager(status: access, accuracy: precise ? .fullAccuracy : .reducedAccuracy)
        let sharing = LocationSharing(store: InMemoryLocationStateStore(state), uploader: ScriptedLocationUploader())
        return LocationController(manager: manager, sharing: sharing, defaults: defaults)
    }

    /// Show the "Share Your Location" sheet, for previews and screenshots.
    func previewPrompt() { wantsPrompt = true }

    /// Set the state of a "Send Location Now" tap, for previews and screenshots.
    func previewManualSend(_ state: ManualSend) { manualSend = state }
}

/// A location manager that does nothing, for previews.
final class PreviewLocationManager: LocationManaging {
    weak var delegate: (any CLLocationManagerDelegate)?
    var authorizationStatus: CLAuthorizationStatus
    var accuracyAuthorization: CLAccuracyAuthorization

    init(status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization) {
        authorizationStatus = status
        accuracyAuthorization = accuracy
    }

    func requestWhenInUseAuthorization() {}
    func requestAlwaysAuthorization() {}
    func startMonitoringSignificantLocationChanges() {}
    func stopMonitoringSignificantLocationChanges() {}
    func startMonitoringVisits() {}
    func stopMonitoringVisits() {}
    func requestLocation() {}
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
    var distanceFilter: CLLocationDistance = kCLDistanceFilterNone
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
}
