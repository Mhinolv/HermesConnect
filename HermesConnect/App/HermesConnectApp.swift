import HermesKit
import SwiftUI
import UserNotifications

@main
struct HermesConnectApp: App {
    @State private var model: AppModel
    @State private var sessions: SessionListModel
    /// Made at launch, also for a relaunch in the background by a location event (issue #13).
    @State private var location: LocationController
    /// Issue #15: permission, badge and the tap route of local notifications.
    @State private var notifications: NotificationController
    /// The Release chat link to Hermes. Nil in the DEBUG demo.
    private let link: LiveChatTransport?
    private let usesAppLock: Bool

    init() {
        // QA 52-1: no model download unless the owner taps Download.
        OnDeviceTranscription.lockModelNetwork()
        #if DEBUG
        if ChatLaunch.isDemo {
            sessions = ChatLaunch.makeDemoSessions()
            link = nil
            // The DEBUG demo conversation: no server, no App Lock, so screenshots show the chat.
            let demo = AppModel.preview(setUp: true, hostKey: .sample)
            demo.previewConnection(.connected(gateVersion: "demo"))
            model = demo
            location = LocationController.preview(enabled: false)
            let off = ChatLaunch.demoScenario == .notificationsOff
            notifications = NotificationController(center: DemoNotificationCenter(status: off ? .denied : .authorized),
                                                   defaults: UserDefaults(suiteName: "demo") ?? .standard)
            usesAppLock = false
            return
        }
        #endif
        let live = AppModel.live()
        let link = ChatLaunch.makeLink(renew: { await live.renewHermesSession() })
        model = live
        location = LocationController.live()
        self.link = link
        let sessions = ChatLaunch.makeSessions(link: link)
        self.sessions = sessions
        let notifications = NotificationController()
        self.notifications = notifications
        UNUserNotificationCenter.current().delegate = notifications
        // Issue #45: the Siri shortcuts run in this process, also in a launch in the background.
        SiriRuntime.service = SiriService(model: live, link: link, sessions: sessions, notifications: notifications)
        // Issue #15: register before the app finishes launching (BGTaskScheduler rule).
        BackgroundRefresh.register {
            await BackgroundRefresh.run(model: live, link: link, sessions: sessions, notifications: notifications)
        }
        usesAppLock = true
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ChatLaunch.demoScenario?.showsNotificationSettings == true {
                // Issue #15: the DEBUG screenshot of Settings > Notifications.
                NavigationStack {
                    Form { NotificationSettingsSection() }
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .environment(notifications)
            } else if let demo = ChatLaunch.demoScenario, demo.showsVoiceSettings {
                // Issue #44: the DEBUG screenshot of Settings > Voice.
                NavigationStack {
                    Form {
                        VoiceSettingsSection()
                        TranscriptionSettingsSection(parakeet: TranscriptionSettingsDemo.store(for: demo))
                    }
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                }
            } else {
                scene
            }
            #else
            scene
            #endif
        }
    }

    @ViewBuilder private var scene: some View {
        Group {
            if usesAppLock {
                RootView(sessions: sessions, link: link)
                    .environment(model)
                    .environment(location)
                    .environment(notifications)
                    .appLock(model)
            } else {
                RootView(sessions: sessions, link: link)
                    .environment(model)
                    .environment(location)
                    .environment(notifications)
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(NotificationController.self) private var notifications: NotificationController?
    @Environment(\.scenePhase) private var scenePhase
    /// Issue #15: when the app went to the background. Nil while it is active.
    @State private var backgroundedAt: Date?
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
    /// Issue #16: the "Ask Hermes" shortcut puts its request here.
    var ask = AskHermesInbox.shared

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
                let chat = switch route {
                case .session(let id): sessions.chat(for: id)
                case .new(let key): sessions.newChat(key: key)
                }
                ChatScreen(model: chat, link: link) {
                    // A dead id (QA #27 defect 1): drop it and show the list, never an empty chat.
                    if let id = chat.storedSessionId { sessions.forget(id) }
                    path.removeAll()
                }
                // Issue #15: the open session loses its blue dot and gets no new one.
                // The list follows the chat, so a New Chat counts once it gets its id (QA #38 defect 2).
                .onAppear { sessions.openChat(chat) }
                .onDisappear { sessions.closeChat(chat) }
            }
            .hermesStartAlert()
        }
        .sheet(isPresented: $showSetup) { SetupFlowView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .hostTrustPresenter(enabled: !showSetup && !showSettings)
        .locationAccessPrompt(enabled: !showSetup && !showSettings && model.pendingTrust == nil)
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
        .onChange(of: scenePhase) { _, phase in foregroundChange(phase) }
        // Issue #15: a tap on a notification opens that session. App Lock stays on top until unlock.
        .onChange(of: notifications?.pendingSessionId) { _, id in
            guard let id, model.isSetUp else { return }
            notifications?.pendingSessionId = nil
            launchDone = true
            path = [.session(id)]
        }
        // Issue #16: "Ask Hermes" waits for setup and App Lock, then sends the text at once.
        .onChange(of: ask.pending, initial: true) { askHermes() }
        .onChange(of: model.lock) { askHermes() }
        .onChange(of: scenePhase) { askHermes() }
        .onChange(of: sessions.unreadCount, initial: true) { _, count in
            if !ChatLaunch.isDemo { notifications?.setBadge(count) }
        }
        .onChange(of: showSettings) { _, shown in
            // A new server or a forgotten host key leaves the status idle. Connect when Settings closes.
            if !shown, model.isSetUp, model.connection == .idle { Task { await model.connect() } }
        }
    }
}

extension RootView {
    /// Issue #16: run the "Ask Hermes" request that waits. App Lock covers the app until Face ID, so the
    /// text never goes before an unlock. No setup: show the setup screen and drop the text.
    private func askHermes() {
        guard scenePhase == .active else { return }
        let locked = !ChatLaunch.isDemo && model.lock.locks(at: .now)
        switch ask.next(isSetUp: model.isSetUp, isLocked: locked) {
        case nil:
            return
        case .dropForSetup:
            showSettings = false
            showSetup = true
        case .run(let request):
            launchDone = true
            showSettings = false
            let link = self.link
            Task {
                await AskHermes.run(request, sessions: sessions,
                                    linkReady: { await AskHermes.waitUntilReady { link?.status } },
                                    show: { route in
                                        launchDone = true
                                        path = [ChatRoute(route)]
                                    })
            }
        }
    }

    /// Issue #15: schedule the background refresh on the way out. Back in the foreground, reconnect when
    /// the connection can be dead, and refresh the list. The chats catch up on the `connected` event.
    private func foregroundChange(_ phase: ScenePhase) {
        guard model.isSetUp, !ChatLaunch.isDemo else { return }
        switch phase {
        case .background:
            if backgroundedAt == nil { backgroundedAt = .now }
            BackgroundRefresh.schedule()
        case .active:
            guard let since = backgroundedAt else { return }
            backgroundedAt = nil
            let away = Date.now.timeIntervalSince(since)
            Task {
                await notifications?.refreshStatus()
                await model.reconnectOnForeground(link: link?.status, away: away)
                await sessions.refresh()
            }
        default:
            break
        }
    }
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView().environment(AppModel.preview(setUp: false)).environment(LocationController.preview())
        RootView().environment(AppModel.preview(setUp: true)).environment(LocationController.preview())
    }
}
