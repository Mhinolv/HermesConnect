import UIKit

/// Issue #49 (owner decision): the full text of a voice reply, with Markdown, in a sheet.
/// The text selects and copies. A link opens on a tap.
final class ReplyTextViewController: UIViewController {
    let textView = UITextView()
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
