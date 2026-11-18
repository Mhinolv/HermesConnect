import HermesKit
import SwiftUI
import UIKit

/// Issue #66: Settings > Servers. One row for each server in the order added, then "Add Server".
struct ServersSection: View {
    @Environment(AppModel.self) private var model
    let onAdd: () -> Void

    var body: some View {
        Section("Servers") {
            ForEach(model.servers) { server in
                NavigationLink(value: server.id) {
                    ServerRow(server: server, isActive: server.id == model.profile?.id)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ServerRow.accessibilityLabel(server: server, isActive: server.id == model.profile?.id))
                .accessibilityAddTraits(.isButton)
            }
            Button(action: onAdd) {
                Label(ServerRow.addTitle, systemImage: "plus")
            }
        }
    }
}

/// The name, the host under it, and a checkmark on the active server. At AX5 the host wraps.
struct ServerRow: View {
    let server: ServerProfile
    let isActive: Bool

    static let addTitle = "Add Server"

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                if server.name != server.host {
                    Text(server.host)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isActive {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
            }
        }
    }

    /// "<name>, <host>, Active" (design notes). A name that is the host is read once.
    static func accessibilityLabel(server: ServerProfile, isActive: Bool) -> String {
        var parts = [server.name]
        if server.name != server.host { parts.append(server.host) }
        if isActive { parts.append("Active") }
        return parts.joined(separator: ", ")
    }
}

/// Issue #66: Settings > Servers > a server. Name, Host, Port, User, the host key of this server, and Remove.
struct ServerDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let serverID: UUID
    @State private var name = ""
    @State private var host = ""
    @State private var port = ServerProfile.defaultPort
    @State private var loaded = false
    @State private var confirmRemove: Bool
    @State private var confirmForget = false
    @State private var saveFailed = false
    @State private var removeFailed = false
    @State private var forgetFailed = false

    static let removeTitle = "Remove Server…"
    static let removeButton = "Remove Server"
    static let removeMessage = "This iPhone forgets the server, its host key and its chats. The chats stay on the server."
    static let duplicateFooter = "This server is already in the list."

    static func removeDialogTitle(_ server: ServerProfile) -> String { "Remove \u{201C}\(server.name)\u{201D}?" }

    init(serverID: UUID, confirmRemove: Bool = false) {
        self.serverID = serverID
        _confirmRemove = State(initialValue: confirmRemove)
    }

    private var server: ServerProfile? { model.serverList.server(id: serverID) }

    var body: some View {
        if let server {
            form(server)
        } else {
            // The server was removed. Settings pops this screen.
            Color.clear
        }
    }

    private func form(_ server: ServerProfile) -> some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $name, prompt: Text(trimmedHost.isEmpty ? server.host : trimmedHost))
                        .multilineTextAlignment(.trailing)
                }
                ServerFieldRows(host: $host, port: $port)
            } footer: {
                if isDuplicate { Text(Self.duplicateFooter) }
            }
            ServerLocationSection(serverID: serverID)
            Section {
                if let hostKey = server.hostKey {
                    NavigationLink {
                        HostKeyDetailView(key: hostKey)
                    } label: {
                        LabeledContent("Host Key", value: hostKey.shortFingerprint)
                    }
                    .accessibilityValue(hostKey.spokenFingerprint)
                } else {
                    LabeledContent("Host Key", value: "Not trusted yet")
                }
                // Issue #18: the last successful negotiation with this server, also when offline.
                LabeledContent("SSH algorithms") {
                    Text(server.lastAlgorithms?.displayText ?? "—")
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
                if server.hostKey != nil {
                    Button("Forget Host Key…", role: .destructive) { confirmForget = true }
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button(Self.removeTitle, role: .destructive) { confirmRemove = true }
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(title: "Done", enabled: isValid && !isDuplicate,
                              disabledHint: isDuplicate ? Self.duplicateFooter : "Enter a valid host and port.") {
                    save(server)
                }
            }
        }
        .confirmationDialog(Self.removeDialogTitle(server), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(Self.removeButton, role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.removeMessage)
        }
        .confirmationDialog("Forget Host Key?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                Task {
                    do { try await model.forgetHostKey(id: serverID) } catch { forgetFailed = true }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will ask you to trust the server again on the next connect.")
        }
        .alert("Could not save the server.", isPresented: $saveFailed) {}
        .alert("Could not remove the server.", isPresented: $removeFailed) {}
        .alert("Could not forget the host key.", isPresented: $forgetFailed) {}
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = server.displayName == server.host ? "" : server.displayName
            host = server.host
            port = server.port
        }
    }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var edited: ServerProfile? {
        guard var profile = server else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.host = trimmedHost
        profile.port = port
        profile.displayName = trimmedName.isEmpty ? trimmedHost : trimmedName
        return profile
    }

    private var isValid: Bool {
        ServerProfile.isValidHost(host) && ServerProfile.isValidPort(port)
    }

    private var isDuplicate: Bool {
        guard let edited else { return false }
        return model.containsServer(like: edited, excluding: serverID)
    }

    /// "Done" saves this server only. A new host, port or user clears its pin (`isDifferentServer`).
    private func save(_ server: ServerProfile) {
        guard let edited else { return }
        do {
            if edited != server { try model.updateServer(edited) }
            dismiss()
        } catch {
            saveFailed = true
        }
    }

    private func remove() {
        do {
            try model.removeServer(id: serverID)
            dismiss()
        } catch {
            removeFailed = true
        }
    }
}

/// Issue #92: the "Share Location" switch of one server, in the server detail. Off for a new server.
struct ServerLocationSection: View {
    @Environment(LocationController.self) private var location: LocationController?
    @Environment(\.openURL) private var openURL
    let serverID: UUID
    @State private var accessOff = false

    static let title = "Share Location"
    static let onFooter = "Hermes sends your location to this server when you move a long distance or arrive at a place."
    static let offFooter = "This server does not get your location."

    /// The footer of the switch. A refusal of the gate (`--no-location`) or another upload error shows under it.
    static func footer(isOn: Bool, status: LocationShareStatus) -> String {
        let text = isOn ? onFooter : offFooter
        guard let error = status.lastError else { return text }
        return "\(text)\nLast error: \(error)"
    }

    var body: some View {
        if let location {
            Section {
                Toggle(Self.title, isOn: Binding(
                    get: { location.isSharing(server: serverID) },
                    set: { if !location.setSharing($0, server: serverID) { accessOff = true } }
                ))
            } footer: {
                Text(Self.footer(isOn: location.isSharing(server: serverID), status: location.status(server: serverID)))
            }
            .alert("Location Access Off", isPresented: $accessOff) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Allow location access for Hermes in Settings.")
            }
        }
    }
}

#if DEBUG
/// DEBUG only: the issue #66 screenshots. `HERMES_DEMO_SERVERS=<list|detail|remove|new-server|one|share>`.
enum ServersDemo: String {
    /// Settings with 3 servers. The second is active.
    case list
    /// Server detail of the first server (pin trusted).
    case detail
    /// Server detail with the remove dialog open.
    case remove
    /// The "New Server" sheet with a host that is already in the list.
    case newServer = "new-server"
    /// Settings with one server (the migrated profile) and the checkmark.
    case one
    /// Issue #92: the "Share Location" section of the first server alone (for AX5).
    case share

    static var current: ServersDemo? {
        ProcessInfo.processInfo.environment["HERMES_DEMO_SERVERS"].flatMap(ServersDemo.init(rawValue:))
    }

    @MainActor static func makeModel(_ demo: ServersDemo) -> AppModel {
        let algorithms = SSHNegotiatedAlgorithms(cipher: "aes256-gcm@openssh.com", keyExchange: "curve25519-sha256")
        let home = ServerProfile(id: ServerProfile.legacyID, host: "100.101.7.12", displayName: "Home Agent",
                                 hostKey: .sample, lastAlgorithms: algorithms)
        if demo == .one { return AppModel.preview(servers: [home], activeIndex: 0) }
        let lab = ServerProfile(host: "lab.tailnet-1234.ts.net", displayName: "Lab", hostKey: .otherSample,
                                lastAlgorithms: algorithms)
        let fresh = ServerProfile(host: "100.88.4.20")
        return AppModel.preview(servers: [home, lab, fresh], activeIndex: 1)
    }
}
#endif

struct ServerViews_Previews: PreviewProvider {
    static var previews: some View {
        let model = AppModel.preview(servers: [ServerProfile(host: "vps.example.com", displayName: "Home", hostKey: .sample),
                                               ServerProfile(host: "100.88.4.20")], activeIndex: 0)
        NavigationStack {
            Form { ServersSection(onAdd: {}) }
                .navigationDestination(for: UUID.self) { ServerDetailView(serverID: $0) }
        }
        .environment(model)
        .environment(LocationController.preview(servers: model.servers, sharing: [model.servers[0].id]))
    }
}
