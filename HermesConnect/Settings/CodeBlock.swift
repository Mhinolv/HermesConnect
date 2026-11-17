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
        Text(text)
            .font(.footnote.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }
}
