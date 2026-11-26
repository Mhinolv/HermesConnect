import HermesKit
import SwiftUI
import UserNotifications

@main
struct HermesConnectApp: App {
    @State private var model: AppModel
    @State private var sessions: SessionListModel
    /// Issue #73: the job list of the Jobs tab.
    @State private var jobs: JobsModel
    /// Issue #101: the Voice tab and its voice session.
    @State private var voice: VoiceTabModel
    /// Made at launch, also for a relaunch in the background by a location event (issue #13).
    @State private var location: LocationController
    /// Issue #15: permission, badge and the tap route of local notifications.
    @State private var notifications: NotificationController
    /// The Release chat link to Hermes. Nil in the DEBUG demo.
    private let link: LiveChatTransport?
    /// Issue #178: reconnects a dead link while the app is open. Nil in the DEBUG demo.
    private let supervisor: LinkSupervisor?
    private let usesAppLock: Bool

    init() {
        // QA 52-1: no model download unless the owner taps Download.
        OnDeviceTranscription.lockModelNetwork()
        #if DEBUG
        if ChatLaunch.isDemo {
            // Issue #83: right after a switch the list has no rows yet (redacted rows, "Connecting…").
            let demoSessions = ServerSwitchDemo.current == .connecting ? ChatLaunch.makeOfflineSessions()
                : ChatLaunch.makeDemoSessions()
            let demoJobs = JobsDemo.makeJobs() ?? ChatLaunch.makeOfflineJobs()
            sessions = demoSessions
            jobs = demoJobs
            // Issue #102: `HERMES_DEMO_LIVE=on|off` gives the Live status with no server.
            voice = VoiceTabModel(sessions: demoSessions, liveService: LiveModeDemo.service)
            link = nil
            supervisor = nil
            // The DEBUG demo conversation: no server, no App Lock, so screenshots show the chat.
            // Issue #66: the Servers screenshots use 3 servers.
            let demo = ServersDemo.current.map(ServersDemo.makeModel) ?? AppModel.preview(setUp: true, hostKey: .sample)
            demo.previewConnection(.connected(gateVersion: "demo"))
            // Issue #83: the server menu screenshots use 3 servers.
            let switchDemo = ServerSwitchDemo.current.map(ServerSwitchDemo.makeModel) ?? demo
            ServerSwitchGlue.attach(model: switchDemo, sessions: demoSessions, jobs: demoJobs,
                                    caches: ServerCaches(inMemory: switchDemo.profile?.id))
            if ServerSwitchDemo.current == .menu { ServerSwitchDemo.openMenu() }
            model = switchDemo
            // Issue #92: the Servers screenshots show "Share Location" on for the first server.
            location = ServersDemo.current == nil ? LocationController.preview(enabled: false)
                : LocationController.preview(servers: demo.servers, sharing: Set(demo.servers.prefix(1).map(\.id)))
            let off = ChatLaunch.demoScenario == .notificationsOff
            notifications = NotificationController(center: DemoNotificationCenter(status: off ? .denied : .authorized),
                                                   defaults: UserDefaults(suiteName: "demo") ?? .standard)
            usesAppLock = false
            return
        }
        #endif
        let live = AppModel.live()
        // Issue #84: one cache folder for each server. The flat cache of older builds moves before any list reads it.
        let caches = ServerCacheSetup.live(model: live)
        let link = ChatLaunch.makeLink(renew: { await live.renewHermesSession() })
        // Issue #68: the slash suggestions keep the catalog of the connected server.
        let slashCache = SlashSuggestions.liveCache()
        SlashSuggestions.shared = SlashSuggestions.makeLive(link: link, cache: slashCache, profile: { live.profile })
        model = live
        let location = LocationController.live()
        self.location = location
        self.link = link
        supervisor = ChatLaunch.makeSupervisor(model: live, link: link)
        let sessions = ChatLaunch.makeSessions(link: link, cache: caches.sessions)
        self.sessions = sessions
        let jobs = ChatLaunch.makeJobs(link: link, cache: caches.jobs)
        self.jobs = jobs
        voice = VoiceTabModel.live(sessions: sessions, link: link)
        let notifications = NotificationController()
        self.notifications = notifications
        // Issue #104: an approval that comes while the app is in the background and the socket is open.
        sessions.onApprovalRequest = { alert in
            let server = live.profile.map { NotificationServer($0, serverCount: live.servers.count) }
            notifications.postApproval(alert, server: server)
        }
        // Issue #83: a switch resets the lists before the new connect. Issue #84: each server keeps its folder.
        // "Remove Server" deletes its folder, its delivered notifications and its slash catalog.
        // Issue #92: it also deletes its "Share Location" setting and its pending fix.
        ServerSwitchGlue.attach(model: live, sessions: sessions, jobs: jobs, caches: caches) { removed in
            notifications.removeDelivered(server: removed.id)
            location.serverRemoved(removed.id)
            slashCache.remove(server: SlashCatalogServerKey.make(removed))
        }
        UNUserNotificationCenter.current().delegate = notifications
        // Issue #45: the Siri shortcuts run in this process, also in a launch in the background.
        SiriRuntime.service = SiriService(model: live, link: link, sessions: sessions, notifications: notifications)
        // Issue #15: register before the app finishes launching (BGTaskScheduler rule).
        BackgroundRefresh.register {
            await BackgroundRefresh.run(model: live, link: link, sessions: sessions, notifications: notifications,
                                        caches: caches)
        }
        usesAppLock = true
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let servers = ServersDemo.current {
                // Issue #66: the DEBUG screenshots of Settings > Servers.
                serversDemo(servers)
            } else if ChatLaunch.demoScenario?.showsNotificationSettings == true {
                // Issue #15: the DEBUG screenshot of Settings > Notifications.
                NavigationStack {
                    Form { NotificationSettingsSection() }
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .environment(notifications)
                // Issue #84: with `HERMES_DEMO_SWITCH`, three servers: the footer names the background refresh.
                .environment(model)
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
            } else if NotificationBannerDemo.isOn {
                // Issue #84: a notification from a server that is not active, over the Chats list.
                scene.overlay(alignment: .top) { NotificationBannerDemo().padding(.top, 4) }
            } else {
                scene
            }
            #else
            scene
            #endif
        }
    }

    #if DEBUG
    @ViewBuilder private func serversDemo(_ demo: ServersDemo) -> some View {
        let first = model.servers.first?.id
        Color(uiColor: .systemBackground)
            .sheet(isPresented: .constant(true)) {
                switch demo {
                case .list, .one:
                    SettingsView()
                case .detail:
                    SettingsView(path: first.map { [$0] } ?? [])
                case .share:
                    // At AX5 the switch is below the fold of the server detail, so this shows its section alone.
                    NavigationStack {
                        Form { if let first { ServerLocationSection(serverID: first) } }
                            .navigationTitle(model.servers.first?.name ?? "")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                case .remove:
                    SettingsView(path: first.map { [$0] } ?? [], opensRemoveDialog: true)
                case .newServer:
                    SettingsView(showAddServer: true, addServerHost: model.servers.first?.host ?? "")
                }
            }
            .environment(model)
            .environment(location)
            .environment(notifications)
    }
    #endif

    @ViewBuilder private var scene: some View {
        Group {
            if usesAppLock {
                RootView(sessions: sessions, jobs: jobs, voice: voice, link: link, supervisor: supervisor)
                    .environment(model)
                    .environment(location)
                    .environment(notifications)
                    .appLock(model)
            } else {
                RootView(sessions: sessions, jobs: jobs, voice: voice, link: link, supervisor: supervisor)
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
    /// Issue #176: background time after the owner leaves, so the link stays alive for a quick switch.
    @State private var linkKeeper = LinkKeeper()
    /// The session list and the chats of this window (issue #7). The app owns it, so it lives across view updates.
    var sessions = ChatLaunch.makeOfflineSessions()
    /// Issue #73: the job list of the Jobs tab.
    var jobs = ChatLaunch.makeOfflineJobs()
    /// Issue #101: the Voice tab and its voice session.
    var voice = VoiceTabModel(sessions: ChatLaunch.makeOfflineSessions())
    /// The chat link. It follows the #4 endpoint ("Hermes ready").
    var link: LiveChatTransport?
    /// Issue #178: the link supervisor. It acts only while the scene is not in the background.
    var supervisor: LinkSupervisor?
    @State private var showSetup = false
    @State private var showSettings = false
    /// The list is the root. A chat is pushed on top of it.
    @State private var path: [ChatRoute] = []
    /// Issue #73: Chats or Jobs. Launch, notifications and "Ask Hermes" select Chats.
    @State private var tab = JobsDemo.initialTab
    @State private var jobsPath = JobsDemo.initialPath
    /// `true` after the launch push, or after the owner moved in the stack. Then launch pushes nothing more.
    @State private var launchDone = false
    /// Issue #16: the "Ask Hermes" shortcut puts its request here.
    var ask = AskHermesInbox.shared
    /// Issue #124: the "Start Hands-Free" shortcut puts its request here.
    var handsFree = HandsFreeInbox.shared
    /// Issue #84: a tapped notification of another server. The chat opens after the switch to that server.
    @State private var routeAfterSwitch: NotifiedChat?

    var body: some View {
        tabs
        // Issue #101: while voice mode runs, Chats and Jobs show the mini bar.
        .voiceMiniBar(voice, isEnabled: voice.isRunning && tab != .voice) { tab = .voice }
        // Issue #83: a switch ends the voice session. Its target choice belongs to the old server.
        .onChange(of: model.profile?.id, initial: true) { _, id in voice.serverChanged(id) }
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
        // Issue #73: launch does not take the owner back from the Jobs tab.
        .onChange(of: tab) { launchDone = true }
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
        // Issue #178: the supervisor acts while the app is open. The #176 check handles the return.
        .onChange(of: scenePhase, initial: true) { _, phase in supervisor?.setForeground(phase != .background) }
        // Issue #178: VoiceOver says "Reconnecting" one time for each drop.
        .onChange(of: model.isRecoveringLink) { _, recovering in
            if recovering { ReconnectAnnouncement.post() }
        }
        // Issue #15: a tap on a notification opens that session. App Lock stays on top until unlock.
        // Issue #84: a notification of another server switches to it after the unlock, then opens the chat.
        .onChange(of: notifications?.pendingSessionId) { openNotification() }
        .onChange(of: model.lock) { openNotification() }
        // Issue #16: "Ask Hermes" waits for setup and App Lock, then sends the text at once.
        .onChange(of: ask.pending, initial: true) { askHermes() }
        .onChange(of: model.lock) { askHermes() }
        .onChange(of: scenePhase) { askHermes() }
        // Issue #83, #122: the app icon badge counts the unread chats of all servers.
        .onChange(of: model.badgeCount(sessions), initial: true) { _, count in
            if !ChatLaunch.isDemo { notifications?.setBadge(count) }
        }
        // Issue #83: a switch closes the open chat (its draft stays) and shows the root of both tabs.
        .onChange(of: model.profile?.id) { old, new in
            // The first setup (no old server) keeps the launch push of the last chat.
            guard let old, let new, old != new else { return }
            launchDone = true
            path.removeAll()
            jobsPath.removeAll()
            // Issue #84: the switch came from a tap on a notification of this server.
            if let route = routeAfterSwitch, route.server == new {
                routeAfterSwitch = nil
                openNotified(route.sessionId)
            }
        }
        .serverSwitchFeedback(model)
        .onChange(of: showSettings) { _, shown in
            // A new server or a forgotten host key leaves the status idle. Connect when Settings closes.
            if !shown, model.isSetUp, model.connection == .idle { Task { await model.connect() } }
        }
    }

    /// Issue #73 and #101: Chats, Jobs and Voice.
    /// Issue #124: "Start Hands-Free" waits for setup and App Lock, then starts on the Voice tab.
    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: RootTab.chats) { chats }
                .badge(RootTab.chats.badge(sessions))
            Tab("Jobs", systemImage: "clock.arrow.circlepath", value: RootTab.jobs) {
                JobsTab(model: jobs, sessions: sessions, link: link, path: $jobsPath,
                        onSettings: { showSettings = true })
            }
            .badge(RootTab.jobs.badge(sessions))
            // Issue #101: the Voice tab, after Jobs. The tab bar stays during a session.
            Tab("Voice", systemImage: "waveform", value: RootTab.voice) {
                VoiceTab(model: voice, link: link, activeUnreadChats: sessions.chatsUnreadCount,
                         onSettings: { showSettings = true })
            }
        }
        .onChange(of: HandsFreeTrigger(pending: handsFree.pending?.id, lock: model.lock, phase: scenePhase),
                  initial: true) { startHandsFree() }
    }

    /// The chats list with the pushed chats (issue #7). Issue #73: the Chats tab.
    private var chats: some View {
        NavigationStack(path: $path) {
            Group {
                if model.isSetUp {
                    SessionListScreen(model: sessions, link: link, query: ChatLaunch.demoSearch,
                                      onSettings: { showSettings = true },
                                      onNewChat: { path.append(.new(UUID().uuidString)) },
                                      onMarkedAllRead: recordActiveServerState)
                } else {
                    ContentUnavailableView {
                        Label("Set Up Hermes", systemImage: "key.horizontal")
                    } description: {
                        Text("Connect this iPhone to your Hermes server.")
                    } actions: {
                        Button("Set Up Server") { showSetup = true }
                            .buttonStyle(.glassProminent)
                    }
                    // Issue #73: no tab bar before setup. Issue #95: on this view only, so the select mode
                    // of the list can hide the tab bar too.
                    .toolbarVisibility(.hidden, for: .tabBar)
                }
            }
            .navigationTitle("Hermes")
            .navigationDestination(for: ChatRoute.self) { route in
                switch route {
                case .session(let id): chatScreen(sessions.chat(for: id))
                case .new(let key): chatScreen(sessions.newChat(key: key))
                // Issue #64: the Archived list.
                case .archived: ArchivedSessionsScreen(model: sessions)
                }
            }
            .hermesStartAlert()
        }
    }
}

extension RootView {
    /// The screen of a stored session or a new chat.
    private func chatScreen(_ chat: ChatViewModel) -> some View {
        ChatScreen(model: chat, link: link, sessions: sessions) {
            // A dead id (QA #27 defect 1): drop it and show the list, never an empty chat.
            if let id = chat.storedSessionId { sessions.forget(id) }
            path.removeAll()
        }
        // Issue #15: the open session loses its blue dot and gets no new one.
        // The list follows the chat, so a New Chat counts once it gets its id (QA #38 defect 2).
        .onAppear { sessions.openChat(chat) }
        .onDisappear { sessions.closeChat(chat) }
        // Issue #73: a pushed chat has no tab bar.
        .toolbarVisibility(.hidden, for: .tabBar)
        // Issue #67: `/new` pushes a new chat.
        .onChange(of: chat.newChatRequest) { _, request in
            guard let request else { return }
            chat.clearNewChatRequest(request)
            path.append(.new(UUID().uuidString))
        }
    }

    /// Issue #94: after "Mark All as Read", the server book entry of the active server has no unread chat.
    private func recordActiveServerState() {
        ServerSwitchGlue.recordActiveState(model: model, sessions: sessions)
    }

    /// Issue #15 and #84: the route of a tapped notification (design notes, "Tap on a notification").
    private func openNotification() {
        guard let id = notifications?.pendingSessionId, model.isSetUp else { return }
        let route = NotificationRoute.resolve(sessionId: id, serverID: notifications?.pendingServerId,
                                              activeID: model.profile?.id, servers: Set(model.servers.map(\.id)))
        // App Lock shows first. A switch connects to another server, so it waits for the unlock.
        if case .switchThenOpen = route, !ChatLaunch.isDemo, model.lock.locks(at: .now) { return }
        notifications?.pendingSessionId = nil
        notifications?.pendingServerId = nil
        launchDone = true
        switch route {
        case .open(let id):
            openNotified(id)
        case .switchThenOpen(let server, let id):
            routeAfterSwitch = NotifiedChat(server: server, sessionId: id)
            Task { await model.switchServer(to: server) }
        case .showList:
            // The server was removed: show the Chats list.
            tab = .chats
            path.removeAll()
        }
    }

    /// Open the session of a notification on the active server.
    private func openNotified(_ id: String) {
        // Issue #73: a cron run opens read-only in the Jobs tab, never as a chat.
        if let runPath = JobsRouting.path(forSession: id, sessions: sessions, jobs: jobs) {
            tab = .jobs
            jobsPath = runPath
            return
        }
        tab = .chats
        path = [.session(id)]
    }

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
                                        tab = .chats
                                        path = [ChatRoute(route)]
                                    })
            }
        }
    }

    /// Issue #124: run the "Start Hands-Free" request that waits. App Lock covers the app until Face ID, so the
    /// microphone never opens before an unlock. No setup: show the setup screen and drop the request.
    private func startHandsFree() {
        guard scenePhase == .active else { return }
        let locked = !ChatLaunch.isDemo && model.lock.locks(at: .now)
        switch handsFree.next(isSetUp: model.isSetUp, isLocked: locked) {
        case nil:
            return
        case .dropForSetup:
            showSettings = false
            showSetup = true
        case .run(let request):
            launchDone = true
            showSettings = false
            tab = .voice
            let model = self.model, voice = self.voice
            Task {
                await HandsFreeLaunch.run(request, active: model.profile?.id, servers: Set(model.servers.map(\.id)),
                                          switchServer: { await model.switchServer(to: $0) },
                                          start: { await voice.startHandsFree(server: model.profile?.id) })
            }
        }
    }

    /// Issue #15: schedule the background refresh on the way out. Back in the foreground, reconnect when
    /// the connection can be dead, and refresh the list. The chats catch up on the `connected` event.
    private func foregroundChange(_ phase: ScenePhase) {
        guard model.isSetUp, !ChatLaunch.isDemo else { return }
        switch phase {
        case .background:
            // Issue #165: a draft that waits for the draft delay goes to disk before a suspend.
            sessions.flushCache()
            if backgroundedAt == nil { backgroundedAt = .now }
            BackgroundRefresh.schedule()
            linkKeeper.hold()
        case .active:
            linkKeeper.release()
            guard let since = backgroundedAt else { return }
            backgroundedAt = nil
            // Issue #138: a voice session kept the app and the link alive. Only the time after it ended counts.
            let away = voice.awakeAway(backgroundedAt: since)
            Task {
                await notifications?.refreshStatus()
                // Issue #176: a link that answers one ping stays. Only a dead link reconnects.
                let link = self.link
                await model.reconnectOnForeground(link: link?.status, away: away,
                                                  probe: { await link?.probe() ?? false })
                await sessions.refresh()
            }
        default:
            break
        }
    }
}

/// Issue #124: a change of one of these runs the "Start Hands-Free" request that waits.
private struct HandsFreeTrigger: Equatable {
    var pending: UUID?
    var lock: AppLockPolicy
    var phase: ScenePhase
}

/// Issue #84: the chat of a tapped notification of another server.
struct NotifiedChat: Equatable {
    var server: UUID
    var sessionId: String
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView().environment(AppModel.preview(setUp: false)).environment(LocationController.preview())
        RootView().environment(AppModel.preview(setUp: true)).environment(LocationController.preview())
    }
}
