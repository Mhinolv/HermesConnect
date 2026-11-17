import AVFoundation
import HermesKit
import UIKit

/// The system microphone permission.
enum MicrophoneAccess: Equatable {
    case granted
    case denied
    case undetermined
}

/// Records one clip at a time. `AVVoiceRecorder` is the device recorder. Tests and the DEBUG demo use fakes.
@MainActor
protocol VoiceRecording: AnyObject {
    var access: MicrophoneAccess { get }
    /// Shows the system permission prompt. Returns `true` when the owner allows the microphone.
    func requestAccess() async -> Bool
    /// Starts a new clip in `url`.
    func start(url: URL) throws
    /// Stops the recording and keeps the clip open, so `stop()` can still finish it.
    func pause()
    /// Finishes the clip. Returns its length in seconds.
    func stop() -> TimeInterval
    /// Stops the recording and deletes the clip.
    func discard()
    /// The length of the clip so far.
    var currentTime: TimeInterval { get }
    /// The last meter reading in dBFS.
    func level() -> Float
    /// A phone call, Siri or the background stopped the recording.
    var onInterruption: (() -> Void)? { get set }
}

/// `AVAudioRecorder`: AAC in `.m4a`, mono, 22.05 kHz (docs/hermes-protocol.md 3.9 step 1).
/// The audio session is `.playAndRecord`, so a car or headset microphone works too.
@MainActor
final class AVVoiceRecorder: VoiceRecording {
    struct StartFailed: Error {}

    private var recorder: AVAudioRecorder?
    private var observers: [any NSObjectProtocol] = []
    var onInterruption: (() -> Void)?

    static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 22_050,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    var access: MicrophoneAccess {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    func requestAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            recorder.deleteRecording()
            deactivate()
            throw StartFailed()
        }
        self.recorder = recorder
        observe()
    }

    func pause() {
        recorder?.pause()
    }

    func stop() -> TimeInterval {
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        finish()
        return duration
    }

    func discard() {
        recorder?.stop()
        recorder?.deleteRecording()
        finish()
    }

    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }

    func level() -> Float {
        guard let recorder, recorder.isRecording else { return VoiceWaveform.floorDecibels }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }

    private func finish() {
        recorder = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        deactivate()
    }

    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observe() {
        let center = NotificationCenter.default
        let interrupted: @Sendable (Notification) -> Void = { [weak self] note in
            let began = note.name == UIApplication.didEnterBackgroundNotification
                || (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            guard began else { return }
            MainActor.assumeIsolated { self?.onInterruption?() }
        }
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main,
                               using: interrupted),
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main,
                               using: interrupted),
        ]
    }
}

/// The folder of the memo files: Application Support/VoiceMemos. The files stay until the owner deletes the memo.
/// `ProtectedStorage` rules (issue #18): `completeUntilFirstUserAuthentication`, and no backup.
enum VoiceMemoFiles {
    static func directory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("VoiceMemos", isDirectory: true)
        try? ProtectedStorage.prepare(directory: folder)
        return folder
    }

    static func newFile(in folder: URL) -> URL {
        folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
    }
}

// MARK: - Recording flow

/// One haptic of the recording flow (issue #9 design notes).
enum VoiceHaptic: Equatable {
    /// `.impact(.medium)` when the recording starts.
    case start
    /// `.success` when the memo is sent.
    case sent
    /// `.warning` at 9:30.
    case warning
    /// `.impact(.light)` when the owner cancels.
    case cancelled
}

/// Connects the mic button, the recorder and the chat (issue #9). The rules are in `VoiceMemoCapture`.
@MainActor
final class VoiceMemoController {
    private(set) var capture = VoiceMemoCapture()
    /// Meter levels from 0 to 1, about 20 per second. The bar draws the last ones.
    private(set) var levels: [Float] = []
    private(set) var elapsed: TimeInterval = 0

    let recorder: any VoiceRecording
    private let folder: URL
    private let clock: () -> TimeInterval
    private var fileURL: URL?
    private var timer: Timer?

    /// The bar state changed.
    var onChange: (() -> Void)?
    /// A memo is ready to send.
    var onSend: ((VoiceMemo) -> Void)?
    /// The microphone is off in Settings.
    var onAccessDenied: (() -> Void)?
    /// The recorder did not start.
    var onRecordFailed: (() -> Void)?
    var onHaptic: @MainActor (VoiceHaptic) -> Void = { VoiceMemoController.playHaptic($0) }
    var onAnnounce: @MainActor (String) -> Void = { UIAccessibility.post(notification: .announcement, argument: $0) }
    var isVoiceOverRunning: @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning }

    init(recorder: any VoiceRecording, folder: URL = VoiceMemoFiles.directory(),
         clock: @escaping () -> TimeInterval = { CACurrentMediaTime() }) {
        self.recorder = recorder
        self.folder = folder
        self.clock = clock
        self.recorder.onInterruption = { [weak self] in self?.interrupt() }
    }

    var isActive: Bool { capture.isActive }

    // MARK: Input

    /// The finger touched the mic. Returns `true` when the recording started.
    @discardableResult
    func press() -> Bool {
        guard !capture.isActive, canRecord() else { return false }
        guard begin() else { return false }
        capture.press(at: clock())
        changed()
        return true
    }

    /// Hands-free recording with no hold (VoiceOver, design notes).
    @discardableResult
    func startTapMode() -> Bool {
        guard !capture.isActive, canRecord() else { return false }
        guard begin() else { return false }
        capture.startTapMode()
        changed()
        return true
    }

    func drag(dx: Double) {
        let action = capture.drag(dx: dx)
        handle(action)
        if action == nil { changed() }
    }

    func release() {
        handle(capture.release(at: clock()))
    }

    func touchCancelled() {
        handle(capture.touchCancelled())
    }

    func send() {
        handle(capture.send())
    }

    func cancel() {
        handle(capture.cancel())
    }

    func interrupt() {
        handle(capture.interrupt())
    }

    /// One timer step: read the meter and the clip length, then apply the time rules. Tests call it.
    func tick() {
        guard capture.isActive else { return }
        if capture.phase != .paused {
            elapsed = recorder.currentTime
            levels.append(VoiceWaveform.level(decibels: recorder.level()))
        }
        for action in capture.tick(now: clock(), recorded: elapsed, voiceOver: isVoiceOverRunning()) {
            handle(action)
        }
        changed()
    }

    // MARK: Steps

    private func canRecord() -> Bool {
        switch recorder.access {
        case .granted:
            return true
        case .denied:
            onAccessDenied?()
            return false
        case .undetermined:
            // The system prompt shows. The owner presses again after the answer.
            let recorder = self.recorder
            Task { _ = await recorder.requestAccess() }
            return false
        }
    }

    private func begin() -> Bool {
        let url = VoiceMemoFiles.newFile(in: folder)
        do {
            try recorder.start(url: url)
        } catch {
            onRecordFailed?()
            return false
        }
        fileURL = url
        levels = []
        elapsed = 0
        onHaptic(.start)
        startTimer()
        return true
    }

    private func handle(_ action: VoiceMemoCapture.Action?) {
        guard let action else { return }
        switch action {
        case .startHold, .startTapMode:
            changed()
        case .warn:
            onHaptic(.warning)
        case .pause:
            elapsed = recorder.currentTime
            recorder.pause()
            changed()
        case .announceMinutes(let minutes):
            onAnnounce(minutes == 1 ? "1 minute" : "\(minutes) minutes")
        case .send:
            finish(send: true)
        case .cancel:
            finish(send: false)
        }
    }

    private func finish(send: Bool) {
        stopTimer()
        guard let url = fileURL else { return changed() }
        fileURL = nil
        if send {
            let duration = recorder.stop()
            let memo = VoiceMemo(fileURL: url, duration: max(duration, elapsed), waveform: VoiceWaveform.bars(from: levels))
            onHaptic(.sent)
            onSend?(memo)
        } else {
            recorder.discard()
            onHaptic(.cancelled)
        }
        levels = []
        elapsed = 0
        changed()
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func changed() {
        onChange?()
    }

    private static func playHaptic(_ haptic: VoiceHaptic) {
        switch haptic {
        case .start: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .sent: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .cancelled: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

// MARK: - Playback

/// Plays one clip at a time: the owner's memos (#9) and the voice replies (#10). A new playback stops
/// the old one. A tap on the clip that plays pauses it, and the next tap goes on from the same point.
/// The session is `.playback` with `.spokenAudio`, and it ducks other audio, so it plays over car audio.
@MainActor
final class VoiceMemoPlayer: NSObject, AVAudioPlayerDelegate {
    /// The loaded clip, playing or paused.
    private(set) var playingURL: URL?
    private(set) var isPlaying = false
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var observer: (any NSObjectProtocol)?
    /// The play state changed. The screen draws the play and pause icons again.
    var onChange: (() -> Void)?
    /// About 10 times per second while a clip plays: the clip, its time and its length.
    var onProgress: ((URL, TimeInterval, TimeInterval) -> Void)?

    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    func isPlaying(_ url: URL) -> Bool { isPlaying && playingURL == url }

    func toggle(_ url: URL) {
        if playingURL == url, let player {
            if player.isPlaying {
                player.pause()
                setPlaying(false)
            } else {
                resume()
            }
        } else {
            play(url)
        }
    }

    func play(_ url: URL, from time: TimeInterval = 0) {
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.currentTime = min(max(0, time), player.duration)
            guard player.play() else { return }
            self.player = player
            playingURL = url
            observeInterruptions()
            setPlaying(true)
        } catch {
            // A missing or broken file plays nothing. The bubble stays.
            onChange?()
        }
    }

    /// The owner dragged the progress bar. A clip that is not loaded starts at that point.
    func seek(_ url: URL, to time: TimeInterval) {
        guard playingURL == url, let player else { return play(url, from: time) }
        player.currentTime = min(max(0, time), player.duration)
        onProgress?(url, player.currentTime, player.duration)
        if !player.isPlaying { resume() }
    }

    func stop() {
        guard player != nil || playingURL != nil else { return }
        player?.stop()
        player = nil
        playingURL = nil
        isPlaying = false
        stopTimer()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onChange?()
    }

    private func resume() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        guard player.play() else { return }
        setPlaying(true)
    }

    private func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if playing { startTimer() } else { stopTimer() }
        onChange?()
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player, let url = playingURL else { return }
        onProgress?(url, player.currentTime, player.duration)
    }

    /// A phone call or Siri pauses the clip. The owner taps play to go on.
    private func observeInterruptions() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                                          queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            guard began else { return }
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.player?.pause()
                self.setPlaying(false)
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in self.stop() }
    }
}
