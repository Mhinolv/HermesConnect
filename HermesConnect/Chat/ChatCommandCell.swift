import HermesKit
import MessageKit
import UIKit

/// Issue #67: the local card of a slash command. Full width, `.secondarySystemBackground`, radius 12.
/// Header: the `terminal` symbol (an error: a red `exclamationmark.triangle`) and the command, `.caption1`,
/// secondary. Body: the output, `.footnote`. It never goes to Hermes.
enum ChatCommandCardLayout {
    static let inset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    static let gap: CGFloat = 4
    static let cornerRadius: CGFloat = 12

    static func header(_ card: ChatCommandCard, traits: UITraitCollection) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        let color: UIColor = card.isError ? .systemRed : .secondaryLabel
        let symbol = card.isError ? "exclamationmark.triangle" : "terminal"
        let text = NSMutableAttributedString()
        if let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: card.command))
        text.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: text.length))
        return text
    }

    static func body(_ card: ChatCommandCard, traits: UITraitCollection) -> NSAttributedString {
        NSAttributedString(string: card.output, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits),
            .foregroundColor: card.isError ? UIColor.systemRed : UIColor.label,
        ])
    }

    /// The card spans the bubble area of the thread. Its height fits the header and the output.
    static func size(_ card: ChatCommandCard, traits: UITraitCollection, maxWidth: CGFloat) -> CGSize {
        let width = max(0, maxWidth - inset.left - inset.right)
        let header = height(header(card, traits: traits), width: width)
        let body = height(body(card, traits: traits), width: width)
        return CGSize(width: maxWidth, height: ceil(inset.top + header + gap + body + inset.bottom))
    }

    static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
    }
}

final class ChatCommandCell: MessageContentCell {
    let headerLabel = UILabel()
    let bodyLabel = UILabel()

    override func setupSubviews() {
        super.setupSubviews()
        headerLabel.numberOfLines = 0
        bodyLabel.numberOfLines = 0
        messageContainerView.addSubview(headerLabel)
        messageContainerView.addSubview(bodyLabel)
    }

    func configure(card: ChatCommandCard, traits: UITraitCollection) {
        headerLabel.attributedText = ChatCommandCardLayout.header(card, traits: traits)
        bodyLabel.attributedText = ChatCommandCardLayout.body(card, traits: traits)
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        headerLabel.attributedText = nil
        bodyLabel.attributedText = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = ChatCommandCardLayout.inset
        let width = max(0, messageContainerView.bounds.width - inset.left - inset.right)
        let header = ChatCommandCardLayout.height(headerLabel.attributedText ?? NSAttributedString(), width: width)
        headerLabel.frame = CGRect(x: inset.left, y: inset.top, width: width, height: header)
        let bodyY = headerLabel.frame.maxY + ChatCommandCardLayout.gap
        bodyLabel.frame = CGRect(x: inset.left, y: bodyY, width: width,
                                 height: max(0, messageContainerView.bounds.height - bodyY - inset.bottom))
    }
}
