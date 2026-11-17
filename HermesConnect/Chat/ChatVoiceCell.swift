import HermesKit
import MessageKit
import UIKit

/// Sizes and text of the voice memo bubble (issue #9 design notes, "After send").
enum ChatVoiceLayout {
    /// The transcript shows 3 lines until the owner taps it.
    static let collapsedLines = 3
    /// Issue #49 (owner decision): the reply text under a voice reply shows 2 lines. A tap opens the full text.
    static let replyLines = 2
    /// Space between the bubble and the transcript, and under the transcript.
    static let transcriptPadding = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)

    static func durationFont(_ traits: UITraitCollection) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        return UIFont.monospacedDigitSystemFont(ofSize: base.pointSize, weight: .medium)
    }

    /// Play button, waveform and duration. It grows with the text size, up to the column width.
    static func bubbleSize(traits: UITraitCollection, maxWidth: CGFloat) -> CGSize {
        let font = durationFont(traits)
        let height = max(48, (font.lineHeight + 26).rounded(.up))
        let width = min(maxWidth, (160 + font.pointSize * 4).rounded(.up))
        return CGSize(width: width, height: height)
    }

    /// The line under the bubble: "Transcribing…", the transcript, or "Couldn't transcribe".
    /// An empty transcript shows nothing here: the footnote says "No speech found.".
    static func transcriptText(for voice: VoiceMemo, traits: UITraitCollection) -> NSAttributedString? {
        let caption = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits)
        switch voice.transcript {
        case .pending:
            return NSAttributedString(string: "Transcribing…", attributes: [.font: caption,
                                                                             .foregroundColor: UIColor.secondaryLabel])
        case .failed:
            return NSAttributedString(string: "Couldn't transcribe", attributes: [
                .font: caption, .foregroundColor: UIColor.secondaryLabel,
            ])
        case .done(let text):
            return NSAttributedString(string: text, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits),
                .foregroundColor: UIColor.secondaryLabel,
            ])
        case .empty:
            return nil
        }
    }

    /// Issue #10: the line under a voice reply while the audio is on its way.
    /// Issue #49: with ready audio, the reply text as plain text, like the transcript of a memo.
    static func replyCaption(for spoken: SpokenReply, text: String, traits: UITraitCollection) -> NSAttributedString? {
        switch spoken {
        case .preparing:
            return NSAttributedString(string: "Preparing audio…", attributes: [
                .font: UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits),
                .foregroundColor: UIColor.secondaryLabel,
            ])
        case .ready:
            let preview = VoiceReplyText.previewText(text)
            guard !preview.isEmpty else { return nil }
            return NSAttributedString(string: preview, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits),
                .foregroundColor: UIColor.secondaryLabel,
            ])
        case .failed:
            return nil
        }
    }

    /// The height of the transcript area, padding included. 0 when there is no text.
    /// Issue #49: a label measures it, so the label always has room for each line it shows. A height of
    /// `lines * lineHeight` was a little short, and the label dropped the last line.
    @MainActor
    static func transcriptHeight(_ text: NSAttributedString?, width: CGFloat, expanded: Bool,
                                 lines: Int = collapsedLines) -> CGFloat {
        guard let text, text.length > 0, width > 0 else { return 0 }
        let inner = width - transcriptPadding.left - transcriptPadding.right
        sizingLabel.attributedText = text
        sizingLabel.lineBreakMode = .byTruncatingTail
        sizingLabel.numberOfLines = expanded ? 0 : lines
        let bounds = CGRect(x: 0, y: 0, width: inner, height: .greatestFiniteMagnitude)
        let shown = sizingLabel.textRect(forBounds: bounds, limitedToNumberOfLines: sizingLabel.numberOfLines).height
        return (shown + transcriptPadding.top + transcriptPadding.bottom).rounded(.up)
    }

    @MainActor private static let sizingLabel = UILabel()

    /// `true` when the transcript has more lines than the collapsed view shows.
    @MainActor
    static func isTruncated(_ text: NSAttributedString?, width: CGFloat) -> Bool {
        transcriptHeight(text, width: width, expanded: true) > transcriptHeight(text, width: width, expanded: false)
    }
}

/// The voice memo bubble: play button, waveform and duration, with the transcript under it.
/// Issue #10: a voice reply uses the same cell. Issue #49: it shows a waveform too, with the played part
/// in full color. A tap or a drag on the waveform seeks. The reply text shows under the bubble.
final class ChatVoiceCell: MessageContentCell {
    private let playIcon = UIImageView()
    /// The waveform of a memo or a voice reply.
    let waveform = VoiceWaveformView()
    /// The length of the clip. Issue #49: a voice reply always shows its full length, also part way.
    let durationLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var isReply = false
    /// `true` for a voice reply with ready audio: the waveform seeks.
    private(set) var seeks = false
    private var replyDuration: TimeInterval = 0
    private lazy var scrub = UIPanGestureRecognizer(target: self, action: #selector(scrubbed(_:)))
    private let scrubDelegate = ScrubDelegate()
    let transcriptLabel = UILabel()
    /// The area of the bottom label from the layout: the transcript, then the footnote.
    private var bottomRegion: CGRect = .zero
    private var transcriptHeight: CGFloat = 0

    var onPlay: (() -> Void)?
    var onTranscriptTap: (() -> Void)?
    /// The owner tapped the waveform, or let go of it after a drag, at this time in seconds.
    var onSeek: ((TimeInterval) -> Void)?

    override func setupSubviews() {
        super.setupSubviews()
        playIcon.contentMode = .center
        spinner.hidesWhenStopped = true
        messageContainerView.addSubview(spinner)
        // A sideways drag on the waveform seeks. An up or down drag scrolls the thread.
        scrubDelegate.shouldBegin = { [weak self] gesture in self?.scrubShouldBegin(gesture) ?? false }
        scrub.delegate = scrubDelegate
        messageContainerView.addGestureRecognizer(scrub)
        durationLabel.adjustsFontForContentSizeCategory = false
        durationLabel.textAlignment = .right
        transcriptLabel.lineBreakMode = .byTruncatingTail
        messageContainerView.addSubview(playIcon)
        messageContainerView.addSubview(waveform)
        messageContainerView.addSubview(durationLabel)
        contentView.addSubview(transcriptLabel)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onPlay = nil
        onTranscriptTap = nil
        onSeek = nil
        isReply = false
        seeks = false
        spinner.stopAnimating()
        waveform.isHidden = false
        waveform.progress = nil
        transcriptLabel.attributedText = nil
        transcriptHeight = 0
    }

    func configure(voice: VoiceMemo, outgoing: Bool, playing: Bool, transcript: NSAttributedString?,
                   transcriptHeight: CGFloat, expanded: Bool, traits: UITraitCollection) {
        isReply = false
        seeks = false
        waveform.isHidden = false
        waveform.progress = nil
        spinner.stopAnimating()
        playIcon.isHidden = false
        let tint: UIColor = outgoing ? .white : .label
        let symbol = UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        playIcon.image = UIImage(systemName: playing ? "pause.circle.fill" : "play.circle.fill", withConfiguration: symbol)
        playIcon.tintColor = tint
        waveform.barColor = tint.withAlphaComponent(0.85)
        waveform.levels = voice.waveform
        waveform.barCount = max(1, voice.waveform.count)
        durationLabel.font = ChatVoiceLayout.durationFont(traits)
        durationLabel.textColor = tint
        durationLabel.text = VoiceMemoFormat.duration(voice.duration)
        transcriptLabel.attributedText = transcript
        transcriptLabel.numberOfLines = expanded ? 0 : ChatVoiceLayout.collapsedLines
        self.transcriptHeight = transcriptHeight
        layoutTranscript()
        setNeedsLayout()
    }

    /// Issue #10: an incoming voice reply. `time` is the play position of a loaded clip.
    func configure(reply spoken: SpokenReply, playing: Bool, time: TimeInterval, caption: NSAttributedString?,
                   captionHeight: CGFloat, traits: UITraitCollection) {
        isReply = true
        seeks = false
        waveform.isHidden = true
        waveform.progress = nil
        let symbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        playIcon.tintColor = .label
        durationLabel.font = ChatVoiceLayout.durationFont(traits)
        durationLabel.textColor = .label
        switch spoken {
        case .preparing:
            playIcon.isHidden = true
            spinner.startAnimating()
            durationLabel.text = nil
        case .ready(let audio):
            playIcon.isHidden = false
            spinner.stopAnimating()
            playIcon.image = UIImage(systemName: playing ? "pause.fill" : "play.fill", withConfiguration: symbol)
            seeks = true
            replyDuration = audio.duration
            // Issue #49: the same bars as the owner's memos. A reply that an older build cached has no levels.
            waveform.isHidden = false
            waveform.levels = audio.waveform.isEmpty ? VoiceWaveform.bars(from: []) : audio.waveform
            waveform.barCount = max(1, waveform.levels.count)
            waveform.barColor = .tertiaryLabel
            waveform.playedColor = .label
            durationLabel.text = VoiceMemoFormat.duration(audio.duration)
            setProgress(time: time)
        case .failed:
            playIcon.isHidden = false
            spinner.stopAnimating()
            playIcon.image = UIImage(systemName: "arrow.clockwise", withConfiguration: symbol)
            durationLabel.text = nil
        }
        transcriptLabel.attributedText = caption
        transcriptLabel.numberOfLines = spoken.audio == nil ? 1 : ChatVoiceLayout.replyLines
        transcriptHeight = captionHeight
        layoutTranscript()
        setNeedsLayout()
    }

    /// Fills the waveform up to the play time. The screen calls it about 10 times per second while the clip
    /// plays, with no reload of the row. A drag in progress keeps its place. Issue #49: the label keeps the
    /// full length, so the owner never reads the play time as the length.
    func setProgress(time: TimeInterval) {
        guard seeks, scrub.state != .changed, scrub.state != .began else { return }
        waveform.progress = Self.fraction(time: time, duration: replyDuration)
    }

    /// The played part from 0 to 1.
    static func fraction(time: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard duration > 0, time.isFinite else { return 0 }
        return CGFloat(min(1, max(0, time / duration)))
    }

    /// The clip time at a point on the waveform.
    func seekTime(at point: CGPoint) -> TimeInterval {
        let frame = waveform.frame
        guard frame.width > 0 else { return 0 }
        return replyDuration * Double(min(1, max(0, (point.x - frame.minX) / frame.width)))
    }

    /// The waveform area that takes a tap or a drag: the bars, plus a margin for a finger.
    private var seekArea: CGRect { waveform.frame.insetBy(dx: -6, dy: -waveform.frame.minY) }

    private func scrubShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard seeks, let pan = gesture as? UIPanGestureRecognizer,
              seekArea.contains(pan.location(in: messageContainerView)) else { return false }
        let velocity = pan.velocity(in: messageContainerView)
        return abs(velocity.x) > abs(velocity.y)
    }

    @objc private func scrubbed(_ gesture: UIPanGestureRecognizer) {
        let time = seekTime(at: gesture.location(in: messageContainerView))
        switch gesture.state {
        case .began, .changed:
            waveform.progress = Self.fraction(time: time, duration: replyDuration)
        case .ended:
            onSeek?(time)
        default:
            break
        }
    }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        bottomRegion = messageBottomLabel.frame
        layoutTranscript()
    }

    /// The transcript takes the top of the bottom label area, so the footnote stays under it.
    private func layoutTranscript() {
        let height = min(transcriptHeight, bottomRegion.height)
        let pad = ChatVoiceLayout.transcriptPadding
        let bubble = messageContainerView.frame
        transcriptLabel.frame = CGRect(x: bubble.minX + pad.left, y: bottomRegion.minY + pad.top,
                                       width: max(0, bubble.width - pad.left - pad.right),
                                       height: max(0, height - pad.top - pad.bottom))
        messageBottomLabel.frame = CGRect(x: bottomRegion.minX, y: bottomRegion.minY + height,
                                          width: bottomRegion.width, height: bottomRegion.height - height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = messageContainerView.bounds
        // A voice reply has a 44 pt play button (issue #10 design notes).
        let icon: CGFloat = isReply ? 44 : 32
        playIcon.frame = CGRect(x: isReply ? 6 : 10, y: (bounds.height - icon) / 2, width: icon, height: icon)
        spinner.center = CGPoint(x: playIcon.frame.midX, y: playIcon.frame.midY)
        let durationWidth = (durationLabel.font ?? .systemFont(ofSize: 15)).pointSize * 3
        durationLabel.frame = CGRect(x: bounds.width - 14 - durationWidth, y: 0, width: durationWidth,
                                     height: bounds.height)
        let waveX = playIcon.frame.maxX + (isReply ? 4 : 8)
        waveform.frame = CGRect(x: waveX, y: bounds.height * 0.25, width: max(0, durationLabel.frame.minX - 8 - waveX),
                                height: bounds.height * 0.5)
    }

    /// Taps: the bubble plays, the transcript expands, the footnote shows the send options.
    override func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let point = gesture.location(in: self)
        let inBubble = gesture.location(in: messageContainerView)
        if seeks, seekArea.contains(inBubble) {
            // Issue #49: a tap on the waveform of a voice reply plays from that point.
            onSeek?(seekTime(at: inBubble))
            return
        }
        if messageContainerView.frame.contains(point) {
            onPlay?()
        } else if transcriptLabel.frame.insetBy(dx: 0, dy: -4).contains(point), transcriptLabel.attributedText != nil {
            onTranscriptTap?()
        } else {
            super.handleTapGesture(gesture)
        }
    }
}

/// Gives the voice bubble its size. The other settings copy the text calculator.
final class ChatVoiceSizeCalculator: MessageSizeCalculator {
    var bubbleSize: (MessageType, CGFloat) -> CGSize = { _, _ in .zero }

    init(layout: MessagesCollectionViewFlowLayout, copying source: MessageSizeCalculator) {
        super.init(layout: layout)
        incomingAvatarSize = source.incomingAvatarSize
        outgoingAvatarSize = source.outgoingAvatarSize
        incomingMessagePadding = source.incomingMessagePadding
        outgoingMessagePadding = source.outgoingMessagePadding
        incomingCellTopLabelAlignment = source.incomingCellTopLabelAlignment
        outgoingCellTopLabelAlignment = source.outgoingCellTopLabelAlignment
        incomingCellBottomLabelAlignment = source.incomingCellBottomLabelAlignment
        outgoingCellBottomLabelAlignment = source.outgoingCellBottomLabelAlignment
        incomingMessageBottomLabelAlignment = source.incomingMessageBottomLabelAlignment
        outgoingMessageBottomLabelAlignment = source.outgoingMessageBottomLabelAlignment
        incomingAccessoryViewSize = source.incomingAccessoryViewSize
        outgoingAccessoryViewSize = source.outgoingAccessoryViewSize
        incomingAccessoryViewPadding = source.incomingAccessoryViewPadding
        outgoingAccessoryViewPadding = source.outgoingAccessoryViewPadding
    }

    override func messageContainerSize(for message: MessageType, at indexPath: IndexPath) -> CGSize {
        bubbleSize(message, messageContainerMaxWidth(for: message, at: indexPath))
    }
}

/// The sideways-drag check of the waveform. A separate object, so the cell keeps the MessageKit delegates.
private final class ScrubDelegate: NSObject, UIGestureRecognizerDelegate {
    var shouldBegin: (UIGestureRecognizer) -> Bool = { _ in false }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        shouldBegin(gestureRecognizer)
    }
}
