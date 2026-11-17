import SwiftUI
import HermesKit

@main
struct HermesConnectApp: App {
    @State private var model: AppModel
    @State private var chat: ChatViewModel
    private let usesAppLock: Bool

    init() {
        chat = ChatLaunch.makeModel()
        #if DEBUG
        if ChatLaunch.isDemo {
            // The DEBUG demo conversation: no server, no App Lock, so screenshots show the chat.
            let demo = AppModel.preview(setUp: true, hostKey: .sample)
            demo.previewConnection(.connected(gateVersion: "demo"))
            model = demo
            usesAppLock = false
            return
        }
        #endif
        model = AppModel.live()
        usesAppLock = true
    }

    var body: some Scene {
        WindowGroup {
            if usesAppLock {
                RootView(chat: chat)
                    .environment(model)
                    .appLock(model)
            } else {
                RootView(chat: chat)
                    .environment(model)
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    /// The chat of this window. The app owns it, so it lives across view updates.
    var chat = ChatViewModel(transport: OfflineChatTransport())
    @State private var showSetup = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if model.isSetUp {
                    ChatScreen(model: chat) { showSettings = true }
                } else {
                    ContentUnavailableView {
                        Label("Set Up Hermes", systemImage: "key.horizontal")
                    } description: {
                        Text("Connect this iPhone to your Hermes server.")
                    } actions: {
                        Button("Set Up Server") { showSetup = true }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
            .navigationTitle("Hermes")
        }
        .sheet(isPresented: $showSetup) { SetupFlowView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .hostTrustPresenter(enabled: !showSetup && !showSettings)
        .task(id: model.isSetUp) {
            if model.isSetUp, !ChatLaunch.isDemo { await model.connect() }
        }
        .onChange(of: showSettings) { _, shown in
            // A new server or a forgotten host key leaves the status idle. Connect when Settings closes.
            if !shown, model.isSetUp, model.connection == .idle { Task { await model.connect() } }
        }
    }
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView().environment(AppModel.preview(setUp: false))
        RootView().environment(AppModel.preview(setUp: true))
    }
}
