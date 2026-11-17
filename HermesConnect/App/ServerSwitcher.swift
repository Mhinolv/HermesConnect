import HermesKit
import SwiftUI
import UIKit
import UserNotifications

/// Issue #83: connects the server switch of `AppModel` to the lists of the app. One server is connected at a time.
/// Issue #84: each server has its own cache folder. A switch selects the folder of the new server, then the lists
/// show its cache at once.
@MainActor
enum ServerSwitchGlue {
    /// Launch: select the folder of the active server, put back lost blue dots, and follow each switch.
    /// `onRemoved`: the app also drops the notifications and the slash catalog of a removed server.
    static func attach(model: AppModel, sessions: SessionListModel, jobs: JobsModel, caches: ServerCaches,
                       onRemoved: @escaping @MainActor (ServerProfile) -> Void = { _ in }) {
        let active = model.profile?.id
        if caches.activeServer != active {
            caches.select(active)
            sessions.switchServer(carryingUnread: [])
            jobs.switchServer()
        }
        if let active { sessions.carryUnread(model.serverBook.entry(for: active).unreadIds) }
        // The lists live as long as the app. They hold no reference to the model, so only the model is weak.
        model.onActiveServerChange = { [weak model] change in
            guard let model else { return }
            apply(change, model: model, sessions: sessions, jobs: jobs, caches: caches)
        }
        model.onServerRemoved = { profile in
            caches.remove(server: profile.id)
            onRemoved(profile)
        }
    }

    /// The active server changed. `AppModel` calls it before the new connect starts.
    static func apply(_ change: ServerChange, model: AppModel, sessions: SessionListModel, jobs: JobsModel,
                      caches: ServerCaches) {
        if let from = change.from, !change.isSameServer, model.serverList.server(id: from) != nil {
            model.recordServerState(sessions.serverState(fallback: model.serverBook.entry(for: from)), for: from)
        }
        caches.select(change.to)
        let carried = change.isSameServer ? [] : (change.to.map { model.serverBook.entry(for: $0).unreadIds } ?? [])
        // A new host on the same entry: its rows, outbox and new chat belong to the old machine.
        sessions.switchServer(carryingUnread: carried, newHost: change.isSameServer && change.to != nil)
        jobs.switchServer()
    }
}

/// Issue #84: the cache folders at launch.
@MainActor
enum ServerCacheSetup {
    /// Move the flat cache of an older build to the folder of the active server, delete the folders of removed
    /// servers, then select the folder of the active server. It runs before the lists read the cache.
    static func live(model: AppModel) -> ServerCaches {
        guard let root = try? ServerCaches.defaultRoot() else { return ServerCaches(inMemory: model.profile?.id) }
        prepare(root: root, model: model)
        return ServerCaches(root: root, active: model.profile?.id)
    }

    static func prepare(root: URL, model: AppModel) {
        // No server (not set up, or the list did not load): the files stay as they are.
        guard let active = model.profile?.id else { return }
        let ids = Set(model.servers.map(\.id))
        let outboxes = model.serverBook.entries.mapValues(\.outboxIds)
        ServerCacheMigration.run(root: root, active: active, servers: ids, outboxes: outboxes)
        ServerCaches(root: root).removeFolders(except: ids)
    }
}

/// Issue #83: the title of the Chats list and the Jobs list. With two or more servers it is a menu, as in
/// Mail accounts: the active server name, `chevron.down`, and the #3 status under it. One server: no menu.
struct ServerTitle: View {
    @Environment(AppModel.self) private var model
    /// The title with one server: "Hermes" for Chats, "Jobs" for Jobs.
    let title: String
    var link: LiveChatTransport?
    /// The live unread chats of the active server.
    var activeUnreadChats = 0
    /// "Manage Servers…" opens Settings.
    var onManage: () -> Void = {}

    var body: some View {
        let menu = model.serverMenu(activeChats: activeUnreadChats)
        if menu.showsMenu {
            VStack(spacing: 0) {
                Menu {
                    ServerMenuItems(menu: menu, onManage: onManage)
                } label: {
                    HStack(spacing: 3) {
                        Text(menu.title(default: title))
                            .font(.headline)
                            .lineLimit(1)
                        if menu.showsDot {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 6, height: 6)
                        }
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(menu.titleAccessibilityLabel(default: title))
                }
                .accessibilityHint("Shows the servers.")
                ChatTitleStatus(link: link)
            }
            .accessibilityElement(children: .contain)
        } else {
            ChatNavigationTitle(title: title, link: link)
        }
    }
}

/// The items of the server menu: one button for each server, a divider, then "Manage Servers…".
struct ServerMenuItems: View {
    @Environment(AppModel.self) private var model
    let menu: ServerMenu
    var onManage: () -> Void = {}

    var body: some View {
        ForEach(menu.items) { item in
            Button {
                guard !item.isActive else { return }
                Task { await model.switchServer(to: item.id) }
            } label: {
                if item.isActive {
                    Label(item.name, systemImage: "checkmark")
                } else {
                    Text(item.name)
                }
                if let subtitle = item.subtitle { Text(subtitle) }
            }
            .accessibilityLabel(item.accessibilityLabel)
        }
        Divider()
        Button("Manage Servers…", systemImage: "server.rack", action: onManage)
    }
}

extension View {
    /// Issue #83: after a switch, play the selection haptic and say "Switched to <name>".
    func serverSwitchFeedback(_ model: AppModel) -> some View {
        modifier(ServerSwitchFeedback(model: model))
    }
}

private struct ServerSwitchFeedback: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.selection, trigger: model.profile?.id)
            .onChange(of: model.profile?.id) { old, new in
                guard old != nil, new != nil, model.servers.count > 1, let name = model.profile?.name else { return }
                AccessibilityNotification.Announcement(ServerMenu.switchAnnouncement(name)).post()
            }
    }
}

#if DEBUG
/// Issue #83: the DEBUG screenshots of the server menu (`HERMES_DEMO=list HERMES_DEMO_SWITCH=<state>`).
enum ServerSwitchDemo: String {
    /// The Chats list of the active server. Another server has unread chats: the blue dot.
    case dot
    /// The open server menu.
    case menu
    /// Right after a switch: the redacted rows and "Connecting…".
    case connecting

    static var current: ServerSwitchDemo? {
        ProcessInfo.processInfo.environment["HERMES_DEMO_SWITCH"].flatMap(ServerSwitchDemo.init(rawValue:))
    }

    static let home = ServerProfile(id: ServerProfile.legacyID, host: "100.101.7.12", displayName: "Home Agent",
                                    hostKey: .sample)
    static let lab = ServerProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000083")!,
                                   host: "lab.tailnet-1234.ts.net", displayName: "Lab", hostKey: .otherSample)
    static let vps = ServerProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000084")!,
                                   host: "100.88.4.20", hostKey: .sample)

    /// Three servers. "Home Agent" is active. "Lab" has 3 unread chats.
    @MainActor static func makeModel(_ demo: ServerSwitchDemo) -> AppModel {
        let model = AppModel.preview(servers: [home, lab, vps], activeIndex: 0)
        model.recordServerState(ServerStateBook.Entry(unreadIds: ["l1", "l2", "l3"], unreadChats: 3), for: lab.id)
        model.previewConnection(demo == .connecting ? .connecting : .connected(gateVersion: "demo"))
        return model
    }

    /// The menu opens with no tap: the UIKit button that SwiftUI makes for the title menu performs its action.
    @MainActor static func openMenu() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            for window in windows {
                guard let button = menuButton(in: window) else { continue }
                button.performPrimaryAction()
                return
            }
        }
    }

    /// The first `HostingUIButton` in the navigation bar: the title menu.
    @MainActor private static func menuButton(in view: UIView, inBar: Bool = false) -> UIButton? {
        let inBar = inBar || view is UINavigationBar
        if inBar, let button = view as? UIButton, String(describing: type(of: button)).contains("HostingUIButton") {
            return button
        }
        for sub in view.subviews {
            if let found = menuButton(in: sub, inBar: inBar) { return found }
        }
        return nil
    }
}
#endif

#if DEBUG
/// Issue #84: the DEBUG screenshot of a notification from a server that is not active
/// (`HERMES_DEMO=list HERMES_DEMO_SWITCH=dot HERMES_DEMO_BANNER=1`). The Simulator shows no real banner without
/// the notification permission, so this view draws one with the title and body of the real request.
struct NotificationBannerDemo: View {
    static var isOn: Bool { ProcessInfo.processInfo.environment["HERMES_DEMO_BANNER"] == "1" }

    /// "Lab" is not active. Its background refresh found a new reply.
    static var request: UNNotificationRequest {
        let note = CatchUpNotification(session: SessionListItem(id: "20261117_090000_lab001", title: "Build logs"),
                                       reply: "", showsPreview: false,
                                       server: NotificationServer(ServerSwitchDemo.lab, serverCount: 3))
        return LocalNotificationPoster.request(for: note)
    }

    var body: some View {
        let content = Self.request.content
        HStack(alignment: .top, spacing: 10) {
            // The app icon of a banner has a fixed size, also with large text.
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(content.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Text("now")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(content.body)
                    .font(.subheadline)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }
}
#endif

struct ServerTitle_Previews: PreviewProvider {
    static var previews: some View {
        let lab = ServerProfile(host: "lab.example.com", displayName: "Lab")
        let model = AppModel.preview(servers: [ServerProfile(host: "home.example.com", displayName: "Home"), lab],
                                     activeIndex: 0)
        NavigationStack {
            Text("List")
                .toolbar { ToolbarItem(placement: .principal) { ServerTitle(title: "Hermes") } }
        }
        .environment(model)
    }
}
