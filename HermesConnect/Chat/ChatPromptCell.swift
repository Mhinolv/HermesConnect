import HermesKit
import MessageKit
import UIKit

/// Issue #117: what the owner typed or picked on a prompt card that waits. The screen keeps it only until Send or
/// Cancel, so a reload of the thread does not empty the field. It never goes to the model, the cache or a log.
struct ChatPromptDraft: Equatable {
    /// The key of the masked field of a secret or a password.
    static let valueKey = "value"
    /// The text of each field, by `qid` (or `valueKey`).
    var texts: [String: String] = [:]
    /// The picked choices of each question with choices, by `qid`, in tap order.
    var picks: [String: [String]] = [:]

    /// The value of a secret or a password.
    var value: String { texts[Self.valueKey] ?? "" }

    /// The answer of each open question: a pick, a JSON list of picks, or the typed text.
    func typedAnswers(_ card: ChatPromptCard) -> [String: String] {
        var answers: [String: String] = [:]
        for question in card.openQuestions {
            if question.choices.isEmpty {
                answers[question.qid] = texts[question.qid] ?? ""
            } else if let picked = picks[question.qid], !picked.isEmpty {
                answers[question.qid] = question.answer(for: picked)
            }
        }
        return answers
    }

    /// Send is on when each field has text.
    func canSend(_ card: ChatPromptCard) -> Bool {
        guard card.isWaiting else { return false }
        if card.isSecure { return !value.isEmpty }
        return card.clarifyAnswers(typedAnswers(card)) != nil
    }

    /// A tap on a choice. A multi-select question toggles it. Other questions keep one pick.
    mutating func toggle(_ choice: String, in question: ClarifyQuestion) {
        var picked = picks[question.qid] ?? []
        if question.multiSelect {
            if let index = picked.firstIndex(of: choice) { picked.remove(at: index) } else { picked.append(choice) }
        } else {
            picked = [choice]
        }
        picks[question.qid] = picked
    }
}

/// Issue #117: the secret, password and question card. The same system card as the approval card (#104): full
/// width on the left, `.secondarySystemBackground`, radius 12. The title, the server prompt, the env var name or the
/// command (monospaced), then the fields, then Cancel and Send. After an answer only a secondary line shows.
enum ChatPromptCardLayout {
    typealias Base = ChatApprovalCardLayout
    static let fieldPadding: CGFloat = 10
    static let choiceGap: CGFloat = 6

    /// One part of the card under the title, in order.
    enum Part: Equatable {
        /// The question text of a clarify question.
        case question(Int)
        /// The masked field (`nil`) or the text field of a question.
        case field(Int?)
        /// A choice button of a question.
        case choice(question: Int, choice: Int)
    }

    static func symbol(_ card: ChatPromptCard) -> String {
        switch card.kind {
        case .secret: "key.fill"
        case .sudo: "lock.fill"
        case .clarify: "questionmark.bubble.fill"
        }
    }

    static func title(_ card: ChatPromptCard, traits: UITraitCollection) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).promptBold()
        let text = NSMutableAttributedString()
        if let image = UIImage(systemName: symbol(card), withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(.systemOrange, renderingMode: .alwaysOriginal) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: card.title))
        text.addAttributes([.font: font, .foregroundColor: UIColor.label], range: NSRange(location: 0, length: text.length))
        return text
    }

    static func body(_ card: ChatPromptCard, traits: UITraitCollection) -> NSAttributedString? {
        guard let text = card.bodyText else { return nil }
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits), .foregroundColor: UIColor.label,
        ])
    }

    static func detail(_ card: ChatPromptCard, traits: UITraitCollection) -> NSAttributedString? {
        guard let text = card.detailText else { return nil }
        let base = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel,
        ])
    }

    static func question(_ question: ClarifyQuestion, traits: UITraitCollection) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits).promptBold()
        return NSAttributedString(string: question.question, attributes: [.font: font, .foregroundColor: UIColor.label])
    }

    static func result(_ card: ChatPromptCard, traits: UITraitCollection) -> NSAttributedString? {
        guard let text = card.resultText else { return nil }
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits),
            .foregroundColor: UIColor.secondaryLabel,
        ])
    }

    static func fieldFont(traits: UITraitCollection) -> UIFont {
        UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
    }

    static func fieldHeight(traits: UITraitCollection) -> CGFloat {
        max(Base.minButtonHeight, ceil(fieldFont(traits: traits).lineHeight + fieldPadding * 2))
    }

    /// The parts under the text, while the card waits.
    static func parts(_ card: ChatPromptCard) -> [Part] {
        guard card.isWaiting else { return [] }
        if card.isSecure { return [.field(nil)] }
        var parts: [Part] = []
        for (index, question) in card.openQuestions.enumerated() {
            parts.append(.question(index))
            if question.choices.isEmpty {
                parts.append(.field(index))
            } else {
                parts += question.choices.indices.map { .choice(question: index, choice: $0) }
            }
        }
        return parts
    }

    /// The button text height reserves the checkmark image, so a pick does not change the size.
    static func buttonHeight(_ title: String, traits: UITraitCollection, width: CGFloat, image: Bool) -> CGFloat {
        let font = Base.buttonFont(traits: traits)
        let text = NSAttributedString(string: title, attributes: [.font: font])
        let imageWidth = image ? ceil(font.pointSize * 1.3) + 6 : 0
        let textWidth = max(0, width - Base.buttonPadding.leading - Base.buttonPadding.trailing - imageWidth)
        let height = Base.height(text, width: textWidth, lines: 0)
        return max(Base.minButtonHeight, ceil(height + Base.buttonPadding.top + Base.buttonPadding.bottom))
    }

    struct Frames {
        var title: CGRect
        var body: CGRect?
        var detail: CGRect?
        var parts: [(Part, CGRect)]
        var cancel: CGRect?
        var send: CGRect?
        var result: CGRect?
        var height: CGFloat
    }

    static func frames(_ card: ChatPromptCard, traits: UITraitCollection, width cardWidth: CGFloat) -> Frames {
        let inset = Base.inset
        let width = max(0, cardWidth - inset.left - inset.right)
        var y = inset.top
        func text(_ value: NSAttributedString?, gap: CGFloat) -> CGRect? {
            guard let value else { return nil }
            y += gap
            let frame = CGRect(x: inset.left, y: y, width: width, height: Base.height(value, width: width, lines: 0))
            y = frame.maxY
            return frame
        }
        let titleFrame = text(title(card, traits: traits), gap: 0) ?? .zero
        let bodyFrame = text(body(card, traits: traits), gap: Base.gap)
        let detailFrame = text(detail(card, traits: traits), gap: Base.gap)
        var placed: [(Part, CGRect)] = []
        let questions = card.openQuestions
        for part in parts(card) {
            switch part {
            case .question(let index):
                placed.append((part, text(question(questions[index], traits: traits), gap: Base.gap + 4) ?? .zero))
            case .field:
                y += Base.gap + (card.isSecure ? 4 : 0)
                let frame = CGRect(x: inset.left, y: y, width: width, height: fieldHeight(traits: traits))
                placed.append((part, frame))
                y = frame.maxY
            case .choice(let question, let choice):
                y += choiceGap
                let title = questions[question].choices[choice]
                let frame = CGRect(x: inset.left, y: y, width: width,
                                   height: buttonHeight(title, traits: traits, width: width, image: true))
                placed.append((part, frame))
                y = frame.maxY
            }
        }
        var cancelFrame: CGRect?
        var sendFrame: CGRect?
        if card.isWaiting {
            y += Base.gap + 6
            if stacksButtons(traits) {
                // Accessibility text sizes: one button in each row, Send first and Cancel last (as Deny on #104).
                let send = buttonHeight(ChatPromptCard.sendTitle, traits: traits, width: width, image: false)
                sendFrame = CGRect(x: inset.left, y: y, width: width, height: send)
                y += send + Base.buttonGap
                let cancel = buttonHeight(ChatPromptCard.cancelTitle, traits: traits, width: width, image: false)
                cancelFrame = CGRect(x: inset.left, y: y, width: width, height: cancel)
                y += cancel
            } else {
                let half = floor((width - Base.buttonGap) / 2)
                let height = max(buttonHeight(ChatPromptCard.cancelTitle, traits: traits, width: half, image: false),
                                 buttonHeight(ChatPromptCard.sendTitle, traits: traits, width: half, image: false))
                cancelFrame = CGRect(x: inset.left, y: y, width: half, height: height)
                sendFrame = CGRect(x: inset.left + width - half, y: y, width: half, height: height)
                y += height
            }
        }
        let resultFrame = text(result(card, traits: traits), gap: Base.gap)
        return Frames(title: titleFrame, body: bodyFrame, detail: detailFrame, parts: placed, cancel: cancelFrame,
                      send: sendFrame, result: resultFrame, height: ceil(y + inset.bottom))
    }

    /// Cancel and Send share one row, except at accessibility text sizes.
    static func stacksButtons(_ traits: UITraitCollection) -> Bool {
        traits.preferredContentSizeCategory.isAccessibilityCategory
    }

    static func size(_ card: ChatPromptCard, traits: UITraitCollection, maxWidth: CGFloat) -> CGSize {
        CGSize(width: maxWidth, height: frames(card, traits: traits, width: maxWidth).height)
    }
}

private extension UIFont {
    func promptBold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// A text field with the inner padding of the card buttons.
final class ChatPromptField: UITextField {
    override func textRect(forBounds bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: ChatPromptCardLayout.fieldPadding + 2, dy: 0)
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }
}

final class ChatPromptCell: MessageContentCell, UITextFieldDelegate {
    let titleLabel = UILabel()
    let bodyLabel = UILabel()
    let detailLabel = UILabel()
    let resultLabel = UILabel()
    private(set) var questionLabels: [UILabel] = []
    /// The fields in order: the masked field, or one field for each open question with no choices.
    private(set) var fields: [ChatPromptField] = []
    private(set) var choiceButtons: [UIButton] = []
    private(set) var cancelButton: UIButton?
    private(set) var sendButton: UIButton?
    private var card: ChatPromptCard?
    private var draft = ChatPromptDraft()
    private var cellTraits: UITraitCollection = .current
    /// The draft key of each field, in `fields` order.
    private var fieldKeys: [String] = []

    /// The draft changed: a key stroke or a pick.
    var onDraftChange: ((ChatPromptDraft) -> Void)?
    /// Send with the draft. The cell empties its fields first.
    var onSend: ((ChatPromptDraft) -> Void)?
    var onCancel: (() -> Void)?
    /// A field took the focus, with its draft key. The screen scrolls the card into view and keeps the key, so a
    /// reload of the thread can give the focus back.
    var onFocus: ((String) -> Void)?
    /// A field lost the focus: the owner tapped elsewhere, Send or Cancel. A reload does not call it: the cell drops
    /// its callbacks before it removes its fields.
    var onBlur: ((String) -> Void)?
    /// The field that takes the focus once the cell is in the window again (after a reload).
    private var pendingFocusKey: String?

    override func setupSubviews() {
        super.setupSubviews()
        // Issue #111: MessageKit's `messageContainerView` is a `UIImageView`, which takes no touches by default.
        // Without this, a tap never gets to the fields or the buttons.
        messageContainerView.isUserInteractionEnabled = true
        for label in [titleLabel, bodyLabel, detailLabel, resultLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = false
            messageContainerView.addSubview(label)
        }
        titleLabel.accessibilityTraits = .header
    }

    func configure(card: ChatPromptCard, draft: ChatPromptDraft, traits: UITraitCollection) {
        let rebuild = self.card?.serverRequestId != card.serverRequestId || self.card?.state != card.state
            || cellTraits.preferredContentSizeCategory != traits.preferredContentSizeCategory
        self.card = card
        self.draft = draft
        cellTraits = traits
        titleLabel.attributedText = ChatPromptCardLayout.title(card, traits: traits)
        titleLabel.accessibilityLabel = card.title
        let body = ChatPromptCardLayout.body(card, traits: traits)
        bodyLabel.attributedText = body
        bodyLabel.isHidden = body == nil
        let detail = ChatPromptCardLayout.detail(card, traits: traits)
        detailLabel.attributedText = detail
        detailLabel.isHidden = detail == nil
        if case .secret = card.kind { detailLabel.accessibilityLabel = card.detailText.map { "Variable: \($0)" } }
        if case .sudo = card.kind { detailLabel.accessibilityLabel = card.detailText.map { "Command: \($0)" } }
        let result = ChatPromptCardLayout.result(card, traits: traits)
        resultLabel.attributedText = result
        resultLabel.isHidden = result == nil
        if rebuild || fields.count + choiceButtons.count + questionLabels.count == 0 { makeControls(card, traits: traits) }
        applyDraft()
        // VoiceOver reads the title and the prompt, then the fields, then the buttons.
        var elements: [Any] = [titleLabel]
        if body != nil { elements.append(bodyLabel) }
        if detail != nil { elements.append(detailLabel) }
        var fieldIndex = 0
        var choiceIndex = 0
        for part in ChatPromptCardLayout.parts(card) {
            switch part {
            case .question(let index): elements.append(questionLabels[index])
            case .field:
                elements.append(fields[fieldIndex])
                fieldIndex += 1
            case .choice:
                elements.append(choiceButtons[choiceIndex])
                choiceIndex += 1
            }
        }
        // The buttons in screen order: Cancel then Send in one row, Send then Cancel when stacked.
        let buttons = ChatPromptCardLayout.stacksButtons(traits) ? [sendButton, cancelButton] : [cancelButton, sendButton]
        elements += buttons.compactMap { $0 }
        if result != nil { elements.append(resultLabel) }
        messageContainerView.accessibilityElements = elements
        setNeedsLayout()
    }

    private func removeControls() {
        (questionLabels as [UIView] + fields + choiceButtons + [cancelButton, sendButton].compactMap { $0 })
            .forEach { $0.removeFromSuperview() }
        for field in fields { field.text = nil }
        questionLabels = []
        fields = []
        fieldKeys = []
        choiceButtons = []
        cancelButton = nil
        sendButton = nil
    }

    private func makeControls(_ card: ChatPromptCard, traits: UITraitCollection) {
        removeControls()
        guard card.isWaiting else { return }
        let questions = card.openQuestions
        for part in ChatPromptCardLayout.parts(card) {
            switch part {
            case .question(let index):
                let label = UILabel()
                label.numberOfLines = 0
                label.attributedText = ChatPromptCardLayout.question(questions[index], traits: traits)
                messageContainerView.addSubview(label)
                questionLabels.append(label)
            case .field(let index):
                let field = makeField(card, traits: traits, question: index.map { questions[$0] })
                fieldKeys.append(index.map { questions[$0].qid } ?? ChatPromptDraft.valueKey)
                fields.append(field)
            case .choice(let question, let choice):
                let item = questions[question]
                let title = item.choices[choice]
                let button = UIButton(configuration: .tinted(), primaryAction: UIAction { [weak self] _ in
                    guard let self else { return }
                    draft.toggle(title, in: item)
                    applyDraft()
                    onDraftChange?(draft)
                })
                button.accessibilityLabel = title
                messageContainerView.addSubview(button)
                choiceButtons.append(button)
            }
        }
        for field in fields.dropLast() { field.returnKeyType = .next }
        cancelButton = makeButton(ChatPromptCard.cancelTitle, tint: .systemRed, traits: traits) { [weak self] in
            self?.cancelTapped()
        }
        sendButton = makeButton(ChatPromptCard.sendTitle, tint: .systemBlue, traits: traits) { [weak self] in
            self?.sendTapped()
        }
    }

    private func makeField(_ card: ChatPromptCard, traits: UITraitCollection, question: ClarifyQuestion?) -> ChatPromptField {
        let field = ChatPromptField()
        field.font = ChatPromptCardLayout.fieldFont(traits: traits)
        field.adjustsFontForContentSizeCategory = false
        field.backgroundColor = .tertiarySystemBackground
        field.layer.cornerRadius = 10
        field.layer.cornerCurve = .continuous
        field.isSecureTextEntry = card.isSecure
        // No autofill suggestions, no autocorrect, no predictions (design notes).
        field.textContentType = nil
        field.passwordRules = nil
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no
        field.returnKeyType = .send
        // The Send key is off while the field is empty.
        field.enablesReturnKeyAutomatically = true
        field.placeholder = question == nil ? card.fieldPlaceholder : "Answer"
        field.accessibilityLabel = question?.question ?? card.fieldPlaceholder
        field.delegate = self
        field.addTarget(self, action: #selector(fieldChanged(_:)), for: .editingChanged)
        messageContainerView.addSubview(field)
        return field
    }

    private func makeButton(_ title: String, tint: UIColor, traits: UITraitCollection,
                            action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.tinted()
        config.cornerStyle = .large
        config.contentInsets = ChatApprovalCardLayout.buttonPadding
        config.titleLineBreakMode = .byWordWrapping
        config.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: ChatApprovalCardLayout.buttonFont(traits: traits),
        ]))
        config.baseForegroundColor = tint
        config.baseBackgroundColor = tint
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = title
        messageContainerView.addSubview(button)
        return button
    }

    /// Puts the draft in the fields and the picks on the choice buttons, and turns Send on or off.
    private func applyDraft() {
        guard let card else { return }
        for (field, key) in zip(fields, fieldKeys) where field.text != draft.texts[key] {
            field.text = draft.texts[key]
        }
        var index = 0
        for question in card.openQuestions where !question.choices.isEmpty {
            let picked = draft.picks[question.qid] ?? []
            for choice in question.choices {
                guard index < choiceButtons.count else { return }
                styleChoice(choiceButtons[index], title: choice, picked: picked.contains(choice),
                            multi: question.multiSelect)
                index += 1
            }
        }
        sendButton?.isEnabled = draft.canSend(card)
    }

    private func styleChoice(_ button: UIButton, title: String, picked: Bool, multi: Bool) {
        var config: UIButton.Configuration = picked ? .filled() : .tinted()
        config.cornerStyle = .large
        config.contentInsets = ChatApprovalCardLayout.buttonPadding
        config.titleLineBreakMode = .byWordWrapping
        config.imagePadding = 6
        let font = ChatApprovalCardLayout.buttonFont(traits: cellTraits)
        config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: font]))
        let symbol = picked ? "checkmark.circle.fill" : (multi ? "square" : "circle")
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font))
        config.baseBackgroundColor = .systemBlue
        config.baseForegroundColor = picked ? .white : .systemBlue
        button.configuration = config
        button.contentHorizontalAlignment = .leading
        button.accessibilityTraits = picked ? [.button, .selected] : .button
    }

    @objc private func fieldChanged(_ field: ChatPromptField) {
        guard let index = fields.firstIndex(of: field) else { return }
        draft.texts[fieldKeys[index]] = field.text ?? ""
        sendButton?.isEnabled = card.map(draft.canSend) ?? false
        onDraftChange?(draft)
    }

    private func key(of textField: UITextField) -> String? {
        fields.firstIndex(where: { $0 === textField }).map { fieldKeys[$0] }
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        guard let key = key(of: textField) else { return }
        onFocus?(key)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        guard let key = key(of: textField) else { return }
        onBlur?(key)
    }

    /// Issue #117 (QA note): a reload of the thread builds new fields. The field of `key` takes the focus back as
    /// soon as the cell is in the window, so the keyboard stays up while the owner types.
    func restoreFocus(_ key: String) {
        pendingFocusKey = key
        setNeedsLayout()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let index = fields.firstIndex(where: { $0 === textField }), index + 1 < fields.count {
            fields[index + 1].becomeFirstResponder()
        } else {
            sendTapped()
        }
        return false
    }

    /// Send reads the draft, then empties every field, so no field holds the value after Send.
    func sendTapped() {
        guard let card, draft.canSend(card) else { return }
        let sent = draft
        clearFields()
        onSend?(sent)
    }

    func cancelTapped() {
        clearFields()
        onCancel?()
    }

    private func clearFields() {
        for field in fields {
            field.text = nil
            if field.isFirstResponder { field.resignFirstResponder() }
        }
        draft = ChatPromptDraft()
        sendButton?.isEnabled = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onDraftChange = nil
        onSend = nil
        onCancel = nil
        onFocus = nil
        onBlur = nil
        pendingFocusKey = nil
        removeControls()
        draft = ChatPromptDraft()
        card = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let card else { return }
        let frames = ChatPromptCardLayout.frames(card, traits: cellTraits, width: messageContainerView.bounds.width)
        titleLabel.frame = frames.title
        bodyLabel.frame = frames.body ?? .zero
        detailLabel.frame = frames.detail ?? .zero
        var question = 0
        var field = 0
        var choice = 0
        for (part, frame) in frames.parts {
            switch part {
            case .question:
                if question < questionLabels.count { questionLabels[question].frame = frame }
                question += 1
            case .field:
                if field < fields.count { fields[field].frame = frame }
                field += 1
            case .choice:
                if choice < choiceButtons.count { choiceButtons[choice].frame = frame }
                choice += 1
            }
        }
        cancelButton?.frame = frames.cancel ?? .zero
        sendButton?.frame = frames.send ?? .zero
        resultLabel.frame = frames.result ?? .zero
        if let key = pendingFocusKey, window != nil, let index = fieldKeys.firstIndex(of: key) {
            pendingFocusKey = nil
            fields[index].becomeFirstResponder()
        }
    }
}
