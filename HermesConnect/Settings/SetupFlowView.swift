import HermesKit
import SwiftUI

/// The setup sheet: Server, Device Key, Install on Server. "Done" saves the profile and closes the sheet.
struct SetupFlowView: View {
    enum Step: Hashable {
        case deviceKey
        case install
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []
    @State private var host = ""
    @State private var port = ServerProfile.defaultPort
    @State private var saveFailed = false

    var body: some View {
        NavigationStack(path: $path) {
            ServerFields(host: $host, port: $port)
                .navigationTitle("Server")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        ConfirmButton(title: "Next", enabled: isValid, disabledHint: "Enter the host first.") {
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
            if let profile = model.profile {
                host = profile.host
                port = profile.port
            }
        }
    }

    private var isValid: Bool {
        ServerProfile.isValidHost(host) && ServerProfile.isValidPort(port)
    }

    private func finish() {
        do {
            try model.saveProfile(ServerProfile(host: host, port: port))
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}

/// Host, Port and the fixed User row. Setup and Settings use it.
struct ServerFields: View {
    @Binding var host: String
    @Binding var port: Int

    var body: some View {
        Form {
            Section {
                ServerFieldRows(host: $host, port: $port)
            } footer: {
                Text("The app connects over SSH as the user hermes.")
            }
        }
    }
}

struct ServerFieldRows: View {
    @Binding var host: String
    @Binding var port: Int

    var body: some View {
        LabeledContent("Host") {
            TextField("Host", text: $host, prompt: Text("vps.example.com"))
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
