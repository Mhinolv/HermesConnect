import HermesKit
import SwiftUI

/// Settings: one grouped `Form` in a sheet. Later issues add rows here.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = ServerProfile.defaultPort
    @State private var confirmReset = false
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    ServerFieldRows(host: $host, port: $port)
                    NavigationLink("Public Key") { DeviceKeyView() }
                    NavigationLink("Install Steps") { InstallStepsView() }
                    Button("Reset Device Key…", role: .destructive) { confirmReset = true }
                        .foregroundStyle(.red)
                }
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
            .alert("Could not save the server.", isPresented: $saveFailed) {}
        }
        .onAppear {
            host = model.profile?.host ?? ""
            port = model.profile?.port ?? ServerProfile.defaultPort
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

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView().environment(AppModel.preview(setUp: true))
    }
}
