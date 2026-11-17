import HermesKit
import SwiftUI

/// Settings: one grouped `Form` in a sheet. Later issues add rows here.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = ServerProfile.defaultPort
    @State private var confirmReset = false
    @State private var confirmForget = false
    @State private var forgetFailed = false
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    ServerFieldRows(host: $host, port: $port)
                    NavigationLink("Public Key") { DeviceKeyView() }
                    NavigationLink("Install Steps") { InstallStepsView() }
                    if let hostKey = model.profile?.hostKey {
                        NavigationLink {
                            HostKeyDetailView(key: hostKey)
                        } label: {
                            LabeledContent("Host Key", value: hostKey.shortFingerprint)
                        }
                        .accessibilityValue(hostKey.spokenFingerprint)
                    } else {
                        LabeledContent("Host Key", value: "Not trusted yet")
                    }
                    // Issue #18: the last successful negotiation, also when offline.
                    LabeledContent("SSH algorithms") {
                        Text(model.profile?.lastAlgorithms?.displayText ?? "—")
                            .font(.footnote.monospaced())
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                    Button("Reset Device Key…", role: .destructive) { confirmReset = true }
                        .foregroundStyle(.red)
                    if model.profile?.hostKey != nil {
                        Button("Forget Host Key…", role: .destructive) { confirmForget = true }
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    LabeledContent("Status", value: connectionText)
                    Button("Connect") { Task { await model.connect() } }
                        .disabled(model.connection == .connecting || model.connection == .startingHermes
                                  || !model.isSetUp)
                } header: {
                    Text("Connection")
                } footer: {
                    if let reason = connectionReason { Text(reason) }
                }
                VoiceSettingsSection()
                LocationSettingsSection()
                PhotoSettingsSection()
                Section {
                    Toggle(Authenticator.appLockToggleTitle, isOn: Binding(
                        get: { model.lock.isEnabled },
                        set: { model.setAppLockEnabled($0) }
                    ))
                } header: {
                    Text("Security")
                } footer: {
                    Text(Authenticator.appLockFooter)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(title: "Done", enabled: isValid, disabledHint: "Enter a valid host and port.") { save() }
                }
            }
            .confirmationDialog("Reset Device Key?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset Key", role: .destructive) { Task { await model.resetKey() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The server will reject this iPhone until you install the new public key.")
            }
            .confirmationDialog("Forget Host Key?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    Task {
                        do { try await model.forgetHostKey() } catch { forgetFailed = true }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Hermes will ask you to trust the server again on the next connect.")
            }
            .alert("Could not save the server.", isPresented: $saveFailed) {}
            .alert("Could not forget the host key.", isPresented: $forgetFailed) {}
            .hostTrustPresenter(enabled: true)
        }
        .onAppear {
            host = model.profile?.host ?? ""
            port = model.profile?.port ?? ServerProfile.defaultPort
        }
    }

    /// The Settings > Connection status. It never shows the port or the token (issue #4).
    private var connectionText: String {
        switch model.connection {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .startingHermes: "Starting Hermes…"
        case .connected: "Hermes ready"
        case .offline: "Offline"
        case .hostKeyChanged, .notStarted: "Not connected"
        }
    }

    private var connectionReason: String? {
        switch model.connection {
        case .offline(let error?), .notStarted(let error): error.description
        case .hostKeyChanged: "The server host key changed. Hermes did not connect."
        default: nil
        }
    }

    private var isValid: Bool {
        ServerProfile.isValidHost(host) && ServerProfile.isValidPort(port)
    }

    private func save() {
        var profile = model.profile ?? ServerProfile(host: host, port: port)
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if profile.displayName == profile.host { profile.displayName = trimmed }
        profile.host = trimmed
        profile.port = port
        do {
            if profile != model.profile { try model.saveProfile(profile) }
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}

/// Settings > Voice (issue #10). Auto-play is on by default (owner decision 2026-11-16).
struct VoiceSettingsSection: View {
    @AppStorage(VoiceReplySettings.autoPlayKey) private var autoPlay = true

    static let toggleTitle = "Auto-Play Voice Replies"
    static let footer = "Hermes speaks replies to your voice memos."

    var body: some View {
        Section {
            Toggle(Self.toggleTitle, isOn: $autoPlay)
        } header: {
            Text("Voice")
        } footer: {
            Text(Self.footer)
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView().environment(AppModel.preview(setUp: true)).environment(LocationController.preview())
    }
}
