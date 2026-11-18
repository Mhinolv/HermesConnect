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

/// One haptic of the recording flow (issue #9, issue #103 design notes).
enum VoiceHaptic: Equatable {
    /// `.impact(.medium)` when the recording starts.
    case start
    /// `.impact(.rigid)` when a slide up locks the recording.
    case lock
    /// `.success` when the memo is sent.
    case sent
    /// `.warning` at the cancel distance and at 9:30.
    case warning
    /// `.impact(.light)` when the owner cancels.
    case cancelled
}

/// Joins the parts of a memo into one `.m4a` file. Pause ends a part, and Add More starts a new one
/// (issue #103). `AVVoiceClipJoiner` is the device joiner. Tests use a fake.
@MainActor
protocol VoiceClipJoining: AnyObject {
    /// Writes `parts` one after the other into `url`. Calls `completion` on the main actor.
    func join(_ parts: [URL], into url: URL, completion: @escaping @MainActor (Bool) -> Void)
}

/// `AVMutableComposition` and an Apple M4A export. The parts stay on disk. The caller deletes them.
@MainActor
final class AVVoiceClipJoiner: VoiceClipJoining {
    func join(_ parts: [URL], into url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        Task {
            let joined = await Self.export(parts, into: url)
            completion(joined)
        }
    }

    private nonisolated static func export(_ parts: [URL], into url: URL) async -> Bool {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
        var cursor = CMTime.zero
        do {
            for part in parts {
                let asset = AVURLAsset(url: part)
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let duration = try await asset.load(.duration)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
                cursor = cursor + duration
            }
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                return false
            }
            try? FileManager.default.removeItem(at: url)
            try await export.export(to: url, as: .m4a)
            return true
        } catch {
            return false
        }
    }
}

/// Connects the mic button, the recorder and the chat (issue #9, issue #103). The rules are in `VoiceMemoCapture`.
///
/// Issue #103: Pause finishes the current part, so the owner can play the clip. Add More records a new part.
/// More than one part are joined into one file on pause and on send.
@MainActor
final class VoiceMemoController {
    private(set) var capture = VoiceMemoCapture()
    /// Meter levels from 0 to 1, about 20 per second. The bar draws the last ones.
    private(set) var levels: [Float] = []
    /// The length of the whole clip: the finished parts plus the part that records.
    private(set) var elapsed: TimeInterval = 0

    let recorder: any VoiceRecording
    private let joiner: any VoiceClipJoining
    private let folder: URL
    private let clock: () -> TimeInterval
    /// The part that records now.
    private var fileURL: URL?
    /// The finished parts, in order.
    private var parts: [URL] = []
    /// The length of the finished parts.
    private var partsDuration: TimeInterval = 0
    /// Counts the joins, so a late join of an old clip does nothing.
    private var joinGeneration = 0
    /// `true` while the parts of a sent clip join. A new recording waits, so a failed join can come back.
    private(set) var isSending = false
    private var timer: Timer?

    /// The bar state changed.
    var onChange: (() -> Void)?
    /// A memo is ready to send.
    var onSend: ((VoiceMemo) -> Void)?
    /// The microphone is off in Settings.
    var onAccessDenied: (() -> Void)?
    /// The recorder did not start.
    var onRecordFailed: (() -> Void)?
    /// QA #116: the parts did not join. The clip is kept in the paused bar, and Send or Play tries again.
    var onJoinFailed: (() -> Void)?
    var onHaptic: @MainActor (VoiceHaptic) -> Void = { VoiceMemoController.playHaptic($0) }
    var onAnnounce: @MainActor (String) -> Void = { UIAccessibility.post(notification: .announcement, argument: $0) }
    var isVoiceOverRunning: @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning }

    init(recorder: any VoiceRecording, joiner: any VoiceClipJoining = AVVoiceClipJoiner(),
         folder: URL = VoiceMemoFiles.directory(), clock: @escaping () -> TimeInterval = { CACurrentMediaTime() }) {
        self.recorder = recorder
        self.joiner = joiner
        self.folder = folder
        self.clock = clock
        self.recorder.onInterruption = { [weak self] in self?.interrupt() }
    }

    var isActive: Bool { capture.isActive }

    /// The paused clip as one file, ready to play. `nil` while it records or while the parts join.
    var reviewURL: URL? {
        guard capture.phase == .paused, fileURL == nil, parts.count == 1 else { return nil }
        return parts.first
    }

    // MARK: Input

    /// The finger touched the mic. Returns `true` when the recording started.
    @discardableResult
    func press() -> Bool {
        guard !capture.isActive, !isSending, canRecord() else { return false }
        guard begin() else { return false }
        capture.press(at: clock())
        changed()
        return true
    }

    /// A tap or VoiceOver: locked recording with no hold.
    @discardableResult
    func startTapMode() -> Bool {
        guard !capture.isActive, !isSending, canRecord() else { return false }
        guard begin() else { return false }
        capture.startTapMode()
        changed()
        return true
    }

    func drag(dx: Double, dy: Double = 0) {
        let action = capture.drag(dx: dx, dy: dy)
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

    /// The Pause key.
    func pause() {
        handle(capture.pause())
    }

    /// QA #116: the Play key when the paused parts are not one file yet (a join failed). It tries the join again.
    func prepareReview() {
        guard capture.phase == .paused, fileURL == nil, parts.count > 1 else { return }
        joinPartsForReview(reportsFailure: true)
    }

    /// The Add More key.
    func resume() {
        handle(capture.resume())
    }

    func interrupt() {
        handle(capture.interrupt())
    }

    /// One timer step: read the meter and the clip length, then apply the time rules. Tests call it.
    func tick() {
        guard capture.isActive else { return }
        if capture.phase != .paused, fileURL != nil {
            elapsed = partsDuration + recorder.currentTime
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
        guard startPart() else { return false }
        parts = []
        partsDuration = 0
        levels = []
        elapsed = 0
        onHaptic(.start)
        startTimer()
        return true
    }

    /// Starts a new part file. Returns `false` and shows the alert when the recorder does not start.
    private func startPart() -> Bool {
        let url = VoiceMemoFiles.newFile(in: folder)
        do {
            try recorder.start(url: url)
        } catch {
            onRecordFailed?()
            return false
        }
        fileURL = url
        return true
    }

    /// Finishes the part that records and keeps it.
    private func endPart() {
        guard let url = fileURL else { return }
        fileURL = nil
        let duration = recorder.stop()
        partsDuration += max(0, duration)
        elapsed = partsDuration
        parts.append(url)
    }

    private func handle(_ action: VoiceMemoCapture.Action?) {
        guard let action else { return }
        switch action {
        case .startHold, .startTapMode, .disarmCancel:
            changed()
        case .lock:
            onHaptic(.lock)
            changed()
        case .armCancel:
            onHaptic(.warning)
            changed()
        case .warn:
            onHaptic(.warning)
        case .pause:
            endPart()
            stopTimer()
            joinPartsForReview(reportsFailure: false)
            changed()
        case .resume:
            if startPart() {
                startTimer()
            } else {
                _ = capture.interrupt()
            }
            changed()
        case .announceMinutes(let minutes):
            onAnnounce(minutes == 1 ? "1 minute" : "\(minutes) minutes")
        case .send:
            finish(send: true)
        case .cancel:
            finish(send: false)
        }
    }

    /// The paused clip plays as one file, so more than one part are joined now.
    private func joinPartsForReview(reportsFailure: Bool) {
        guard parts.count > 1 else { return }
        joinGeneration += 1
        let generation = joinGeneration
        let sources = parts
        let target = VoiceMemoFiles.newFile(in: folder)
        joiner.join(sources, into: target) { [weak self] joined in
            guard let self else { return }
            guard joined, generation == self.joinGeneration, self.parts == sources else {
                if joined { try? FileManager.default.removeItem(at: target) }
                // The parts stay. Send joins them again.
                if !joined, reportsFailure, generation == self.joinGeneration { self.onJoinFailed?() }
                return
            }
            sources.forEach { try? FileManager.default.removeItem(at: $0) }
            self.parts = [target]
            self.changed()
        }
    }

    private func finish(send: Bool) {
        stopTimer()
        joinGeneration += 1
        let hadClip = fileURL != nil || !parts.isEmpty
        guard hadClip else { return changed() }
        if send {
            endPart()
            let sources = parts
            let duration = partsDuration
            let memoLevels = levels
            reset()
            if sources.count == 1, let url = sources.first {
                deliver(url: url, duration: duration, levels: memoLevels)
                return changed()
            }
            // QA #116: the parts stay on disk until the join works. A failed join goes back to the paused bar.
            isSending = true
            changed()
            let target = VoiceMemoFiles.newFile(in: folder)
            joiner.join(sources, into: target) { [weak self] joined in
                guard let self else { return }
                self.isSending = false
                if joined {
                    sources.forEach { try? FileManager.default.removeItem(at: $0) }
                    self.deliver(url: target, duration: duration, levels: memoLevels)
                } else {
                    try? FileManager.default.removeItem(at: target)
                    self.restore(parts: sources, duration: duration, levels: memoLevels)
                }
            }
            return
        } else {
            if fileURL != nil { recorder.discard() }
            fileURL = nil
            parts.forEach { try? FileManager.default.removeItem(at: $0) }
            parts = []
            onHaptic(.cancelled)
        }
        reset()
        changed()
    }

    private func reset() {
        parts = []
        partsDuration = 0
        levels = []
        elapsed = 0
    }

    /// QA #116: the clip did not send. It comes back in the paused bar, so no recording is lost.
    private func restore(parts sources: [URL], duration: TimeInterval, levels memoLevels: [Float]) {
        guard capture.restorePaused() else { return }
        parts = sources
        partsDuration = duration
        elapsed = duration
        levels = memoLevels
        onJoinFailed?()
        changed()
    }

    private func deliver(url: URL, duration: TimeInterval, levels: [Float]) {
        let memo = VoiceMemo(fileURL: url, duration: duration, waveform: VoiceWaveform.bars(from: levels))
        onHaptic(.sent)
        onSend?(memo)
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
        case .lock: UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .sent: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .cancelled: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

// MARK: - Playback

/// Plays one clip at a time: the owner's memos (#9) and the voice replies (#10). A new playback stops
/// the old one. A tap on the clip that plays pauses it, and the next tap goes on from the same point.
/// The session is `.playback` with `.spokenAudio`. It ducks other audio when other audio plays, so it plays over
/// car audio. With no other audio, it does not mix, so a car Bluetooth output starts its media stream (issue #130).
@MainActor
final class VoiceMemoPlayer: NSObject, AVAudioPlayerDelegate {
    /// The loaded clip, playing or paused.
    private(set) var playingURL: URL?
    private(set) var isPlaying = false
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var observer: (any NSObjectProtocol)?
    private var routeObserver: (any NSObjectProtocol)?
    /// Issue #130: the session settings and the playback diagnostics (`Library/Caches/audio_diag.log`).
    private let audio: VoicePlaybackAudio
    /// The play state changed. The screen draws the play and pause icons again.
    var onChange: (() -> Void)?
    /// About 10 times per second while a clip plays: the clip, its time and its length.
    var onProgress: ((URL, TimeInterval, TimeInterval) -> Void)?
    /// Issue #42: the clip did not open or did not start. The screen shows the error state, not a silent Play.
    var onFailure: ((URL) -> Void)?

    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    init(audio: VoicePlaybackAudio = VoicePlaybackAudio(session: SystemVoicePlaybackSession(),
                                                        diagnostics: .shared)) {
        self.audio = audio
        super.init()
    }

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
            try audio.play()
        } catch {
            // The session did not start (for example during a call). The file can be good, so the bubble stays.
            onChange?()
            return
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return failed(url) }
        player.delegate = self
        player.currentTime = min(max(0, time), player.duration)
        // Issue #42: AVAudioPlayer opens an Ogg file but cannot prepare it. That is an error, not a silent Play.
        guard player.prepareToPlay(), player.play() else { return failed(url) }
        self.player = player
        playingURL = url
        observeInterruptions()
        observeRoute()
        setPlaying(true)
    }

    /// A missing or broken file plays nothing. Other audio comes back, and the screen shows the error.
    private func failed(_ url: URL) {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onFailure?(url)
        onChange?()
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
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onChange?()
    }

    private func resume() {
        guard let player else { return }
        // Issue #130: a memo or Hands-Free can have set `.playAndRecord` with HFP in the pause.
        try? audio.resume()
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

    /// Issue #130: one diagnostic line per route change while a clip is loaded. AVFAudio posts the change on its
    /// own queue, so the block is nonisolated and touches no main actor state (lesson of #127).
    private func observeRoute() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                               object: nil, queue: nil) { [audio] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            audio.routeChanged(reason: reason.map(SystemVoiceAudioSession.name) ?? "unknown")
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in self.stop() }
    }
}
