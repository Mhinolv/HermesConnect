import AVFoundation
import Foundation

/// Issue #139: the quick ack lines in the Kokoro `af_bella` voice, as clips in the app bundle.
/// `scripts/render_ack_clips.sh` renders them on the Mac from `ack_lines.txt`. Nothing goes to the network.
public enum VoiceModeAckClips {
    public static let fileExtension = "m4a"

    /// The clip name of a line: "ack-" and the lowercase letters and digits, with "-" for each other run.
    /// "Just a moment." is "ack-just-a-moment". The render script uses the same rule.
    public static func fileName(for line: String) -> String {
        var slug = ""
        var gap = false
        for scalar in line.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if gap, !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                gap = false
            } else {
                gap = true
            }
        }
        return "ack-" + slug
    }

    /// Decodes one clip to one buffer. A missing, empty or bad file throws.
    public static func decode(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw VoiceReplyError.cannotDecode
        }
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { throw VoiceReplyError.cannotDecode }
        return buffer
    }
}

/// Issue #139: plays one ack clip. Tests use a fake. The app uses `AVAudioEngineAckPlayer`.
public protocol VoiceModeAckClipPlaying: AnyObject, Sendable {
    /// Plays the clip at `url`. Returns when it played, or at once after `stop`. A bad clip throws.
    func play(_ url: URL) async throws
    /// Silence at once.
    func stop()
}

/// Issue #139: the ack on the Hands-Free engine of #127, on its own `AVAudioPlayerNode`.
///
/// - The node goes to the main mixer of the reply engine, so the ack plays at the reply level, through voice
///   processing, and with the screen locked (#138).
/// - The reply has its own node. `stop()` here never drops the queued reply audio.
/// - AVFAudio calls the completion handler on its own queue. The class is not main actor isolated, so the block
///   has no main actor isolation. A lock guards the state.
public final class AVAudioEngineAckPlayer: VoiceModeAckClipPlaying, @unchecked Sendable {
    public let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var generation = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var buffers: [URL: AVAudioPCMBuffer] = [:]

    private let limitMarginSeconds: TimeInterval

    /// - Parameter limitMarginSeconds: with no completion this long after the clip length, the ack ends.
    public init(engine: AVAudioEngine, limitMarginSeconds: TimeInterval = 2) {
        self.engine = engine
        self.limitMarginSeconds = limitMarginSeconds
    }

    public func play(_ url: URL) async throws {
        stop()
        let buffer = try buffer(for: url)
        try prepare(buffer.format)
        let current = lock.withLock { generation }
        // `.dataPlayedBack` waits for the output latency too. An offline engine (tests) uses `.dataRendered`.
        let callback: AVAudioPlayerNodeCompletionCallbackType =
            engine.isInManualRenderingMode ? .dataRendered : .dataPlayedBack
        // A route change can stop the engine with the buffer still queued, and then no handler comes.
        // The ack stops at the clip length plus a margin at the latest.
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate + limitMarginSeconds
        let limit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, lock.withLock({ current == generation }) else { return }
            // The queued buffer must not play late, when the engine starts again.
            stop()
        }
        defer { limit.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let stopped = lock.withLock {
                guard current == generation else { return true }
                waiter = continuation
                return false
            }
            if stopped { return continuation.resume() }
            node.scheduleBuffer(buffer, completionCallbackType: callback) { [weak self] _ in
                self?.finished(generation: current)
            }
            // A stop between the check and the schedule: the buffer must not play.
            if lock.withLock({ current != generation }) { node.stop() }
        }
    }

    public func stop() {
        let woken = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            generation += 1
            defer { waiter = nil }
            return waiter
        }
        if node.engine != nil { node.stop() }
        woken?.resume()
    }

    private func finished(generation finished: Int) {
        let woken = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard finished == generation else { return nil }
            defer { waiter = nil }
            return waiter
        }
        woken?.resume()
    }

    private func buffer(for url: URL) throws -> AVAudioPCMBuffer {
        if let cached = lock.withLock({ buffers[url] }) { return cached }
        let buffer = try VoiceModeAckClips.decode(url)
        lock.withLock { buffers[url] = buffer }
        return buffer
    }

    /// The node joins the engine at the first ack. The mixer converts the clip to the output rate.
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
        if !node.isPlaying { node.play() }
    }
}

/// Issue #139: the quick ack in the `af_bella` voice from the bundled clips.
/// A missing or bad clip, or a player failure, says the line with `fallback` (the on-device voice of #134).
@MainActor
public final class BundledAckVoice: VoiceModeAckVoice {
    private let clipURL: @MainActor (String) -> URL?
    private let player: any VoiceModeAckClipPlaying
    private let fallback: (any VoiceModeAckVoice)?
    private let log = HermesLog(category: "voice-mode")
    /// One more on each speak and stop. A clip of an older serial does not start the fallback.
    private var serial = 0

    /// - Parameter clipURL: the bundle URL of the clip of a line, or `nil` when it is not there.
    public init(clipURL: @escaping @MainActor (String) -> URL?, player: any VoiceModeAckClipPlaying,
                fallback: (any VoiceModeAckVoice)?) {
        self.clipURL = clipURL
        self.player = player
        self.fallback = fallback
    }

    /// The clips of `bundle`, by `VoiceModeAckClips.fileName(for:)`.
    public convenience init(bundle: Bundle, player: any VoiceModeAckClipPlaying, fallback: (any VoiceModeAckVoice)?) {
        self.init(clipURL: { bundle.url(forResource: VoiceModeAckClips.fileName(for: $0),
                                        withExtension: VoiceModeAckClips.fileExtension) },
                  player: player, fallback: fallback)
    }

    public func speak(_ line: String) async {
        stop()
        let current = serial
        if let url = clipURL(line) {
            do {
                try await player.play(url)
                return
            } catch {
                log.notice("voice mode ack clip failed, on-device voice")
            }
        } else {
            log.notice("voice mode ack clip missing, on-device voice")
        }
        guard current == serial, let fallback else { return }
        await fallback.speak(line)
    }

    public func stop() {
        serial += 1
        player.stop()
        fallback?.stop()
    }
}
