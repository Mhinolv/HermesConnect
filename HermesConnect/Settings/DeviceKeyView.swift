import HermesKit
import SwiftUI

/// Screen 2 of setup, and "Public Key" in Settings. Creates the key on open if there is no key.
struct DeviceKeyView: View {
    @Environment(AppModel.self) private var model
    var onNext: (() -> Void)?

    var body: some View {
        Group {
            switch model.keyState {
            case .ready:
                if let key = model.deviceKey, let ssh = model.openSSHKey {
                    keyForm(key: key, ssh: ssh)
                }
            case .failed:
                ContentUnavailableView {
                    Label("Could not create the key.", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Try Again") { Task { await model.ensureKey() } }
                        .buttonStyle(.glassProminent)
                }
            case .none, .creating:
                ProgressView("Creating key…")
            }
        }
        .navigationTitle("Device Key")
        .toolbar {
            if let onNext {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next", action: onNext).disabled(model.keyState != .ready)
                }
            }
        }
        .task { await model.ensureKey() }
    }

    private func keyForm(key: DeviceKey, ssh: OpenSSHPublicKey) -> some View {
        Form {
            Section {
                LabeledContent("Type", value: key.kind.displayName)
                LabeledContent("Fingerprint") {
                    Text(ssh.fingerprint)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section {
                CodeBlock(text: ssh.line, accessibilityLabel: "Public key, fingerprint \(ssh.fingerprint)")
                CopyButton(title: "Copy Public Key", text: ssh.line)
                ShareLink(item: ssh.line) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Public Key")
            } footer: {
                Text("Install this public key on your Hermes server.")
            }
        }
    }
}

struct DeviceKeyView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack { DeviceKeyView() }
            .environment(AppModel.preview(setUp: true))
    }
}
