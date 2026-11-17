import HermesKit
import SwiftUI

/// The shared connection status: the subtitle under the chat navigation title (issue #3).
/// It never shows the host name.
struct ConnectionStatusView: View {
    @Environment(AppModel.self) private var model
    /// "Connected" shows for 2 seconds, then the subtitle hides.
    @State private var hidesConnected = false
    /// "Starting Hermes…" shows only when the stage takes more than 1 second (issue #4).
    @State private var showsStarting = false
    /// Stages that VoiceOver announced since the last "Connected". A retry does not announce them again.
    @State private var announced: Set<String> = []

    static let startingDelay: Duration = .seconds(1)

    var body: some View {
        content
            .font(.caption)
            .foregroundStyle(.secondary)
            .task(id: model.connection) {
                hidesConnected = false
                showsStarting = false
                switch model.connection {
                case .connected:
                    announced.removeAll()
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { withAnimation { hidesConnected = true } }
                case .startingHermes:
                    try? await Task.sleep(for: Self.startingDelay)
                    guard !Task.isCancelled else { return }
                    showsStarting = true
                    announceOnce("Starting Hermes")
                case .notStarted:
                    announceOnce("Not connected. Hermes did not start.")
                default:
                    break
                }
            }
    }

    private func announceOnce(_ text: String) {
        guard announced.insert(text).inserted else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    @ViewBuilder private var content: some View {
        switch model.connection {
        case .idle:
            EmptyView()
        case .connecting:
            progress("Connecting…", spoken: "Connecting")
        case .startingHermes:
            if showsStarting {
                progress("Starting Hermes…", spoken: "Starting Hermes")
            } else {
                progress("Connecting…", spoken: "Connecting")
            }
        case .connected:
            if !hidesConnected {
                Text("Connected")
                    .accessibilityLabel("Connection status, Connected")
            }
        case .offline:
            Button {
                Task { await model.connect() }
            } label: {
                Label("Offline", systemImage: "arrow.clockwise")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connection status, Offline")
            .accessibilityHint("Double-tap to retry.")
        case .hostKeyChanged:
            Button {
                model.showsHostKeyError = true
            } label: {
                Label("Not connected", systemImage: "exclamationmark.shield.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel("Connection status, Not connected. The server identity changed.")
            .accessibilityHint("Double-tap for details.")
        case .notStarted:
            Button {
                model.showsHermesStartError = true
            } label: {
                Label("Not connected", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel("Connection status, Not connected. Hermes did not start.")
            .accessibilityHint("Double-tap for details.")
        }
    }

    private func progress(_ text: String, spoken: String) -> some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            Text(text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection status, \(spoken)")
    }
}

/// The text, then the symbol: "Offline ↻".
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

extension View {
    /// The "Hermes Did Not Start" alert of issue #4. "Install Steps" pushes the setup screen 3 (`InstallStepsView`).
    /// Put it inside the `NavigationStack`. The alert never shows server log text, the token or the port.
    func hermesStartAlert() -> some View {
        modifier(HermesStartAlert())
    }
}

struct HermesStartAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var showsInstallSteps = false

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .alert(HermesStartAlert.title, isPresented: $model.showsHermesStartError) {
                Button("Install Steps") { showsInstallSteps = true }
                Button("OK", role: .cancel) {}
            } message: {
                Text(HermesStartAlert.message)
            }
            .navigationDestination(isPresented: $showsInstallSteps) { InstallStepsView() }
    }

    static let title = "Hermes Did Not Start"
    static let message = "The server refused the request. Check the install steps in Settings."
}

/// The chat navigation title with the connection status under it.
struct ChatTitleView: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("Hermes").font(.headline)
            ConnectionStatusView()
        }
    }
}

struct ConnectionStatusView_Previews: PreviewProvider {
    static func model(_ state: AppModel.ConnectionState) -> AppModel {
        let model = AppModel.preview(setUp: true)
        model.previewConnection(state)
        return model
    }

    static var previews: some View {
        VStack(spacing: 24) {
            ChatTitleView().environment(model(.connecting))
            ChatTitleView().environment(model(.startingHermes))
            ChatTitleView().environment(model(.connected(gateVersion: "1")))
            ChatTitleView().environment(model(.offline(.unreachable)))
            ChatTitleView().environment(model(.hostKeyChanged(saved: .sample, received: .otherSample)))
            ChatTitleView().environment(model(.notStarted(.gateError("hermes-not-found"))))
        }
    }
}
