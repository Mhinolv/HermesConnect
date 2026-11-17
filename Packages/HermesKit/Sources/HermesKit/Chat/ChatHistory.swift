import Foundation

/// Turns a `session.history` transcript into chat bubbles (issue #7).
///
/// - Only `user` and `assistant` rows with text show. Tool, system and hidden rows do not.
/// - One turn gets one incoming bubble: the last assistant text of the turn, as `message.complete` gives it live.
/// - A row keeps the id of the bubble that is already on the screen (same prompt row, or the reply of
///   that prompt), so a merge does not reload or move the thread.
public enum ChatHistory {
    public static func messages(from transcript: [TranscriptMessage], reusing current: [ChatMessage] = [],
                                fallbackDate: Date = Date()) -> [ChatMessage] {
        var used = Set<String>()
        let promptIdsByRow = Dictionary(current.compactMap { message in
            message.role == .user ? message.userRowId.map { ($0, message.id) } : nil
        }, uniquingKeysWith: { first, _ in first })
        var result: [ChatMessage] = []
        var promptId: String?
        var replyIndex: Int?
        var lastDate = fallbackDate

        for (index, row) in transcript.enumerated() {
            guard row.displayKind != "hidden", let text = text(of: row), !text.isEmpty else { continue }
            let date = row.timestamp.map { Date(timeIntervalSince1970: $0) } ?? lastDate
            lastDate = date
            switch row.role {
            case "user":
                let existing = row.rowId.flatMap { promptIdsByRow[$0] }.flatMap { used.contains($0) ? nil : $0 }
                let id = existing ?? historyId(row, index: index)
                used.insert(id)
                result.append(ChatMessage(id: id, role: .user, text: text, date: date, delivery: .delivered,
                                          userRowId: row.rowId))
                promptId = id
                replyIndex = nil
            case "assistant":
                if let replyIndex {
                    // A later text of the same turn: the bubble shows the final text.
                    result[replyIndex].text = text
                    result[replyIndex].date = date
                    continue
                }
                let existing = current.first { message in
                    message.role == .assistant && message.promptId != nil && message.promptId == promptId
                        && !used.contains(message.id)
                }
                let id = existing?.id ?? historyId(row, index: index)
                used.insert(id)
                let reply: ChatMessage.Reply = existing?.reply == .interrupted ? .interrupted : .complete
                result.append(ChatMessage(id: id, role: .assistant, text: text, date: date, reply: reply,
                                          promptId: promptId))
                replyIndex = result.count - 1
            default:
                continue
            }
        }
        return result
    }

    /// The text of a row: `text`, else the string content, else the text parts of the content.
    static func text(of row: TranscriptMessage) -> String? {
        if let text = row.text { return text }
        switch row.content {
        case .string(let value):
            return value
        case .array(let parts):
            let texts = parts.compactMap { part -> String? in
                if case .string(let value) = part { return value }
                guard part["type"]?.stringValue == "text" else { return nil }
                return part["text"]?.stringValue
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        default:
            return nil
        }
    }

    private static func historyId(_ row: TranscriptMessage, index: Int) -> String {
        row.rowId.map { "row-\($0)" } ?? "history-\(index)"
    }
}
