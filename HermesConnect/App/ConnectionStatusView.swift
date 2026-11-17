import HermesKit
import SwiftUI

/// The shared connection status: the subtitle under the chat navigation title (issue #3).
/// It never shows the host name.
struct ConnectionStatusView: View {
    @Environment(AppModel.self) private var model
    /// "Connected" shows for 2 seconds, then the subtitle hides.
    @State private var hidesConnected = false

    var body: some View {
        content
            .font(.caption)
            .foregroundStyle(.secondary)
            .task(id: model.connection) {
                hidesConnected = false
                guard case .connected = model.connection else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { withAnimation { hidesConnected = true } }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.connection {
        case .idle:
            EmptyView()
        case .connecting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Connecting…")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Connection status, Connecting")
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
        }
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
            ChatTitleView().environment(model(.connected(gateVersion: "1")))
            ChatTitleView().environment(model(.offline(.unreachable)))
            ChatTitleView().environment(model(.hostKeyChanged(saved: .sample, received: .otherSample)))
        }
    }
}
