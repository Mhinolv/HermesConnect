import Foundation

/// The gesture and time rules of the mic button (issue #9 design notes, owner decision 2026-11-16).
/// A plain value type with no I/O. The app feeds it touches and recorder time, then acts on the result.
///
/// - Press: recording starts at once (`.pressed`).
/// - Release before 0.3 s: hands-free recording (`.recording`), with Cancel and Send.
/// - Hold 0.3 s or more: record while held (`.holding`). Release sends. A slide left of 80 pt cancels.
/// - 9:30 gives one warning. 10:00 sends.
/// - An interruption (phone call, Siri, background) pauses and keeps the clip (`.paused`).
public struct VoiceMemoCapture: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// The finger is down. It is not yet a hold.
        case pressed
        /// Press and hold: the recording ends when the finger lifts.
        case holding
        /// Hands-free (tap) recording: the recording bar shows Cancel and Send.
        case recording
        /// Interrupted. The clip is kept. The bar shows Cancel and Send.
        case paused
    }

    public enum Action: Sendable, Equatable {
        /// The press became a hold. The bar shows "Slide to Cancel".
        case startHold
        /// The press was a tap. The bar shows Cancel and Send.
        case startTapMode
        /// The 9:30 warning haptic.
        case warn
        /// Stop the recorder and send the clip.
        case send
        /// Stop the recorder and delete the clip.
        case cancel
        /// Stop the recorder and keep the clip until Send or Cancel.
        case pause
        /// VoiceOver: announce the elapsed whole minutes.
        case announceMinutes(Int)
    }

    public private(set) var phase: Phase = .idle
    /// How far the finger slid left, from 0 to 1 of the cancel distance. The bar moves its hint with it.
    public private(set) var cancelProgress: Double = 0
    private var pressedAt: TimeInterval = 0
    private var warned = false
    private var announcedMinutes = 0

    public init() {}

    public var isActive: Bool { phase != .idle }

    /// The finger touched the mic. Returns `false` if a recording already runs.
    @discardableResult
    public mutating func press(at time: TimeInterval) -> Bool {
        guard phase == .idle else { return false }
        reset()
        phase = .pressed
        pressedAt = time
        return true
    }

    /// VoiceOver activates the mic: hands-free recording only (design notes, Accessibility).
    @discardableResult
    public mutating func startTapMode() -> Bool {
        guard phase == .idle else { return false }
        reset()
        phase = .recording
        return true
    }

    /// Called about every 50 ms. `now` is the clock of `press(at:)`. `recorded` is the clip length.
    public mutating func tick(now: TimeInterval, recorded: TimeInterval, voiceOver: Bool = false) -> [Action] {
        guard phase != .idle else { return [] }
        var actions: [Action] = []
        if phase == .pressed, now - pressedAt >= VoiceMemoLimits.holdThreshold {
            phase = .holding
            actions.append(.startHold)
        }
        guard phase != .paused else { return actions }
        if recorded >= VoiceMemoLimits.maxDuration {
            phase = .idle
            actions.append(.send)
            return actions
        }
        if !warned, recorded >= VoiceMemoLimits.warningAt {
            warned = true
            actions.append(.warn)
        }
        let minutes = Int(recorded / 60)
        if voiceOver, minutes > announcedMinutes {
            announcedMinutes = minutes
            actions.append(.announceMinutes(minutes))
        }
        return actions
    }

    /// The finger moved. `dx` is the horizontal distance from the press point (negative is left).
    public mutating func drag(dx: Double) -> Action? {
        guard phase == .pressed || phase == .holding else { return nil }
        cancelProgress = min(1, max(0, -dx / VoiceMemoLimits.cancelDistance))
        guard dx <= -VoiceMemoLimits.cancelDistance else { return nil }
        phase = .idle
        return .cancel
    }

    /// The finger lifted. A short press starts hands-free recording. A hold sends.
    public mutating func release(at time: TimeInterval) -> Action? {
        switch phase {
        case .pressed where time - pressedAt < VoiceMemoLimits.holdThreshold:
            phase = .recording
            cancelProgress = 0
            return .startTapMode
        case .pressed, .holding:
            phase = .idle
            return .send
        case .idle, .recording, .paused:
            return nil
        }
    }

    /// The system ended the touch (for example, a call came in): keep the clip, as for an interruption.
    public mutating func touchCancelled() -> Action? {
        guard phase == .pressed || phase == .holding else { return nil }
        return interrupt()
    }

    /// A phone call, Siri, or the app went to the background.
    public mutating func interrupt() -> Action? {
        guard phase != .idle, phase != .paused else { return nil }
        phase = .paused
        cancelProgress = 0
        return .pause
    }

    /// The Send button of the recording bar.
    public mutating func send() -> Action? {
        guard phase != .idle else { return nil }
        phase = .idle
        return .send
    }

    /// The Cancel button of the recording bar.
    public mutating func cancel() -> Action? {
        guard phase != .idle else { return nil }
        phase = .idle
        return .cancel
    }

    private mutating func reset() {
        cancelProgress = 0
        warned = false
        announcedMinutes = 0
    }
}
