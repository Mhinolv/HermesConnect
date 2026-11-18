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
    /// Issue #12: the download state of a received file part.
    var received: ReceivedFileState = .idle

    var row: ChatRow { part.row }
    var sender: SenderType { row.message.role == .user ? ChatSender.owner : ChatSender.hermes }
    var messageId: String { part.id }
    var sentDate: Date { row.message.date }
    /// A voice memo and the audio of a voice reply (issue #10) draw in `ChatVoiceCell` (issue #9). Issue #8: a photo or location part draws as a photo.
    var kind: MessageKind {
        // Issue #67: a command card draws in `ChatCommandCell`.
        // Issue #104: an approval card draws in `ChatApprovalCell`. Issue #117: a prompt card in `ChatPromptCell`.
        if row.message.voice != nil || part.content == .spokenReply || row.message.isLocalCard {
            return .custom(nil)
        }
        // Issue #12: a received image is a photo bubble. Received audio uses the #10 audio bubble (custom cell).
        if let file = part.receivedFile {
            switch file.kind {
            case .image: return .photo(ReceivedPhotoItem(file: file, fileURL: received.fileURL, image: thumbnail))
            case .audio where received.fileURL != nil: return .custom(nil)
            case .audio, .file: return .attributedText(text)
            }
        }
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
        if message.text.isEmpty, let quote = message.quote {
            // Issue #17 (QA #80): a reply of attachments only. The text bubble is the quote line.
            let line = ChatQuoteText.make(quote, style: ChatMarkdownText.Style(traits: traits, outgoing: outgoing))
            line.deleteCharacters(in: NSRange(location: line.length - 1, length: 1))
            return line
        }
        if message.text.isEmpty {
            // A failed reply with no text.
            let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
            return NSAttributedString(string: "No reply", attributes: [.font: body.adding(.traitItalic),
                                                                        .foregroundColor: UIColor.secondaryLabel])
        }
        let style = ChatMarkdownText.Style(traits: traits, outgoing: outgoing)
        let body = ChatMarkdownText.make(message.text, style: style, width: width, streaming: message.reply == .streaming)
        // Issue #17: the quote line at the top of a reply.
        guard let quote = message.quote else { return body }
        let text = ChatQuoteText.make(quote, style: style)
        text.append(body)
        return text
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
    /// Issue #17: a tap on the quote line of a reply.
    var openQuote: (() -> Void)?
    /// Issue #49 (QA #54): the spinner of the "Preparing audio…" caption row under a reply.
    let captionSpinner = UIActivityIndicatorView(style: .medium)

    /// Issue #56: draws the text. `MessageLabel` puts one paragraph style on all of the text, so lists, quotes and
    /// tables lose their indents and tab stops there. The label stays for MessageKit, hidden.
    let markdownView = ChatMarkdownView()
    /// Issue #87: the #50 transcript line under a sent audio file cell. It takes the top of the bottom label area.
    let transcriptLabel = UILabel()
    var onTranscriptTap: (() -> Void)?
    private var transcriptHeight: CGFloat = 0
    private var bottomRegion: CGRect = .zero

    override func setupSubviews() {
        super.setupSubviews()
        messageLabel.isHidden = true
        messageContainerView.addSubview(markdownView)
        transcriptLabel.lineBreakMode = .byTruncatingTail
        transcriptLabel.isAccessibilityElement = false
        contentView.addSubview(transcriptLabel)
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
        bottomRegion = messageBottomLabel.frame
        layoutTranscript()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        markdownView.attributedText = nil
        openLink = nil
        openQuote = nil
        captionSpinner.stopAnimating()
        transcriptLabel.attributedText = nil
        transcriptHeight = 0
        onTranscriptTap = nil
    }

    /// Issue #87: the transcript line, or "Transcribe", under the file cell. `height` includes the padding.
    func configure(transcript: NSAttributedString?, height: CGFloat, lines: Int) {
        transcriptLabel.attributedText = transcript
        transcriptLabel.numberOfLines = lines
        transcriptHeight = transcript == nil ? 0 : height
        layoutTranscript()
    }

    /// Like `ChatVoiceCell`: the line takes the top of the bottom label area, so the footnote stays under it.
    private func layoutTranscript() {
        guard transcriptHeight > 0 else {
            transcriptLabel.frame = .zero
            return
        }
        let height = min(transcriptHeight, bottomRegion.height)
        let pad = ChatVoiceLayout.transcriptPadding
        let bubble = messageContainerView.frame
        transcriptLabel.frame = CGRect(x: bubble.minX + pad.left, y: bottomRegion.minY + pad.top,
                                       width: max(0, bubble.width - pad.left - pad.right),
                                       height: max(0, height - pad.top - pad.bottom))
        messageBottomLabel.frame = CGRect(x: bottomRegion.minX, y: bottomRegion.minY + height,
                                          width: bottomRegion.width, height: bottomRegion.height - height)
    }

    /// Issue #87: a tap on the transcript line starts, cancels or expands it.
    override func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let point = gesture.location(in: self)
        if let onTranscriptTap, transcriptLabel.attributedText != nil,
           transcriptLabel.frame.insetBy(dx: 0, dy: -4).contains(point) {
            onTranscriptTap()
            return
        }
        super.handleTapGesture(gesture)
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
        if let openQuote, markdownView.isQuote(at: touchPoint) {
            openQuote()
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

    /// The SF Symbol at the start of the row. Issue #39: `clock` for a message in the outbox.
    static func symbolName(_ footnote: ChatRow.Footnote) -> String? {
        switch footnote {
        case .audioUnavailable: "arrow.clockwise"
        case .queued: "clock"
        default: nil
        }
    }

    /// The text of the row: an icon or the spinner space, then the footnote text.
    static func text(_ footnote: ChatRow.Footnote, font: UIFont) -> NSAttributedString {
        let color: UIColor = footnote.isError ? .systemRed : .secondaryLabel
        let row = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        let side = iconSide(font)
        if let name = symbolName(footnote) {
            let symbol = UIImage.SymbolConfiguration(font: font).applying(UIImage.SymbolConfiguration(weight: .semibold))
            attachment.image = UIImage(systemName: name, withConfiguration: symbol)?
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

/// Issue #87: the text bubble size. A sent audio file cell is at least as wide as the audio bubble, so the
/// transcript line under it has the width of a received audio transcript.
final class ChatTextSizeCalculator: TextMessageSizeCalculator {
    /// The minimum bubble width of a message, or `nil` for the text width.
    var minimumWidth: (MessageType, _ maxWidth: CGFloat) -> CGFloat? = { _, _ in nil }

    override func messageContainerSize(for message: MessageType, at indexPath: IndexPath) -> CGSize {
        var size = super.messageContainerSize(for: message, at: indexPath)
        let maxWidth = messageContainerMaxWidth(for: message, at: indexPath)
        if let minimum = minimumWidth(message, maxWidth) { size.width = max(size.width, min(minimum, maxWidth)) }
        return size
    }
}
