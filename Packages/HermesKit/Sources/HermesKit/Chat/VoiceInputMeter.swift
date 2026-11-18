import Foundation
import Synchronization

/// Issue #127: the input level of Hands-Free from the samples of the voice processing input.
///
/// The level is the RMS of the samples since the last read, in dBFS. This is the scale of
/// `AVAudioRecorder.averagePower`, so the silence and barge-in thresholds of `VoiceModeTuning` stay the same.
/// The audio thread calls `record`. The engine reads `level` up to 30 times a second.
public final class VoiceInputMeter: Sendable {
    /// The level of no signal, as `AVAudioRecorder` reports it.
    public static let silence: Float = -160

    private struct State {
        var sum: Double = 0
        var count = 0
        var last: Float = VoiceInputMeter.silence
    }

    private let state = Mutex(State())

    public init() {}

    /// Adds the samples of one input buffer.
    public func record(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        var sum: Double = 0
        for sample in samples { sum += Double(sample) * Double(sample) }
        state.withLock { state in
            state.sum += sum
            state.count += samples.count
        }
    }

    /// The level of the samples since the last read. With no new samples, the last level.
    public func level() -> Float {
        state.withLock { state in
            if state.count > 0 {
                state.last = Self.decibels(rms: (state.sum / Double(state.count)).squareRoot())
                state.sum = 0
                state.count = 0
            }
            return state.last
        }
    }

    /// Forgets the samples and the last level. A new clip starts at silence.
    public func reset() {
        state.withLock { $0 = State() }
    }

    public static func decibels(rms: Double) -> Float {
        guard rms > 0 else { return silence }
        return max(silence, Float(20 * log10(rms)))
    }
}

/// Issue #127: the voice processing of the Hands-Free engine, for the diagnostics.
public struct VoiceProcessingStatus: Sendable, Equatable {
    /// `true` when the engine input runs voice processing.
    public var enabled: Bool
    /// The ducking of other audio, for example `min`. `nil` when voice processing is off.
    public var ducking: String?

    public init(enabled: Bool, ducking: String? = nil) {
        self.enabled = enabled
        self.ducking = ducking
    }

    public static let off = VoiceProcessingStatus(enabled: false)

    /// For the diagnostic line: `vp=on ducking=min` or `vp=off`.
    public var description: String {
        enabled ? "vp=on ducking=\(ducking ?? "default")" : "vp=off"
    }
}
