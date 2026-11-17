import Foundation

/// When App Lock asks for Face ID: on launch, and on return after 5 minutes or more in the background.
/// While the app is not active, the app shows the cover so the app switcher shows no messages.
public struct AppLockPolicy: Sendable, Equatable {
    public static let relockInterval: TimeInterval = 5 * 60

    public private(set) var isEnabled: Bool
    public private(set) var isLocked: Bool
    public private(set) var backgroundedAt: Date?

    /// On launch the app is locked if App Lock is on.
    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
        self.isLocked = isEnabled
    }

    public mutating func didEnterBackground(at date: Date) {
        backgroundedAt = date
    }

    /// Lock again if the app was in the background for `relockInterval` or more.
    public mutating func willEnterForeground(at date: Date) {
        defer { backgroundedAt = nil }
        guard isEnabled, let backgroundedAt else { return }
        if date.timeIntervalSince(backgroundedAt) >= Self.relockInterval {
            isLocked = true
        }
    }

    public mutating func unlockSucceeded() {
        isLocked = false
    }

    /// Turn App Lock on or off. Off unlocks at once. On does not lock until the next launch or return.
    public mutating func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { isLocked = false }
    }
}
