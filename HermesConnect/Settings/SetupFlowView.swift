import HermesKit
import SwiftUI

/// The setup sheet: Server, Device Key, Install on Server. "Done" saves the profile and closes the sheet.
/// Issue #66: Settings > "Add Server" shows it as "New Server", with a Name row above Host.
struct SetupFlowView: View {
    enum Step: Hashable {
        case deviceKey
        case install
    }

    enum Mode {
        /// The first server. No change from before issue #66: the host is the name.
        case firstRun
        /// One more server. "Done" adds it and makes it the active server.
        case newServer
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var mode: Mode = .firstRun
    @State private var path: [Step] = []
    @State private var name = ""
    @State private var host: String
    @State private var port = ServerProfile.defaultPort
    @State private var saveFailed = false

    static let newServerTitle = "New Server"

    init(mode: Mode = .firstRun, host: String = "") {
        self.mode = mode
        _host = State(initialValue: host)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ServerFields(name: mode == .newServer ? $name : nil, host: $host, port: $port,
                         isDuplicate: isDuplicate)
                .navigationTitle(mode == .newServer ? Self.newServerTitle : "Server")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        ConfirmButton(title: "Next", enabled: isValid && !isDuplicate,
                                      disabledHint: isDuplicate ? ServerDetailView.duplicateFooter
                                          : "Enter the host first.") {
                            path.append(.deviceKey)
                        }
                    }
                }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .deviceKey:
                        DeviceKeyView { path.append(.install) }
                    case .install:
                        InstallStepsView { finish() }
                    }
                }
        }
        .interactiveDismissDisabled(!path.isEmpty)
        .alert("Could not save the server.", isPresented: $saveFailed) {}
        .onAppear {
            if mode == .firstRun, let profile = model.profile {
                host = profile.host
                port = profile.port
            }
        }
    }

    private var isValid: Bool {
        ServerProfile.isValidHost(host) && ServerProfile.isValidPort(port)
    }

    /// Issue #66: a new server with the host, port and user of a saved server cannot go on.
    private var isDuplicate: Bool {
        mode == .newServer && model.containsServer(like: ServerProfile(host: host, port: port))
    }

    private func finish() {
        do {
            switch mode {
            case .firstRun:
                // A saved server keeps its id, and its pin when the host, port and user stay the same.
                let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
                var profile = model.profile ?? ServerProfile(host: trimmed, port: port)
                if profile.displayName == profile.host { profile.displayName = trimmed }
                profile.host = trimmed
                profile.port = port
                try model.saveProfile(profile)
            case .newServer:
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                try model.addServer(ServerProfile(host: host, port: port, displayName: trimmed.isEmpty ? nil : trimmed))
            }
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}

/// Host, Port and the fixed User row. Setup and Settings use it. Issue #66: "New Server" adds a Name row.
struct ServerFields: View {
    var name: Binding<String>?
    @Binding var host: String
    @Binding var port: Int
    var isDuplicate = false

    var body: some View {
        Form {
            Section {
                if let name {
                    LabeledContent("Name") {
                        TextField("Name", text: name, prompt: Text(host.isEmpty ? "Name" : host))
                            .multilineTextAlignment(.trailing)
                    }
                }
                ServerFieldRows(host: $host, port: $port)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if isDuplicate {
                        Text(ServerDetailView.duplicateFooter).fontWeight(.semibold)
                    }
                    Text("\(ServerProfile.hostHint) The app connects over SSH as the user hermes.")
                }
            }
        }
    }
}

struct ServerFieldRows: View {
    @Binding var host: String
    @Binding var port: Int

    var body: some View {
        LabeledContent("Host") {
            TextField("Host", text: $host, prompt: Text(ServerProfile.exampleHost))
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("Port") {
            TextField("Port", value: $port, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("User") {
            Text(ServerProfile.defaultUser).foregroundStyle(.secondary)
        }
    }
}

struct SetupFlowView_Previews: PreviewProvider {
    static var previews: some View {
        SetupFlowView().environment(AppModel.preview(setUp: false))
    }
}
