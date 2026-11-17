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
                    Button("Done", action: onDone)
                }
            }
        }
    }

    @ViewBuilder
    private func steps(_ guide: ServerInstallGuide) -> some View {
        Section {
            Step(number: 1, text: "Copy the `server` folder of HermesConnect to `\(ServerInstallGuide.serverFolder)` on the server. Then install the gate and the key:")
            CodeBlock(text: guide.installCommand,
                      accessibilityLabel: "Install command with the public key of this iPhone")
            CopyButton(title: "Copy Command", text: guide.installCommand)
        }
        Section {
            Step(number: 2, text: "Make sure that `\(guide.authorizedKeysPath)` has this line:")
            CodeBlock(text: guide.authorizedKeysLine,
                      accessibilityLabel: "authorized_keys line with the public key of this iPhone")
            CopyButton(title: "Copy Line", text: guide.authorizedKeysLine)
        }
        Section {
            Step(number: 3, text: "Add this block at the end of `\(ServerInstallGuide.sshdConfigPath)`:")
            CodeBlock(text: guide.sshdMatchBlock, accessibilityLabel: guide.sshdMatchBlock)
            CopyButton(title: "Copy Block", text: guide.sshdMatchBlock)
        }
        Section {
            Step(number: 4, text: "Check the configuration, then reload SSH:")
            CodeBlock(text: ServerInstallGuide.reloadCommand, accessibilityLabel: ServerInstallGuide.reloadCommand)
            CopyButton(title: "Copy Reload Command", text: ServerInstallGuide.reloadCommand)
        } footer: {
            Text(model.deviceKey?.kind == .software
                 ? "This Simulator key is not hardware-backed."
                 : "The private key stays on this iPhone. It cannot be exported.")
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
