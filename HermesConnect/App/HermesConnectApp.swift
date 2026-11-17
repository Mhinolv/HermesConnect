import SwiftUI
import HermesKit

@main
struct HermesConnectApp: App {
    @State private var model: AppModel
    @State private var sessions: SessionListModel
    /// The Release chat link to Hermes. Nil in the DEBUG demo.
    private let link: LiveChatTransport?
    private let usesAppLock: Bool

    init() {
        #if DEBUG
        if ChatLaunch.isDemo {
            sessions = ChatLaunch.makeDemoSessions()
            link = nil
            // The DEBUG demo conversation: no server, no App Lock, so screenshots show the chat.
            let demo = AppModel.preview(setUp: true, hostKey: .sample)
            demo.previewConnection(.connected(gateVersion: "demo"))
            model = demo
            usesAppLock = false
            return
        }
        #endif
        let live = AppModel.live()
        let link = ChatLaunch.makeLink(renew: { await live.renewHermesSession() })
        model = live
        self.link = link
        sessions = ChatLaunch.makeSessions(link: link)
        usesAppLock = true
    }

    var body: some Scene {
        WindowGroup {
            if usesAppLock {
                RootView(sessions: sessions, link: link)
                    .environment(model)
                    .appLock(model)
            } else {
                RootView(sessions: sessions, link: link)
                    .environment(model)
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    /// The session list and the chats of this window (issue #7). The app owns it, so it lives across view updates.
    var sessions = ChatLaunch.makeOfflineSessions()
    /// The chat link. It follows the #4 endpoint ("Hermes ready").
    var link: LiveChatTransport?
    @State private var showSetup = false
    @State private var showSettings = false
    /// The list is the root. A chat is pushed on top of it.
    @State private var path: [ChatRoute] = []
    /// `true` after the launch push, or after the owner moved in the stack. Then launch pushes nothing more.
    @State private var launchDone = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.isSetUp {
                    SessionListScreen(model: sessions, link: link, query: ChatLaunch.demoSearch,
                                      onSettings: { showSettings = true },
                                      onNewChat: { path.append(.new(UUID().uuidString)) })
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
            .navigationDestination(for: ChatRoute.self) { route in
                switch route {
                case .session(let id): ChatScreen(model: sessions.chat(for: id), link: link)
                case .new(let key): ChatScreen(model: sessions.newChat(key: key), link: link)
                }
            }
            .hermesStartAlert()
        }
        .sheet(isPresented: $showSetup) { SetupFlowView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .hostTrustPresenter(enabled: !showSetup && !showSettings)
        .onChange(of: model.hermesEndpoint, initial: true) { _, endpoint in
            link?.setEndpoint(endpoint)
        }
        .onAppear {
            sessions.startEvents()
            // Launch pushes the last session at once, from the cache. No cache: wait for `session.most_recent`.
            guard model.isSetUp, !launchDone, path.isEmpty else { return }
            if let route = ChatLaunch.cachedLaunchRoute(sessions) {
                path = [route]
                launchDone = true
            }
        }
        .onChange(of: path) { launchDone = true }
        .onChange(of: model.connection, initial: true) { _, connection in
            guard case .connected = connection, model.isSetUp, !launchDone, path.isEmpty else { return }
            Task {
                let id = await sessions.mostRecentSessionId()
                guard !launchDone, path.isEmpty else { return }
                launchDone = true
                if let id { path = [.session(id)] }
            }
        }
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
