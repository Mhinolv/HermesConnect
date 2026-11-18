import Foundation

/// Turns a `session.history` transcript into chat bubbles (issue #7).
///
/// - Only `user` and `assistant` rows with text show. Tool, system and hidden rows do not.
/// - One turn gets one incoming bubble: the last assistant text of the turn, as `message.complete` gives it live.
/// - A row keeps the id of the bubble that is already on the screen (same prompt row, or the reply of
///   that prompt), so a merge does not reload or move the thread. A voice memo keeps its audio (issue #9).
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
                let shown = existing.flatMap { id in current.first { $0.id == id } }
                // A voice memo on the screen keeps its bubble (issue #9). The row text is its transcript.
                let voice = shown?.voice.map { memo in
                    var memo = memo
                    memo.transcript = .done(text)
                    return memo
                }
                var prompt = ChatMessage(id: id, role: .user, text: text, date: date, delivery: .delivered,
                                         userRowId: row.rowId, voice: voice)
                // Issue #8: the server text has the `@file:` refs. The bubble keeps the local text and items.
                if let shown, !shown.attachments.isEmpty {
                    prompt.text = shown.text
                    prompt.attachments = shown.attachments
                } else if voice == nil {
                    // Issue #12: no local items (another device, or a cleared cache). The refs show as file cells.
                    let refs = AttachmentRefs.split(text)
                    if !refs.paths.isEmpty {
                        prompt.text = refs.text
                        prompt.attachments = AttachmentRefs.attachments(for: refs.paths, rowId: id)
                    }
                }
                if voice == nil {
                    // Issue #17: the server text starts with the quote block. The bubble shows the reply and the quote.
                    let split = QuoteReply.split(prompt.text)
                    if split.quote != nil { prompt.text = split.text }
                    prompt.quote = shown?.quote ?? split.quote
                }
                result.append(prompt)
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
                // Issue #10: a reply on the screen keeps its spoken audio. Issue #120: and its tool calls.
                result.append(ChatMessage(id: id, role: .assistant, text: text, date: date, reply: reply,
                                          promptId: promptId, spokenReply: existing?.spokenReply,
                                          tools: existing?.tools ?? []))
                replyIndex = result.count - 1
            default:
                continue
            }
        }
        // Issue #11: the server has no reactions. A bubble keeps the agent ack and tapback that it has on the phone.
        // A live ack (eyes) or a thumbs down from a dropped socket follows the reply in the history (QA #40).
        let shown = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let replies = Dictionary(result.compactMap { message in
            message.role == .assistant ? message.promptId.map { ($0, message.reply) } : nil
        }, uniquingKeysWith: { first, _ in first })
        for index in result.indices {
            guard let message = shown[result[index].id] else { continue }
            result[index].agentAck = message.agentAck
            result[index].tapback = message.tapback
            if message.agentAck == .seen || message.agentAck == .failed, let reply = replies[message.id] {
                result[index].agentAck = AgentAckRules.ack(endingWith: reply, prompt: result[index].text)
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
