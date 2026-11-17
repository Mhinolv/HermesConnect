import HermesKit
import InputBarAccessoryView
import MessageKit
import Observation
import QuickLook
import UIKit

/// The text thread (issue #6) with voice memos (issue #9). A thin MessageKit view of `ChatViewModel`:
/// it draws, the model decides.
final class ChatViewController: MessagesViewController {
    private let model: ChatViewModel
    /// The mic button, the recording bar and the recorder (issue #9).
    let voice: VoiceMemoController
    private let player = VoiceMemoPlayer()
    private let micButton = InputBarButtonItem()
    private let recordingBar = VoiceRecordingBar()
    private lazy var micPress = UILongPressGestureRecognizer(target: self, action: #selector(micPressChanged(_:)))
    private let micPressDelegate = MicPressDelegate()
    private var micPressStart: CGPoint = .zero
    private var voiceCalculator: ChatVoiceSizeCalculator?
    /// Issue #67: the size of a command card.
    private var commandCalculator: ChatVoiceSizeCalculator?
    /// Issue #67: the last composer text that the model gave.
    private var handledComposerFillId: String?
    /// Memos whose transcript shows all lines.
    private var expandedTranscripts: Set<String> = []
    /// DEBUG demo: runs once when the screen shows (recording bar screenshots).
    var onFirstAppear: ((ChatViewController) -> Void)?
    private var bubbles: [ChatBubble] = []
    /// Styled text per message id. Built again when the text, the text size or the thread width changes.
    private var textCache: [String: (key: TextKey, text: NSAttributedString)] = [:]
    private struct TextKey: Equatable {
        let source: String
        let size: UIContentSizeCategory
        let width: CGFloat
        let streaming: Bool
        let quote: ChatQuote?
    }
    /// Issue #56: the thread width of the bubble text. A table is a grid only when it fits.
    private var textWidth: CGFloat = 0
    /// Issue #56: a streaming reply does not get shorter while a table row completes.
    private var streamingHeights = ChatStreamingHeights()
    private var announcedReplyId: String?
    /// Issue #10: the last voice reply that the screen auto-played, or chose not to play.
    private var handledAutoPlayId: String?
    /// "Auto-Play Voice Replies" in Settings > Voice. Tests set it.
    var autoPlayEnabled: () -> Bool = { VoiceReplySettings.autoPlay() }
    /// The thread follows new text. A drag away from the bottom unpins it, and the `arrow.down` button shows.
    private var pinnedToBottom = true
    private let scrollButton = UIButton(configuration: .glass())
    /// Issue #15: the glass pill "3 New Messages" after a catch-up, when the owner was not at the bottom.
    private let newMessagesButton = UIButton(configuration: .glass())
    /// The first new message of the catch-up that the screen handled (scrolled to, or showed the pill for).
    private var handledNewMessageId: String?
    private var composerText = ""
    /// Issue #60: the space under the composer field. `updateComposerBottom()` sets it from the window.
    private var composerBottom: NSLayoutConstraint?
    /// Issue #8: the `plus` menu and the pending photos and files.
    private let attachments = AttachmentComposer()
    /// Issue #68: the slash command suggestions above the field.
    let slashSuggestions = SlashSuggestionComposer()
    /// Issue #11: the symbol that each badge showed last ("<message id>#ack"), for the `.replace` change.
    private var shownBadges: [String: String] = [:]
    /// Issue #11: the open tapback capsule (double-tap).
    private(set) var tapbackPicker: TapbackPickerView?
    private lazy var doubleTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        gesture.numberOfTapsRequired = 2
        return gesture
    }()
    /// Issue #65: a single tap on the thread hides the keyboard. It waits for the double-tap.
    private lazy var hideKeyboardTap = UITapGestureRecognizer(target: self, action: #selector(threadTapped))
    private let hideKeyboardTapDelegate = HideKeyboardTapDelegate()
    /// Issue #12: what to do with a received file when its download ends (a tap or a menu action started it).
    private var pendingFileActions: [String: ReceivedFileAction] = [:]
    /// Issue #12: the Quick Look data source. Quick Look keeps only a weak reference.
    private var filePreview: ReceivedFilePreview?
    /// Issue #12: `true` while bubbles are built. A state change in that time is part of the same render.
    private var buildingBubbles = false
    /// Issue #73: the cron run screen. No composer and no tapbacks. "Copy" stays.
    let readOnly: Bool
    /// Issue #50: the on-device transcripts of received audio files. Tests and the DEBUG demo set a fake first.
    lazy var audioTranscripts = ReceivedAudioTranscripts(files: model.receivedFiles,
                                                         transcription: OnDeviceTranscription.shared.transcription,
                                                         permission: SystemSpeechPermission())
    /// Issue #17: the quote box above the text view, the swipe to reply, and "Original message not loaded".
    let quoteView = QuoteComposerView()
    private let swipeReply = ChatSwipeReply()
    private let noticePill = ChatNoticePill()

    init(model: ChatViewModel, recorder: any VoiceRecording = AVVoiceRecorder(),
         voiceFolder: URL = VoiceMemoFiles.directory(), readOnly: Bool = false) {
        self.model = model
        self.readOnly = readOnly
        self.voice = VoiceMemoController(recorder: recorder, folder: voiceFolder)
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
        messagesCollectionView.register(ChatVoiceCell.self)
        messagesCollectionView.register(ChatCommandCell.self)
        messagesCollectionView.keyboardDismissMode = .interactive
        scrollsToLastItemOnKeyboardBeginsEditing = true
        maintainPositionOnInputBarHeightChanged = true
        // Issue #60: 10 pt between the last bubble and the composer, keyboard up or down (iMessage).
        additionalBottomInset = ChatComposerLayout.threadGap
        configureLayout()
        audioTranscripts.onChange = { [weak self] file in self?.audioTranscriptChanged(file) }
        if readOnly {
            // Issue #73: an empty input bar of no height, so the thread goes to the bottom of the screen.
            // MessageKit swaps the bar on the next main queue turn. Take the composer out now, so it never shows.
            let empty = UIView(frame: .zero)
            empty.heightAnchor.constraint(equalToConstant: 0).isActive = true
            inputBarType = .custom(empty)
            messageInputBar.removeFromSuperview()
        } else {
            configureComposer()
            configureAttachments()
            configureReply()
            configureVoice()
            restoreDraft()
        }
        configureScrollButton()
        if !readOnly {
            configureTapbacks()
            configureKeyboardDismiss()
        }
        configureNewMessagesButton()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.textSizeChanged()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.updateComposerBorder()
        }
        announcedReplyId = model.completedReplyId
        // A reply that got its audio before this screen opened does not play now.
        handledAutoPlayId = model.autoPlayReplyId
        handledComposerFillId = model.composerFill?.id
        render()
        observeModel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Empty session: no placeholder, the composer has focus. Not while the history loads (issue #7)
        // or while a memo records (issue #9).
        if !readOnly, bubbles.isEmpty, !model.isLoadingHistory, !voice.isActive {
            messageInputBar.inputTextView.becomeFirstResponder()
        }
        if let first = onFirstAppear {
            onFirstAppear = nil
            first(self)
        }
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
        // Issue #49: the space between bubbles comes from `insetForSectionAt` (2 pt in a group, 10 pt between groups).
        layout.sectionInset = .zero
        let voiceCalculator = ChatVoiceSizeCalculator(layout: layout, copying: layout.attributedTextMessageSizeCalculator)
        voiceCalculator.bubbleSize = { [weak self] _, maxWidth in
            ChatVoiceLayout.bubbleSize(traits: self?.traitCollection ?? .current, maxWidth: maxWidth)
        }
        self.voiceCalculator = voiceCalculator
        let commandCalculator = ChatVoiceSizeCalculator(layout: layout,
                                                        copying: layout.attributedTextMessageSizeCalculator)
        commandCalculator.bubbleSize = { [weak self] message, maxWidth in
            guard let card = (message as? ChatBubble)?.row.message.command else { return .zero }
            return ChatCommandCardLayout.size(card, traits: self?.traitCollection ?? .current, maxWidth: maxWidth)
        }
        self.commandCalculator = commandCalculator
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
        installComposerBottom()

        let textView = bar.inputTextView
        textView.placeholder = "Message"
        // Issue #60: a safe area under the composer does not move the text in the field.
        textView.contentInsetAdjustmentBehavior = .never
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.placeholderLabel.font = .preferredFont(forTextStyle: .body)
        textView.placeholderLabel.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.layer.cornerRadius = 18
        textView.layer.borderWidth = 1
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
        slashSuggestions.install(in: bar)
        updateSendButton()
    }

    /// Issue #60: the composer does not use its own safe area for the space under the field. With the keyboard up,
    /// that safe area kept the 34 pt home indicator inset, so the composer had a band on the keyboard.
    /// The space comes from the window instead (`updateComposerBottom()`).
    private func installComposerBottom() {
        let bar = messageInputBar
        dropSafeAreaBottom()
        let bottom = bar.contentView.bottomAnchor.constraint(lessThanOrEqualTo: bar.bottomAnchor,
                                                             constant: -bar.padding.bottom)
        bottom.isActive = true
        composerBottom = bottom
    }

    /// The input bar activates its safe area constraint again each time it moves to a superview.
    private func dropSafeAreaBottom() {
        let bar = messageInputBar
        for constraint in bar.constraints where constraint.isActive && constraint.firstItem === bar.contentView
            && constraint.firstAttribute == .bottom && constraint.secondItem === bar.safeAreaLayoutGuide {
            constraint.isActive = false
        }
    }

    /// Keyboard down: the padding plus the home indicator. Keyboard up: only the padding. During the keyboard
    /// animation and the interactive dismissal, the composer frame gives the part over the home indicator.
    private func updateComposerBottom() {
        guard let bottom = composerBottom, let window = view.window else { return }
        dropSafeAreaBottom()
        let composer = inputContainerView.convert(inputContainerView.bounds, to: window)
        let space = ChatComposerLayout.bottomSpace(padding: messageInputBar.padding.bottom, composerMaxY: composer.maxY,
                                                   windowHeight: window.bounds.height,
                                                   homeIndicator: window.safeAreaInsets.bottom)
        guard abs(bottom.constant + space) > 0.5 else { return }
        bottom.constant = -space
        view.layoutIfNeeded()
    }

    private func configureAttachments() {
        model.receivedFiles.onChange = { [weak self] file in self?.receivedFileChanged(file) }
        attachments.onChange = { [weak self] in self?.updateSendButton() }
        attachments.sendNow = { [weak self] text, items in self?.model.send(text, attachments: items) }
        AttachmentThumbnails.onReady[ObjectIdentifier(self)] = { [weak self] in self?.thumbnailsReady() }
    }

    /// A photo thumbnail finished decoding: put it in the visible photo bubbles.
    private func thumbnailsReady() {
        for case let cell as MediaMessageCell in messagesCollectionView.visibleCells {
            guard let indexPath = messagesCollectionView.indexPath(for: cell), let part = bubble(at: indexPath)?.part
            else { continue }
            if let item = part.attachment {
                cell.imageView.image = AttachmentThumbnails.image(for: item)
            } else if let file = part.receivedFile, let url = model.receivedFiles.state(for: file).fileURL {
                // Issue #12: a downloaded image. Its bubble already has the right size.
                cell.imageView.image = AttachmentThumbnails.image(for: ReceivedPhotoItem.thumbnailItem(file, url: url))
            }
        }
    }

    private func configureVoice() {
        let symbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: symbol), for: .normal)
        micButton.setSize(CGSize(width: ChatComposerLayout.control, height: ChatComposerLayout.control), animated: false)
        micButton.tintColor = .white
        micButton.backgroundColor = .systemBlue
        micButton.layer.cornerRadius = 22
        micButton.accessibilityLabel = "Record Voice Memo"
        micButton.accessibilityHint = "Starts a recording. Double-tap Send to send it."
        // Touches go to `micPress`. VoiceOver activation, and a touch the recognizer missed, start tap mode.
        micButton.onTouchUpInside { [weak self] _ in self?.voice.startTapMode() }

        micPressDelegate.shouldReceive = { [weak self] touch in self?.micPressShouldReceive(touch) ?? false }
        micPress.minimumPressDuration = 0
        micPress.delegate = micPressDelegate
        messageInputBar.addGestureRecognizer(micPress)

        recordingBar.onCancel = { [weak self] in self?.voice.cancel() }
        recordingBar.onSend = { [weak self] in self?.voice.send() }
        voice.onChange = { [weak self] in self?.updateRecordingBar() }
        voice.onSend = { [weak self] memo in
            self?.pinnedToBottom = true
            self?.model.sendVoiceMemo(memo)
        }
        voice.onAccessDenied = { [weak self] in self?.showMicrophoneOff() }
        voice.onRecordFailed = { [weak self] in self?.showRecordFailed() }
        player.onChange = { [weak self] in self?.reloadVoiceRows() }
        player.onProgress = { [weak self] url, time, _ in self?.showProgress(url: url, time: time) }
        player.onFailure = { [weak self] url in self?.playbackFailed(url: url) }
        updateSendButton()
    }

    /// The 64 pt hit area of the 44 pt mic (driving use). VoiceOver uses the button activation instead.
    private func micPressShouldReceive(_ touch: UITouch) -> Bool {
        guard showsMic, !voice.isActive, !UIAccessibility.isVoiceOverRunning, micButton.window != nil else {
            return false
        }
        let area = micButton.convert(micButton.bounds, to: messageInputBar).insetBy(dx: -10, dy: -10)
        return area.contains(touch.location(in: messageInputBar))
    }

    @objc private func micPressChanged(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            micPressStart = point
            player.stop()
            voice.press()
        case .changed:
            voice.drag(dx: Double(point.x - micPressStart.x))
        case .ended:
            voice.release()
        case .cancelled, .failed:
            voice.touchCancelled()
        default:
            break
        }
    }

    /// The recording bar takes the place of the text view while a memo records.
    private func updateRecordingBar() {
        let bar = messageInputBar
        let capture = voice.capture
        guard capture.isActive else {
            if bar.middleContentView === recordingBar {
                attachments.setPlusShown(true)
                bar.setMiddleContentView(bar.inputTextView, animated: false)
                updateSendButton()
                UIAccessibility.post(notification: .layoutChanged, argument: micButton)
            }
            return
        }
        if bar.middleContentView !== recordingBar {
            player.stop()
            bar.inputTextView.resignFirstResponder()
            bar.setStackViewItems([], forStack: .right, animated: false)
            bar.setRightStackViewWidthConstant(to: 0, animated: false)
            // Issue #49: like iMessage, the `+` button hides while a memo records.
            attachments.setPlusShown(false)
            bar.setMiddleContentView(recordingBar, animated: false)
            UIAccessibility.post(notification: .layoutChanged, argument: recordingBar.sendButton)
        }
        let mode: VoiceRecordingBar.Mode = switch capture.phase {
        case .pressed, .holding: .hold(cancelProgress: capture.cancelProgress)
        case .paused: .paused
        case .recording, .idle: .tap
        }
        recordingBar.update(mode: mode, elapsed: voice.elapsed, levels: voice.levels)
    }

    /// The recording bar (tests).
    var recordingBarMode: VoiceRecordingBar.Mode? {
        messageInputBar.middleContentView === recordingBar ? recordingBar.mode : nil
    }

    private func showMicrophoneOff() {
        let alert = UIAlertController(title: "Microphone Access Off",
                                      message: "Turn on Microphone for Hermes in Settings to record voice memos.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let open = UIAlertAction(title: "Open Settings", style: .default) { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
        alert.addAction(open)
        alert.preferredAction = open
        present(alert, animated: true)
    }

    private func showRecordFailed() {
        let alert = UIAlertController(title: "Can't Record", message: "Another app may use the microphone. Try again.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func togglePlay(id: String) {
        guard !voice.isActive, let message = model.messages.first(where: { $0.id == id }) else { return }
        if let memo = message.voice {
            player.toggle(memo.fileURL)
            return
        }
        // Issue #10: a voice reply. The cached file plays with no network call. A failed one speaks again.
        switch message.spokenReply {
        case .ready(let audio): player.toggle(audio.fileURL)
        case .failed: model.retrySpeech(id: id)
        case .preparing, nil: break
        }
    }

    /// Issue #42: a voice reply that does not play shows "Audio unavailable. Tap to retry." A memo stays as is.
    private func playbackFailed(url: URL) {
        guard let reply = model.messages.first(where: { $0.spokenReply?.audio?.fileURL == url }) else { return }
        model.speechDidNotPlay(id: reply.id)
    }

    /// The file of the audio bubble of a row: a memo, a voice reply or a received audio file (issue #12).
    private func audioURL(of part: ChatBubblePart) -> URL? {
        if let memo = part.row.message.voice { return memo.fileURL }
        if let file = part.receivedFile, file.kind == .audio, model.receivedFiles.state(for: file).fileURL != nil {
            return model.receivedFiles.audio(for: file).audio?.fileURL
        }
        guard part.content == .spokenReply else { return nil }
        return part.row.message.spokenReply?.audio?.fileURL
    }

    /// Moves the progress bar of the visible reply bubble, with no reload.
    private func showProgress(url: URL, time: TimeInterval) {
        for case let cell as ChatVoiceCell in messagesCollectionView.visibleCells {
            guard let indexPath = messagesCollectionView.indexPath(for: cell), let part = bubble(at: indexPath)?.part,
                  audioURL(of: part) == url else { continue }
            cell.setProgress(time: time)
        }
    }

    /// Issue #10: a reply to a voice memo got its audio. It plays once if Auto-Play is on and no recording runs.
    /// A manual play or a new recording stops it (owner decision 2026-11-16).
    private func autoPlayVoiceReply() {
        guard let id = model.autoPlayReplyId, id != handledAutoPlayId else { return }
        handledAutoPlayId = id
        guard autoPlayEnabled(), !voice.isActive,
              let audio = model.messages.first(where: { $0.id == id })?.spokenReply?.audio else { return }
        player.play(audio.fileURL)
    }

    /// A tap on the audio bubble of a message (tests and the DEBUG demo).
    func tapAudio(id: String) { togglePlay(id: id) }

    /// `true` while the player plays (tests).
    var playerIsPlaying: Bool { player.isPlaying }

    /// The URL that the player has loaded (tests).
    var playerURL: URL? { player.playingURL }

    private func toggleTranscript(id: String) {
        guard model.messages.first(where: { $0.id == id })?.voice?.transcript.text != nil else { return }
        if expandedTranscripts.remove(id) == nil { expandedTranscripts.insert(id) }
        guard let index = bubbles.firstIndex(where: { $0.row.id == id }) else { return }
        UIView.performWithoutAnimation {
            messagesCollectionView.reloadSections(IndexSet(integer: index))
        }
    }

    private func reloadVoiceRows() {
        let rows = IndexSet(bubbles.indices.filter { audioURL(of: bubbles[$0].part) != nil })
        guard !rows.isEmpty else { return }
        UIView.performWithoutAnimation {
            messagesCollectionView.reloadSections(rows)
        }
    }

    /// The transcript under a memo, and its height at the bubble width.
    private func transcript(for row: ChatRow, message: MessageType, at indexPath: IndexPath)
        -> (text: NSAttributedString?, height: CGFloat, width: CGFloat)? {
        guard let calculator = voiceCalculator else { return nil }
        let text: NSAttributedString?
        if let voice = row.message.voice {
            // Issue #39: a queued memo is transcribed on connect. No "Transcribing…" while it waits.
            let waits = row.message.delivery == .queued && voice.transcript == .pending
            text = waits ? nil : ChatVoiceLayout.transcriptText(for: voice, traits: traitCollection)
        } else if (message as? ChatBubble)?.part.content == .spokenReply, let spoken = row.message.spokenReply {
            text = ChatVoiceLayout.replyCaption(for: spoken, text: row.message.text, traits: traitCollection)
        } else if let bubble = message as? ChatBubble, let file = bubble.part.receivedFile {
            // Issue #50: the transcript line under a received audio bubble.
            guard let state = audioTranscriptState(bubble, file: file) else { return nil }
            text = ReceivedAudioTranscriptText.make(state, traits: traitCollection)
        } else {
            return nil
        }
        let maxWidth = calculator.messageContainerMaxWidth(for: message, at: indexPath)
        let width = ChatVoiceLayout.bubbleSize(traits: traitCollection, maxWidth: maxWidth).width
        let isFile = (message as? ChatBubble)?.part.receivedFile != nil
        let lines = row.message.voice == nil && !isFile ? ChatVoiceLayout.replyLines : ChatVoiceLayout.collapsedLines
        let key = isFile ? message.messageId : row.id
        let height = ChatVoiceLayout.transcriptHeight(text, width: width, expanded: expandedTranscripts.contains(key),
                                                      lines: lines)
        return (text, height, width)
    }

    /// Issue #49: the full reply text of a voice bubble, with Markdown, in a sheet. The text selects and copies.
    func showReplyText(id: String) {
        guard presentedViewController == nil, let message = model.messages.first(where: { $0.id == id }),
              !message.text.isEmpty else { return }
        // The sheet text uses the full width, less the 16 pt insets of the text view.
        let sheet = ReplyTextViewController(text: ChatBubbleText.make(message, traits: traitCollection,
                                                                       width: view.bounds.width - 32))
        let navigation = UINavigationController(rootViewController: sheet)
        if let presentation = navigation.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        present(navigation, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// The draft of this session (issue #7) goes back into the composer.
    private func restoreDraft() {
        let draft = model.draft
        guard !draft.isEmpty else { return }
        messageInputBar.inputTextView.text = draft
        composerText = draft
        updateSendButton()
    }

    private func configureNewMessagesButton() {
        newMessagesButton.translatesAutoresizingMaskIntoConstraints = false
        newMessagesButton.isHidden = true
        newMessagesButton.addAction(UIAction { [weak self] _ in self?.showFirstNewMessage(animated: true) },
                                    for: .touchUpInside)
        view.addSubview(newMessagesButton)
        NSLayoutConstraint.activate([
            newMessagesButton.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            newMessagesButton.bottomAnchor.constraint(equalTo: inputContainerView.topAnchor, constant: -12),
            newMessagesButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    /// Issue #15: after a catch-up, scroll to the first new message if the owner was at the bottom.
    /// Else show the pill. VoiceOver reads the count once.
    private func handleNewMessages() {
        guard let first = model.newMessageIds.first, first != handledNewMessageId else {
            if model.newMessageIds.isEmpty { newMessagesButton.isHidden = true }
            return
        }
        handledNewMessageId = first
        let count = model.newMessageIds.count
        UIAccessibility.post(notification: .announcement, argument: ChatNewMessages.spoken(count))
        if pinnedToBottom {
            showFirstNewMessage(animated: false)
            return
        }
        var config = UIButton.Configuration.glass()
        config.title = ChatNewMessages.title(count)
        config.image = UIImage(systemName: "arrow.down")
        config.imagePadding = 6
        config.cornerStyle = .capsule
        newMessagesButton.configuration = config
        newMessagesButton.accessibilityLabel = ChatNewMessages.title(count)
        newMessagesButton.accessibilityHint = "Double-tap to show the first new message."
        newMessagesButton.isHidden = false
        updateScrollButton()
    }

    private func showFirstNewMessage(animated: Bool) {
        newMessagesButton.isHidden = true
        defer { model.clearNewMessages() }
        guard let first = model.newMessageIds.first,
              let section = bubbles.firstIndex(where: { $0.messageId == first }) else { return }
        messagesCollectionView.layoutIfNeeded()
        pinnedToBottom = section == bubbles.count - 1
        messagesCollectionView.scrollToItem(at: IndexPath(item: 0, section: section), at: .top, animated: animated)
        updateScrollButton()
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
        let bar = messageInputBar
        let textView = bar.inputTextView
        let lineHeight = (textView.font ?? .preferredFont(forTextStyle: .body)).lineHeight
        // Issue #49: one line of text sits on the center line of the 44 pt `+` and mic. With large text the
        // field is taller, so the `+` and the mic move up to its center. More lines grow up, the buttons stay.
        let inset = ChatComposerLayout.textInset(lineHeight: lineHeight)
        textView.textContainerInset = UIEdgeInsets(top: inset, left: 12, bottom: inset, right: 12)
        textView.placeholderLabelInsets = UIEdgeInsets(top: inset, left: 16, bottom: inset, right: 16)
        let lift = ChatComposerLayout.controlLift(lineHeight: lineHeight)
        for stack in [bar.leftStackView, bar.rightStackView] {
            stack.isLayoutMarginsRelativeArrangement = true
            // Issue #60: the lift is the only bottom margin. A safe area under the composer does not move the buttons.
            stack.insetsLayoutMarginsFromSafeArea = false
            stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: lift, trailing: 0)
        }
        messageInputBar.maxTextViewHeight = (lineHeight * 6 + textView.textContainerInset.top
            + textView.textContainerInset.bottom).rounded(.up)
    }

    /// Send while there is text. Stop while a reply runs and the text is empty (owner decision 2026-11-16).
    private var showsStop: Bool {
        model.isReplyActive && composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !attachments.hasPending
    }

    /// The mic replaces Send when the text is empty and no reply runs (issue #9 design notes).
    /// Pending attachments (issue #8) keep Send.
    var showsMic: Bool {
        !showsStop && composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !attachments.hasPending
    }

    private func updateSendButton() {
        let bar = messageInputBar
        guard !voice.isActive else { return }
        let current = bar.rightStackViewItems.first as? UIView
        if showsMic {
            if current !== micButton {
                bar.setStackViewItems([micButton], forStack: .right, animated: false)
                bar.setRightStackViewWidthConstant(to: 44, animated: false)
            }
            return
        }
        if current !== bar.sendButton {
            bar.setStackViewItems([bar.sendButton], forStack: .right, animated: false)
            bar.setRightStackViewWidthConstant(to: 36, animated: false)
        }
        let send = bar.sendButton
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
        streamingHeights.removeAll()
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
            _ = model.autoPlayReplyId
            _ = model.newMessageIds
            _ = model.composerFill
            _ = model.replyQuote
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyComposerFill()
                self?.applyReplyQuote()
                self?.render()
                self?.observeModel()
            }
        }
    }

    /// Issue #67: a `prefill` result replaces the composer text. The text of a failed command goes back into an
    /// empty composer, so the owner can fix it.
    private func applyComposerFill() {
        guard let fill = model.composerFill, fill.id != handledComposerFillId else { return }
        handledComposerFillId = fill.id
        let textView = messageInputBar.inputTextView
        if fill.reason == .restore, !textView.text.isEmpty { return }
        textView.text = fill.text
        composerText = fill.text
        model.updateDraft(fill.text)
        updateSendButton()
    }

    private func styledText(for message: ChatMessage) -> NSAttributedString {
        // The thread spans the screen width.
        textWidth = view.bounds.width
        let key = TextKey(source: message.text, size: traitCollection.preferredContentSizeCategory, width: textWidth,
                          streaming: message.reply == .streaming, quote: message.quote)
        if let cached = textCache[message.id], cached.key == key {
            return cached.text
        }
        let width = ChatBubbleText.maxWidth(threadWidth: textWidth, outgoing: message.role == .user)
        let text = streamingHeights.hold(ChatBubbleText.make(message, traits: traitCollection, width: width),
                                         id: message.id, width: width, streaming: key.streaming)
        textCache[message.id] = (key, text)
        return text
    }

    private func makeBubble(_ part: ChatBubblePart) -> ChatBubble {
        if let file = part.receivedFile { return receivedBubble(part, file: file) }
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
        buildingBubbles = true
        let next = ChatBubbleParts.parts(for: rows).map(makeBubble)
        buildingBubbles = false
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
            let changed = next.indices.filter { old[$0].row != next[$0].row || old[$0].received != next[$0].received }
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
        handleNewMessages()
        updateScrollButton()
        updateSendButton()
        announceCompletedReply()
        autoPlayVoiceReply()
    }

    /// VoiceOver reads a reply once, when it ends.
    private func announceCompletedReply() {
        guard let id = model.completedReplyId, id != announcedReplyId else { return }
        announcedReplyId = id
        guard UIAccessibility.isVoiceOverRunning,
              let message = model.messages.first(where: { $0.id == id }) else { return }
        // Issue #12: VoiceOver does not read the `MEDIA:` paths. The file bubbles have their own labels.
        let text = MediaTags.visibleText(message.text)
        guard !text.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: "Hermes, \(text)")
    }

    private func updateScrollButton() {
        // The "New Messages" pill does the same job, so only one of them shows.
        scrollButton.isHidden = pinnedToBottom || bubbles.isEmpty || !newMessagesButton.isHidden
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

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // Issue #56: a new thread width (rotation, split view) can turn a table grid into cards, or back.
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self, self.view.bounds.width != self.textWidth,
                  self.model.messages.contains(where: { $0.text.contains("|") }) else { return }
            self.textCache = [:]
            self.streamingHeights.removeAll()
            self.bubbles = []
            self.render()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateComposerBottom()
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
        closeTapbackPicker()
        let pinned = ChatScroll.isNearBottom(offset: scrollView.contentOffset.y,
                                             contentHeight: scrollView.contentSize.height,
                                             viewHeight: scrollView.bounds.height,
                                             insets: scrollView.adjustedContentInset)
        if pinned != pinnedToBottom {
            pinnedToBottom = pinned
            updateScrollButton()
        }
        // The owner scrolled down to the new messages: the pill goes away.
        if pinned, !newMessagesButton.isHidden {
            newMessagesButton.isHidden = true
            model.clearNewMessages()
        }
    }

    #if DEBUG
    /// The DEBUG demo `catch-up-pill`: scroll to the top, as if the owner reads older messages.
    func unpinForDemo() {
        pinnedToBottom = false
        messagesCollectionView.setContentOffset(CGPoint(x: 0, y: -messagesCollectionView.adjustedContentInset.top),
                                                animated: false)
        updateScrollButton()
    }

    /// The DEBUG demo `markdown-*-top`: the top of a message at the top of the screen.
    func scrollToMessageForDemo(id: String) {
        guard let section = bubbles.firstIndex(where: { $0.row.id == id }) else { return }
        pinnedToBottom = false
        messagesCollectionView.layoutIfNeeded()
        messagesCollectionView.scrollToItem(at: IndexPath(item: 0, section: section), at: .top, animated: false)
        updateScrollButton()
    }
    #endif

    /// The "New Messages" pill shows (tests).
    var showsNewMessagesPill: Bool { !newMessagesButton.isHidden }

    /// The pin state (tests).
    var isPinnedToBottom: Bool { pinnedToBottom }

    /// The attachment composer (tests).
    var attachmentComposer: AttachmentComposer? { attachments }

    // MARK: Rows

    /// Issue #49: about 2 pt between the bubbles of one sender, about 10 pt when the sender changes or a time
    /// header shows (iMessage). The typing indicator starts a new group.
    @objc func collectionView(_: UICollectionView, layout _: UICollectionViewLayout,
                              insetForSectionAt section: Int) -> UIEdgeInsets {
        guard bubbles.indices.contains(section) else {
            return UIEdgeInsets(top: ChatBubbleParts.Spacing.betweenGroups, left: 0, bottom: 0, right: 0)
        }
        let previous = section > 0 ? bubbles[section - 1].part : nil
        return UIEdgeInsets(top: ChatBubbleParts.spaceAbove(bubbles[section].part, after: previous), left: 0,
                            bottom: 0, right: 0)
    }

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
        showBadges(on: cell, row: row)
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = ChatBubbleParts.accessibilityLabel(for: part)
        cell.accessibilityHint = switch row.footnote {
        case .notDelivered, .noSpeech, .queued: "Double-tap for options."
        case .replyFailed, .audioUnavailable: "Double-tap to retry."
        default: nil
        }
        var actions: [UIAccessibilityCustomAction] = []
        // Issue #17: "Reply" after the actions of the bubble, on every return path.
        defer { cell.accessibilityCustomActions = (cell.accessibilityCustomActions ?? []) + replyAccessibilityActions(for: row) }
        if let file = part.receivedFile {
            // Issue #12: "Hermes sent a file, report.pdf, 2 MB" with "Open", "Save to Files" and "Share".
            let state = model.receivedFiles.state(for: file)
            let stateText: String? = switch state {
            case .ready, .idle: nil
            default: ReceivedFileText.detail(for: state, byteCount: nil)
            }
            cell.accessibilityLabel = ChatBubbleParts.receivedFileLabel(file, byteCount: model.receivedFiles.byteCount(for: file),
                                                                        row: row, state: stateText)
            cell.accessibilityHint = nil
            // Issue #50: the transcript, and "Transcribe" or "Cancel Transcription".
            if let bubble = bubble(at: indexPath), let transcript = audioTranscriptState(bubble, file: file) {
                if let spoken = ReceivedAudioTranscriptText.spoken(transcript) {
                    cell.accessibilityLabel = [cell.accessibilityLabel ?? "", spoken].joined(separator: ", ")
                }
                actions += audioTranscriptAccessibilityActions(for: file, state: transcript)
            }
            for (name, action) in [("Open", ReceivedFileAction.open), ("Save to Files", .saveToFiles), ("Share", .share)] {
                actions.append(UIAccessibilityCustomAction(name: name) { [weak self, weak cell] _ in
                    guard let self else { return false }
                    self.perform(action, on: file, from: cell ?? self.view)
                    return true
                })
            }
            if row.showsReactions { actions += tapbackActions(for: row) }
            cell.accessibilityCustomActions = actions
            return cell
        }
        if part.content == .spokenReply {
            let id = row.id
            cell.accessibilityHint = row.message.spokenReply == .failed ? "Double-tap to retry." : nil
            guard let audio = row.message.spokenReply?.audio else {
                cell.accessibilityCustomActions = []
                return cell
            }
            actions.append(UIAccessibilityCustomAction(name: player.isPlaying(audio.fileURL) ? "Pause" : "Play") {
                [weak self] _ in
                self?.togglePlay(id: id)
                return true
            })
            // Issue #49: the voice bubble is the whole reply. Its text opens in full, copies, and takes a tapback.
            guard row.showsReactions, !row.message.text.isEmpty else {
                cell.accessibilityCustomActions = actions
                return cell
            }
            actions.append(UIAccessibilityCustomAction(name: "Show Full Text") { [weak self] _ in
                self?.showReplyText(id: id)
                return true
            })
        }
        if let memo = row.message.voice {
            let id = row.id
            let playing = player.isPlaying(memo.fileURL)
            actions.append(UIAccessibilityCustomAction(name: playing ? "Pause" : "Play") { [weak self] _ in
                self?.togglePlay(id: id)
                return true
            })
            if memo.transcript.text != nil, !expandedTranscripts.contains(id),
               let info = transcript(for: row, message: bubbles[indexPath.section], at: indexPath),
               ChatVoiceLayout.isTruncated(info.text, width: info.width) {
                actions.append(UIAccessibilityCustomAction(name: "Show Full Transcript") { [weak self] _ in
                    self?.toggleTranscript(id: id)
                    return true
                })
            }
        }
        if !row.message.text.isEmpty {
            actions.append(UIAccessibilityCustomAction(name: "Copy") { _ in
                UIPasteboard.general.string = row.message.text
                return true
            })
        }
        for run in ChatMarkdown.runs(row.message.text) {
            guard let url = run.link else { continue }
            actions.append(UIAccessibilityCustomAction(name: "Open \(run.text)") { _ in
                UIApplication.shared.open(url)
                return true
            })
        }
        if row.showsReactions { actions += tapbackActions(for: row) }
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
            var actions: [UIMenuElement] = []
            // Issue #11: the six tapbacks in one row above the other actions.
            if let self, !self.readOnly, Self.canReact(row.message) { actions.append(self.tapbackMenu(for: row)) }
            // Issue #17: "Reply" is the first action under the tapbacks.
            if let self, let reply = self.replyMenuAction(for: row) { actions.append(reply) }
            if let file = part.receivedFile, let self {
                // Issue #12: "Save to Files", "Share", and "Copy" for images. A file that is not here downloads first.
                let source = collectionView.cellForItem(at: indexPath) ?? self.view!
                actions.append(UIAction(title: "Save to Files", image: UIImage(systemName: "folder")) { [weak self] _ in
                    self?.perform(.saveToFiles, on: file, from: source)
                })
                actions.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    self?.perform(.share, on: file, from: source)
                })
                if file.kind == .image {
                    actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                        self?.perform(.copy, on: file, from: source)
                    })
                }
                actions += self.audioTranscriptMenu(for: file, bubble: self.bubble(at: indexPath))
            } else if let item = part.attachment {
                actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    if item.showsAsImage {
                        UIPasteboard.general.image = UIImage(contentsOfFile: item.fileURL.path)
                    } else {
                        UIPasteboard.general.string = item.name
                    }
                })
            } else if !row.message.text.isEmpty {
                actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = row.message.text
                })
            }
            if row.message.delivery == .failed, let self {
                actions += self.sendFailureActions(for: row)
            } else if row.message.delivery == .queued, let self {
                actions += self.queuedActions(for: row)
            }
            return actions.isEmpty ? nil : UIMenu(children: actions)
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

    // MARK: Tapbacks (issue #11)

    private func configureTapbacks() {
        messagesCollectionView.addGestureRecognizer(doubleTap)
        // MessageKit's tap waits for the double-tap, so a double-tap does not also run the bubble tap.
        for gesture in messagesCollectionView.gestureRecognizers ?? [] where gesture !== doubleTap {
            if let tap = gesture as? UITapGestureRecognizer, tap.numberOfTapsRequired == 1 {
                tap.require(toFail: doubleTap)
            }
        }
    }

    /// A bubble that still sends or streams takes no tapback.
    static func canReact(_ message: ChatMessage) -> Bool {
        message.delivery != .sending && message.reply != .streaming
    }

    private func showBadges(on cell: UICollectionViewCell, row: ChatRow) {
        guard let cell = cell as? MessageContentCell else { return }
        let badges = ReactionBadge.badges(for: row)
        let existing = cell.contentView.subviews.contains { $0 is ReactionBadgeOverlay }
        guard !badges.isEmpty || existing else { return }
        let overlay = ReactionBadgeOverlay.of(cell, bubble: cell.messageContainerView)
        let id = row.id
        overlay.show(badges) { [shownBadges] badge in shownBadges["\(id)#\(badge.corner)"] }
        for badge in badges { shownBadges["\(id)#\(badge.corner)"] = badge.symbolName }
        if !badges.contains(where: { $0.corner == .topLeading }) { shownBadges["\(id)#\(ReactionBadge.Corner.topLeading)"] = nil }
        if !badges.contains(where: { $0.corner == .topTrailing }) { shownBadges["\(id)#\(ReactionBadge.Corner.topTrailing)"] = nil }
    }

    /// A tap sets the tapback. The selected one removes it. Gives the `.selection` haptic.
    func react(_ tapback: Tapback?, id: String) {
        UISelectionFeedbackGenerator().selectionChanged()
        model.react(tapback, id: id)
    }

    private func tapbackMenu(for row: ChatRow) -> UIMenu {
        let id = row.id
        let actions = Tapback.allCases.map { tapback in
            let selected = row.message.tapback == tapback
            let action = UIAction(title: selected ? "Remove \(tapback.title)" : tapback.title,
                                  image: UIImage(systemName: tapback.symbolName)) { [weak self] _ in
                self?.react(tapback, id: id)
            }
            action.state = selected ? .on : .off
            return action
        }
        let menu = UIMenu(title: "", options: .displayInline, children: actions)
        menu.preferredElementSize = .small
        return menu
    }

    /// VoiceOver: "React Heart" … "React Question", plus "Remove Reaction".
    private func tapbackActions(for row: ChatRow) -> [UIAccessibilityCustomAction] {
        guard !readOnly, Self.canReact(row.message) else { return [] }
        let id = row.id
        var actions = Tapback.allCases.map { tapback in
            UIAccessibilityCustomAction(name: "React \(tapback.title)") { [weak self] _ in
                self?.react(tapback == row.message.tapback ? nil : tapback, id: id)
                return true
            }
        }
        if row.message.tapback != nil {
            actions.append(UIAccessibilityCustomAction(name: "Remove Reaction") { [weak self] _ in
                self?.react(nil, id: id)
                return true
            })
        }
        return actions
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: messagesCollectionView)
        guard let indexPath = messagesCollectionView.indexPathForItem(at: point),
              let cell = messagesCollectionView.cellForItem(at: indexPath) as? MessageContentCell,
              cell.messageContainerView.frame.contains(gesture.location(in: cell.contentView)) else { return }
        showTapbackPicker(at: indexPath)
    }

    /// Shows the glass capsule above the bubble at `indexPath` (double-tap, and the DEBUG demo).
    func showTapbackPicker(at indexPath: IndexPath) {
        guard !readOnly, let row = bubble(at: indexPath)?.row, Self.canReact(row.message),
              let cell = messagesCollectionView.cellForItem(at: indexPath) as? MessageContentCell else { return }
        closeTapbackPicker()
        // The model is newer than the drawn rows when a redraw waits.
        let selected = model.messages.first { $0.id == row.id }?.tapback
        let picker = TapbackPickerView(frame: view.bounds, selected: selected)
        let bubbleFrame = cell.messageContainerView.convert(cell.messageContainerView.bounds, to: view)
        // The visible thread: under the navigation bar, above the composer.
        let collection = messagesCollectionView
        let visible = collection.convert(collection.bounds.inset(by: collection.adjustedContentInset), to: view)
        picker.capsule.frame = TapbackCapsuleView.frame(size: picker.capsule.frame.size, above: bubbleFrame,
                                                        outgoing: row.message.role == .user, in: visible)
        let id = row.id
        picker.capsule.onSelect = { [weak self] tapback in
            self?.react(tapback, id: id)
            self?.closeTapbackPicker()
        }
        picker.onDismiss = { [weak self] in self?.closeTapbackPicker() }
        view.addSubview(picker)
        tapbackPicker = picker
        UIAccessibility.post(notification: .screenChanged, argument: picker.capsule)
    }

    /// Shows the capsule on the first bubble of a message (DEBUG demo, tests).
    func showTapbackPicker(messageId: String) {
        guard let section = bubbles.firstIndex(where: { $0.row.id == messageId }) else { return }
        let indexPath = IndexPath(item: 0, section: section)
        // The bubble must show. A scroll away from the end unpins the thread.
        pinnedToBottom = false
        messagesCollectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        messagesCollectionView.layoutIfNeeded()
        updateScrollButton()
        showTapbackPicker(at: indexPath)
    }

    func closeTapbackPicker() {
        tapbackPicker?.removeFromSuperview()
        tapbackPicker = nil
    }

    private func sendFailureActions(for row: ChatRow) -> [UIAction] {
        let id = row.id
        return [
            UIAction(title: "Try Again", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.model.retrySend(id: id)
            },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.deleteMessage(id: id)
            },
        ]
    }

    /// Issue #39: "Send Now" sends the outbox in order now. "Delete" takes the message out of the outbox.
    private func queuedActions(for row: ChatRow) -> [UIAction] {
        let id = row.id
        return [
            UIAction(title: "Send Now", image: UIImage(systemName: "arrow.up.circle")) { [weak self] _ in
                self?.model.sendQueued()
            },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.deleteMessage(id: id)
            },
        ]
    }

    private func showQueuedOptions(for row: ChatRow, from cell: UIView) {
        let sheet = UIAlertController(title: nil, message: "This message will send when Hermes is connected.",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Send Now", style: .default) { [weak self] _ in
            self?.model.sendQueued()
        })
        sheet.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteMessage(id: row.id)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell
        present(sheet, animated: true)
    }

    private func showSendFailureOptions(for row: ChatRow, from cell: UIView) {
        let text = switch row.message.voice?.transcript {
        case .empty: "No speech was found in your voice memo."
        case .failed: "Your voice memo was not transcribed."
        case .pending, .done: "Your voice memo was not delivered."
        case nil: "Your message was not delivered."
        }
        let sheet = UIAlertController(title: nil, message: text, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in
            self?.model.retrySend(id: row.id)
        })
        sheet.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteMessage(id: row.id)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell
        present(sheet, animated: true)
    }

    private func deleteMessage(id: String) {
        if let url = model.messages.first(where: { $0.id == id })?.voice?.fileURL, player.playingURL == url {
            player.stop()
        }
        expandedTranscripts.remove(id)
        model.delete(id: id)
    }

    private func handleTap(in cell: MessageCollectionViewCell) {
        guard let indexPath = messagesCollectionView.indexPath(for: cell), let row = bubble(at: indexPath)?.row else {
            return
        }
        // Issue #12: a received file opens, downloads, or asks before a large download.
        if let file = bubble(at: indexPath)?.part.receivedFile {
            perform(.open, on: file, from: cell)
            return
        }
        // Issue #8: each part of a message that was not delivered opens the options.
        if row.message.delivery == .failed {
            showSendFailureOptions(for: row, from: cell)
            return
        }
        // Issue #39: each part of a queued message opens "Send Now" and "Delete".
        if row.message.delivery == .queued {
            showQueuedOptions(for: row, from: cell)
            return
        }
        switch row.footnote {
        case .notDelivered, .noSpeech: showSendFailureOptions(for: row, from: cell)
        case .queued: showQueuedOptions(for: row, from: cell)
        case .replyFailed: model.retryReply(id: row.id)
        case .audioUnavailable: model.retrySpeech(id: row.id)
        default: break
        }
    }
}

// MARK: - Composer

/// Issue #49: the `+` button, a one-line field and the mic share one center line, like iMessage.
enum ChatComposerLayout {
    /// The size of the `+` button and the mic, and the height of a one-line field.
    static let control: CGFloat = 44

    /// The top and bottom text inset that puts one line in the middle of a 44 pt field. 8 pt at the least.
    static func textInset(lineHeight: CGFloat) -> CGFloat {
        max(8, (control - lineHeight) / 2)
    }

    /// The space under the `+` button and the mic, so that they stay on the center line of a taller
    /// one-line field (large text sizes). 0 at the default sizes.
    static func controlLift(lineHeight: CGFloat) -> CGFloat {
        max(0, (lineHeight + 2 * textInset(lineHeight: lineHeight) - control) / 2)
    }

    /// Issue #60: the space between the last bubble and the composer.
    static let threadGap: CGFloat = 10

    /// Issue #60: the space under the field. It is the padding, plus the part of the composer over the home
    /// indicator. With the keyboard up, the composer ends above the home indicator, so only the padding stays.
    static func bottomSpace(padding: CGFloat, composerMaxY: CGFloat, windowHeight: CGFloat,
                            homeIndicator: CGFloat) -> CGFloat {
        padding + min(homeIndicator, max(0, composerMaxY - (windowHeight - homeIndicator)))
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
        if ChatCaptionRow.uses(footnote) || footnote == .queued {
            return ChatCaptionRow.text(footnote, font: ChatLabelStyle.font(.caption2, traitCollection))
        }
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

    func customCell(for message: MessageType, at indexPath: IndexPath,
                    in messagesCollectionView: MessagesCollectionView) -> UICollectionViewCell {
        if let card = row(for: message)?.message.command {
            let cell = messagesCollectionView.dequeueReusableCell(ChatCommandCell.self, for: indexPath)
            cell.configure(with: message, at: indexPath, and: messagesCollectionView)
            cell.configure(card: card, traits: traitCollection)
            return cell
        }
        let cell = messagesCollectionView.dequeueReusableCell(ChatVoiceCell.self, for: indexPath)
        cell.configure(with: message, at: indexPath, and: messagesCollectionView)
        // Issue #12: a received audio file uses the #10 audio bubble, with no auto-play.
        if let bubble = message as? ChatBubble, let file = bubble.part.receivedFile {
            let spoken = model.receivedFiles.audio(for: file)
            let url = spoken.audio?.fileURL
            let loaded = url != nil && player.playingURL == url
            // Issue #50: the transcript line, or "Transcribe", under the bubble.
            let info = transcript(for: bubble.row, message: message, at: indexPath)
            cell.configure(reply: spoken, playing: url.map(player.isPlaying) ?? false,
                           time: loaded ? player.currentTime : 0, caption: info?.text, captionHeight: info?.height ?? 0,
                           traits: traitCollection)
            let partId = message.messageId
            cell.transcriptLabel.numberOfLines = expandedTranscripts.contains(partId) ? 0 : ChatVoiceLayout.collapsedLines
            cell.onPlay = { [weak self, weak cell] in
                guard let self else { return }
                self.perform(.open, on: file, from: cell ?? self.view)
            }
            cell.onSeek = { [weak self] time in
                guard let self, !self.voice.isActive, let url else { return }
                self.player.seek(url, to: time)
            }
            cell.onTranscriptTap = info?.text == nil ? nil : { [weak self] in
                self?.tapAudioTranscript(file, partId: partId)
            }
            return cell
        }
        guard let row = row(for: message), let info = transcript(for: row, message: message, at: indexPath) else {
            return cell
        }
        let id = row.id
        if (message as? ChatBubble)?.part.content == .spokenReply, let spoken = row.message.spokenReply {
            let url = spoken.audio?.fileURL
            let loaded = url != nil && player.playingURL == url
            cell.configure(reply: spoken, playing: url.map(player.isPlaying) ?? false,
                           time: loaded ? player.currentTime : 0, caption: info.text, captionHeight: info.height,
                           traits: traitCollection)
            cell.onPlay = { [weak self] in self?.togglePlay(id: id) }
            cell.onSeek = { [weak self] time in
                guard let self, !self.voice.isActive, let url else { return }
                self.player.seek(url, to: time)
            }
            cell.onTranscriptTap = { [weak self] in self?.showReplyText(id: id) }
            return cell
        }
        guard let memo = row.message.voice else { return cell }
        cell.configure(voice: memo, outgoing: row.message.role == .user, playing: player.isPlaying(memo.fileURL),
                       transcript: info.text, transcriptHeight: info.height,
                       expanded: expandedTranscripts.contains(id), traits: traitCollection)
        cell.onPlay = { [weak self] in self?.togglePlay(id: id) }
        cell.onTranscriptTap = { [weak self] in self?.toggleTranscript(id: id) }
        return cell
    }

    func textCell(for message: MessageType, at indexPath: IndexPath,
                  in messagesCollectionView: MessagesCollectionView) -> UICollectionViewCell? {
        let cell = messagesCollectionView.dequeueReusableCell(ChatTextCell.self, for: indexPath)
        cell.configure(with: message, at: indexPath, and: messagesCollectionView)
        cell.showsCaptionSpinner(row(for: message)?.footnote == .preparingAudio)
        cell.openLink = { url in UIApplication.shared.open(url) }
        if let id = row(for: message).flatMap({ $0.message.quote == nil ? nil : $0.id }) {
            cell.openQuote = { [weak self] in self?.showQuotedMessage(for: id) }
        }
        return cell
    }
}

// MARK: - MessageKit layout

extension ChatViewController: MessagesLayoutDelegate {
    func cellTopLabelHeight(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        row(for: message)?.timeHeader == nil ? 0 : ChatLabelStyle.height(.caption2, traitCollection, padding: 18)
    }

    /// A memo puts its transcript above the footnote, in the same area (`ChatVoiceCell`).
    func messageBottomLabelHeight(for message: MessageType, at indexPath: IndexPath,
                                  in _: MessagesCollectionView) -> CGFloat {
        guard let row = row(for: message) else { return 0 }
        var footnote = row.footnote == nil ? 0 : ChatLabelStyle.height(.caption2, traitCollection, padding: 4)
        // QA #54: the caption row of a reply wraps at large text sizes. The retry row is a 44 pt tap target.
        if let caption = row.footnote, ChatCaptionRow.uses(caption) {
            // The label spans the row and has an 18 pt leading inset. 8 pt more keeps a margin.
            let width = messagesCollectionView.bounds.width - 18 - 8
            footnote = ChatCaptionRow.height(caption, font: ChatLabelStyle.font(.caption2, traitCollection), width: width)
        }
        return footnote + (transcript(for: row, message: message, at: indexPath)?.height ?? 0)
    }

    func customCellSizeCalculator(for message: MessageType, at _: IndexPath,
                                  in _: MessagesCollectionView) -> CellSizeCalculator {
        if row(for: message)?.message.command != nil, let commandCalculator { return commandCalculator }
        return voiceCalculator ?? MessageSizeCalculator(layout: flowLayout)
    }

    func cellBottomLabelHeight(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        row(for: message)?.statusLine == nil ? 0 : ChatLabelStyle.height(.caption1, traitCollection, padding: 12)
    }

    /// Issue #11: room above a bubble with a badge, so the badge does not cover the bubble above it.
    func messageTopLabelHeight(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        guard let row = row(for: message), !ReactionBadge.badges(for: row).isEmpty else { return 0 }
        return ReactionBadge.overhang
    }
}

// MARK: - MessageKit display

extension ChatViewController: MessagesDisplayDelegate {
    func messageStyle(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> MessageStyle {
        if row(for: message)?.message.command != nil {
            return .custom { $0.layer.cornerRadius = ChatCommandCardLayout.cornerRadius }
        }
        guard let row = row(for: message), row.hasTail else { return .bubble }
        return .bubbleTail(row.message.role == .user ? .bottomRight : .bottomLeft, .curved)
    }

    func backgroundColor(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> UIColor {
        if row(for: message)?.message.command != nil { return .secondarySystemBackground }
        return row(for: message)?.message.role == .user ? .systemBlue : .systemGray5
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
        guard let bubble = message as? ChatBubble else { return }
        // Issue #12: a received image: the gray box with a `ProgressView`, or its state, until the image is here.
        ReceivedImageOverlay.clear(on: imageView)
        if bubble.part.receivedFile != nil {
            ReceivedImageOverlay.update(on: imageView, state: bubble.received)
            imageView.contentMode = .scaleAspectFill
            imageView.backgroundColor = .secondarySystemFill
            AttachmentProgressRing.update(on: imageView, uploading: false, failed: false)
            return
        }
        guard let item = bubble.part.attachment else { return }
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

// MARK: - Reply by quote (issue #17)

extension ChatViewController {
    fileprivate func configureReply() {
        quoteView.onCancel = { [weak self] in self?.model.cancelReply() }
        messageInputBar.topStackView.insertArrangedSubview(quoteView, at: 0)
        swipeReply.target = { [weak self] point in
            guard let self, let indexPath = self.messagesCollectionView.indexPathForItem(at: point),
                  let cell = self.messagesCollectionView.cellForItem(at: indexPath) as? MessageContentCell,
                  let row = self.bubble(at: indexPath)?.row, QuoteReply.canQuote(row.message) else { return nil }
            return (cell, row.id)
        }
        swipeReply.onReply = { [weak self] id in self?.startReply(to: id) }
        swipeReply.install(on: messagesCollectionView)
        noticePill.translatesAutoresizingMaskIntoConstraints = false
        noticePill.isHidden = true
        view.addSubview(noticePill)
        NSLayoutConstraint.activate([
            noticePill.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            noticePill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            noticePill.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32),
            noticePill.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        applyReplyQuote()
    }

    /// The composer quote box follows `model.replyQuote`.
    fileprivate func applyReplyQuote() {
        guard !readOnly, quoteView.quote != model.replyQuote else { return }
        quoteView.show(model.replyQuote)
        messageInputBar.invalidateIntrinsicContentSize()
    }

    /// "Reply" from the swipe, the menu or VoiceOver: the quote shows in the composer and the keyboard opens.
    func startReply(to id: String) {
        guard !readOnly, model.startReply(to: id) else { return }
        applyReplyQuote()
        messageInputBar.inputTextView.becomeFirstResponder()
    }

    /// The "Reply" menu action (internal for tests).
    func replyMenuAction(for row: ChatRow) -> UIAction? {
        guard !readOnly, QuoteReply.canQuote(row.message) else { return nil }
        let id = row.id
        return UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
            self?.startReply(to: id)
        }
    }

    fileprivate func replyAccessibilityActions(for row: ChatRow) -> [UIAccessibilityCustomAction] {
        guard !readOnly, QuoteReply.canQuote(row.message) else { return [] }
        let id = row.id
        var actions = [UIAccessibilityCustomAction(name: "Reply") { [weak self] _ in
            self?.startReply(to: id)
            return true
        }]
        if row.message.quote != nil {
            actions.append(UIAccessibilityCustomAction(name: "Show Original Message") { [weak self] _ in
                self?.showQuotedMessage(for: id)
                return true
            })
        }
        return actions
    }

    /// A tap on the quote line: scroll to the original and highlight it for 1 s.
    /// If it is not in the thread, show "Original message not loaded".
    func showQuotedMessage(for id: String) {
        guard let target = model.quotedMessageId(of: id),
              let section = bubbles.firstIndex(where: { $0.row.id == target }) else {
            noticePill.show(Self.originalNotLoaded)
            return
        }
        pinnedToBottom = false
        messagesCollectionView.layoutIfNeeded()
        let animated = !UIAccessibility.isReduceMotionEnabled
        messagesCollectionView.scrollToItem(at: IndexPath(item: 0, section: section), at: .centeredVertically,
                                            animated: animated)
        updateScrollButton()
        Task { @MainActor [weak self] in
            if animated { try? await Task.sleep(for: .milliseconds(350)) }
            self?.highlight(messageId: target)
        }
    }

    static let originalNotLoaded = "Original message not loaded"

    private func highlight(messageId: String) {
        for (section, bubble) in bubbles.enumerated() where bubble.row.id == messageId {
            guard let cell = messagesCollectionView.cellForItem(at: IndexPath(item: 0, section: section))
                    as? MessageContentCell else { continue }
            let container = cell.messageContainerView
            let flash = UIView(frame: container.bounds)
            flash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            flash.isUserInteractionEnabled = false
            flash.backgroundColor = (bubble.row.message.role == .user ? UIColor.white : UIColor.systemBlue)
                .withAlphaComponent(0.3)
            container.addSubview(flash)
            UIView.animate(withDuration: 0.25, delay: 1, options: []) { flash.alpha = 0 } completion: { _ in
                flash.removeFromSuperview()
            }
            if section == bubbles.firstIndex(where: { $0.row.id == messageId }) {
                UIAccessibility.post(notification: .layoutChanged, argument: cell)
            }
        }
    }

    #if DEBUG
    /// The DEBUG demo `HERMES_DEMO_QUOTE=swipe`: a bubble held part way through the swipe.
    func showSwipeForDemo(messageId: String, offset: CGFloat) {
        guard let section = bubbles.firstIndex(where: { $0.row.id == messageId }),
              let cell = messagesCollectionView.cellForItem(at: IndexPath(item: 0, section: section)) as? MessageContentCell
        else { return }
        swipeReply.move(cell, to: offset, in: messagesCollectionView)
    }
    #endif
}

// MARK: - Composer

extension ChatViewController: InputBarAccessoryViewDelegate {
    func inputBar(_ inputBar: InputBarAccessoryView, didPressSendButtonWith text: String) {
        if showsStop {
            model.stop()
            return
        }
        // Issue #67: a slash command leaves the attachments in the composer. They go with the next message.
        let isCommand = SlashCommand(text) != nil
        guard model.send(text, attachments: isCommand ? [] : attachments.pending) != nil else { return }
        if !isCommand { _ = attachments.takeAll() }
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

// MARK: - Hide the keyboard (issue #65)

/// Issue #65: a single tap on the thread, or a drag down, hides the keyboard (iMessage).
enum ChatKeyboardDismiss {
    static let tapName = "hideKeyboardTap"
    /// The finger moves down this far, and more down than sideways, before the keyboard hides.
    static let dragDistance: CGFloat = 20

    static func hides(after translation: CGPoint) -> Bool {
        translation.y >= dragDistance && translation.y > abs(translation.x)
    }
}

extension ChatViewController {
    private func configureKeyboardDismiss() {
        hideKeyboardTap.name = ChatKeyboardDismiss.tapName
        // MessageKit's bubble tap still runs: links, the voice play control and the send options keep working.
        hideKeyboardTap.cancelsTouchesInView = false
        hideKeyboardTapDelegate.doubleTap = doubleTap
        hideKeyboardTap.delegate = hideKeyboardTapDelegate
        messagesCollectionView.addGestureRecognizer(hideKeyboardTap)
        // `.interactive` moves the keyboard only when the finger gets to it. A drag down hides it before that.
        messagesCollectionView.panGestureRecognizer.addTarget(self, action: #selector(threadPanned(_:)))
    }

    /// The text stays in the composer. With the keyboard down, nothing changes.
    @objc func threadTapped() {
        messageInputBar.inputTextView.resignFirstResponder()
    }

    @objc private func threadPanned(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .changed else { return }
        threadDragged(by: pan.translation(in: messagesCollectionView))
    }

    func threadDragged(by translation: CGPoint) {
        let field = messageInputBar.inputTextView
        guard field.isFirstResponder, ChatKeyboardDismiss.hides(after: translation) else { return }
        field.resignFirstResponder()
    }
}

/// The keyboard tap waits for the tapback double-tap, and runs with MessageKit's bubble tap.
private final class HideKeyboardTapDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var doubleTap: UIGestureRecognizer?

    func gestureRecognizer(_: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        other === doubleTap
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Mic press

/// Lets `micPress` take only touches on the mic and its 64 pt hit area.
private final class MicPressDelegate: NSObject, UIGestureRecognizerDelegate {
    var shouldReceive: (UITouch) -> Bool = { _ in false }

    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        shouldReceive(touch)
    }
}

// MARK: - Received files (issue #12)

/// What the owner asked for on a received file.
enum ReceivedFileAction: Equatable {
    /// Quick Look (images, PDFs, most documents), the share sheet for other types, play for audio.
    case open
    case saveToFiles
    case share
    case copy
}

extension ChatViewController {
    fileprivate func receivedBubble(_ part: ChatBubblePart, file: ReceivedFile) -> ChatBubble {
        let files = model.receivedFiles
        // Images and audio load when their bubble shows. Other files wait for a tap.
        if files.state(for: file) == .idle, file.kind != .file { files.load(file) }
        let state = files.state(for: file)
        switch file.kind {
        case .image:
            let thumbnail = state.fileURL.flatMap { url in
                AttachmentThumbnails.image(for: ReceivedPhotoItem.thumbnailItem(file, url: url))
            }
            return ChatBubble(part: part, text: NSAttributedString(), thumbnail: thumbnail, received: state)
        case .audio, .file:
            let text = ReceivedFileText.make(file, state: state, byteCount: files.byteCount(for: file),
                                             traits: traitCollection)
            return ChatBubble(part: part, text: text, received: state)
        }
    }

    /// A download state changed: rebuild the bubbles of the file, then run the action that waited for it.
    fileprivate func receivedFileChanged(_ file: ReceivedFile) {
        guard isViewLoaded, !buildingBubbles else { return }
        let sections = bubbles.indices.filter { bubbles[$0].part.receivedFile == file }
        buildingBubbles = true
        for index in sections { bubbles[index] = makeBubble(bubbles[index].part) }
        buildingBubbles = false
        if !sections.isEmpty {
            UIView.performWithoutAnimation {
                messagesCollectionView.reloadSections(IndexSet(sections))
            }
            if pinnedToBottom { scrollToBottom() }
        }
        guard let action = pendingFileActions[file.path] else { return }
        switch model.receivedFiles.state(for: file) {
        case .downloading, .idle:
            return
        case .ready:
            pendingFileActions[file.path] = nil
            // Audio gets ready twice (file, then its length). Only "open" waits for the second step.
            perform(action, on: file, from: sections.first.flatMap {
                messagesCollectionView.cellForItem(at: IndexPath(item: 0, section: $0))
            } ?? view)
        case .needsConfirmation, .notAvailable, .offline, .failed:
            pendingFileActions[file.path] = nil
            // The cell shows the reason. A large file asks once: the alert came from the tap.
            if case .needsConfirmation(let bytes) = model.receivedFiles.state(for: file) {
                confirmDownload(file, byteCount: bytes, then: action)
            }
        }
    }

    /// Runs `action` on the downloaded file, or downloads it first.
    func perform(_ action: ReceivedFileAction, on file: ReceivedFile, from source: UIView) {
        let files = model.receivedFiles
        switch files.state(for: file) {
        case .ready(let url):
            run(action, on: file, url: url, from: source)
        case .downloading:
            pendingFileActions[file.path] = action
        case .needsConfirmation(let bytes):
            confirmDownload(file, byteCount: bytes, then: action)
        case .idle, .notAvailable, .offline, .failed:
            pendingFileActions[file.path] = action
            files.load(file)
        }
    }

    /// The design notes alert: "Download 120 MB?" with "Download" and "Cancel".
    private func confirmDownload(_ file: ReceivedFile, byteCount: Int, then action: ReceivedFileAction) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Download \(AttachmentPayload.sizeText(byteCount))?", message: nil,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Download", style: .default) { [weak self] _ in
            self?.pendingFileActions[file.path] = action
            self?.model.receivedFiles.load(file, confirmed: true)
        })
        present(alert, animated: true)
    }

    private func run(_ action: ReceivedFileAction, on file: ReceivedFile, url: URL, from source: UIView) {
        switch action {
        case .open:
            if file.kind == .audio {
                switch model.receivedFiles.audio(for: file) {
                case .ready(let audio):
                    guard !voice.isActive else { return }
                    player.toggle(audio.fileURL)
                    return
                case .preparing:
                    pendingFileActions[file.path] = .open
                    return
                case .failed:
                    break // It does not play on iOS: the share sheet still saves it.
                }
            }
            if file.kind != .audio, ReceivedFilePreview.canPreview(url) {
                showPreview(url)
            } else {
                share(url, from: source)
            }
        case .saveToFiles:
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            present(picker, animated: true)
        case .share:
            share(url, from: source)
        case .copy:
            if let image = UIImage(contentsOfFile: url.path) { UIPasteboard.general.image = image }
        }
    }

    private func showPreview(_ url: URL) {
        guard presentedViewController == nil else { return }
        let preview = ReceivedFilePreview(url: url)
        filePreview = preview
        let controller = QLPreviewController()
        controller.dataSource = preview
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }

    /// The share sheet: "Save Image" for images, "Save to Files", and the other apps.
    private func share(_ url: URL, from source: UIView) {
        guard presentedViewController == nil else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = source
        sheet.popoverPresentationController?.sourceRect = source.bounds
        present(sheet, animated: true)
    }

    /// The bubbles of received files (tests).
    var receivedFileBubbles: [ChatBubble] { bubbles.filter { $0.part.receivedFile != nil } }
}

// MARK: - Audio file transcripts (issue #50)

extension ChatViewController {
    /// The transcript state of a received audio bubble. `nil` while the bubble is not an audio bubble yet
    /// (download, or the audio length and levels), so no "Transcribe" shows before a run can start.
    fileprivate func audioTranscriptState(_ bubble: ChatBubble, file: ReceivedFile) -> AudioFileTranscript? {
        guard file.kind == .audio, bubble.received.fileURL != nil else { return nil }
        let state = audioTranscripts.state(for: file)
        if state == .none, model.receivedFiles.audio(for: file) == .preparing { return nil }
        return state
    }

    /// A tap on the line under the bubble.
    fileprivate func tapAudioTranscript(_ file: ReceivedFile, partId: String) {
        switch audioTranscripts.state(for: file) {
        case .none, .failed, .noPermission:
            audioTranscripts.start(file)
        case .transcribing:
            audioTranscripts.cancel(file)
        case .done:
            if expandedTranscripts.remove(partId) == nil { expandedTranscripts.insert(partId) }
            guard let index = bubbles.firstIndex(where: { $0.messageId == partId }) else { return }
            UIView.performWithoutAnimation {
                messagesCollectionView.reloadSections(IndexSet(integer: index))
            }
        case .empty, .unreadable:
            break
        }
    }

    /// The "Transcribe" or "Cancel Transcription" item of the long-press menu.
    fileprivate func audioTranscriptMenu(for file: ReceivedFile, bubble: ChatBubble?) -> [UIMenuElement] {
        guard let bubble, let state = audioTranscriptState(bubble, file: file) else { return [] }
        if state.isTranscribing {
            return [UIAction(title: "Cancel Transcription", image: UIImage(systemName: "xmark")) { [weak self] _ in
                self?.audioTranscripts.cancel(file)
            }]
        }
        guard state.canStart else { return [] }
        return [UIAction(title: "Transcribe", image: UIImage(systemName: ReceivedAudioTranscriptText.symbolName)) {
            [weak self] _ in
            self?.audioTranscripts.start(file)
        }]
    }

    fileprivate func audioTranscriptAccessibilityActions(for file: ReceivedFile,
                                                         state: AudioFileTranscript) -> [UIAccessibilityCustomAction] {
        if state.isTranscribing {
            return [UIAccessibilityCustomAction(name: "Cancel Transcription") { [weak self] _ in
                self?.audioTranscripts.cancel(file)
                return true
            }]
        }
        guard state.canStart else { return [] }
        return [UIAccessibilityCustomAction(name: "Transcribe") { [weak self] _ in
            self?.audioTranscripts.start(file)
            return true
        }]
    }

    /// A run ended with speech recognition off: the alert with "Open Settings" (like "Microphone Access Off").
    fileprivate func audioTranscriptChanged(_ file: ReceivedFile) {
        receivedFileChanged(file)
        guard audioTranscripts.state(for: file) == .noPermission, presentedViewController == nil else { return }
        present(ReceivedAudioTranscriptText.permissionAlert(), animated: true)
    }
}
