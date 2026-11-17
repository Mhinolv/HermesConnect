import Foundation

/// One drawn bubble of a row (issue #8). A message with attachments draws one bubble per attachment,
/// then its text bubble. The time header goes on the first part. The tail, the footnote and the
/// status line go on the last part.
public struct ChatBubblePart: Sendable, Equatable, Identifiable {
    public enum Content: Sendable, Equatable {
        case text
        case attachment(ChatAttachment)
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
        guard !items.isEmpty else { return [ChatBubblePart(row: row, content: .text, id: row.id)] }
        var parts = items.map { ChatBubblePart(row: row, content: .attachment($0), id: "\(row.id)#\($0.id)") }
        if !row.message.text.isEmpty {
            parts.append(ChatBubblePart(row: row, content: .text, id: "\(row.id)#text"))
        }
        for index in parts.indices {
            if index > 0 { parts[index].row.timeHeader = nil }
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

    /// VoiceOver: "You sent a photo", "You sent a file, Lease.pdf, 2.4 MB", "You sent your location".
    /// Upload states and "Not Delivered" follow.
    public static func accessibilityLabel(for part: ChatBubblePart) -> String {
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
        if let footnote = part.row.footnote, footnote == .notDelivered { parts.append(footnote.text) }
        return parts.joined(separator: ", ")
    }
}
