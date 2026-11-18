import Foundation

/// Issue #120: one tool call of a reply, from `tool.start` and `tool.complete` (docs/hermes-protocol.md 3.10).
/// It keeps only the name, the short summary and the duration. Never the args, the result or `result_text`:
/// they can hold secrets.
public struct ChatToolCall: Sendable, Equatable, Identifiable {
    /// `tool_id`.
    public var id: String
    /// The tool name, as Hermes sends it.
    public var name: String
    /// `summary` of `tool.complete`, else `preview` of `tool.start`. `nil` when Hermes sent neither.
    public var summary: String?
    /// `duration_s` of `tool.complete`. `nil` when no `tool.complete` came: the list shows "—".
    public var duration: TimeInterval?

    public init(id: String, name: String, summary: String? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.name = ChatToolText.clean(name, limit: ChatToolText.nameLimit) ?? "tool"
        self.summary = summary.flatMap { ChatToolText.clean($0, limit: ChatToolText.summaryLimit) }
        self.duration = Self.validDuration(duration)
    }

    /// A negative or broken `duration_s` reads as no duration.
    static func validDuration(_ seconds: TimeInterval?) -> TimeInterval? {
        seconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

/// Issue #120: the text of the tool row, the tool list and the Voice tab tool line.
public enum ChatToolText {
    /// The longest tool name that the app keeps.
    static let nameLimit = 80
    /// The longest summary that the app keeps. The list shows 2 lines.
    static let summaryLimit = 240

    /// "Used web_search" for one tool, "Used 3 tools" for more.
    public static func rowTitle(_ tools: [ChatToolCall]) -> String {
        if tools.count == 1, let tool = tools.first { return "Used \(tool.name)" }
        return "Used \(tools.count) tools"
    }

    public static let rowHint = "Shows the tools."

    public static func rowValue(expanded: Bool) -> String {
        expanded ? "Expanded" : "Collapsed"
    }

    /// The line while a tool runs: "Using web_search…".
    public static func runningLine(_ name: String) -> String {
        "Using \(name)…"
    }

    /// "0.4 s", "12 s", "1 min 4 s". "—" with no `tool.complete`.
    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        if seconds < 10 { return String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), seconds) }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) s" }
        return "\(whole / 60) min \(whole % 60) s"
    }

    /// VoiceOver: "1.2 seconds", "1 minute 4 seconds". `nil` with no `tool.complete`.
    public static func spokenDuration(_ seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        if seconds < 10 {
            let value = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
            return "\(value) seconds"
        }
        let whole = Int(seconds.rounded())
        func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)\(count == 1 ? "" : "s")" }
        if whole < 60 { return unit(whole, "second") }
        return "\(unit(whole / 60, "minute")) \(unit(whole % 60, "second"))"
    }

    /// One list row for VoiceOver: "web_search, Searched 4 pages, 1.2 seconds".
    public static func accessibilityLabel(_ tool: ChatToolCall) -> String {
        ([tool.name] + [tool.summary, spokenDuration(tool.duration)].compactMap { $0 }).joined(separator: ", ")
    }

    /// Trims the text and cuts it at `limit` characters. An empty text is `nil`.
    static func clean(_ text: String, limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }
}
