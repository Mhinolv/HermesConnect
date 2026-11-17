import UIKit

/// Issue #49 (owner decision): the full text of a voice reply, with Markdown, in a sheet.
/// The text selects and copies. A link opens on a tap.
final class ReplyTextViewController: UIViewController {
    /// TextKit 1, so `ChatMarkdownBackdrop` can draw the table lines, cards and quote bars of issue #56.
    let textView = UITextView(usingTextLayoutManager: false)
    private let backdrop = ChatMarkdownBackdrop()
    private let text: NSAttributedString

    init(text: NSAttributedString) {
        self.text = Self.withLinks(text)
        super.init(nibName: nil, bundle: nil)
        title = "Reply"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
        })
        textView.attributedText = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 24, right: 16)
        textView.linkTextAttributes = [.foregroundColor: UIColor.link, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.accessibilityLabel = "Reply"
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(textView)
        backdrop.textView = textView
        textView.insertSubview(backdrop, at: 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        backdrop.frame = CGRect(origin: .zero, size: CGSize(width: textView.bounds.width,
                                                            height: max(textView.contentSize.height, textView.bounds.height)))
        backdrop.setNeedsDisplay()
    }

    /// The bubble text keeps its link targets under `ChatBubbleText.linkKey`. The text view needs `.link`.
    static func withLinks(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.enumerateAttribute(ChatBubbleText.linkKey, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            copy.addAttribute(.link, value: url, range: range)
        }
        return copy
    }
}
