import BackgroundTasks
import Foundation
import HermesKit
import UIKit

/// `BGTaskScheduler` behind a protocol, so tests use a fake.
protocol BackgroundTaskScheduling {
    func submit(_ request: BGTaskRequest) throws
    func cancel(taskRequestWithIdentifier identifier: String)
}

extension BGTaskScheduler: BackgroundTaskScheduling {}

/// Issue #15: the `BGAppRefreshTask` (research D5). iOS runs it when it allows. The task connects with the
/// pinned host key and the gate (#3, #4), runs one catch-up, and posts local notifications. No APNs.
@MainActor
enum BackgroundRefresh {
    /// Also in Info.plist `BGTaskSchedulerPermittedIdentifiers`.
    static let identifier = "io.mhinoverse.hermesconnect.refresh"
    /// The earliest next run. iOS can run it later, or not at all.
    static let interval: TimeInterval = 15 * 60
    /// The longest wait for the chat socket after the SSH connect.
    static let linkTimeout: Duration = .seconds(15)

    static func request(now: Date = .now) -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = now.addingTimeInterval(interval)
        return request
    }

    /// The app calls this when it goes to the background. A new request replaces the old one.
    static func schedule(on scheduler: any BackgroundTaskScheduling = BGTaskScheduler.shared, now: Date = .now) {
        try? scheduler.submit(request(now: now))
    }

    /// Call it once, before the app finishes launching.
    static func register(_ work: @escaping @MainActor () async -> Bool) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            // The `.main` queue runs this handler on the main thread.
            MainActor.assumeIsolated {
                schedule()
                let run = Task { @MainActor in await work() }
                task.expirationHandler = { run.cancel() }
                Task { @MainActor in
                    let success = await run.value
                    task.setTaskCompleted(success: success && !run.isCancelled)
                }
            }
        }
    }

    /// Issue #84: the other server gets a turn only when the active server took less than this.
    static let otherServerStartLimit: Duration = .seconds(12)

    /// One run: connect if needed, wait for the chat socket, catch up, then disconnect again if the run
    /// made the connection and the app is still not active.
    /// Issue #84: then, if time is left and the app is still not active, one other server, in turn. The active
    /// link closes before that connect. Its notifications name the server, and its counts go to the server book.
    static func run(model: AppModel, link: LiveChatTransport, sessions: SessionListModel,
                    notifications: NotificationController, caches: ServerCaches? = nil,
                    defaults: UserDefaults = .standard, linkTimeout: Duration = BackgroundRefresh.linkTimeout,
                    isActive: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
                    makeLink: @MainActor () -> LiveChatTransport = { LiveChatTransport() }) async -> Bool {
        guard model.isSetUp else { return false }
        let clock = ContinuousClock()
        let started = clock.now
        var madeConnection = false
        let activeOK = await catchUpActive(model: model, link: link, sessions: sessions, notifications: notifications,
                                           linkTimeout: linkTimeout, madeConnection: &madeConnection)
        guard !isActive() else { return activeOK }
        let last = defaults.string(forKey: BackgroundRotation.lastServerKey).flatMap(UUID.init(uuidString:))
        if let caches, !Task.isCancelled, clock.now - started < otherServerStartLimit,
           let other = BackgroundRotation.next(servers: model.servers.map(\.id), active: model.profile?.id, last: last) {
            defaults.set(other.uuidString, forKey: BackgroundRotation.lastServerKey)
            link.setEndpoint(nil)
            _ = await catchUpOther(other, model: model, sessions: sessions, notifications: notifications,
                                   caches: caches, linkTimeout: linkTimeout, makeLink: makeLink)
        } else if madeConnection {
            await model.disconnect()
        }
        return activeOK
    }

    private static func catchUpActive(model: AppModel, link: LiveChatTransport, sessions: SessionListModel,
                                      notifications: NotificationController, linkTimeout: Duration,
                                      madeConnection: inout Bool) async -> Bool {
        if case .connected = model.connection {} else {
            await model.connect()
            madeConnection = true
        }
        guard case .connected = model.connection else { return false }
        // The root view can be missing in a background launch, so give the endpoint to the link here too.
        link.setEndpoint(model.hermesEndpoint)
        guard await waitUntilReady(link, timeout: linkTimeout) else { return false }
        let server = model.profile.map { NotificationServer($0, serverCount: model.servers.count) }
        let result = await sessions.catchUp(showsPreview: notifications.showsPreview, notifier: notifications.poster,
                                            server: server, setsBadge: false)
        // Issue #83: the app icon badge counts the unread sessions of all servers.
        if result != nil { notifications.setBadge(model.badgeCount(activeUnread: sessions.unreadCount)) }
        return result != nil
    }

    /// Issue #84: one catch-up of a server that is not active, with its own link and its own cache folder.
    static func catchUpOther(_ id: UUID, model: AppModel, sessions: SessionListModel,
                             notifications: NotificationController, caches: ServerCaches,
                             linkTimeout: Duration = BackgroundRefresh.linkTimeout,
                             makeLink: @MainActor () -> LiveChatTransport) async -> Bool {
        guard let profile = model.serverList.server(id: id) else { return false }
        let server = NotificationServer(profile, serverCount: model.servers.count)
        let cache = caches.sessionStore(for: id)
        let link = makeLink()
        let poster = notifications.poster
        let showsPreview = notifications.showsPreview
        return await model.withBackgroundLink(to: id) { endpoint in
            link.setEndpoint(endpoint)
            defer { link.setEndpoint(nil) }
            guard await waitUntilReady(link, timeout: linkTimeout) else { return false }
            let refresher = CatchUpRefresher(sessions: link, chats: link, cache: cache, notifier: poster)
            guard (try? await refresher.run(showsPreview: showsPreview, server: server, setsBadge: false)) != nil
            else { return false }
            // The server menu and the app icon badge count the new replies of that server.
            model.recordServerState(ServerStateBook.Entry(cachedRows: cache.loadSessions(),
                                                          outbox: cache.outboxSessionIds()), for: id)
            notifications.setBadge(model.badgeCount(activeUnread: sessions.unreadCount))
            return true
        }
    }

    private static func waitUntilReady(_ link: LiveChatTransport, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while link.status != .ready {
            if Task.isCancelled || clock.now >= deadline || link.status == .failed { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }
}
