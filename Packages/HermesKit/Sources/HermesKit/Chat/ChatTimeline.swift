import Foundation

/// One drawn bubble: the message plus the labels around it (issue #6 design notes).
public struct ChatRow: Sendable, Equatable, Identifiable {
    /// The small line under a bubble.
    public enum Footnote: Sendable, Equatable {
        case sending
        case delivered
        case notDelivered
        case replyFailed
        case stopped
        /// A voice memo with no speech in it. No turn was sent (issue #9).
        case noSpeech
        /// The speak call of a voice reply failed (issue #10). A tap tries again.
        case audioUnavailable

        public var text: String {
            switch self {
            case .sending: "Sending…"
            case .delivered: "Delivered"
            case .notDelivered: "Not Delivered"
            case .replyFailed: "Reply failed. Tap to retry."
            case .stopped: "Stopped"
            case .noSpeech: "No speech found."
            case .audioUnavailable: "Audio unavailable. Tap to retry."
            }
        }

        public var isError: Bool {
            self == .notDelivered || self == .replyFailed || self == .noSpeech || self == .audioUnavailable
        }
    }

    public var message: ChatMessage
    /// A centered time header above the bubble ("Today 9:41 AM").
    public var timeHeader: Date?
    /// Only the last bubble of a run of one sender gets the tail.
    public var hasTail: Bool
    public var footnote: Footnote?
    /// The tool or status line of the running turn, under the last bubble.
    public var statusLine: String?

    public var id: String { message.id }
}

public enum ChatTimeline {
    /// A gap longer than this starts a new time header.
    public static let headerGap: TimeInterval = 15 * 60

    /// Builds the rows. `statusLine` goes under the last bubble.
    public static func rows(for messages: [ChatMessage], statusLine: String? = nil) -> [ChatRow] {
        let lastOutgoing = messages.lastIndex { $0.role == .user && $0.delivery != .failed }
        var rows: [ChatRow] = []
        rows.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            let previous = index > 0 ? messages[index - 1] : nil
            let header = previous.map { message.date.timeIntervalSince($0.date) > headerGap } ?? true
            let next = index + 1 < messages.count ? messages[index + 1] : nil
            let nextStartsRun = next.map { $0.role != message.role || $0.date.timeIntervalSince(message.date) > headerGap }
            rows.append(ChatRow(message: message, timeHeader: header ? message.date : nil,
                                hasTail: nextStartsRun ?? true,
                                footnote: footnote(for: message, isLastOutgoing: index == lastOutgoing),
                                statusLine: index == messages.count - 1 ? statusLine : nil))
        }
        return rows
    }

    private static func footnote(for message: ChatMessage, isLastOutgoing: Bool) -> ChatRow.Footnote? {
        switch message.role {
        case .user:
            if message.voice?.transcript == .empty { return .noSpeech }
            switch message.delivery {
            case .failed: return .notDelivered
            case .sending: return isLastOutgoing ? .sending : nil
            case .delivered: return isLastOutgoing ? .delivered : nil
            case nil: return nil
            }
        case .assistant:
            switch message.reply {
            case .failed: return .replyFailed
            case .interrupted: return .stopped
            default: return message.spokenReply == .failed ? .audioUnavailable : nil
            }
        }
    }

    /// The time header text: "Today 9:41 AM", "Yesterday 9:41 AM", "Monday 9:41 AM" or "Nov 3, 2026 9:41 AM".
    public static func headerText(for date: Date, now: Date = Date(), calendar: Calendar = .current,
                                  locale: Locale = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                   calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < now {
            var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            style = style.weekday(.wide)
            return "\(date.formatted(style)) \(time)"
        }
        let day = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale,
                                                  calendar: calendar, timeZone: calendar.timeZone))
        return "\(day) \(time)"
    }

    /// The VoiceOver label of a bubble: "You, <text>, 9:41 AM" or "Hermes, <text>, 9:41 AM".
    public static func accessibilityLabel(for row: ChatRow, calendar: Calendar = .current,
                                          locale: Locale = .current) -> String {
        let sender = row.message.role == .user ? "You" : "Hermes"
        let time = row.message.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                               calendar: calendar, timeZone: calendar.timeZone))
        var parts = [sender]
        if let voice = row.message.voice {
            parts.append("Voice memo, \(VoiceMemoFormat.spokenDuration(voice.duration))")
            switch voice.transcript {
            case .pending: parts.append("Transcribing")
            case .failed: parts.append("Couldn't transcribe")
            case .done, .empty: break
            }
        }
        if !row.message.text.isEmpty { parts.append(row.message.text) }
        parts.append(time)
        if let footnote = row.footnote, footnote != .sending, footnote != .delivered { parts.append(footnote.text) }
        return parts.joined(separator: ", ")
    }
}
