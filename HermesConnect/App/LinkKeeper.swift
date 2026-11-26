import UIKit

/// `UIApplication` background time behind a protocol, so tests use a fake.
@MainActor
protocol BackgroundTimeGranting {
    func beginBackgroundTask(withName name: String?,
                             expirationHandler: (@MainActor @Sendable () -> Void)?) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

extension UIApplication: BackgroundTimeGranting {}

/// Issue #176: asks iOS for background time (about 30 s) when the owner leaves the app. The link and
/// its heartbeat stay alive in that time, so a quick switch to another app does not drop the link.
@MainActor
final class LinkKeeper {
    static let taskName = "keep-link"

    private let application: any BackgroundTimeGranting
    private(set) var task = UIBackgroundTaskIdentifier.invalid

    init(application: any BackgroundTimeGranting = UIApplication.shared) {
        self.application = application
    }

    var isHolding: Bool { task != .invalid }

    /// The scene went to the background. A second call keeps the first task.
    func hold() {
        guard task == .invalid else { return }
        task = application.beginBackgroundTask(withName: Self.taskName) { [weak self] in
            // iOS ends the app when a task is still open after this handler. End it here.
            MainActor.assumeIsolated { self?.release() }
        }
    }

    /// The scene is active again, or iOS ends the time.
    func release() {
        guard task != .invalid else { return }
        application.endBackgroundTask(task)
        task = .invalid
    }
}
