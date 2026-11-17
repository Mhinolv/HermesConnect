import SwiftUI
import UIKit

/// A copy button. After a copy it shows "Copied" with a checkmark for 2 seconds.
struct CopyButton: View {
    let title: String
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Monospaced, selectable text that wraps at all Dynamic Type sizes.
struct CodeBlock: View {
    let text: String
    /// What VoiceOver reads instead of the code.
    let accessibilityLabel: String

    var body: some View {
        ExactText(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }
}

/// Selectable monospaced text that shows the exact characters. It wraps at any character
/// and never adds hyphens, so base64 and fingerprints stay exact. SwiftUI `Text` can hyphenate.
struct ExactText: UIViewRepresentable {
    let text: String
    var textStyle: UIFont.TextStyle = .footnote
    var color: UIColor = .label

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.attributedText = Self.attributed(text, font: font(context), color: color)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    /// The font follows the SwiftUI Dynamic Type size, so AX sizes also apply here.
    private func font(_ context: Context) -> UIFont {
        let category = UIContentSizeCategory(context.environment.dynamicTypeSize)
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let base = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits).pointSize
        return UIFont.monospacedSystemFont(ofSize: base, weight: .regular)
    }

    static func attributed(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.hyphenationFactor = 0
        paragraph.usesDefaultHyphenation = false
        return NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
    }
}

/// The confirm button of a toolbar (Next, Done). iOS 26 dims a disabled toolbar button to about 2:1
/// in dark mode. This button shows its unavailable state in an opaque system gray (about 5:1 on the
/// bar in light and dark), ignores taps, and tells VoiceOver why.
struct ConfirmButton: View {
    let title: String
    let enabled: Bool
    var disabledHint: String = ""
    let action: () -> Void

    var body: some View {
        Button {
            if enabled { action() }
        } label: {
            Text(title).foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(uiColor: Self.unavailableColor)))
        }
        .accessibilityHint(enabled ? "" : disabledHint)
        .accessibilityValue(enabled ? "" : "Unavailable")
    }

    /// `systemGray` in dark mode. The high-contrast `systemGray` in light mode, because the plain one is 3:1 on white.
    static let unavailableColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.systemGray.resolvedColor(with: traits)
            : UIColor.systemGray.resolvedColor(with: UITraitCollection(traitsFrom: [
                traits, UITraitCollection(accessibilityContrast: .high),
            ]))
    }
}
