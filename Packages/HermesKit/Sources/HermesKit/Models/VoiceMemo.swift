import Foundation

/// A voice memo that the owner recorded on the phone (issue #9, docs/hermes-protocol.md 3.9).
/// The audio stays in a local `.m4a` file. The app keeps the file until the owner deletes the memo.
public struct VoiceMemo: Sendable, Equatable {
    public var fileURL: URL
    /// The recorded length in seconds.
    public var duration: TimeInterval
    /// Bar heights for the bubble, each from 0 to 1.
    public var waveform: [Float]
    public var transcript: VoiceTranscript

    public init(fileURL: URL, duration: TimeInterval, waveform: [Float], transcript: VoiceTranscript = .pending) {
        self.fileURL = fileURL
        self.duration = duration
        self.waveform = waveform
        self.transcript = transcript
    }
}

/// The state of `POST /api/audio/transcribe` for one memo.
public enum VoiceTranscript: Sendable, Equatable {
    /// The upload runs. The bubble shows "Transcribing…".
    case pending
    /// The transcript. The voice turn uses it as its text.
    case done(String)
    /// The server found no speech. No turn is sent.
    case empty
    /// The upload or the transcription failed. The memo stays, so the owner can try again.
    case failed

    public var text: String? {
        if case .done(let text) = self { return text }
        return nil
    }
}

/// Limits of a voice memo (issue #9 design notes, `web_routers/audio.py:52`).
public enum VoiceMemoLimits {
    /// The server refuses a decoded clip over 25 MiB with 413.
    public static let maxUploadBytes = 25 * 1024 * 1024
    /// Recording stops and sends at 10:00.
    public static let maxDuration: TimeInterval = 600
    /// A warning haptic at 9:30.
    public static let warningAt: TimeInterval = 570
    /// A press longer than this records while held. A shorter press starts hands-free recording.
    public static let holdThreshold: TimeInterval = 0.3
    /// A slide left of this many points cancels a held recording.
    public static let cancelDistance: Double = 80
    /// The MIME type of an AAC clip in an `.m4a` container (docs/hermes-protocol.md 3.9 step 2).
    public static let mimeType = "audio/mp4"
    /// The bar count of the bubble waveform.
    public static let waveformBars = 32
}

public enum VoiceMemoError: Error, Sendable, Equatable {
    /// The transport has no voice support (offline transport, fakes).
    case unsupported
    /// The clip is over `VoiceMemoLimits.maxUploadBytes`, or it is empty.
    case badClip
}

public enum VoiceMemoFormat {
    /// "0:12", "9:30", "10:00". Whole seconds, rounded down.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// "12 seconds", "1 minute 5 seconds" for VoiceOver.
    public static func spokenDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let minutes = total / 60
        let rest = total % 60
        var parts: [String] = []
        if minutes > 0 { parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes") }
        if rest > 0 || minutes == 0 { parts.append(rest == 1 ? "1 second" : "\(rest) seconds") }
        return parts.joined(separator: " ")
    }
}

public enum VoiceWaveform {
    /// The quietest level that shows as a bar, in dBFS. Lower levels show as the smallest bar.
    public static let floorDecibels: Float = -50

    /// One meter reading (`averagePower`, dBFS) as a height from 0 to 1.
    public static func level(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        let clamped = min(0, max(floorDecibels, decibels))
        return (clamped - floorDecibels) / -floorDecibels
    }

    /// Reduces many levels to `bars` bars. Each bar is the peak of its slice. An empty input gives flat bars.
    public static func bars(from levels: [Float], count bars: Int = VoiceMemoLimits.waveformBars) -> [Float] {
        guard bars > 0 else { return [] }
        guard !levels.isEmpty else { return Array(repeating: 0, count: bars) }
        return (0..<bars).map { bar in
            let start = bar * levels.count / bars
            let end = max(start + 1, (bar + 1) * levels.count / bars)
            let slice = levels[min(start, levels.count - 1)..<min(end, levels.count)]
            return min(1, max(0, slice.max() ?? 0))
        }
    }
}
