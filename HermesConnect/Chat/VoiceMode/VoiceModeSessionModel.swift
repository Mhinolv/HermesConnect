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
    init(speech: any VoiceStreamTransport, microphone: AVVoiceModeMicrophone = AVVoiceModeMicrophone()) {
        let player = microphone.player
        controller = VoiceModeController(
            microphone: microphone, player: player,
            makeSpeech: { try await speech.makeStreamedSpeech(player: $0) },
            makeClipURL: { VoiceMemoFiles.newFile(in: VoiceMemoFiles.directory()) })
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
@MainActor
final class AVVoiceModeMicrophone: VoiceModeMicrophone {
    /// The reply player. It stops with the session.
    let player = AVAudioEnginePCMPlayer()
    private var recorder: AVAudioRecorder?

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
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        try session.setActive(true)
    }

    func deactivate() {
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
