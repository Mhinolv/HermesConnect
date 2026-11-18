import Foundation

/// The gesture and time rules of the mic button (issue #9, issue #103 Glass Capsule).
/// A plain value type with no I/O. The app feeds it touches and recorder time, then acts on the result.
///
/// - Press: recording starts at once (`.pressed`).
/// - Release before 0.3 s: locked (hands-free) recording (`.recording`), with Delete, Pause and Send.
/// - Hold 0.3 s or more: record while held (`.holding`). Release sends.
/// - A slide up of 60 pt locks the recording. A slide left of 100 pt arms the cancel: release deletes the clip,
///   and a slide back keeps it.
/// - Pause, a phone call, Siri or the background keeps the clip (`.paused`). The owner plays it, adds more or sends.
/// - 9:30 gives one warning. 10:00 sends (main decision 2026-11-17).
public struct VoiceMemoCapture: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// The finger is down. It is not yet a hold.
        case pressed
        /// Press and hold: the recording ends when the finger lifts.
        case holding
        /// Locked (hands-free) recording: the bar shows Delete, Pause and Send.
        case recording
        /// Paused or interrupted. The clip is kept. The bar shows Play, Add More, Delete and Send.
        case paused
    }

    public enum Action: Sendable, Equatable {
        /// The press became a hold. The bar shows "Slide to cancel".
        case startHold
        /// The press was a tap. The bar shows the locked keys.
        case startTapMode
        /// A slide up locked the held recording.
        case lock
        /// The finger went past the cancel distance. Release now deletes the clip.
        case armCancel
        /// The finger slid back. Release now sends the clip.
        case disarmCancel
        /// The 9:30 warning haptic.
        case warn
        /// Stop the recorder and send the clip.
        case send
        /// Stop the recorder and delete the clip.
        case cancel
        /// Stop the recorder and keep the clip until Send or Delete.
        case pause
        /// Record more into the kept clip.
        case resume
        /// VoiceOver: announce the elapsed whole minutes.
        case announceMinutes(Int)
    }

    public private(set) var phase: Phase = .idle
    /// How far the finger slid left, from 0 to 1 of the cancel distance. The bar moves its hint with it.
    public private(set) var cancelProgress: Double = 0
    /// How far the finger slid up, from 0 to 1 of the lock distance. The lock pill moves with it.
    public private(set) var lockProgress: Double = 0
    /// `true` while the finger is past the cancel distance. Release deletes the clip.
    public private(set) var cancelArmed = false
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

    /// A tap or VoiceOver activates the mic: locked recording (design notes, Accessibility).
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

    /// The finger moved. `dx` and `dy` are the distances from the press point (negative is left and up).
    public mutating func drag(dx: Double, dy: Double = 0) -> Action? {
        guard phase == .pressed || phase == .holding else { return nil }
        cancelProgress = min(1, max(0, -dx / VoiceMemoLimits.cancelDistance))
        let past = -dx >= VoiceMemoLimits.cancelDistance
        let change: Action? = past == cancelArmed ? nil : (past ? .armCancel : .disarmCancel)
        cancelArmed = past
        lockProgress = cancelArmed ? 0 : min(1, max(0, -dy / VoiceMemoLimits.lockDistance))
        if !cancelArmed, -dy >= VoiceMemoLimits.lockDistance {
            phase = .recording
            cancelProgress = 0
            lockProgress = 0
            return .lock
        }
        return change
    }

    /// The finger lifted. A short press starts locked recording. A hold sends. An armed cancel deletes.
    public mutating func release(at time: TimeInterval) -> Action? {
        if cancelArmed, phase == .pressed || phase == .holding {
            phase = .idle
            cancelArmed = false
            return .cancel
        }
        switch phase {
        case .pressed where time - pressedAt < VoiceMemoLimits.holdThreshold:
            phase = .recording
            cancelProgress = 0
            lockProgress = 0
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
        lockProgress = 0
        cancelArmed = false
        return .pause
    }

    /// The Pause key of the locked bar.
    public mutating func pause() -> Action? {
        guard phase == .recording else { return nil }
        return interrupt()
    }

    /// The Add More key of the paused bar.
    public mutating func resume() -> Action? {
        guard phase == .paused else { return nil }
        phase = .recording
        return .resume
    }

    /// The Send key of the recording bar.
    public mutating func send() -> Action? {
        guard phase != .idle else { return nil }
        phase = .idle
        return .send
    }

    /// The Delete key of the recording bar.
    public mutating func cancel() -> Action? {
        guard phase != .idle else { return nil }
        phase = .idle
        cancelArmed = false
        return .cancel
    }

    private mutating func reset() {
        cancelProgress = 0
        lockProgress = 0
        cancelArmed = false
        warned = false
        announcedMinutes = 0
    }
}
