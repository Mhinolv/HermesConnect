import Foundation

// Issue #130: the audio session of bubble playback and auto-play (#9, #10). The app gives the real
// `AVAudioSession`. Tests use a fake.

/// The audio session of bubble playback. The app wraps `AVAudioSession.sharedInstance()`.
public protocol VoicePlaybackSession: AnyObject, Sendable {
    var routeState: VoiceAudioRouteState { get }
    /// `AVAudioSession.isOtherAudioPlaying`.
    var isOtherAudioPlaying: Bool { get }
    /// `.playback` with `.spokenAudio`. With `duckOthers`, the option `.duckOthers` too.
    func setPlaybackCategory(duckOthers: Bool) throws
    func setActive(_ active: Bool) throws
}

/// Sets the audio session before a clip plays and writes the playback diagnostics.
public final class VoicePlaybackAudio: Sendable {
    private let session: any VoicePlaybackSession
    private let diagnostics: AudioDiagnosticsFile?
    private let log = HermesLog(category: "audio")

    public init(session: any VoicePlaybackSession, diagnostics: AudioDiagnosticsFile? = nil) {
        self.session = session
        self.diagnostics = diagnostics
    }

    /// A clip starts to play from the start or from a seek.
    public func play() throws {
        try start("play")
    }

    /// A paused clip plays again. A memo or Hands-Free can have set `.playAndRecord` with HFP in the pause,
    /// so the category is set again.
    public func resume() throws {
        try start("resume")
    }

    /// The category, then the activation. With other audio on (#10), the clip ducks it. With no other audio,
    /// the session does not mix: a mixable session does not start the media stream of some car Bluetooth
    /// units, so the clip was silent until music played (issue #130). `.playback` also leaves the HFP call channel.
    private func start(_ event: String) throws {
        try session.setPlaybackCategory(duckOthers: session.isOtherAudioPlaying)
        try session.setActive(true)
        report(event)
    }

    /// `AVAudioSession.routeChangeNotification` while a clip is loaded. Safe on any queue.
    public func routeChanged(reason: String) {
        report("route", reason: reason)
    }

    private func report(_ event: String, reason: String? = nil) {
        let line = VoiceAudioRoute.line(event: event, reason: reason, state: session.routeState)
        log.notice("playback " + line)
        diagnostics?.append("playback " + line)
    }
}
