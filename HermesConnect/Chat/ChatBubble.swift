import HermesKit
import MessageKit
import UIKit

struct ChatSender: SenderType {
    let senderId: String
    let displayName: String

    static let owner = ChatSender(senderId: "owner", displayName: "You")
    static let hermes = ChatSender(senderId: "hermes", displayName: "Hermes")
}

/// One MessageKit message: one part of a `ChatRow` with its styled text.
/// Issue #8: a photo or location part draws as a photo, a file part as its file text.
struct ChatBubble: MessageType {
    let part: ChatBubblePart
    let text: NSAttributedString
    /// The photo of a photo part, if it is decoded.
    var thumbnail: UIImage?

    var row: ChatRow { part.row }
    var sender: SenderType { row.message.role == .user ? ChatSender.owner : ChatSender.hermes }
    var messageId: String { part.id }
    var sentDate: Date { row.message.date }
    /// A voice memo and the audio of a voice reply (issue #10) draw in `ChatVoiceCell` (issue #9). Issue #8: a photo or location part draws as a photo.
    var kind: MessageKind {
        if row.message.voice != nil || part.content == .spokenReply { return .custom(nil) }
        if let item = part.attachment, item.showsAsImage {
            return .photo(AttachmentPhotoItem(attachment: item, image: thumbnail))
        }
        return .attributedText(text)
    }
}

/// Bubble text: inline Markdown, code blocks and links, with Dynamic Type fonts (issue #6).
enum ChatBubbleText {
    /// The link target of a run. Not `.link`, so the label draws our colors.
    static let linkKey = NSAttributedString.Key("HermesConnectLink")

    static func make(_ message: ChatMessage, traits: UITraitCollection) -> NSAttributedString {
        let outgoing = message.role == .user
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let color: UIColor = outgoing ? .white : .label
        if message.text.isEmpty {
            // A failed reply with no text.
            let italic = body.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: 0) }
            return NSAttributedString(string: "No reply", attributes: [.font: italic ?? body,
                                                                        .foregroundColor: UIColor.secondaryLabel])
        }
        let mono = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular), compatibleWith: traits)
        let codeBackground: UIColor = outgoing ? .white.withAlphaComponent(0.2) : .tertiarySystemFill
        let result = NSMutableAttributedString()
        for run in ChatMarkdown.runs(message.text) {
            var font = run.isCode || run.isCodeBlock ? mono : body
            var symbolic: UIFontDescriptor.SymbolicTraits = []
            if run.isBold { symbolic.insert(.traitBold) }
            if run.isItalic { symbolic.insert(.traitItalic) }
            if !symbolic.isEmpty,
               let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(symbolic)) {
                font = UIFont(descriptor: descriptor, size: 0)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if run.isCode || run.isCodeBlock { attributes[.backgroundColor] = codeBackground }
            if let link = run.link {
                attributes[linkKey] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if !outgoing { attributes[.foregroundColor] = UIColor.link }
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }
}

/// A text bubble with tappable links.
final class ChatTextCell: TextMessageCell {
    var openLink: ((URL) -> Void)?

    override func prepareForReuse() {
        super.prepareForReuse()
        openLink = nil
    }

    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        if let url = link(at: touchPoint) {
            openLink?(url)
            return true
        }
        return super.cellContentView(canHandle: touchPoint)
    }

    /// The link under a point in the bubble. The label draws from the top left of its text insets.
    private func link(at point: CGPoint) -> URL? {
        guard let text = messageLabel.attributedText, text.length > 0 else { return nil }
        let insets = messageLabel.textInsets
        let container = NSTextContainer(size: messageLabel.bounds.inset(by: insets).size)
        container.lineFragmentPadding = 0
        container.lineBreakMode = messageLabel.lineBreakMode
        container.maximumNumberOfLines = messageLabel.numberOfLines
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        let storage = NSTextStorage(attributedString: text)
        storage.addLayoutManager(manager)
        let location = CGPoint(x: point.x - insets.left, y: point.y - insets.top)
        let glyph = manager.glyphIndex(for: location, in: container)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -6, dy: -6).contains(location) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < text.length else { return nil }
        return text.attribute(ChatBubbleText.linkKey, at: index, effectiveRange: nil) as? URL
    }
}
