import Foundation

// Issue #135: Hands-Free asked for the microphone on every start in the car (Bluetooth HFP).
// The engine starts, then the HFP route comes up (`categoryChange`). The new input format stops the engine.
// The first clip opened before the `AVAudioEngineConfigurationChange` restart, so it failed, and a failed
// restart left the microphone silent. This keeper starts the engine again with a new tap, and logs each failure.

/// The format of the engine input (`inputNode.outputFormat(forBus: 0)`). Numbers only.
public struct VoiceInputFormat: Sendable, Equatable, CustomStringConvertible {
    public var sampleRate: Double
    public var channels: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// A route change can show 0 Hz or 0 channels for a short time. A tap with that format traps.
    public var isValid: Bool { sampleRate > 0 && channels > 0 }

    public var description: String { "rate=\(Int(sampleRate)) ch=\(channels)" }
}

/// The step of the Hands-Free start that failed, for the diagnostics.
public enum VoiceStartStep: String, Sendable {
    /// `setCategory` or `setActive`.
    case session
    case engine
    case tap
    /// The clip file did not open.
    case clip
}

/// The input format is not valid yet (route change in progress).
public struct VoiceInputFormatError: Error, Sendable, Equatable {}

/// The engine of the microphone and the reply (#127). The app wraps `AVAudioEngine`. Tests use a fake.
@MainActor
public protocol VoiceCaptureEngine: AnyObject {
    var isRunning: Bool { get }
    /// `inputNode.outputFormat(forBus: 0)` now.
    var inputFormat: VoiceInputFormat { get }
    /// Turns on voice processing if the engine stops (Apple: only then), and sets the ducking.
    func prepareVoiceProcessing()
    /// Removes the input tap and puts it on again with the input format now.
    func installTap()
    /// `prepare()` and `start()`.
    func start() throws
}

/// Keeps the Hands-Free engine running with a tap in the input format now.
///
/// - `start()`: a new tap, then the engine starts. Each failure writes a `fail` line to the diagnostics.
/// - `ensureRunning()`: before each clip. A stopped engine or a changed format starts again.
/// - `refresh()`: the route and configuration changes. Errors stay in the diagnostics.
/// - `heal()`: each tick while a clip records. A stopped engine starts again, at most every `healInterval`.
@MainActor
public final class VoiceEngineKeeper {
    public static let healInterval: TimeInterval = 0.5

    private let engine: any VoiceCaptureEngine
    private let route: VoiceAudioRoute
    private let clock: @Sendable () -> TimeInterval
    /// The format of the tap that is on now. `nil` with no tap.
    public private(set) var tapFormat: VoiceInputFormat?
    /// `true` from the activation to the deactivation of Hands-Free.
    public var active = false {
        didSet { if !active { tapFormat = nil } }
    }
    private var lastHeal: TimeInterval?

    public init(engine: any VoiceCaptureEngine, route: VoiceAudioRoute,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.engine = engine
        self.route = route
        self.clock = clock
    }

    /// A new tap with the input format now, then the engine starts if it stopped.
    public func start() throws {
        engine.prepareVoiceProcessing()
        let format = engine.inputFormat
        guard format.isValid else {
            tapFormat = nil
            let error = VoiceInputFormatError()
            route.failed(.tap, error: error)
            throw error
        }
        engine.installTap()
        tapFormat = format
        route.tapInstalled(format)
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                route.failed(.engine, error: error)
                throw error
            }
        }
        route.engineStarted()
    }

    /// Before a clip: starts again when the engine stopped or the input format changed since the tap went on.
    public func ensureRunning() throws {
        if engine.isRunning, let tapFormat, tapFormat == engine.inputFormat { return }
        try start()
    }

    /// `routeChangeNotification` and `AVAudioEngineConfigurationChange`.
    public func refresh() {
        guard active else { return }
        try? ensureRunning()
    }

    /// Each tick while a clip records. Only `isRunning` is read on most ticks.
    public func heal() {
        guard active, !engine.isRunning else { return }
        let now = clock()
        if let lastHeal, now - lastHeal < Self.healInterval { return }
        lastHeal = now
        try? start()
    }
}
