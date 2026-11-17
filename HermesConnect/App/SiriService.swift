import Foundation
import HermesKit
import UIKit

/// Issue #45: the app side of "Ask Hermes" and "Read Hermes". Both run in the background (owner decision
/// 2026-11-17). They use the same SSH connect as the app: the pinned host key, the gate and the Keychain key
/// (accessible after the first unlock). A changed or unknown host key never connects: Siri says it cannot reach
/// Hermes. The spoken text never goes to a log.
@MainActor
final class SiriService: SiriServing {
    private let model: AppModel
    private let link: LiveChatTransport
    private let sessions: SessionListModel
    private let notifications: NotificationController
    /// `true` while the iPhone is locked. Protected data goes away a few seconds after a lock.
    private let isDeviceLocked: @MainActor () -> Bool
    private let isAppActive: @MainActor () -> Bool
    /// The connect that a run made. The last run that ends closes it when the app is not active.
    private var runs = 0
    private var madeConnection = false

    init(model: AppModel, link: LiveChatTransport, sessions: SessionListModel, notifications: NotificationController,
         isDeviceLocked: @escaping @MainActor () -> Bool = { !UIApplication.shared.isProtectedDataAvailable },
         isAppActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.model = model
        self.link = link
        self.sessions = sessions
        self.notifications = notifications
        self.isDeviceLocked = isDeviceLocked
        self.isAppActive = isAppActive
    }

    private var blockingDialog: String? {
        SiriDialog.blocking(isSetUp: model.isSetUp, isDeviceLocked: isDeviceLocked(),
                            usesSiriWhenLocked: notifications.usesSiriWhenLocked)
    }

    func read() async -> String {
        if let blockingDialog { return blockingDialog }
        begin()
        defer { end() }
        return await SiriRead.run(sessions: sessions) { [self] remaining in await linkReady(within: remaining) }.dialog
    }

    func ask(_ text: String) async -> String {
        if let blockingDialog { return blockingDialog }
        begin()
        let outcome = await SiriAsk.run(text: text, sessions: sessions) { [self] remaining in
            await linkReady(within: remaining)
        }
        if case .stillWorking(let pending) = outcome {
            followUp(pending)
        } else {
            end()
        }
        return outcome.dialog
    }

    /// A slow reply: keep the app alive in the background for the reply, then post the notification.
    /// If iOS ends the time first, the #15 background refresh posts it later.
    private func followUp(_ pending: SiriAsk.Pending) {
        let application = UIApplication.shared
        let background = BackgroundTime()
        // Schedule first: if iOS ends the app, the #15 refresh still posts the reply later.
        BackgroundRefresh.schedule()
        let work = Task { @MainActor [self] in
            let sessions = self.sessions
            await SiriAsk.notifyWhenDone(pending, title: {
                pending.chat.storedSessionId.flatMap { sessions.session(id: $0)?.displayTitle }
                    ?? pending.chat.title ?? "Hermes"
            }, showsPreview: notifications.showsPreview, notifier: notifications.poster)
            end()
            background.finish(application)
        }
        background.id = application.beginBackgroundTask(withName: "SiriFollowUp") {
            // Issue #71: iOS ends the app when a task is still open after this handler. End it here, not later.
            work.cancel()
            background.finish(application)
        }
    }

    /// Connect if needed (pin, gate, Hermes), then wait for the chat socket. `false` at the time limit.
    private func linkReady(within remaining: Duration) async -> Bool {
        sessions.startEvents()
        if case .connected = model.connection {} else {
            madeConnection = true
            await model.connect()
        }
        // A connect that the app started can still run. Wait for it in the time left.
        let deadline = ContinuousClock.now.advanced(by: remaining)
        while model.connection == .connecting || model.connection == .startingHermes, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard case .connected = model.connection else { return false }
        // The root view can be missing in a background launch, so give the endpoint to the link here too.
        link.setEndpoint(model.hermesEndpoint)
        return await AskHermes.waitUntilReady(timeout: SiriTiming.remaining(until: deadline)) { [link] in link.status }
    }

    private func begin() { runs += 1 }

    private func end() {
        runs -= 1
        guard runs == 0, madeConnection, !isAppActive() else { return }
        madeConnection = false
        Task { await model.disconnect() }
    }
}

/// Issue #71: the background time of one Siri follow-up. `finish` ends it once.
@MainActor
private final class BackgroundTime {
    var id = UIBackgroundTaskIdentifier.invalid

    func finish(_ application: UIApplication) {
        guard id != .invalid else { return }
        application.endBackgroundTask(id)
        id = .invalid
    }
}
