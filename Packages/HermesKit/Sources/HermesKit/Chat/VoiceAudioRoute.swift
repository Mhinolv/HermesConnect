import Foundation

// Issue #127: the output route of Hands-Free. With no Bluetooth or wired output, the reply plays on the
// built-in speaker, not on the receiver (the earpiece). The app gives the real `AVAudioSession`. Tests use a fake.

/// The output route now, for the checks and the diagnostics. Port types only: no audio, no text, no ids.
public struct VoiceAudioRouteState: Sendable, Equatable {
    /// `AVAudioSession.Port` raw values of the outputs, for example `Receiver`, `Speaker`, `BluetoothHFP`.
    public var outputs: [String]
    /// `AVAudioSession.Category` raw value.
    public var category: String
    /// `AVAudioSession.Mode` raw value.
    public var mode: String
    /// The names of the category options, for example `defaultToSpeaker`.
    public var options: [String]
    /// The system output volume, 0 to 1.
    public var volume: Float

    public init(outputs: [String], category: String = "", mode: String = "", options: [String] = [], volume: Float = 0) {
        self.outputs = outputs
        self.category = category
        self.mode = mode
        self.options = options
        self.volume = volume
    }
}

/// Issue #134: how one reply plays, for the diagnostics. No text, no audio.
public enum VoiceReplyStart: Sendable, Equatable {
    /// `speak-stream` PCM at the `start` frame `sample_rate` (24000 for Kokoro).
    case stream(sampleRate: Double)
    /// The `POST /api/audio/speak` clip.
    case fallback

    var diagnostics: [String] {
        switch self {
        case .stream(let sampleRate): ["path=stream", "rate=\(Int(sampleRate.rounded()))"]
        case .fallback: ["path=fallback", "rate=none"]
        }
    }
}

/// The mode of the Hands-Free session. `voiceChat` is the default: its voice processing holds the echo
/// of the reply down, so barge-in does not hear the reply. `HERMES_AUDIO_MODE` changes it for device checks.
public enum VoiceAudioMode: String, Sendable, CaseIterable {
    case voiceChat
    case videoChat
    case `default`
}

/// The audio session of Hands-Free. The app wraps `AVAudioSession.sharedInstance()`.
public protocol VoiceAudioSession: AnyObject, Sendable {
    var routeState: VoiceAudioRouteState { get }
    /// `.playAndRecord` with `mode`, `.defaultToSpeaker`, `.allowBluetoothHFP` and `.duckOthers`.
    func setVoiceCategory(mode: VoiceAudioMode) throws
    func setActive(_ active: Bool) throws
    /// `overrideOutputAudioPort(.speaker)`.
    func overrideOutputToSpeaker() throws
}

/// Keeps the Hands-Free reply off the receiver and writes the route diagnostics.
///
/// The diagnostics go to the log at the notice level. With `HERMES_AUDIO_DIAG=1` they also go to stdout,
/// one line per event, with the prefix `AUDIO_DIAG`.
public final class VoiceAudioRoute: Sendable {
    public static let diagnosticsKey = "HERMES_AUDIO_DIAG"
    public static let modeKey = "HERMES_AUDIO_MODE"
    public static let receiver = "Receiver"
    public static let speaker = "Speaker"

    public let mode: VoiceAudioMode
    private let session: any VoiceAudioSession
    private let printsDiagnostics: Bool
    private let printLine: @Sendable (String) -> Void
    private let processing: @Sendable () -> VoiceProcessingStatus
    private let log = HermesLog(category: "audio")
    private let diagnostics: AudioDiagnosticsFile?

    public init(session: any VoiceAudioSession,
                processing: @escaping @Sendable () -> VoiceProcessingStatus = { .off },
                environment: [String: String] = ProcessInfo.processInfo.environment,
                diagnostics: AudioDiagnosticsFile? = nil,
                printLine: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.session = session
        self.diagnostics = diagnostics
        self.processing = processing
        printsDiagnostics = environment[Self.diagnosticsKey] == "1"
        mode = environment[Self.modeKey].flatMap(VoiceAudioMode.init(rawValue:)) ?? .voiceChat
        self.printLine = printLine
    }

    /// `true` when the reply would play on the receiver only. Bluetooth, wired and AirPlay outputs win.
    public static func needsSpeaker(_ outputs: [String]) -> Bool {
        !outputs.isEmpty && outputs.allSatisfy { $0 == receiver }
    }

    /// Hands-Free starts: the category, the activation, then the speaker check.
    public func activate() throws {
        report("start")
        try session.setVoiceCategory(mode: mode)
        try session.setActive(true)
        report("active")
        keepSpeaker()
    }

    /// The engine of the microphone and the reply started (issue #127). The line shows its voice processing.
    public func engineStarted() {
        report("engine")
    }

    /// A reply starts to play. Issue #134: the line shows the speak path and the sample rate. One line per reply.
    public func beforeReply(_ start: VoiceReplyStart? = nil) {
        keepSpeaker()
        report("reply", extra: start?.diagnostics ?? [])
    }

    /// `AVAudioSession.routeChangeNotification`. `reason` is the name of the change reason.
    public func routeChanged(reason: String) {
        report("route", reason: reason)
        keepSpeaker()
    }

    /// Moves a receiver-only route to the speaker. An override lasts until the next route change
    /// (Apple docs), so the route code calls it again on each change. Returns `true` when it overrides.
    @discardableResult
    public func keepSpeaker() -> Bool {
        guard Self.needsSpeaker(session.routeState.outputs) else { return false }
        do {
            try session.overrideOutputToSpeaker()
        } catch {
            log.notice("audio speaker override failed: \((error as NSError).code)")
            return false
        }
        report("speaker")
        return true
    }

    private func report(_ event: String, reason: String? = nil, extra: [String] = []) {
        let line = Self.line(event: event, reason: reason, extra: extra, state: session.routeState,
                             processing: processing())
        log.notice(line)
        diagnostics?.append("handsfree " + line)
        if printsDiagnostics { printLine("AUDIO_DIAG " + line) }
    }

    /// One diagnostic line: the event and the route. Port types and session settings only.
    static func line(event: String, reason: String?, extra: [String] = [], state: VoiceAudioRouteState,
                     processing: VoiceProcessingStatus = .off) -> String {
        var parts = ["event=\(event)"]
        if let reason { parts.append("reason=\(reason)") }
        parts += extra
        parts.append("out=\(state.outputs.isEmpty ? "none" : state.outputs.joined(separator: ","))")
        parts.append("category=\(state.category)")
        parts.append("mode=\(state.mode)")
        parts.append("options=\(state.options.isEmpty ? "none" : state.options.joined(separator: ","))")
        parts.append("volume=\(String(format: "%.2f", state.volume))")
        parts.append(processing.description)
        return parts.joined(separator: " ")
    }
}

/// Calls `beforeReply` before each reply plays, then plays it on `base`.
/// `StreamedSpeech` calls it on its own executor, not on the main actor: `beforeReply` must be safe on any queue.
public final class VoiceRoutePlayer: StreamedSpeechPlaying {
    private let base: any StreamedSpeechPlaying
    private let beforeReply: @Sendable (VoiceReplyStart) -> Void

    /// Issue #134: `beforeReply` gets the speak path and the sample rate of the reply.
    public init(base: any StreamedSpeechPlaying, beforeReply: @escaping @Sendable (VoiceReplyStart) -> Void) {
        self.base = base
        self.beforeReply = beforeReply
    }

    public func begin(sampleRate: Double) throws {
        beforeReply(.stream(sampleRate: sampleRate))
        try base.begin(sampleRate: sampleRate)
    }

    public func enqueue(_ pcm: Data) { base.enqueue(pcm) }

    public func drain() async { await base.drain() }

    public func playClip(_ audio: SpokenAudio) async throws {
        beforeReply(.fallback)
        try await base.playClip(audio)
    }

    public func stop() { base.stop() }
}
