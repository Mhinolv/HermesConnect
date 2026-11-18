import AVFoundation
import HermesKit
import Observation
import UIKit

/// Issue #98: the app side of the GPT-Live engine. It has no views, so the #101 Voice tab can use it as is.
///
/// - The status gate: Live can start only when `voice-live/status` says `available: true`.
/// - The microphone check before a session.
/// - The app end rules: background and a phone call (audio interruption) end the session.
/// - `LiveModeController` (HermesKit) does the rest: WebRTC, SDP, delegations, commentary, idle and reconnect.
@MainActor @Observable
final class LiveModeSessionModel {
    let controller: LiveModeController
    /// The last status of this server. `nil` until the first check, or when the check failed.
    private(set) var status: LiveModeStatus?
    private(set) var isCheckingStatus = false
    /// The owner refused the microphone. The view shows "Microphone Access Off".
    var microphoneDenied = false

    @ObservationIgnored private let service: any LiveModeService
    @ObservationIgnored private let requestsMicrophone: () async -> Bool
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(hermes: any LiveModeHermes, service: any LiveModeService,
         makeConnection: @escaping @MainActor () -> any LiveModeConnection = { WebRTCLiveConnection() },
         requestsMicrophone: @escaping () async -> Bool = { await AVAudioApplication.requestRecordPermission() },
         autoTick: Bool = true) {
        self.service = service
        self.requestsMicrophone = requestsMicrophone
        controller = LiveModeController(service: service, hermes: hermes, makeConnection: makeConnection,
                                        autoTick: autoTick)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(.background) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated { if began { self?.end(.phoneCall) } }
        })
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        controller.end(.hangUp)
    }

    var isAvailable: Bool { status?.available == true }

    /// "About $0.05 a minute", or why Live is not available.
    var availabilityText: String {
        if isCheckingStatus, status == nil { return "Checking…" }
        guard let status else { return "Not connected" }
        return status.available ? LiveModeFormat.costCaption : status.unavailableText
    }

    func refreshStatus() async {
        isCheckingStatus = true
        defer { isCheckingStatus = false }
        do {
            status = try await service.liveModeStatus()
        } catch {
            status = nil
        }
    }

    /// Starts a session after the status gate and the microphone check. "Try Again" calls it too.
    func start() async {
        guard !controller.isActive || controller.phase == .failed else { return }
        await refreshStatus()
        guard isAvailable else { return }
        guard await requestsMicrophone() else {
            microphoneDenied = true
            return
        }
        controller.start()
    }

    /// Ends the session at once. In the background, the app stays awake for the close message to go out.
    func end(_ reason: LiveModeEndReason) {
        guard controller.isActive else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "live-mode-end")
        controller.end(reason)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}
