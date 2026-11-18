import HermesKit
import MessageKit
import UIKit

/// Issue #104: the approval card. A system card on the left of the thread, full width, `.secondarySystemBackground`,
/// radius 12. Title "Hermes asks for approval", the description, the redacted command (monospaced, 3 lines, a tap
/// shows all), then one button per server choice with Deny last and red. After an answer the buttons go and a
/// secondary line shows the result.
enum ChatApprovalCardLayout {
    static let inset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    static let gap: CGFloat = 6
    static let buttonGap: CGFloat = 8
    static let buttonPadding = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
    static let minButtonHeight: CGFloat = 44
    static let collapsedCommandLines = 3
    static let cornerRadius: CGFloat = 12

    static func title(traits: UITraitCollection) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).bold()
        let text = NSMutableAttributedString()
        if let image = UIImage(systemName: "hand.raised.fill", withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(.systemOrange, renderingMode: .alwaysOriginal) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: ChatApprovalCard.title))
        text.addAttributes([.font: font, .foregroundColor: UIColor.label], range: NSRange(location: 0, length: text.length))
        return text
    }

    static func body(_ card: ChatApprovalCard, traits: UITraitCollection) -> NSAttributedString {
        NSAttributedString(string: card.bodyText, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits),
            .foregroundColor: UIColor.label,
        ])
    }

    static func command(_ card: ChatApprovalCard, traits: UITraitCollection) -> NSAttributedString? {
        guard let text = card.commandText else { return nil }
        let base = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        let font = UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
    }

    static func result(_ card: ChatApprovalCard, traits: UITraitCollection) -> NSAttributedString? {
        guard let text = card.resultText else { return nil }
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits),
            .foregroundColor: UIColor.secondaryLabel,
        ])
    }

    static func buttonFont(traits: UITraitCollection) -> UIFont {
        UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
    }

    /// The buttons show only while the card waits.
    static func buttonChoices(_ card: ChatApprovalCard) -> [ApprovalChoice] {
        card.isWaiting ? card.choices : []
    }

    static func buttonHeight(_ choice: ApprovalChoice, traits: UITraitCollection, width: CGFloat) -> CGFloat {
        let title = NSAttributedString(string: ChatApprovalCard.buttonTitle(choice),
                                       attributes: [.font: buttonFont(traits: traits)])
        let textWidth = max(0, width - buttonPadding.leading - buttonPadding.trailing)
        let text = height(title, width: textWidth, lines: 0)
        return max(minButtonHeight, ceil(text + buttonPadding.top + buttonPadding.bottom))
    }

    /// The frames of the parts, from the top of the card.
    struct Frames {
        var title: CGRect
        var body: CGRect
        var command: CGRect?
        var buttons: [CGRect]
        var result: CGRect?
        var height: CGFloat
    }

    static func frames(_ card: ChatApprovalCard, expanded: Bool, traits: UITraitCollection, width cardWidth: CGFloat) -> Frames {
        let width = max(0, cardWidth - inset.left - inset.right)
        var y = inset.top
        let titleHeight = height(title(traits: traits), width: width, lines: 0)
        let titleFrame = CGRect(x: inset.left, y: y, width: width, height: titleHeight)
        y = titleFrame.maxY + gap
        let bodyHeight = height(body(card, traits: traits), width: width, lines: 0)
        let bodyFrame = CGRect(x: inset.left, y: y, width: width, height: bodyHeight)
        y = bodyFrame.maxY
        var commandFrame: CGRect?
        if let command = command(card, traits: traits) {
            y += gap
            let lines = expanded ? 0 : collapsedCommandLines
            let frame = CGRect(x: inset.left, y: y, width: width, height: height(command, width: width, lines: lines))
            commandFrame = frame
            y = frame.maxY
        }
        var buttons: [CGRect] = []
        for choice in buttonChoices(card) {
            y += buttons.isEmpty ? gap + 4 : buttonGap
            let frame = CGRect(x: inset.left, y: y, width: width, height: buttonHeight(choice, traits: traits, width: width))
            buttons.append(frame)
            y = frame.maxY
        }
        var resultFrame: CGRect?
        if let result = result(card, traits: traits) {
            y += gap
            let frame = CGRect(x: inset.left, y: y, width: width, height: height(result, width: width, lines: 0))
            resultFrame = frame
            y = frame.maxY
        }
        return Frames(title: titleFrame, body: bodyFrame, command: commandFrame, buttons: buttons, result: resultFrame,
                      height: ceil(y + inset.bottom))
    }

    static func size(_ card: ChatApprovalCard, expanded: Bool, traits: UITraitCollection, maxWidth: CGFloat) -> CGSize {
        CGSize(width: maxWidth, height: frames(card, expanded: expanded, traits: traits, width: maxWidth).height)
    }

    /// `true` when the command has more lines than the collapsed card shows.
    static func commandIsCut(_ card: ChatApprovalCard, traits: UITraitCollection, width cardWidth: CGFloat) -> Bool {
        guard let command = command(card, traits: traits) else { return false }
        let width = max(0, cardWidth - inset.left - inset.right)
        return height(command, width: width, lines: 0) > height(command, width: width, lines: collapsedCommandLines) + 1
    }

    static func height(_ text: NSAttributedString, width: CGFloat, lines: Int) -> CGFloat {
        let full = ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
        guard lines > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont else { return full }
        return min(full, ceil(font.lineHeight * CGFloat(lines)))
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

final class ChatApprovalCell: MessageContentCell {
    let titleLabel = UILabel()
    let bodyLabel = UILabel()
    let commandLabel = UILabel()
    let resultLabel = UILabel()
    private(set) var buttons: [UIButton] = []
    private var card: ChatApprovalCard?
    private var expanded = false
    private var cellTraits: UITraitCollection = .current

    /// A tap on a choice.
    var onChoice: ((ApprovalChoice) -> Void)?
    /// A tap on a command that the card cuts at 3 lines.
    var onToggleCommand: (() -> Void)?

    override func setupSubviews() {
        super.setupSubviews()
        for label in [titleLabel, bodyLabel, commandLabel, resultLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = false
            messageContainerView.addSubview(label)
        }
        commandLabel.lineBreakMode = .byTruncatingTail
        commandLabel.isUserInteractionEnabled = true
        commandLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(commandTapped)))
        titleLabel.accessibilityTraits = .header
    }

    func configure(card: ChatApprovalCard, expanded: Bool, traits: UITraitCollection) {
        self.card = card
        self.expanded = expanded
        cellTraits = traits
        titleLabel.attributedText = ChatApprovalCardLayout.title(traits: traits)
        titleLabel.accessibilityLabel = ChatApprovalCard.title
        bodyLabel.attributedText = ChatApprovalCardLayout.body(card, traits: traits)
        let command = ChatApprovalCardLayout.command(card, traits: traits)
        commandLabel.attributedText = command
        commandLabel.isHidden = command == nil
        commandLabel.numberOfLines = expanded ? 0 : ChatApprovalCardLayout.collapsedCommandLines
        commandLabel.accessibilityLabel = card.commandText.map { "Command: \($0)" }
        let result = ChatApprovalCardLayout.result(card, traits: traits)
        resultLabel.attributedText = result
        resultLabel.isHidden = result == nil
        makeButtons(ChatApprovalCardLayout.buttonChoices(card), traits: traits)
        // VoiceOver reads the title, the description and the command, then the buttons.
        messageContainerView.accessibilityElements = [titleLabel, bodyLabel, commandLabel] + buttons + [resultLabel]
        setNeedsLayout()
    }

    private func makeButtons(_ choices: [ApprovalChoice], traits: UITraitCollection) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = choices.map { choice in
            var config = UIButton.Configuration.tinted()
            config.cornerStyle = .large
            config.contentInsets = ChatApprovalCardLayout.buttonPadding
            config.titleLineBreakMode = .byWordWrapping
            let font = ChatApprovalCardLayout.buttonFont(traits: traits)
            config.attributedTitle = AttributedString(ChatApprovalCard.buttonTitle(choice),
                                                      attributes: AttributeContainer([.font: font]))
            let tint: UIColor = choice == .deny ? .systemRed : .systemBlue
            config.baseForegroundColor = tint
            config.baseBackgroundColor = tint
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.onChoice?(choice)
            })
            button.accessibilityLabel = ChatApprovalCard.buttonTitle(choice)
            messageContainerView.addSubview(button)
            return button
        }
    }

    @objc private func commandTapped() {
        onToggleCommand?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChoice = nil
        onToggleCommand = nil
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        card = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let card else { return }
        let frames = ChatApprovalCardLayout.frames(card, expanded: expanded, traits: cellTraits,
                                                   width: messageContainerView.bounds.width)
        titleLabel.frame = frames.title
        bodyLabel.frame = frames.body
        commandLabel.frame = frames.command ?? .zero
        for (button, frame) in zip(buttons, frames.buttons) { button.frame = frame }
        resultLabel.frame = frames.result ?? .zero
    }
}
