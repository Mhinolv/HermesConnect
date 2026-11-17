import HermesKit
import SwiftUI

/// The chat screen: the MessageKit thread with the session title and the connection status (issue #6).
struct ChatScreen: View {
    let model: ChatViewModel
    var onSettings: () -> Void = {}

    var body: some View {
        ChatThreadView(model: model)
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { ChatNavigationTitle(title: model.title) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape", action: onSettings)
                }
            }
            .task { await model.run() }
    }
}

/// The session title ("New Chat" for a new session) with the #3 connection status under it.
struct ChatNavigationTitle: View {
    let title: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(title ?? "New Chat")
                .font(.headline)
                .lineLimit(1)
            ConnectionStatusView()
        }
        .accessibilityElement(children: .combine)
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

/// The transport until the tunnel (#4) gives the app a `GatewayClient`. Every send fails with
/// "Not Delivered", so the owner sees that no server is connected.
struct OfflineChatTransport: ChatTransport {
    struct NotConnected: Error {}

    let events: AsyncStream<GatewayClientEvent> = AsyncStream { _ in }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
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
    static var isDemo: Bool {
        #if DEBUG
        DemoChatTransport.Scenario.current != nil
        #else
        false
        #endif
    }

    static func makeModel() -> ChatViewModel {
        #if DEBUG
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
        #endif
        // Until #4 gives the app a GatewayClient, the chat has no server.
        return ChatViewModel(transport: OfflineChatTransport())
    }
}
