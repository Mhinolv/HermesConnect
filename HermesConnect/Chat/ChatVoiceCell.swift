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
final class ChatVoiceCell: MessageContentCell {
    private let playIcon = UIImageView()
    private let waveform = VoiceWaveformView()
    private let durationLabel = UILabel()
    let transcriptLabel = UILabel()
    /// The area of the bottom label from the layout: the transcript, then the footnote.
    private var bottomRegion: CGRect = .zero
    private var transcriptHeight: CGFloat = 0

    var onPlay: (() -> Void)?
    var onTranscriptTap: (() -> Void)?

    override func setupSubviews() {
        super.setupSubviews()
        playIcon.contentMode = .scaleAspectFit
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
        transcriptLabel.attributedText = nil
        transcriptHeight = 0
    }

    func configure(voice: VoiceMemo, outgoing: Bool, playing: Bool, transcript: NSAttributedString?,
                   transcriptHeight: CGFloat, expanded: Bool, traits: UITraitCollection) {
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
        let icon: CGFloat = 32
        playIcon.frame = CGRect(x: 10, y: (bounds.height - icon) / 2, width: icon, height: icon)
        let durationWidth = (durationLabel.font ?? .systemFont(ofSize: 15)).pointSize * 3
        durationLabel.frame = CGRect(x: bounds.width - 14 - durationWidth, y: 0, width: durationWidth,
                                     height: bounds.height)
        let waveX = playIcon.frame.maxX + 8
        waveform.frame = CGRect(x: waveX, y: bounds.height * 0.25, width: max(0, durationLabel.frame.minX - 8 - waveX),
                                height: bounds.height * 0.5)
    }

    /// Taps: the bubble plays, the transcript expands, the footnote shows the send options.
    override func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let point = gesture.location(in: self)
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
