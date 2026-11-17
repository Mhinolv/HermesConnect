import HermesKit
import InputBarAccessoryView
import MessageKit
import Observation
import UIKit

/// The text thread (issue #6). A thin MessageKit view of `ChatViewModel`: it draws, the model decides.
final class ChatViewController: MessagesViewController {
    private let model: ChatViewModel
    private var bubbles: [ChatBubble] = []
    /// Styled text per message id. Built again when the text or the text size changes.
    private var textCache: [String: (source: String, size: UIContentSizeCategory, text: NSAttributedString)] = [:]
    private var announcedReplyId: String?
    /// The thread follows new text. A drag away from the bottom unpins it, and the `arrow.down` button shows.
    private var pinnedToBottom = true
    private let scrollButton = UIButton(configuration: .glass())
    private var composerText = ""
    /// Issue #8: the `plus` menu and the pending photos and files.
    private let attachments = AttachmentComposer()

    init(model: ChatViewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        messagesCollectionView.backgroundColor = .systemBackground
        messagesCollectionView.messagesDataSource = self
        messagesCollectionView.messagesLayoutDelegate = self
        messagesCollectionView.messagesDisplayDelegate = self
        messagesCollectionView.messageCellDelegate = self
        messagesCollectionView.register(ChatTextCell.self)
        messagesCollectionView.keyboardDismissMode = .interactive
        scrollsToLastItemOnKeyboardBeginsEditing = true
        maintainPositionOnInputBarHeightChanged = true
        configureLayout()
        configureComposer()
        configureAttachments()
        restoreDraft()
        configureScrollButton()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.textSizeChanged()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.updateComposerBorder()
        }
        announcedReplyId = model.completedReplyId
        render()
        observeModel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Empty session: no placeholder, the composer has focus. Not while the history loads (issue #7).
        if bubbles.isEmpty, !model.isLoadingHistory { messageInputBar.inputTextView.becomeFirstResponder() }
    }

    // MARK: Setup

    private var flowLayout: MessagesCollectionViewFlowLayout? {
        messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout
    }

    private func configureLayout() {
        guard let layout = flowLayout else { return }
        // No avatars, no sender names.
        layout.setMessageIncomingAvatarSize(.zero)
        layout.setMessageOutgoingAvatarSize(.zero)
        layout.setMessageIncomingMessagePadding(UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 56))
        layout.setMessageOutgoingMessagePadding(UIEdgeInsets(top: 0, left: 56, bottom: 0, right: 10))
        layout.setMessageOutgoingAccessoryViewSize(CGSize(width: 24, height: 24))
        layout.setMessageOutgoingAccessoryViewPadding(HorizontalEdgeInsets(left: 0, right: 6))
        layout.setMessageIncomingMessageBottomLabelAlignment(
            LabelAlignment(textAlignment: .left, textInsets: UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)))
        layout.setMessageOutgoingMessageBottomLabelAlignment(
            LabelAlignment(textAlignment: .right, textInsets: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 18)))
        let statusAlignment = LabelAlignment(textAlignment: .left,
                                             textInsets: UIEdgeInsets(top: 2, left: 18, bottom: 6, right: 0))
        layout.setMessageIncomingCellBottomLabelAlignment(statusAlignment)
        layout.setMessageOutgoingCellBottomLabelAlignment(statusAlignment)
        let header = LabelAlignment(textAlignment: .center, textInsets: .zero)
        layout.setMessageIncomingCellTopLabelAlignment(header)
        layout.setMessageOutgoingCellTopLabelAlignment(header)
        layout.sectionInset = UIEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)
    }

    private func configureComposer() {
        let bar = messageInputBar
        bar.delegate = self
        bar.separatorLine.isHidden = true
        bar.backgroundView.backgroundColor = .clear
        let glass = UIVisualEffectView(effect: UIGlassEffect())
        glass.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundView.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: bar.backgroundView.topAnchor),
            glass.bottomAnchor.constraint(equalTo: bar.backgroundView.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: bar.backgroundView.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: bar.backgroundView.trailingAnchor),
        ])
        bar.padding = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.middleContentViewPadding = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)

        let textView = bar.inputTextView
        textView.placeholder = "Message"
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.placeholderLabel.font = .preferredFont(forTextStyle: .body)
        textView.placeholderLabel.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.layer.cornerRadius = 18
        textView.layer.borderWidth = 1
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        textView.placeholderLabelInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        textView.accessibilityLabel = "Message"
        updateComposerBorder()

        // The text view grows to 6 lines, then scrolls.
        bar.shouldAutoUpdateMaxTextViewHeight = false
        bar.shouldManageSendButtonEnabledState = false
        updateMaxTextViewHeight()

        let send = bar.sendButton
        send.title = nil
        send.setSize(CGSize(width: 36, height: 36), animated: false)
        send.tintColor = .systemBlue
        send.imageView?.contentMode = .scaleAspectFit
        bar.setRightStackViewWidthConstant(to: 36, animated: false)
        attachments.install(in: bar, presenter: self)
        updateSendButton()
    }

    private func configureAttachments() {
        attachments.onChange = { [weak self] in self?.updateSendButton() }
        attachments.sendNow = { [weak self] text, items in self?.model.send(text, attachments: items) }
        AttachmentThumbnails.onReady[ObjectIdentifier(self)] = { [weak self] in self?.thumbnailsReady() }
    }

    /// A photo thumbnail finished decoding: put it in the visible photo bubbles.
    private func thumbnailsReady() {
        for case let cell as MediaMessageCell in messagesCollectionView.visibleCells {
            guard let indexPath = messagesCollectionView.indexPath(for: cell),
                  let item = bubble(at: indexPath)?.part.attachment else { continue }
            cell.imageView.image = AttachmentThumbnails.image(for: item)
        }
    }

    /// The draft of this session (issue #7) goes back into the composer.
    private func restoreDraft() {
        let draft = model.draft
        guard !draft.isEmpty else { return }
        messageInputBar.inputTextView.text = draft
        composerText = draft
        updateSendButton()
    }

    private func configureScrollButton() {
        var config = UIButton.Configuration.glass()
        config.image = UIImage(systemName: "arrow.down")
        config.cornerStyle = .capsule
        scrollButton.configuration = config
        scrollButton.accessibilityLabel = "Scroll to Bottom"
        scrollButton.translatesAutoresizingMaskIntoConstraints = false
        scrollButton.isHidden = true
        scrollButton.addAction(UIAction { [weak self] _ in
            self?.pinnedToBottom = true
            self?.scrollToBottom(animated: true)
            self?.updateScrollButton()
        }, for: .touchUpInside)
        view.addSubview(scrollButton)
        NSLayoutConstraint.activate([
            scrollButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            scrollButton.bottomAnchor.constraint(equalTo: inputContainerView.topAnchor, constant: -12),
            scrollButton.widthAnchor.constraint(equalToConstant: 44),
            scrollButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func updateComposerBorder() {
        messageInputBar.inputTextView.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    private func updateMaxTextViewHeight() {
        let textView = messageInputBar.inputTextView
        let lineHeight = (textView.font ?? .preferredFont(forTextStyle: .body)).lineHeight
        messageInputBar.maxTextViewHeight = (lineHeight * 6 + textView.textContainerInset.top
            + textView.textContainerInset.bottom).rounded(.up)
    }

    /// Send while there is text. Stop while a reply runs and the text is empty (owner decision 2026-11-16).
    private var showsStop: Bool {
        model.isReplyActive && composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !attachments.hasPending
    }

    private func updateSendButton() {
        let send = messageInputBar.sendButton
        let symbol = UIImage.SymbolConfiguration(pointSize: 32)
        if showsStop {
            send.image = UIImage(systemName: "stop.circle.fill", withConfiguration: symbol)
            send.tintColor = .label
            send.isEnabled = true
            send.accessibilityLabel = "Stop"
        } else {
            send.image = UIImage(systemName: "arrow.up.circle.fill", withConfiguration: symbol)
            send.tintColor = .systemBlue
            // Issue #8: pending attachments also send, with no text.
            send.isEnabled = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || attachments.hasPending
            send.accessibilityLabel = "Send"
        }
    }

    private func textSizeChanged() {
        pinnedToBottom = true
        updateMaxTextViewHeight()
        textCache = [:]
        bubbles = []
        render()
    }

    // MARK: Model

    private func observeModel() {
        withObservationTracking {
            _ = model.messages
            _ = model.turn
            _ = model.statusLine
            _ = model.completedReplyId
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.render()
                self?.observeModel()
            }
        }
    }

    private func styledText(for message: ChatMessage) -> NSAttributedString {
        let size = traitCollection.preferredContentSizeCategory
        if let cached = textCache[message.id], cached.source == message.text, cached.size == size {
            return cached.text
        }
        let text = ChatBubbleText.make(message, traits: traitCollection)
        textCache[message.id] = (message.text, size, text)
        return text
    }

    private func makeBubble(_ part: ChatBubblePart) -> ChatBubble {
        guard let item = part.attachment else { return ChatBubble(part: part, text: styledText(for: part.row.message)) }
        if item.showsAsImage {
            return ChatBubble(part: part, text: NSAttributedString(), thumbnail: AttachmentThumbnails.image(for: item))
        }
        let text = AttachmentFileText.make(item, outgoing: part.row.message.role == .user, traits: traitCollection)
        return ChatBubble(part: part, text: text)
    }

    private func render() {
        guard isViewLoaded else { return }
        let rows = ChatTimeline.rows(for: model.messages, statusLine: model.statusLine)
        let next = ChatBubbleParts.parts(for: rows).map(makeBubble)
        let old = bubbles
        let newOutgoing = next.last.map { last in
            last.row.message.role == .user && !old.contains { $0.row.id == last.row.id }
        } ?? false

        // The typing indicator changes against the old data, so the section counts stay valid.
        let showsTyping = model.turn == .typing
        if isTypingIndicatorHidden == showsTyping {
            setTypingIndicatorViewHidden(!showsTyping, animated: false)
        }

        bubbles = next
        if old.map(\.messageId) == next.map(\.messageId) {
            let changed = next.indices.filter { old[$0].row != next[$0].row }
            if !changed.isEmpty {
                UIView.performWithoutAnimation {
                    messagesCollectionView.reloadSections(IndexSet(changed))
                }
            }
        } else {
            messagesCollectionView.reloadData()
        }
        textCache = textCache.filter { id, _ in next.contains { $0.row.id == id } }

        if pinnedToBottom || newOutgoing {
            pinnedToBottom = true
            scrollToBottom()
        }
        updateScrollButton()
        updateSendButton()
        announceCompletedReply()
    }

    /// VoiceOver reads a reply once, when it ends.
    private func announceCompletedReply() {
        guard let id = model.completedReplyId, id != announcedReplyId else { return }
        announcedReplyId = id
        guard UIAccessibility.isVoiceOverRunning,
              let message = model.messages.first(where: { $0.id == id }), !message.text.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: "Hermes, \(message.text)")
    }

    private func updateScrollButton() {
        scrollButton.isHidden = pinnedToBottom || bubbles.isEmpty
    }

    /// Puts the end of the last bubble just above the composer. MessageKit sets the composer inset after
    /// layout, so this runs again on each layout and inset change while the thread is pinned (QA #25 defect 1).
    private func scrollToBottom(animated: Bool = false) {
        let collection = messagesCollectionView
        guard collection.bounds.height > 0, !collection.isDragging, !collection.isDecelerating else { return }
        collection.layoutIfNeeded()
        let target = ChatScroll.bottomOffset(contentHeight: collection.contentSize.height,
                                             viewHeight: collection.bounds.height,
                                             insets: collection.adjustedContentInset)
        guard abs(collection.contentOffset.y - target) > 0.5 else { return }
        collection.setContentOffset(CGPoint(x: collection.contentOffset.x, y: target), animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if pinnedToBottom { scrollToBottom() }
    }

    override func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        super.scrollViewDidChangeAdjustedContentInset(scrollView)
        // MessageKit changes the inset inside its own update. A scroll in this call is lost, so run it next.
        guard pinnedToBottom else { return }
        Task { @MainActor [weak self] in
            guard let self, self.pinnedToBottom else { return }
            self.scrollToBottom()
        }
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)
        // Only the owner's scroll changes the pin. Layout and inset changes do not.
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        let pinned = ChatScroll.isNearBottom(offset: scrollView.contentOffset.y,
                                             contentHeight: scrollView.contentSize.height,
                                             viewHeight: scrollView.bounds.height,
                                             insets: scrollView.adjustedContentInset)
        if pinned != pinnedToBottom {
            pinnedToBottom = pinned
            updateScrollButton()
        }
    }

    /// The pin state (tests).
    var isPinnedToBottom: Bool { pinnedToBottom }

    /// The attachment composer (tests).
    var attachmentComposer: AttachmentComposer? { attachments }

    // MARK: Rows

    private func bubble(at indexPath: IndexPath) -> ChatBubble? {
        bubbles.indices.contains(indexPath.section) ? bubbles[indexPath.section] : nil
    }

    private func row(for message: MessageType) -> ChatRow? {
        (message as? ChatBubble)?.row
    }

    override func collectionView(_ collectionView: UICollectionView,
                                 cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = super.collectionView(collectionView, cellForItemAt: indexPath)
        guard let part = bubble(at: indexPath)?.part else { return cell }
        let row = part.row
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = ChatBubbleParts.accessibilityLabel(for: part)
        cell.accessibilityHint = switch row.footnote {
        case .notDelivered: "Double-tap for options."
        case .replyFailed: "Double-tap to retry."
        default: nil
        }
        var actions = [UIAccessibilityCustomAction(name: "Copy") { _ in
            UIPasteboard.general.string = row.message.text
            return true
        }]
        for run in ChatMarkdown.runs(row.message.text) {
            guard let url = run.link else { continue }
            actions.append(UIAccessibilityCustomAction(name: "Open \(run.text)") { _ in
                UIApplication.shared.open(url)
                return true
            })
        }
        cell.accessibilityCustomActions = actions
        return cell
    }

    // MARK: Menus

    override func collectionView(_: UICollectionView, shouldShowMenuForItemAt _: IndexPath) -> Bool {
        false
    }

    /// Long press: "Copy". A bubble that was not delivered also gets "Try Again" and "Delete".
    @objc func collectionView(_ collectionView: UICollectionView,
                              contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                              point _: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let part = bubble(at: indexPath)?.part else { return nil }
        let row = part.row
        return UIContextMenuConfiguration(identifier: indexPath as NSIndexPath, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = [UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                if let item = part.attachment, item.showsAsImage {
                    UIPasteboard.general.image = UIImage(contentsOfFile: item.fileURL.path)
                } else {
                    UIPasteboard.general.string = part.attachment?.name ?? row.message.text
                }
            }]
            if row.message.delivery == .failed, let self {
                actions += self.sendFailureActions(for: row)
            }
            return UIMenu(children: actions)
        }
    }

    @objc func collectionView(_ collectionView: UICollectionView,
                              contextMenuConfiguration configuration: UIContextMenuConfiguration,
                              highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: indexPath) as? MessageContentCell else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: cell.messageContainerView, parameters: parameters)
    }

    private func sendFailureActions(for row: ChatRow) -> [UIAction] {
        let id = row.id
        return [
            UIAction(title: "Try Again", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.model.retrySend(id: id)
            },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.model.delete(id: id)
            },
        ]
    }

    private func showSendFailureOptions(for row: ChatRow, from cell: UIView) {
        let sheet = UIAlertController(title: nil, message: "Your message was not delivered.", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in
            self?.model.retrySend(id: row.id)
        })
        sheet.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.model.delete(id: row.id)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell
        present(sheet, animated: true)
    }

    private func handleTap(in cell: MessageCollectionViewCell) {
        guard let indexPath = messagesCollectionView.indexPath(for: cell), let row = bubble(at: indexPath)?.row else {
            return
        }
        // Issue #8: each part of a message that was not delivered opens the options.
        if row.message.delivery == .failed {
            showSendFailureOptions(for: row, from: cell)
            return
        }
        switch row.footnote {
        case .notDelivered: showSendFailureOptions(for: row, from: cell)
        case .replyFailed: model.retryReply(id: row.id)
        default: break
        }
    }
}

// MARK: - Scroll math

/// Where "the bottom" of the thread is. Plain math, so tests cover every inset and text size.
enum ChatScroll {
    /// The content offset that shows the end of the content just above the bottom inset (the composer).
    /// Short content stays at the top.
    static func bottomOffset(contentHeight: CGFloat, viewHeight: CGFloat, insets: UIEdgeInsets) -> CGFloat {
        max(-insets.top, contentHeight - viewHeight + insets.bottom)
    }

    static func isNearBottom(offset: CGFloat, contentHeight: CGFloat, viewHeight: CGFloat, insets: UIEdgeInsets,
                             tolerance: CGFloat = 40) -> Bool {
        offset >= bottomOffset(contentHeight: contentHeight, viewHeight: viewHeight, insets: insets) - tolerance
    }
}

// MARK: - Text styles

private enum ChatLabelStyle {
    static func font(_ style: UIFont.TextStyle, _ traits: UITraitCollection) -> UIFont {
        .preferredFont(forTextStyle: style, compatibleWith: traits)
    }

    static func height(_ style: UIFont.TextStyle, _ traits: UITraitCollection, padding: CGFloat) -> CGFloat {
        (font(style, traits).lineHeight + padding).rounded(.up)
    }
}

// MARK: - MessageKit data source

extension ChatViewController: MessagesDataSource {
    var currentSender: SenderType { ChatSender.owner }

    func numberOfSections(in _: MessagesCollectionView) -> Int { bubbles.count }

    func messageForItem(at indexPath: IndexPath, in _: MessagesCollectionView) -> MessageType {
        bubbles[indexPath.section]
    }

    func cellTopLabelAttributedText(for message: MessageType, at _: IndexPath) -> NSAttributedString? {
        guard let date = row(for: message)?.timeHeader else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: ChatTimeline.headerText(for: date), attributes: [
            .font: ChatLabelStyle.font(.caption2, traitCollection), .foregroundColor: UIColor.secondaryLabel,
            .paragraphStyle: paragraph,
        ])
    }

    func messageBottomLabelAttributedText(for message: MessageType, at _: IndexPath) -> NSAttributedString? {
        guard let footnote = row(for: message)?.footnote else { return nil }
        return NSAttributedString(string: footnote.text, attributes: [
            .font: ChatLabelStyle.font(.caption2, traitCollection),
            .foregroundColor: footnote.isError ? UIColor.systemRed : UIColor.secondaryLabel,
        ])
    }

    func cellBottomLabelAttributedText(for message: MessageType, at _: IndexPath) -> NSAttributedString? {
        guard let line = row(for: message)?.statusLine else { return nil }
        return NSAttributedString(string: line, attributes: [
            .font: ChatLabelStyle.font(.caption1, traitCollection), .foregroundColor: UIColor.secondaryLabel,
        ])
    }

    func textCell(for message: MessageType, at indexPath: IndexPath,
                  in messagesCollectionView: MessagesCollectionView) -> UICollectionViewCell? {
        let cell = messagesCollectionView.dequeueReusableCell(ChatTextCell.self, for: indexPath)
        cell.configure(with: message, at: indexPath, and: messagesCollectionView)
        cell.openLink = { url in UIApplication.shared.open(url) }
        return cell
    }
}

// MARK: - MessageKit layout

extension ChatViewController: MessagesLayoutDelegate {
    func cellTopLabelHeight(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        row(for: message)?.timeHeader == nil ? 0 : ChatLabelStyle.height(.caption2, traitCollection, padding: 18)
    }

    func messageBottomLabelHeight(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        row(for: message)?.footnote == nil ? 0 : ChatLabelStyle.height(.caption2, traitCollection, padding: 4)
    }

    func cellBottomLabelHeight(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        row(for: message)?.statusLine == nil ? 0 : ChatLabelStyle.height(.caption1, traitCollection, padding: 12)
    }

    func messageTopLabelHeight(for _: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> CGFloat { 0 }
}

// MARK: - MessageKit display

extension ChatViewController: MessagesDisplayDelegate {
    func messageStyle(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> MessageStyle {
        guard let row = row(for: message), row.hasTail else { return .bubble }
        return .bubbleTail(row.message.role == .user ? .bottomRight : .bottomLeft, .curved)
    }

    func backgroundColor(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> UIColor {
        row(for: message)?.message.role == .user ? .systemBlue : .systemGray5
    }

    func configureAvatarView(_ avatarView: AvatarView, for _: MessageType, at _: IndexPath,
                             in _: MessagesCollectionView) {
        avatarView.isHidden = true
    }

    func configureAccessoryView(_ accessoryView: UIView, for message: MessageType, at _: IndexPath,
                                in _: MessagesCollectionView) {
        accessoryView.subviews.forEach { $0.removeFromSuperview() }
        // Issue #8: a file part shows a spinner until its attach call returns.
        if let bubble = message as? ChatBubble, let item = bubble.part.attachment, !item.showsAsImage,
           Self.isUploading(item, in: bubble.row) {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.frame = accessoryView.bounds
            spinner.startAnimating()
            accessoryView.addSubview(spinner)
            return
        }
        guard row(for: message)?.footnote == .notDelivered else { return }
        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
        icon.tintColor = .systemRed
        icon.contentMode = .scaleAspectFit
        icon.frame = accessoryView.bounds
        icon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        icon.isAccessibilityElement = false
        accessoryView.addSubview(icon)
    }

    func enabledDetectors(for _: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> [DetectorType] { [] }

    /// Issue #8: the progress ring on a photo bubble until its attach call returns.
    func configureMediaMessageImageView(_ imageView: UIImageView, for message: MessageType, at _: IndexPath,
                                        in _: MessagesCollectionView) {
        guard let bubble = message as? ChatBubble, let item = bubble.part.attachment else { return }
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = .secondarySystemFill
        AttachmentProgressRing.update(on: imageView, uploading: Self.isUploading(item, in: bubble.row),
                                      failed: item.upload == .failed)
    }

    /// The attach call runs, or waits for its turn while the message sends.
    static func isUploading(_ item: ChatAttachment, in row: ChatRow) -> Bool {
        item.upload == .uploading || (item.upload == .pending && row.message.delivery == .sending)
    }
}

// MARK: - Taps

extension ChatViewController: @preconcurrency MessageCellDelegate {
    func didTapMessage(in cell: MessageCollectionViewCell) { handleTap(in: cell) }
    func didTapMessageBottomLabel(in cell: MessageCollectionViewCell) { handleTap(in: cell) }
    func didTapAccessoryView(in cell: MessageCollectionViewCell) { handleTap(in: cell) }
    func didTapImage(in cell: MessageCollectionViewCell) { handleTap(in: cell) }
}

// MARK: - Composer

extension ChatViewController: InputBarAccessoryViewDelegate {
    func inputBar(_ inputBar: InputBarAccessoryView, didPressSendButtonWith text: String) {
        if showsStop {
            model.stop()
            return
        }
        guard model.send(text, attachments: attachments.pending) != nil else { return }
        _ = attachments.takeAll()
        inputBar.inputTextView.text = ""
        composerText = ""
        model.updateDraft("")
        updateSendButton()
    }

    func inputBar(_: InputBarAccessoryView, textViewTextDidChangeTo text: String) {
        composerText = text
        model.updateDraft(text)
        updateSendButton()
    }
}
