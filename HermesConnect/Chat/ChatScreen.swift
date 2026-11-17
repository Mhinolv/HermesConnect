import HermesKit
import SwiftUI

/// The chat screen: the MessageKit thread with the session title and the connection status (issue #6).
struct ChatScreen: View {
    let model: ChatViewModel
    var link: LiveChatTransport?
    var onSettings: () -> Void = {}

    var body: some View {
        ChatThreadView(model: model)
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { ChatNavigationTitle(title: model.title, link: link) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape", action: onSettings)
                }
            }
            .task { await model.run() }
    }
}

/// The session title ("New Chat" for a new session) with the connection status under it.
/// A stale Hermes token shows "Reconnecting…" while #4 starts a new session, then "Not connected" if it fails.
struct ChatNavigationTitle: View {
    @Environment(AppModel.self) private var app
    let title: String?
    var link: LiveChatTransport?

    var body: some View {
        VStack(spacing: 0) {
            Text(title ?? "New Chat")
                .font(.headline)
                .lineLimit(1)
            status
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var status: some View {
        switch ChatLaunch.subtitle(link: link?.status, connection: app.connection) {
        case .reconnecting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Reconnecting…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Connection status, Reconnecting")
        case .chatFailed:
            Button {
                link?.retry()
            } label: {
                Label("Not connected", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityLabel("Connection status, Not connected. Hermes refused the session.")
            .accessibilityHint("Double-tap to retry.")
        case .connection:
            ConnectionStatusView()
        }
    }
}

/// `ChatViewController` in SwiftUI.
struct ChatThreadView: UIViewControllerRepresentable {
    let model: ChatViewModel

    func makeUIViewController(context _: Context) -> ChatViewController {
        ChatViewController(model: model)
    }

    func updateUIViewController(_: ChatViewController, context _: Context) {}
}

/// A transport with no server: every send fails with "Not Delivered". Previews, tests and the DEBUG
/// fallback use it. Release builds use `LiveChatTransport`, which also fails sends while not connected.
struct OfflineChatTransport: ChatTransport {
    struct NotConnected: Error {}

    let events: AsyncStream<GatewayClientEvent> = AsyncStream { _ in }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        throw NotConnected()
    }

    func resumeSession(storedId _: String, source _: String) async throws -> ChatSessionRef {
        throw NotConnected()
    }

    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? {
        throw NotConnected()
    }

    func stopReply(sessionId _: String) async throws -> Bool { false }
}

struct ChatScreen_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ChatScreen(model: ChatViewModel(transport: OfflineChatTransport()))
        }
        .environment(AppModel.preview(setUp: true))
    }
}

/// Makes the chat model at launch. DEBUG builds with `HERMES_DEMO` set use the demo conversation.
@MainActor
enum ChatLaunch {
    enum Subtitle: Equatable {
        /// The #3 and #4 connection status.
        case connection
        case reconnecting
        case chatFailed
    }

    /// The SSH and serve stages win when they fail (Offline, Not connected). Else the chat link state shows.
    static func subtitle(link: ChatLinkStatus?, connection: AppModel.ConnectionState) -> Subtitle {
        switch connection {
        case .offline, .notStarted, .hostKeyChanged: return .connection
        case .idle, .connecting, .startingHermes, .connected: break
        }
        switch link {
        case .reconnecting: return .reconnecting
        case .failed: return .chatFailed
        default: return .connection
        }
    }

    /// The Release chat link. `renew` asks #4 for a new Hermes session after a stale token.
    static func makeLink(renew: @escaping @MainActor () async -> Void) -> LiveChatTransport {
        let link = LiveChatTransport()
        link.onStaleToken = renew
        return link
    }

    static var isDemo: Bool {
        #if DEBUG
        DemoChatTransport.Scenario.current != nil
        #else
        false
        #endif
    }

    #if DEBUG
    static func makeDemoModel() -> ChatViewModel {
        if let scenario = DemoChatTransport.Scenario.current {
            let transport = DemoChatTransport(scenario: scenario)
            let model = ChatViewModel(transport: transport, title: scenario == .empty ? nil : "Calendar and logs",
                                      messages: transport.seedMessages())
            if let prompt = scenario.autoPrompt {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    model.send(prompt)
                }
            }
            return model
        }
        return ChatViewModel(transport: OfflineChatTransport())
    }
    #endif
}
