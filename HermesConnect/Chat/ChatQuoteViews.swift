import HermesKit
import MessageKit
import UIKit

/// Issue #17: the glass quote box above the composer text view. A 3 pt blue bar, "Replying to Hermes",
/// the excerpt on 2 lines, and "Cancel Reply". Hidden when there is no quote.
final class QuoteComposerView: UIView {
    var onCancel: (() -> Void)?
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let bar = UIView()
    private let titleLabel = UILabel()
    private let excerptLabel = UILabel()
    private let textGroup = UIView()
    let cancelButton = UIButton(type: .system)
    private(set) var quote: ChatQuote?

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = 14
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        addSubview(glass)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = .systemBlue
        bar.layer.cornerRadius = 1.5
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.textColor = .secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = true
        // The title wraps at large text sizes. The excerpt keeps 2 lines.
        titleLabel.numberOfLines = 0
        excerptLabel.font = .preferredFont(forTextStyle: .subheadline)
        excerptLabel.textColor = .label
        excerptLabel.adjustsFontForContentSizeCategory = true
        excerptLabel.numberOfLines = 2
        excerptLabel.lineBreakMode = .byTruncatingTail
        let stack = UIStackView(arrangedSubviews: [titleLabel, excerptLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        textGroup.translatesAutoresizingMaskIntoConstraints = false
        textGroup.isAccessibilityElement = true
        textGroup.addSubview(stack)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark.circle.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 22))
        config.baseForegroundColor = .secondaryLabel
        config.contentInsets = .zero
        cancelButton.configuration = config
        cancelButton.accessibilityLabel = "Cancel Reply"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        let content = glass.contentView
        content.addSubview(bar)
        content.addSubview(textGroup)
        content.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bar.widthAnchor.constraint(equalToConstant: 3),
            bar.topAnchor.constraint(equalTo: stack.topAnchor),
            bar.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            textGroup.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
            textGroup.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            textGroup.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            textGroup.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: textGroup.topAnchor),
            stack.bottomAnchor.constraint(equalTo: textGroup.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: textGroup.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: textGroup.trailingAnchor),
            // A 44 pt hit area for "Cancel Reply".
            // The circle stays inside the 44 pt area at every text size, with space from the edge (QA #80).
            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            cancelButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 44),
            cancelButton.heightAnchor.constraint(equalToConstant: 44),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The quote to show, or `nil` to hide the box.
    func show(_ quote: ChatQuote?) {
        self.quote = quote
        isHidden = quote == nil
        guard let quote else { return }
        titleLabel.text = quote.replyingTitle
        excerptLabel.text = quote.previewText
        textGroup.accessibilityLabel = "\(quote.replyingTitle), \(quote.previewText)"
    }

    /// The excerpt as the box shows it (tests).
    var excerptText: String? { excerptLabel.text }
    var titleText: String? { titleLabel.text }
}

/// Issue #17: the quote line at the top of a reply bubble. One line, `.footnote`, 70 percent opacity, with a bar.
/// The `>` lines of the prompt never show.
enum ChatQuoteText {
    /// Marks the quote line, so a tap on it scrolls to the original.
    static let tapKey = NSAttributedString.Key("HermesConnectQuoteTap")

    static func make(_ quote: ChatQuote, style: ChatMarkdownText.Style) -> NSMutableAttributedString {
        let bar = max(3, (3 * style.scale).rounded())
        let indent = bar + (8 * style.scale).rounded()
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.paragraphSpacing = (6 * style.scale).rounded()
        let bars = ChatMarkdownDecoration.QuoteBars(positions: [0], color: style.barColor, width: bar)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.font(.footnote),
            .foregroundColor: style.color.withAlphaComponent(0.7),
            .paragraphStyle: paragraph,
            ChatMarkdownText.quoteKey: bars,
            tapKey: true,
        ]
        return NSMutableAttributedString(string: quote.previewText + "\n", attributes: attributes)
    }
}

/// Issue #17: swipe right on a bubble to reply (iMessage). Past 60 pt the arrow fills and a light haptic plays.
/// Letting go past it sets the quote. The bubble springs back.
@MainActor
final class ChatSwipeReply: NSObject, UIGestureRecognizerDelegate {
    static let threshold: CGFloat = 60
    static let maxOffset: CGFloat = 90

    /// The cell under a point and the message id it can reply to. `nil` when the bubble cannot be quoted.
    var target: (CGPoint) -> (cell: MessageContentCell, id: String)? = { _ in nil }
    var onReply: (String) -> Void = { _ in }
    private(set) lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private weak var collectionView: UICollectionView?
    private var active: (cell: MessageContentCell, id: String)?
    private let arrow = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.circle.fill"))
    private var passed = false

    func install(on collectionView: UICollectionView) {
        self.collectionView = collectionView
        pan.delegate = self
        collectionView.addGestureRecognizer(pan)
        // The thread scrolls only after the swipe fails, so a sideways drag never also scrolls.
        collectionView.panGestureRecognizer.require(toFail: pan)
        arrow.tintColor = .secondaryLabel
        arrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26)
        arrow.isAccessibilityElement = false
    }

    /// The offset of the bubble for a finger at `translation`: 1:1 to 60 pt, then slower, to 90 pt at most.
    static func offset(for translation: CGFloat) -> CGFloat {
        guard translation > threshold else { return max(0, translation) }
        return min(maxOffset, threshold + (translation - threshold) * 0.3)
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === pan, let view = collectionView else { return false }
        let velocity = pan.velocity(in: view)
        guard velocity.x > 0, abs(velocity.x) > abs(velocity.y) * 1.5 else { return false }
        return target(pan.location(in: view)) != nil
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard let view = collectionView else { return }
        switch gesture.state {
        case .began:
            active = target(gesture.location(in: view))
            passed = false
        case .changed:
            guard let active else { return }
            move(active.cell, to: Self.offset(for: gesture.translation(in: view).x), in: view)
        case .ended, .cancelled, .failed:
            guard let active else { return }
            let reply = gesture.state == .ended && passed
            release(active.cell)
            self.active = nil
            if reply { onReply(active.id) }
        default:
            break
        }
    }

    /// Moves the bubble and shows the arrow. Also used by the DEBUG demo for the swipe screenshot.
    func move(_ cell: MessageContentCell, to offset: CGFloat, in view: UIView) {
        // The bubble, its labels and badges move. A transform on the content view itself does not show on iOS 26.
        Self.shift(cell, by: offset)
        if arrow.superview !== view { view.addSubview(arrow) }
        let bubble = cell.messageContainerView.convert(cell.messageContainerView.bounds, to: view)
        let progress = min(1, offset / Self.threshold)
        arrow.sizeToFit()
        // The arrow shows in the space that the bubble leaves on its left.
        arrow.center = CGPoint(x: max(cell.frame.minX + arrow.bounds.width / 2, bubble.minX - 8 - arrow.bounds.width / 2),
                               y: bubble.midY)
        arrow.alpha = progress
        arrow.transform = CGAffineTransform(scaleX: 0.6 + 0.4 * progress, y: 0.6 + 0.4 * progress)
        let isPast = offset >= Self.threshold
        arrow.tintColor = isPast ? .systemBlue : .secondaryLabel
        if isPast, !passed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        passed = isPast
    }

    private static func shift(_ cell: MessageContentCell, by offset: CGFloat) {
        let transform = offset == 0 ? .identity : CGAffineTransform(translationX: offset, y: 0)
        for view in cell.contentView.subviews { view.transform = transform }
    }

    private func release(_ cell: MessageContentCell) {
        let reset = { [arrow] in
            Self.shift(cell, by: 0)
            arrow.alpha = 0
        }
        if UIAccessibility.isReduceMotionEnabled {
            reset()
            arrow.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState], animations: reset) { [arrow] _ in
            arrow.removeFromSuperview()
        }
    }
}

/// Issue #17: a short glass notice over the thread, for example "Original message not loaded".
/// VoiceOver reads it once.
final class ChatNoticePill: UIButton {
    private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        var config = UIButton.Configuration.glass()
        config.title = text
        config.cornerStyle = .capsule
        configuration = config
        isUserInteractionEnabled = false
        accessibilityLabel = text
        isHidden = false
        alpha = 1
        UIAccessibility.post(notification: .announcement, argument: text)
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25) { self?.alpha = 0 } completion: { _ in
                self?.isHidden = true
            }
        }
    }
}

#if DEBUG
/// DEBUG only: the issue #17 screenshots. Start with `HERMES_DEMO=thread HERMES_DEMO_QUOTE=<composer|sent|swipe>`.
enum QuoteDemo: String {
    /// The composer shows a quote of the last reply. The keyboard is up.
    case composer
    /// The thread has a sent reply with a quote of an earlier reply.
    case sent
    /// A swipe on the last reply, past the 60 pt point.
    case swipe

    static var current: QuoteDemo? {
        ProcessInfo.processInfo.environment["HERMES_DEMO_QUOTE"].flatMap(QuoteDemo.init(rawValue:))
    }

    /// The seed thread plus, for `sent`, an owner reply that quotes the calendar reply.
    static func messages(_ seeds: [ChatMessage]) -> [ChatMessage] {
        guard current == .sent, let original = seeds.first(where: { $0.id == "d2" }),
              let quote = ChatQuote(message: original) else { return seeds }
        let date = (seeds.last?.date ?? Date()).addingTimeInterval(30)
        return seeds + [
            ChatMessage(id: "q1", role: .user, text: "Move the design review to 11.", date: date,
                        delivery: .delivered, userRowId: 107, quote: quote),
            ChatMessage(id: "q2", role: .assistant, text: "Done. The design review is now at 11:00 AM.",
                        date: date.addingTimeInterval(12), reply: .complete, promptId: "q1"),
        ]
    }

    @MainActor
    func run(on controller: ChatViewController) {
        switch self {
        case .composer: controller.startReply(to: "d6")
        case .sent: break
        case .swipe:
            Task { @MainActor in
                // At large text sizes the bubble is above the screen: scroll to it first (QA #80).
                try? await Task.sleep(for: .milliseconds(300))
                controller.scrollToMessageForDemo(id: "d4")
                // The status line reloads the rows, so the demo holds the swipe for 10 s.
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(500))
                    controller.showSwipeForDemo(messageId: "d4", offset: 72)
                }
            }
        }
    }
}
#endif
