import AVFoundation
import HermesKit
import Observation
import Synchronization
import UIKit

/// Issue #96: the app side of the voice mode engine. It has no views, so the #101 Voice tab can use it as is.
///
/// - The real microphone and audio session (`AVVoiceModeMicrophone`) and the real player (`AVAudioEnginePCMPlayer`).
/// - The pause rule: a call (audio interruption) pauses the loop and closes the mic.
///   Issue #138: background and Lock do not pause. The audio session and the engine stay active, so the session
///   goes on with the screen locked and in other apps.
/// - `VoiceModeController` (HermesKit) does the rest: silence rules, transcript, voice turn, `speak-stream`, barge-in.
@MainActor @Observable
final class VoiceModeSessionModel {
    let controller: VoiceModeController
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// `speech` is the transport of the active server (`LiveChatTransport`).
    /// Issue #101: `tuning` turns off speech barge-in while VoiceOver runs.
    /// Issue #134: `ackVoice` makes the voice of the quick ack. A `nil` voice: no ack.
    /// Issue #139: the default is the bundled `af_bella` clips on the Hands-Free engine, with the on-device
    /// voice (#121) as the fallback.
    convenience init(speech: any VoiceStreamTransport, microphone: AVVoiceModeMicrophone = AVVoiceModeMicrophone(),
                     tuning: VoiceModeTuning = VoiceModeTuning(),
                     ackVoice: @MainActor (AVVoiceModeMicrophone) -> (any VoiceModeAckVoice)? =
                        VoiceModeSessionModel.bundledAckVoice,
                     thinkingSound: @MainActor (AVVoiceModeMicrophone) -> (any VoiceModeThinkingSound)? =
                        VoiceModeSessionModel.bundledThinkingSound) {
        // Issue #127: each reply checks the output route before it plays.
        let player = microphone.replyPlayer
        let ackVoice = ackVoice(microphone)
        let thinkingSound = thinkingSound(microphone)
        self.init(controller: VoiceModeController(
            microphone: microphone, player: player,
            makeSpeech: { try await speech.makeStreamedSpeech(player: $0) },
            makeClipURL: { VoiceMemoFiles.newFile(in: VoiceMemoFiles.directory()) },
            tuning: tuning, ackVoice: ackVoice, thinkingSound: thinkingSound,
            thinkingSoundOn: { VoiceModeThinkingSoundSettings.isOn() }))
    }

    /// Issue #149: the heartbeat loop plays on its own node of the reply engine, like the ack clips (#139).
    static func bundledThinkingSound(_ microphone: AVVoiceModeMicrophone) -> (any VoiceModeThinkingSound)? {
        BundledThinkingSound(bundle: .main, player: microphone.loopPlayer)
    }

    /// Issue #139: the ack clips play on their own node of the reply engine: the reply level, voice processing,
    /// and the screen locked (#138). A missing or bad clip uses the on-device voice.
    static func bundledAckVoice(_ microphone: AVVoiceModeMicrophone) -> (any VoiceModeAckVoice)? {
        BundledAckVoice(bundle: .main, player: microphone.ackPlayer, fallback: OnDevicePromptVoice())
    }

    /// Issue #101: tests give an engine with a fake microphone. The pause rule is the same.
    init(controller: VoiceModeController) {
        self.controller = controller
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated { if began { self?.controller.pause(.call) } }
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

/// The microphone of voice mode. The audio session stays active for the whole loop (`.playAndRecord`, `.voiceChat`).
/// Bluetooth and the speaker work. Other audio ducks.
///
/// Issue #127: one `AVAudioEngine` holds the microphone and the reply. Its input runs voice processing
/// (`setVoiceProcessingEnabled`), so the reply is the processed output: voice processing takes it out of the
/// microphone signal (barge-in) and does not duck it as other audio. Before, `AVAudioRecorder` ran the voice
/// processing and the reply played on a second engine, so the reply was ducked and sounded like the earpiece.
/// The clip is the processed input, with the memo settings of #9 (`AVVoiceRecorder.settings`).
/// `VoiceAudioRoute` keeps a receiver-only route on the speaker and writes the route diagnostics.
/// `HERMES_AUDIO_VP=0` turns voice processing off, for device checks only.
@MainActor
final class AVVoiceModeMicrophone: VoiceModeMicrophone {
    let engine = AVAudioEngine()
    /// The reply player, on `engine`. It stops with the session.
    let player: AVAudioEnginePCMPlayer
    let route: VoiceAudioRoute
    /// `player` with the route check before each reply.
    private(set) lazy var replyPlayer: any StreamedSpeechPlaying = VoiceRoutePlayer(base: player,
                                                                                    beforeReply: Self.beforeReply(route))
    /// Issue #139: the quick ack clips, on `engine` too. Its own node, so a stop of the ack keeps the reply.
    let ackPlayer: AVAudioEngineAckPlayer
    /// Issue #149: the thinking sound loop, on `engine` too, on its own node.
    let loopPlayer: AVAudioEngineLoopPlayer
    /// The engine of the microphone: the engine of the reply too.
    var captureEngine: AVAudioEngine? { engine }

    private let input = VoiceEngineInput()
    private let processing = VoiceProcessingBox()
    /// Issue #135: starts the engine again after a route or configuration change, with a new tap.
    private let keeper: VoiceEngineKeeper
    private var observers: [NSObjectProtocol] = []

    struct StartFailed: Error {}

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        player = AVAudioEnginePCMPlayer(engine: engine)
        ackPlayer = AVAudioEngineAckPlayer(engine: engine)
        loopPlayer = AVAudioEngineLoopPlayer(engine: engine)
        let processing = processing
        route = VoiceAudioRoute(session: SystemVoiceAudioSession(), processing: { processing.value.withLock { $0 } },
                                environment: environment, diagnostics: .shared)
        keeper = VoiceEngineKeeper(engine: AVVoiceCaptureEngine(
            engine: engine, input: input, processing: processing,
            usesVoiceProcessing: environment["HERMES_AUDIO_VP"] != "0"), route: route)
    }

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

    /// Issue #135: only a session failure throws. An engine failure is in the diagnostics, and the clip
    /// start tries the engine again (`ensureRunning`), so Try Again works with the session still active.
    func activate() throws {
        try route.activate()
        keeper.active = true
        try? keeper.start()
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self, route] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            route.routeChanged(reason: reason.map(SystemVoiceAudioSession.name) ?? "unknown")
            MainActor.assumeIsolated { self?.keeper.refresh() }
        })
        // A route change stops the engine (HFP has another input format). The loop goes on with a new tap.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keeper.refresh() }
        })
    }

    func deactivate() {
        keeper.active = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        discardClip()
        engine.inputNode.removeTap(onBus: 0)
        ackPlayer.stop()
        player.shutdown()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Puts the tap on `node` (the engine input). AVFAudio calls the block on its own audio queue.
    /// Issue #127 round 3: the block must not have main actor isolation. A block made in this `@MainActor`
    /// class gets it, and the Swift runtime check traps on the audio queue. So the function is `nonisolated`,
    /// the block is `@Sendable`, and it touches only `VoiceEngineInput` (lock-protected).
    nonisolated static func installInputTap(on node: AVAudioNode, input: VoiceEngineInput) {
        node.installTap(onBus: 0, bufferSize: 1_024, format: node.outputFormat(forBus: 0),
                        block: inputTap(for: input))
    }

    /// Issue #134: `StreamedSpeech` calls this on its own executor, off the main actor. Like the input tap, the block
    /// is made in a `nonisolated` function, so it has no main actor isolation. It writes the diagnostics only.
    nonisolated static func beforeReply(_ route: VoiceAudioRoute) -> @Sendable (VoiceReplyStart) -> Void {
        { @Sendable start in route.beforeReply(start) }
    }

    nonisolated private static func inputTap(for input: VoiceEngineInput) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in input.receive(buffer) }
    }

    /// Issue #135: a stopped engine or a new input format starts again first. Each failure is in the diagnostics.
    func startClip(url: URL) throws {
        guard keeper.active else { throw StartFailed() }
        try keeper.ensureRunning()
        do {
            try input.start(url: url, settings: AVVoiceRecorder.settings)
        } catch {
            route.failed(.clip, error: error)
            throw error
        }
    }

    func stopClip() -> TimeInterval {
        input.stop()
    }

    func discardClip() {
        input.discard()
    }

    /// Issue #135: each tick also starts a stopped engine again, so a failed restart does not leave the mic silent.
    func level() -> Float {
        keeper.heal()
        return input.level() ?? VoiceWaveform.floorDecibels
    }
}

/// Issue #135: `AVAudioEngine` for `VoiceEngineKeeper`. The tap block stays nonisolated (#127 round 3).
@MainActor
final class AVVoiceCaptureEngine: VoiceCaptureEngine {
    private let engine: AVAudioEngine
    private let input: VoiceEngineInput
    private let processing: VoiceProcessingBox
    private let usesVoiceProcessing: Bool

    init(engine: AVAudioEngine, input: VoiceEngineInput, processing: VoiceProcessingBox, usesVoiceProcessing: Bool) {
        self.engine = engine
        self.input = input
        self.processing = processing
        self.usesVoiceProcessing = usesVoiceProcessing
    }

    var isRunning: Bool { engine.isRunning }

    var inputFormat: VoiceInputFormat {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return VoiceInputFormat(sampleRate: format.sampleRate, channels: Int(format.channelCount))
    }

    /// Voice processing can change only while the engine stops (Apple header of `setVoiceProcessingEnabled`).
    func prepareVoiceProcessing() {
        let inputNode = engine.inputNode
        if !engine.isRunning, usesVoiceProcessing, !inputNode.isVoiceProcessingEnabled {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                HermesLog(category: "audio").notice("voice processing failed: \((error as NSError).code)")
            }
        }
        var status = VoiceProcessingStatus.off
        if inputNode.isVoiceProcessingEnabled {
            // Our reply is the voice stream. Other audio (music, on-device speech) ducks as little as it can.
            inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            status = VoiceProcessingStatus(enabled: true, ducking: "min")
        }
        processing.value.withLock { $0 = status }
    }

    func installTap() {
        _ = engine.mainMixerNode
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        AVVoiceModeMicrophone.installInputTap(on: inputNode, input: input)
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }
}

/// The voice processing status for the diagnostics. The route reads it from any thread.
final class VoiceProcessingBox: Sendable {
    let value = Mutex(VoiceProcessingStatus.off)
}

/// Issue #127: the clip of the engine input. The audio thread calls `receive`. The main actor calls the rest.
/// The samples go to the clip file and the meter. They never go to a log.
final class VoiceEngineInput: @unchecked Sendable {
    private let lock = NSLock()
    private let meter = VoiceInputMeter()
    private var file: AVAudioFile?
    private var url: URL?
    private var converter: AVAudioConverter?
    private var frames: AVAudioFramePosition = 0

    /// Opens a new clip in `url` (AAC, `AVVoiceRecorder.settings`).
    func start(url: URL, settings: [String: Any]) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let old = lock.withLock { () -> (AVAudioFile?, URL?) in
            defer {
                self.file = file
                self.url = url
                converter = nil
                frames = 0
            }
            return (self.file, self.url)
        }
        old.0?.close()
        meter.reset()
    }

    /// Closes the clip. Returns its length in seconds.
    func stop() -> TimeInterval {
        let (file, frames) = lock.withLock { () -> (AVAudioFile?, AVAudioFramePosition) in
            defer {
                self.file = nil
                url = nil
            }
            return (self.file, self.frames)
        }
        guard let file else { return 0 }
        file.close()
        return Double(frames) / file.processingFormat.sampleRate
    }

    /// Closes the clip and deletes its file.
    func discard() {
        let (file, url) = lock.withLock { () -> (AVAudioFile?, URL?) in
            defer {
                self.file = nil
                self.url = nil
            }
            return (self.file, self.url)
        }
        file?.close()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// The level of the open clip in dBFS. `nil` with no clip.
    func level() -> Float? {
        guard lock.withLock({ file != nil }) else { return nil }
        return meter.level()
    }

    /// One buffer of the input. Channel 0 is the processed voice.
    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let file, let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            meter.record(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            guard let converted = convert(buffer, to: file.processingFormat) else { return }
            do {
                try file.write(from: converted)
                frames += AVAudioFramePosition(converted.frameLength)
            } catch {
                HermesLog(category: "audio").notice("voice clip write failed: \((error as NSError).code)")
            }
        }
    }

    /// Mono at the clip rate. Call it with the lock held.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            if buffer.format.channelCount > 1 { converter?.channelMap = [0] }
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
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

/// Issue #130: `AVAudioSession.sharedInstance()` for bubble playback and auto-play. It keeps no state.
final class SystemVoicePlaybackSession: VoicePlaybackSession {
    var routeState: VoiceAudioRouteState { SystemVoiceAudioSession().routeState }

    var isOtherAudioPlaying: Bool { AVAudioSession.sharedInstance().isOtherAudioPlaying }

    func setPlaybackCategory(duckOthers: Bool, mode: VoicePlaybackMode) throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: mode == .spokenAudio ? .spokenAudio : .default,
                                                        options: duckOthers ? [.duckOthers] : [])
    }

    func setActive(_ active: Bool) throws {
        try AVAudioSession.sharedInstance().setActive(active)
    }
}
