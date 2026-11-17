import HermesKit
import SwiftUI
import UIKit

/// Settings: one grouped `Form` in a sheet. Later issues add rows here.
/// Issue #66: "Servers" lists each server. "Device Key" is one key for all servers.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The pushed server detail screens (issue #66).
    @State private var path: [UUID]
    @State private var showAddServer: Bool
    @State private var confirmReset = false
    /// DEBUG screenshots open the remove dialog of the pushed server, or fill the host of "New Server".
    private let opensRemoveDialog: Bool
    private let addServerHost: String

    static let deviceKeyFooter = "One device key connects this iPhone to each server."

    init(path: [UUID] = [], showAddServer: Bool = false, opensRemoveDialog: Bool = false, addServerHost: String = "") {
        _path = State(initialValue: path)
        _showAddServer = State(initialValue: showAddServer)
        self.opensRemoveDialog = opensRemoveDialog
        self.addServerHost = addServerHost
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                ServersSection { showAddServer = true }
                Section {
                    NavigationLink("Public Key") { DeviceKeyView() }
                    NavigationLink("Install Steps") { InstallStepsView() }
                    Button("Reset Device Key…", role: .destructive) { confirmReset = true }
                        .foregroundStyle(.red)
                } header: {
                    Text("Device Key")
                } footer: {
                    Text(Self.deviceKeyFooter)
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
                TranscriptionSettingsSection()
                NotificationSettingsSection()
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
            .navigationDestination(for: UUID.self) { id in
                ServerDetailView(serverID: id, confirmRemove: opensRemoveDialog)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(title: "Done", enabled: true) { dismiss() }
                }
            }
            .confirmationDialog("Reset Device Key?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset Key", role: .destructive) { Task { await model.resetKey() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The server will reject this iPhone until you install the new public key.")
            }
            .sheet(isPresented: $showAddServer) { SetupFlowView(mode: .newServer, host: addServerHost) }
            .hostTrustPresenter(enabled: !showAddServer)
        }
        // Issue #66: with no server left, close Settings. The root shows "Set Up Hermes".
        .onChange(of: model.servers.isEmpty) { _, empty in
            if empty { dismiss() }
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

/// Issue #15: Settings > Notifications. "Show Message Preview" is off by default (owner decision 2026-11-16).
struct NotificationSettingsSection: View {
    @Environment(NotificationController.self) private var notifications: NotificationController?
    @Environment(\.openURL) private var openURL

    static let previewTitle = "Show Message Preview"
    static let offTitle = "Notifications Off"
    static let siriTitle = "Use Siri When Locked"
    static let siriFooter = "Siri can read and send Hermes messages while your iPhone is locked."
    static let footer = "A notification says \"New message from Hermes\". Turn on the preview to show "
        + "the first part of the reply."

    var body: some View {
        if let notifications {
            @Bindable var notifications = notifications
            Section {
                if notifications.status == .denied {
                    LabeledContent(Self.offTitle) {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        }
                    }
                }
                Toggle(Self.previewTitle, isOn: $notifications.showsPreview)
            } header: {
                Text("Notifications")
            } footer: {
                Text(Self.footer)
            }
            .task { await notifications.refreshStatus() }
            // Issue #45: off by default. With it off, a locked iPhone makes Siri say "Unlock your iPhone to use Hermes."
            Section {
                Toggle(Self.siriTitle, isOn: $notifications.usesSiriWhenLocked)
            } footer: {
                Text(Self.siriFooter)
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView().environment(AppModel.preview(setUp: true)).environment(LocationController.preview())
    }
}
