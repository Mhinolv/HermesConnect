import HermesKit
import SwiftUI

/// Screen 3 of setup, and "Install Steps" in Settings: what the owner adds on the server.
struct InstallStepsView: View {
    @Environment(AppModel.self) private var model
    var onDone: (() -> Void)?

    var body: some View {
        Form {
            if let guide = model.installGuide {
                steps(guide)
            } else {
                Text("Create the device key first.")
            }
        }
        .navigationTitle("Install on Server")
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(title: "Done", enabled: true, action: onDone)
                }
            }
        }
    }

    @ViewBuilder
    private func steps(_ guide: ServerInstallGuide) -> some View {
        ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
            Section {
                Step(number: index + 1, text: step.text)
                if let code = step.code {
                    CodeBlock(text: code, accessibilityLabel: step.codeLabel ?? code)
                    if let copyTitle = step.copyTitle {
                        CopyButton(title: copyTitle, text: code)
                    }
                }
            } footer: {
                if index == guide.steps.count - 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(.init(ServerInstallGuide.footnote))
                        Text(model.deviceKey?.kind == .software
                             ? "This Simulator key is not hardware-backed."
                             : "The private key stays on this iPhone. It cannot be exported.")
                    }
                }
            }
        }
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .font(.body.monospacedDigit().bold())
                .foregroundStyle(.secondary)
            Text(.init(text))
        }
        .accessibilityElement(children: .combine)
    }
}

struct InstallStepsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack { InstallStepsView(onDone: {}) }
            .environment(AppModel.preview(setUp: true))
    }
}
