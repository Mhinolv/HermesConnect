import Foundation

/// Issue #17: the message that an owner prompt replies to. Hermes has no reply field (docs/hermes-protocol.md
/// 3.11, owner decision D7), so the quote goes to the agent as text at the start of the prompt (`QuoteReply`).
public struct ChatQuote: Sendable, Equatable {
    /// The id of the quoted bubble. `nil` for a quote that the app read back from the server text.
    public var messageId: String?
    /// The sender of the quoted message.
    public var author: ChatMessage.Role
    /// The time of the quoted message, as the prompt shows it ("9:41 AM").
    public var time: String
    /// The quoted text: 500 characters or fewer, with "…" at the end if the app cut it.
    public var excerpt: String

    public init(messageId: String?, author: ChatMessage.Role, time: String, excerpt: String) {
        self.messageId = messageId
        self.author = author
        self.time = time
        self.excerpt = excerpt
    }

    /// The quote of `message`, or `nil` if the message cannot be quoted (`QuoteReply.canQuote`).
    public init?(message: ChatMessage, timeZone: TimeZone = .current) {
        guard QuoteReply.canQuote(message) else { return nil }
        self.init(messageId: message.id, author: message.role,
                  time: QuoteReply.timeText(message.date, timeZone: timeZone),
                  excerpt: QuoteReply.excerpt(QuoteReply.source(of: message)))
    }

    /// "Hermes" or "You".
    public var authorName: String { author == .user ? "You" : "Hermes" }

    /// The composer header: "Replying to Hermes" or "Replying to You".
    public var replyingTitle: String { "Replying to \(authorName)" }

    /// The excerpt on one line with no Markdown marks, for the composer box and the bubble.
    public var previewText: String {
        ChatMarkdown.accessibilityText(excerpt).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// VoiceOver: "Reply to Hermes: <excerpt>". The bubble label starts with it.
    public var accessibilityText: String { "Reply to \(authorName): \(previewText)" }
}

/// Issue #17: the stable text format of a quote in the prompt, and the way back from the server text.
///
/// ```
/// > Hermes, 9:41 AM:
/// > <excerpt, max 500 characters, "…" if cut>
///
/// <reply text>
/// ```
public enum QuoteReply {
    /// The most characters of an excerpt, "…" included.
    public static let excerptLimit = 500

    /// A command card, a reply that still streams, and a bubble with no text, file or memo cannot be quoted.
    public static func canQuote(_ message: ChatMessage) -> Bool {
        guard message.command == nil, message.reply != .streaming else { return false }
        return !source(of: message).isEmpty
    }

    /// The text to quote. A message with no text quotes the names of its attachments (design notes: out of scope
    /// is a quote of the attachment itself). A quote of a reply never quotes its own quote: that is in `quote`.
    static func source(of message: ChatMessage) -> String {
        let raw = message.role == .assistant ? MediaTags.visibleText(message.text) : message.text
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        var names = message.attachments.map { item -> String in
            switch item.kind {
            case .photo: "Photo"
            case .location: "Location"
            case .file, .pdf: item.name
            }
        }
        if message.role == .assistant { names += MediaTags.split(message.text).files.map(\.name) }
        if names.isEmpty, message.voice != nil { names = ["Voice Memo"] }
        return names.joined(separator: ", ")
    }

    /// `text` cut to `excerptLimit` characters, "…" included.
    public static func excerpt(_ text: String) -> String {
        guard text.count > excerptLimit else { return text }
        let kept = text.prefix(excerptLimit - 1)
        return String(kept).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "…"
    }

    /// "9:41 AM", with the same words on every device, so the agent always reads one format.
    public static func timeText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        return formatter.string(from: date)
    }

    /// The quote block, a blank line, then `reply`. With no quote, `reply` does not change.
    public static func promptText(_ reply: String, quote: ChatQuote?) -> String {
        guard let quote else { return reply }
        let lines = quote.excerpt.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }
        let block = (["> \(quote.authorName), \(quote.time):"] + lines).joined(separator: "\n")
        let body = reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : reply
        return body.isEmpty ? block : block + "\n\n" + body
    }

    public struct Split: Sendable, Equatable {
        /// The reply text with no quote block.
        public var text: String
        /// The quote of the block. `messageId` is `nil`: the server text does not have it.
        public var quote: ChatQuote?
    }

    /// Reads a quote block at the start of `text` (a prompt from `session.history`). Text with no block, or
    /// with a block that is not in the format, comes back as it is.
    public static func split(_ text: String) -> Split {
        let none = Split(text: text, quote: nil)
        var lines = text.components(separatedBy: "\n")[...]
        guard let header = lines.first.flatMap(parseHeader) else { return none }
        lines = lines.dropFirst()
        var excerpt: [String] = []
        while let line = lines.first, line.hasPrefix(">") {
            excerpt.append(line.hasPrefix("> ") ? String(line.dropFirst(2)) : String(line.dropFirst()))
            lines = lines.dropFirst()
        }
        guard !excerpt.isEmpty else { return none }
        if let line = lines.first {
            guard line.isEmpty else { return none }
            lines = lines.dropFirst()
        }
        let quote = ChatQuote(messageId: nil, author: header.author, time: header.time,
                              excerpt: excerpt.joined(separator: "\n"))
        return Split(text: lines.joined(separator: "\n"), quote: quote)
    }

    /// "> Hermes, 9:41 AM:" or "> You, 12:05 PM:".
    private static func parseHeader(_ line: String) -> (author: ChatMessage.Role, time: String)? {
        guard line.hasPrefix("> "), line.hasSuffix(":") else { return nil }
        let inner = line.dropFirst(2).dropLast()
        let author: ChatMessage.Role
        if inner.hasPrefix("Hermes, ") {
            author = .assistant
        } else if inner.hasPrefix("You, ") {
            author = .user
        } else {
            return nil
        }
        let time = String(inner.drop { $0 != " " }.dropFirst())
        guard time.wholeMatch(of: /\d{1,2}:\d{2} [AP]M/) != nil else { return nil }
        return (author, time)
    }

    /// The bubble that `quote` points to, if it is in `messages`. A quote from the server text has no id:
    /// the newest message of the same sender with the same excerpt (and time, when one matches) is the one.
    public static func target(of quote: ChatQuote, in messages: [ChatMessage],
                              timeZone: TimeZone = .current) -> String? {
        if let id = quote.messageId, messages.contains(where: { $0.id == id }) { return id }
        let matches = messages.filter { message in
            message.role == quote.author && canQuote(message) && excerpt(source(of: message)) == quote.excerpt
        }
        let sameTime = matches.last { timeText($0.date, timeZone: timeZone) == quote.time }
        return (sameTime ?? matches.last)?.id
    }
}
