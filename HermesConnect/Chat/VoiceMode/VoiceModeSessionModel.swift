import AVFoundation
import HermesKit
import Observation
import UIKit

/// Issue #96: the app side of the voice mode engine. It has no views, so the #101 Voice tab can use it as is.
///
/// - The real microphone and audio session (`AVVoiceModeMicrophone`) and the real player (`AVAudioEnginePCMPlayer`).
/// - The pause rules: a call (audio interruption), background and Lock pause the loop and close the mic.
/// - `VoiceModeController` (HermesKit) does the rest: silence rules, transcript, voice turn, `speak-stream`, barge-in.
@MainActor @Observable
final class VoiceModeSessionModel {
    let controller: VoiceModeController
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// `speech` is the transport of the active server (`LiveChatTransport`).
    /// Issue #101: `tuning` turns off speech barge-in while VoiceOver runs.
    convenience init(speech: any VoiceStreamTransport, microphone: AVVoiceModeMicrophone = AVVoiceModeMicrophone(),
                     tuning: VoiceModeTuning = VoiceModeTuning()) {
        // Issue #127: each reply checks the output route before it plays.
        let player = microphone.replyPlayer
        self.init(controller: VoiceModeController(
            microphone: microphone, player: player,
            makeSpeech: { try await speech.makeStreamedSpeech(player: $0) },
            makeClipURL: { VoiceMemoFiles.newFile(in: VoiceMemoFiles.directory()) },
            tuning: tuning))
    }

    /// Issue #101: tests give an engine with a fake microphone. The pause rules are the same.
    init(controller: VoiceModeController) {
        self.controller = controller
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated { if began { self?.controller.pause(.call) } }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.pause(.background) }
        })
        observers.append(center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.pause(.lock) }
        })
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        controller.end()
    }

    /// Starts the loop in `chat`: the active chat, a new chat or a chat that the owner picks.
    func start(in chat: ChatViewModel) async {
        await controller.start(chat: chat)
    }
}

/// The microphone of voice mode: `AVAudioRecorder` with the memo settings of #9 (`AVVoiceRecorder.settings`).
/// The audio session stays active for the whole loop: `.playAndRecord` with `.voiceChat`, so the echo of
/// the reply is lower for barge-in. Bluetooth and the speaker work. Other audio ducks.
/// Issue #127: `VoiceAudioRoute` keeps a receiver-only route on the speaker and writes the route diagnostics.
@MainActor
final class AVVoiceModeMicrophone: VoiceModeMicrophone {
    /// The reply player. It stops with the session.
    let player = AVAudioEnginePCMPlayer()
    let route = VoiceAudioRoute(session: SystemVoiceAudioSession())
    /// `player` with the route check before each reply.
    private(set) lazy var replyPlayer: any StreamedSpeechPlaying = VoiceRoutePlayer(base: player) { [route] in
        route.beforeReply()
    }
    private var recorder: AVAudioRecorder?
    private var routeObserver: NSObjectProtocol?

    struct StartFailed: Error {}

    var access: VoiceModeMicrophoneAccess {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    func requestAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func activate() throws {
        try route.activate()
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [route] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            route.routeChanged(reason: reason.map(SystemVoiceAudioSession.name) ?? "unknown")
        }
    }

    func deactivate() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        discardClip()
        player.shutdown()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func startClip(url: URL) throws {
        recorder?.stop()
        let recorder = try AVAudioRecorder(url: url, settings: AVVoiceRecorder.settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            recorder.deleteRecording()
            throw StartFailed()
        }
        self.recorder = recorder
    }

    func stopClip() -> TimeInterval {
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        return duration
    }

    func discardClip() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
    }

    func level() -> Float {
        guard let recorder, recorder.isRecording else { return VoiceWaveform.floorDecibels }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }
}

/// Issue #127: `AVAudioSession.sharedInstance()` for `VoiceAudioRoute`. It keeps no state.
final class SystemVoiceAudioSession: VoiceAudioSession {
    var routeState: VoiceAudioRouteState {
        let session = AVAudioSession.sharedInstance()
        return VoiceAudioRouteState(outputs: session.currentRoute.outputs.map(\.portType.rawValue),
                                    category: session.category.rawValue, mode: session.mode.rawValue,
                                    options: Self.names(session.categoryOptions), volume: session.outputVolume)
    }

    func setVoiceCategory(mode: VoiceAudioMode) throws {
        let sessionMode: AVAudioSession.Mode = switch mode {
        case .voiceChat: .voiceChat
        case .videoChat: .videoChat
        case .default: .default
        }
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: sessionMode,
                                                        options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
    }

    func setActive(_ active: Bool) throws {
        try AVAudioSession.sharedInstance().setActive(active)
    }

    func overrideOutputToSpeaker() throws {
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
    }

    static func names(_ options: AVAudioSession.CategoryOptions) -> [String] {
        let known: [(AVAudioSession.CategoryOptions, String)] = [
            (.mixWithOthers, "mixWithOthers"), (.duckOthers, "duckOthers"),
            (.allowBluetoothHFP, "allowBluetoothHFP"), (.defaultToSpeaker, "defaultToSpeaker"),
            (.interruptSpokenAudioAndMixWithOthers, "interruptSpokenAudio"),
            (.allowBluetoothA2DP, "allowBluetoothA2DP"), (.allowAirPlay, "allowAirPlay"),
        ]
        return known.filter { options.contains($0.0) }.map(\.1)
    }

    static func name(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
        case .routeConfigurationChange: "routeConfigurationChange"
        case .unknown: "unknown"
        @unknown default: "other\(reason.rawValue)"
        }
    }
}
