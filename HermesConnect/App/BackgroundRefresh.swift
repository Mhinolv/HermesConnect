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

    /// One run: connect if needed, wait for the chat socket, catch up, then disconnect again if the run
    /// made the connection and the app is still not active.
    static func run(model: AppModel, link: LiveChatTransport, sessions: SessionListModel,
                    notifications: NotificationController,
                    isActive: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active })
        async -> Bool {
        guard model.isSetUp else { return false }
        var madeConnection = false
        if case .connected = model.connection {} else {
            await model.connect()
            madeConnection = true
        }
        defer {
            if madeConnection, !isActive() { Task { await model.disconnect() } }
        }
        guard case .connected = model.connection else { return false }
        // The root view can be missing in a background launch, so give the endpoint to the link here too.
        link.setEndpoint(model.hermesEndpoint)
        guard await waitUntilReady(link) else { return false }
        let result = await sessions.catchUp(showsPreview: notifications.showsPreview, notifier: notifications.poster)
        // Issue #83: the app icon badge counts the unread sessions of all servers.
        if result != nil { notifications.setBadge(model.badgeCount(activeUnread: sessions.unreadCount)) }
        return result != nil
    }

    private static func waitUntilReady(_ link: LiveChatTransport) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: linkTimeout)
        while link.status != .ready {
            if Task.isCancelled || clock.now >= deadline || link.status == .failed { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }
}
