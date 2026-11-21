import AVFoundation
import Foundation

// Issue #149: a soft heartbeat loop in Hands-Free while Hermes thinks (owner pick: sample B "Heartbeat").
// `scripts/render_thinking_sound.py` renders the bundled loop on the Mac. Nothing goes to the network.

/// Settings > Voice, "Thinking Sound". On by default (owner decision, issue #149).
public enum VoiceModeThinkingSoundSettings {
    /// The `UserDefaults` key of "Thinking Sound".
    public static let key = "voice.thinkingSound"
    public static let resourceName = "thinking-heartbeat"
    public static let fileExtension = "m4a"

    public static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// Issue #149: the thinking sound of Hands-Free. Tests use a fake. The app uses `BundledThinkingSound`.
@MainActor
public protocol VoiceModeThinkingSound: AnyObject {
    /// Starts the loop with a short fade in. A second start while it plays does nothing.
    func start()
    /// Fades the loop out and stops it. A stop while it is silent does nothing.
    func stop()
}

/// Issue #149: one looped clip on its own `AVAudioPlayerNode` of the Hands-Free engine (#127), like the ack (#139).
///
/// - The node goes to the main mixer, so the loop plays at the reply level, through voice processing,
///   and with the screen locked (#138).
/// - The reply and the ack have their own nodes. A stop here never drops their audio.
/// - A volume ramp makes the fade in and the fade out. The node stops after the fade out.
@MainActor
public final class AVAudioEngineLoopPlayer {
    public let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var buffers: [URL: AVAudioPCMBuffer] = [:]
    private var ramp: Task<Void, Never>?
    /// One more on each start and stop. A ramp of an older serial does not stop the node.
    private var serial = 0
    public private(set) var isLooping = false

    public init(engine: AVAudioEngine) {
        self.engine = engine
    }

    /// Loops the clip at `url` up to `volume`, with a fade in of `fadeIn` seconds. A bad clip throws.
    public func start(_ url: URL, volume: Float, fadeIn: TimeInterval) throws {
        serial += 1
        ramp?.cancel()
        if !isLooping {
            let buffer = try buffer(for: url)
            try prepare(buffer.format)
            node.stop()
            node.volume = 0
            node.scheduleBuffer(buffer, at: nil, options: [.loops])
            node.play()
            isLooping = true
        }
        ramp = rampVolume(to: volume, seconds: fadeIn, then: nil)
    }

    /// Fades out in `fadeOut` seconds, then stops the node.
    public func stop(fadeOut: TimeInterval) {
        guard isLooping else { return }
        serial += 1
        ramp?.cancel()
        let current = serial
        ramp = rampVolume(to: 0, seconds: fadeOut) { [weak self] in
            guard let self, current == serial else { return }
            stopNow()
        }
    }

    /// Silence at once.
    public func stopNow() {
        serial += 1
        ramp?.cancel()
        ramp = nil
        isLooping = false
        if node.engine != nil { node.stop() }
        node.volume = 0
    }

    private func rampVolume(to target: Float, seconds: TimeInterval, then done: (@MainActor () -> Void)?) -> Task<Void, Never> {
        let start = node.volume
        let steps = max(1, Int(seconds / 0.02))
        return Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, let self else { return }
                node.volume = start + (target - start) * Float(step) / Float(steps)
            }
            guard !Task.isCancelled else { return }
            done?()
        }
    }

    private func buffer(for url: URL) throws -> AVAudioPCMBuffer {
        if let cached = buffers[url] { return cached }
        let buffer = try VoiceModeAckClips.decode(url)
        buffers[url] = buffer
        return buffer
    }

    /// The node joins the engine at the first loop. The mixer converts the clip to the output rate.
    private func prepare(_ newFormat: AVAudioFormat) throws {
        if node.engine == nil { engine.attach(node) }
        if format != newFormat {
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: newFormat)
            format = newFormat
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }
}

/// Issue #149: the bundled heartbeat loop. A missing or bad clip plays nothing. The loop is never required.
@MainActor
public final class BundledThinkingSound: VoiceModeThinkingSound {
    /// The design notes: fade in 0.4 s, fade out 0.2 s.
    public static let fadeInSeconds: TimeInterval = 0.4
    public static let fadeOutSeconds: TimeInterval = 0.2

    private let url: URL?
    private let player: AVAudioEngineLoopPlayer
    private let volume: Float
    private let log = HermesLog(category: "voice-mode")

    public init(url: URL?, player: AVAudioEngineLoopPlayer, volume: Float = 1) {
        self.url = url
        self.player = player
        self.volume = volume
    }

    public convenience init(bundle: Bundle, player: AVAudioEngineLoopPlayer) {
        self.init(url: bundle.url(forResource: VoiceModeThinkingSoundSettings.resourceName,
                                  withExtension: VoiceModeThinkingSoundSettings.fileExtension),
                  player: player)
    }

    public func start() {
        guard let url else { return log.notice("voice mode thinking sound missing") }
        do {
            try player.start(url, volume: volume, fadeIn: Self.fadeInSeconds)
        } catch {
            log.notice("voice mode thinking sound failed")
        }
    }

    public func stop() {
        player.stop(fadeOut: Self.fadeOutSeconds)
    }
}
