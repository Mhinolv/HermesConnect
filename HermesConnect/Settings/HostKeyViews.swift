import HermesKit
import SwiftUI

/// A fingerprint: monospaced, selectable, wraps with no hyphens. VoiceOver reads it in groups of 4 characters.
struct FingerprintRow: View {
    let title: String
    let key: HostKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            ExactText(text: key.fingerprint, textStyle: .body, color: .secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(key.spokenFingerprint)")
    }
}

/// A title and a value. At accessibility sizes the value goes under the title and wraps with no hyphens.
struct ValueRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let value: String

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                ExactText(text: value, textStyle: .body, color: .secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(value)")
        } else {
            LabeledContent(title, value: value)
        }
    }
}

/// The bottom buttons of a screen. At accessibility sizes they go at the end of the scroll content,
/// so they never cover the text.
private struct BottomButtons<Buttons: View>: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let buttons: () -> Buttons

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content
        } else {
            content.safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) { buttons() }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
    }
}

/// First connect: the owner compares the fingerprint with the server, then trusts it.
/// The sheet cannot be swiped away. Cancel stops the connect.
struct TrustServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let host: String
    let key: HostKey

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ValueRow(title: "Host", value: host)
                    LabeledContent("Key type", value: key.displayType)
                    FingerprintRow(title: "Fingerprint", key: key)
                } footer: {
                    Text(Self.instructions(for: key))
                }
                if typeSize.isAccessibilitySize {
                    Section { buttons }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle("Trust This Server?")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(BottomButtons { buttons })
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .interactiveDismissDisabled()
    }

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await model.trustPendingHostKey() }
            } label: {
                Text("Trust Server").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Button("Cancel", role: .cancel) { model.cancelTrust() }
                .controlSize(.large)
        }
    }

    /// The text under the rows. The command names the host key file of the key type.
    static func instructions(for key: HostKey) -> LocalizedStringKey {
        "Compare this fingerprint with the server. Run `ssh-keygen -lf /etc/ssh/\(hostKeyFile(for: key))` on the server."
    }

    static func hostKeyFile(for key: HostKey) -> String {
        switch key.displayType {
        case "ECDSA": "ssh_host_ecdsa_key.pub"
        case "RSA": "ssh_host_rsa_key.pub"
        default: "ssh_host_ed25519_key.pub"
        }
    }
}

/// A changed host key: the app did not connect. There is no "Connect Anyway".
/// To accept a new key, the owner uses "Forget Host Key…" in Settings.
struct HostKeyChangedView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let saved: HostKey
    let received: HostKey

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                        Text("Server Identity Changed")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(Self.message)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 16) {
                        FingerprintRow(title: "Saved", key: saved)
                        FingerprintRow(title: "Received", key: received)
                    }
                    .padding()
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                    Text("To trust a new key, open Settings and use Forget Host Key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if typeSize.isAccessibilitySize { closeButton }
                }
                .padding(20)
            }
            .modifier(BottomButtons { closeButton })
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Text("Close").frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }

    static let message = "The host key for this server does not match the saved key. Hermes did not connect. Someone may be intercepting the connection."
}

/// Settings > Server > Host Key: the full fingerprint of the pinned key.
struct HostKeyDetailView: View {
    let key: HostKey

    var body: some View {
        Form {
            Section {
                LabeledContent("Key type", value: key.displayType)
                FingerprintRow(title: "Fingerprint", key: key)
            } footer: {
                Text("Hermes connects only to a server that has this key.")
            }
        }
        .navigationTitle("Host Key")
    }
}

struct HostKeyViews_Previews: PreviewProvider {
    static var previews: some View {
        Text("Chat")
            .sheet(isPresented: .constant(true)) {
                TrustServerSheet(host: "vps.example.com", key: .sample)
            }
            .environment(AppModel.preview(setUp: true))
        HostKeyChangedView(saved: .sample, received: .otherSample)
        NavigationStack { HostKeyDetailView(key: .sample) }
    }
}

/// Shows the trust sheet and the "Server Identity Changed" screen from the model state.
/// Only one presenter is enabled at a time: the root screen, or Settings while it is open.
struct HostTrustPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { enabled && model.pendingTrust != nil },
                set: { _ in }
            )) {
                if let key = model.pendingTrust {
                    TrustServerSheet(host: model.profile?.host ?? "", key: key)
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { enabled && model.showsHostKeyError },
                set: { model.showsHostKeyError = $0 }
            )) {
                if case .hostKeyChanged(let saved, let received) = model.connection {
                    HostKeyChangedView(saved: saved, received: received)
                }
            }
    }
}

extension View {
    func hostTrustPresenter(enabled: Bool) -> some View {
        modifier(HostTrustPresenter(enabled: enabled))
    }
}
