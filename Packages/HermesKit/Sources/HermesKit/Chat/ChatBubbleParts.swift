import Foundation

/// One drawn bubble of a row (issue #8). A message with attachments draws one bubble per attachment,
/// then its text bubble. The time header goes on the first part. The tail, the footnote and the
/// status line go on the last part.
public struct ChatBubblePart: Sendable, Equatable, Identifiable {
    public enum Content: Sendable, Equatable {
        case text
        case attachment(ChatAttachment)
        /// Issue #10: the audio bubble of a reply to a voice memo. Issue #49 (owner decision): it shows only
        /// with ready audio, as the only bubble of the reply, with the reply text under it. While the audio is
        /// on its way, or after it failed, the text bubble shows with a caption row (QA #54).
        case spokenReply
    }

    /// The row with the labels of this part only.
    public var row: ChatRow
    public var content: Content
    public var id: String

    public var attachment: ChatAttachment? {
        if case .attachment(let item) = content { return item }
        return nil
    }
}

public enum ChatBubbleParts {
    public static func parts(for row: ChatRow) -> [ChatBubblePart] {
        let items = row.message.attachments
        var parts: [ChatBubblePart]
        if let spoken = row.message.spokenReply, spoken.audio != nil, items.isEmpty {
            // Issue #49: one voice bubble with the row id. The text bubble had the same id, so the row reloads
            // in place and the scroll does not jump. "Preparing audio…" and the retry line are the text
            // bubble footnote (QA #54), so there is no empty audio bubble.
            return [ChatBubblePart(row: row, content: .spokenReply, id: row.id)]
        } else if items.isEmpty {
            return [ChatBubblePart(row: row, content: .text, id: row.id)]
        } else {
            parts = items.map { ChatBubblePart(row: row, content: .attachment($0), id: "\(row.id)#\($0.id)") }
            if !row.message.text.isEmpty {
                parts.append(ChatBubblePart(row: row, content: .text, id: "\(row.id)#text"))
            }
        }
        for index in parts.indices {
            if index > 0 {
                parts[index].row.timeHeader = nil
                parts[index].row.showsReactions = false
            }
            if index < parts.count - 1 {
                parts[index].row.hasTail = false
                parts[index].row.footnote = nil
                parts[index].row.statusLine = nil
            }
        }
        return parts
    }

    public static func parts(for rows: [ChatRow]) -> [ChatBubblePart] {
        rows.flatMap { parts(for: $0) }
    }

    /// Issue #49: the space between two drawn bubbles, like iMessage. A new sender or a time header
    /// starts a new group.
    public enum Spacing {
        /// Between two bubbles of one sender, for example a voice reply under its text.
        public static let inGroup: CGFloat = 2
        /// When the sender changes, and above a time header.
        public static let betweenGroups: CGFloat = 10
    }

    /// The space above `part`. The first bubble gets the group space, so it does not touch the top.
    public static func spaceAbove(_ part: ChatBubblePart, after previous: ChatBubblePart?) -> CGFloat {
        guard let previous, previous.row.message.role == part.row.message.role, part.row.timeHeader == nil else {
            return Spacing.betweenGroups
        }
        return Spacing.inGroup
    }

    /// VoiceOver: "You sent a photo", "You sent a file, Lease.pdf, 2.4 MB", "You sent your location".
    /// Upload states and "Not Delivered" follow.
    public static func accessibilityLabel(for part: ChatBubblePart) -> String {
        if part.content == .spokenReply, let spoken = part.row.message.spokenReply {
            // Issue #49: the voice bubble is the whole reply, so VoiceOver also reads the text and the tapback.
            guard spoken.audio != nil, part.row.showsReactions else { return spokenReplyLabel(spoken) }
            let text = VoiceReplyText.previewText(part.row.message.text)
            return ([spokenReplyLabel(spoken)] + (text.isEmpty ? [] : [text])
                + ChatTimeline.reactionLabels(for: part.row)).joined(separator: ", ")
        }
        guard let item = part.attachment else { return ChatTimeline.accessibilityLabel(for: part.row) }
        var parts: [String]
        switch item.kind {
        case .photo: parts = ["You sent a photo"]
        case .location: parts = ["You sent your location"]
        case .file, .pdf: parts = ["You sent a file", item.name, AttachmentPayload.sizeText(item.byteCount)]
        }
        switch item.upload {
        case .uploading: parts.append("Uploading")
        case .failed: parts.append("Upload failed")
        case .pending, .attached: break
        }
        parts += ChatTimeline.reactionLabels(for: part.row)
        if let footnote = part.row.footnote, footnote == .notDelivered { parts.append(footnote.text) }
        return parts.joined(separator: ", ")
    }

    /// VoiceOver: "Hermes voice reply, 0:24" (issue #10 design notes), or the state while there is no audio.
    public static func spokenReplyLabel(_ spoken: SpokenReply) -> String {
        switch spoken {
        case .preparing: "Hermes voice reply, Preparing audio"
        case .ready(let audio): "Hermes voice reply, \(VoiceMemoFormat.duration(audio.duration))"
        case .failed: "Hermes voice reply, Audio unavailable. Tap to retry."
        }
    }
}
