import HermesKit
import MessageKit
import UIKit

/// Sizes and text of the voice memo bubble (issue #9 design notes, "After send").
enum ChatVoiceLayout {
    /// The transcript shows 3 lines until the owner taps it.
    static let collapsedLines = 3
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
    static func replyCaption(for spoken: SpokenReply, traits: UITraitCollection) -> NSAttributedString? {
        guard spoken == .preparing else { return nil }
        return NSAttributedString(string: "Preparing audio…", attributes: [
            .font: UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits),
            .foregroundColor: UIColor.secondaryLabel,
        ])
    }

    /// The height of the transcript area, padding included. 0 when there is no text.
    static func transcriptHeight(_ text: NSAttributedString?, width: CGFloat, expanded: Bool) -> CGFloat {
        guard let text, text.length > 0, width > 0 else { return 0 }
        let inner = width - transcriptPadding.left - transcriptPadding.right
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont ?? .preferredFont(forTextStyle: .footnote)
        let full = text.boundingRect(with: CGSize(width: inner, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        let shown = expanded ? full : min(full, font.lineHeight * CGFloat(collapsedLines))
        return (shown + transcriptPadding.top + transcriptPadding.bottom).rounded(.up)
    }

    /// `true` when the transcript has more lines than the collapsed view shows.
    static func isTruncated(_ text: NSAttributedString?, width: CGFloat) -> Bool {
        transcriptHeight(text, width: width, expanded: true) > transcriptHeight(text, width: width, expanded: false)
    }
}

/// The voice memo bubble: play button, waveform and duration, with the transcript under it.
/// Issue #10: a voice reply uses the same cell with a progress bar in place of the waveform.
final class ChatVoiceCell: MessageContentCell {
    private let playIcon = UIImageView()
    private let waveform = VoiceWaveformView()
    private let durationLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// The progress bar of a voice reply. A drag seeks.
    let progress = UISlider()
    private var isReply = false
    private var replyDuration: TimeInterval = 0
    let transcriptLabel = UILabel()
    /// The area of the bottom label from the layout: the transcript, then the footnote.
    private var bottomRegion: CGRect = .zero
    private var transcriptHeight: CGFloat = 0

    var onPlay: (() -> Void)?
    var onTranscriptTap: (() -> Void)?
    /// The owner let go of the progress bar at this time in seconds.
    var onSeek: ((TimeInterval) -> Void)?

    override func setupSubviews() {
        super.setupSubviews()
        playIcon.contentMode = .center
        spinner.hidesWhenStopped = true
        progress.isHidden = true
        progress.setThumbImage(Self.thumbImage, for: .normal)
        progress.addTarget(self, action: #selector(progressMoved), for: .valueChanged)
        progress.addTarget(self, action: #selector(progressReleased), for: [.touchUpInside, .touchUpOutside])
        messageContainerView.addSubview(spinner)
        messageContainerView.addSubview(progress)
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
        spinner.stopAnimating()
        progress.isHidden = true
        waveform.isHidden = false
        transcriptLabel.attributedText = nil
        transcriptHeight = 0
    }

    func configure(voice: VoiceMemo, outgoing: Bool, playing: Bool, transcript: NSAttributedString?,
                   transcriptHeight: CGFloat, expanded: Bool, traits: UITraitCollection) {
        isReply = false
        waveform.isHidden = false
        progress.isHidden = true
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
        waveform.isHidden = true
        let symbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        playIcon.tintColor = .label
        durationLabel.font = ChatVoiceLayout.durationFont(traits)
        durationLabel.textColor = .label
        switch spoken {
        case .preparing:
            playIcon.isHidden = true
            spinner.startAnimating()
            progress.isHidden = true
            durationLabel.text = nil
        case .ready(let audio):
            playIcon.isHidden = false
            spinner.stopAnimating()
            playIcon.image = UIImage(systemName: playing ? "pause.fill" : "play.fill", withConfiguration: symbol)
            progress.isHidden = false
            replyDuration = audio.duration
            progress.minimumValue = 0
            progress.maximumValue = Float(max(audio.duration, 0.1))
            progress.minimumTrackTintColor = .label
            progress.maximumTrackTintColor = .tertiaryLabel
            setProgress(time: time)
        case .failed:
            playIcon.isHidden = false
            spinner.stopAnimating()
            playIcon.image = UIImage(systemName: "arrow.clockwise", withConfiguration: symbol)
            progress.isHidden = true
            durationLabel.text = nil
        }
        transcriptLabel.attributedText = caption
        transcriptLabel.numberOfLines = 1
        transcriptHeight = captionHeight
        layoutTranscript()
        setNeedsLayout()
    }

    /// Moves the progress bar and the time. The screen calls it about 10 times per second while the clip plays,
    /// with no reload of the row. A drag in progress keeps its place.
    func setProgress(time: TimeInterval) {
        guard isReply, !progress.isTracking else { return }
        progress.value = Float(time)
        durationLabel.text = VoiceMemoFormat.duration(time > 0 ? time : replyDuration)
    }

    @objc private func progressMoved() {
        durationLabel.text = VoiceMemoFormat.duration(TimeInterval(progress.value))
    }

    @objc private func progressReleased() {
        onSeek?(TimeInterval(progress.value))
    }

    private static let thumbImage: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { _ in
        UIColor.label.setFill()
        UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 12, height: 12)).fill()
    }.withRenderingMode(.alwaysTemplate)

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
        let barX = playIcon.frame.maxX + 4
        progress.frame = CGRect(x: barX, y: 0, width: max(0, durationLabel.frame.minX - 8 - barX), height: bounds.height)
        let waveX = playIcon.frame.maxX + 8
        waveform.frame = CGRect(x: waveX, y: bounds.height * 0.25, width: max(0, durationLabel.frame.minX - 8 - waveX),
                                height: bounds.height * 0.5)
    }

    /// Taps: the bubble plays, the transcript expands, the footnote shows the send options.
    override func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let point = gesture.location(in: self)
        if isReply, !progress.isHidden, progress.frame.contains(gesture.location(in: messageContainerView)) {
            // The progress bar takes its own touches.
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
