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
/// Issue #56: also tables, lists, quotes, headings and rules (`ChatMarkdownText`).
enum ChatBubbleText {
    /// The link target of a run. Not `.link`, so the label draws our colors.
    static let linkKey = NSAttributedString.Key("HermesConnectLink")

    /// `width` is the widest text line of the bubble. A table shows as a grid only when it fits in it.
    static func make(_ message: ChatMessage, traits: UITraitCollection, width: CGFloat? = nil) -> NSAttributedString {
        let outgoing = message.role == .user
        if message.text.isEmpty {
            // A failed reply with no text.
            let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
            return NSAttributedString(string: "No reply", attributes: [.font: body.adding(.traitItalic),
                                                                        .foregroundColor: UIColor.secondaryLabel])
        }
        return ChatMarkdownText.make(message.text, style: ChatMarkdownText.Style(traits: traits, outgoing: outgoing),
                                     width: width, streaming: message.reply == .streaming)
    }

    /// The widest text line of a bubble in a thread of this width: the padding of `ChatViewController`
    /// (10 + 56 pt) and the label insets of MessageKit (18 + 14 pt) go.
    static func maxWidth(threadWidth: CGFloat, outgoing: Bool) -> CGFloat {
        // The outgoing accessory (24 pt + 6 pt) takes space too.
        max(0, threadWidth - 66 - 32 - (outgoing ? 30 : 0))
    }
}

/// A text bubble with tappable links.
final class ChatTextCell: TextMessageCell {
    var openLink: ((URL) -> Void)?
    /// Issue #49 (QA #54): the spinner of the "Preparing audio…" caption row under a reply.
    let captionSpinner = UIActivityIndicatorView(style: .medium)

    /// Issue #56: draws the text. `MessageLabel` puts one paragraph style on all of the text, so lists, quotes and
    /// tables lose their indents and tab stops there. The label stays for MessageKit, hidden.
    let markdownView = ChatMarkdownView()

    override func setupSubviews() {
        super.setupSubviews()
        messageLabel.isHidden = true
        messageContainerView.addSubview(markdownView)
        captionSpinner.hidesWhenStopped = true
        captionSpinner.isAccessibilityElement = false
        contentView.addSubview(captionSpinner)
    }

    override func configure(with message: MessageType, at indexPath: IndexPath,
                            and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        if case .attributedText(let text) = message.kind {
            markdownView.attributedText = text
        } else {
            markdownView.attributedText = nil
        }
    }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        markdownView.frame = messageContainerView.bounds
        markdownView.textInsets = messageLabel.textInsets
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        markdownView.attributedText = nil
        openLink = nil
        captionSpinner.stopAnimating()
    }

    /// Shows the spinner in the space that `ChatCaptionRow` leaves at the start of the caption row.
    func showsCaptionSpinner(_ shows: Bool) {
        if shows { captionSpinner.startAnimating() } else { captionSpinner.stopAnimating() }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if markdownView.frame != messageContainerView.bounds { markdownView.frame = messageContainerView.bounds }
        guard captionSpinner.isAnimating, let text = messageBottomLabel.attributedText, text.length > 0,
              let font = text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? UIFont else { return }
        // The spinner grows with the text size, like the icon of the retry row.
        let side = ChatCaptionRow.iconSide(font)
        let scale = side / max(1, captionSpinner.intrinsicContentSize.height)
        captionSpinner.transform = CGAffineTransform(scaleX: scale, y: scale)
        let label = messageBottomLabel.frame
        captionSpinner.center = CGPoint(x: label.minX + messageBottomLabel.textInsets.left + side / 2,
                                        y: label.minY + messageBottomLabel.textInsets.top + font.lineHeight / 2)
    }

    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        if let url = link(at: touchPoint) {
            openLink?(url)
            return true
        }
        return super.cellContentView(canHandle: touchPoint)
    }

    /// The link under a point in the bubble (`messageContainerView` coordinates, the frame of the text view).
    private func link(at point: CGPoint) -> URL? {
        markdownView.link(at: point)
    }
}

/// Issue #49 (QA #54): the caption row under a reply text bubble while its audio prepares or after it failed.
/// It has the place and the style of the memo transcript caption. No empty audio bubble.
enum ChatCaptionRow {
    /// The icon space at the start of the row: the spinner, or `arrow.clockwise`. It grows with the text size.
    static func iconSide(_ font: UIFont) -> CGFloat {
        max(14, (font.capHeight * 1.3).rounded(.up))
    }
    /// The retry row is a tap target, so it is at least 44 pt high.
    static let minimumTapHeight: CGFloat = 44

    /// The text of the row: an icon or the spinner space, then the footnote text.
    static func text(_ footnote: ChatRow.Footnote, font: UIFont) -> NSAttributedString {
        let color: UIColor = footnote.isError ? .systemRed : .secondaryLabel
        let row = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        let side = iconSide(font)
        if footnote == .audioUnavailable {
            let symbol = UIImage.SymbolConfiguration(font: font).applying(UIImage.SymbolConfiguration(weight: .semibold))
            attachment.image = UIImage(systemName: "arrow.clockwise", withConfiguration: symbol)?
                .withTintColor(color, renderingMode: .alwaysOriginal)
            let size = attachment.image?.size ?? CGSize(width: side, height: side)
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        } else {
            // The spinner of `ChatTextCell` draws here. A clear image, so the text system draws no placeholder.
            let format = UIGraphicsImageRendererFormat.preferred()
            format.opaque = false
            attachment.image = UIGraphicsImageRenderer(size: CGSize(width: side, height: 1), format: format).image { _ in }
            attachment.bounds = CGRect(x: 0, y: 0, width: side, height: 1)
        }
        row.append(NSAttributedString(attachment: attachment))
        row.append(NSAttributedString(string: " " + footnote.text))
        row.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: row.length))
        return row
    }

    /// The row height at a label width. The text wraps at large text sizes. The retry row is at least 44 pt.
    static func height(_ footnote: ChatRow.Footnote, font: UIFont, width: CGFloat) -> CGFloat {
        let text = text(footnote, font: font).boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                                           options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                           context: nil).height
        let row = (text + 4).rounded(.up)
        return footnote == .audioUnavailable ? max(minimumTapHeight, row) : row
    }

    /// `true` for the footnotes that use the row: the voice reply audio states.
    static func uses(_ footnote: ChatRow.Footnote?) -> Bool {
        footnote == .preparingAudio || footnote == .audioUnavailable
    }
}
