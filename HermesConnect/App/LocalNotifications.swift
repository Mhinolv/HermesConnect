import Foundation
import HermesKit
import Intents
import Observation
import UIKit
import UserNotifications

/// The notification center calls of issue #15, behind a protocol so tests use a fake.
protocol NotificationCentering: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func setBadgeCount(_ count: Int) async throws
}

/// `UNUserNotificationCenter` is thread-safe. Its async API does not carry `Sendable`.
struct SystemNotificationCenter: NotificationCentering, @unchecked Sendable {
    let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func setBadgeCount(_ count: Int) async throws { try await center.setBadgeCount(count) }
}

/// Posts the catch-up notifications and sets the badge (`LocalNotifying`). No push entitlement (D5).
struct LocalNotificationPoster: LocalNotifying {
    var center: any NotificationCentering = SystemNotificationCenter()

    /// The user info key with the stored id. A tap opens this session.
    static let sessionIdKey = "sessionId"

    /// One request per session: a newer reply replaces the older notification of the same session.
    static func request(for notification: CatchUpNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.sessionId
        content.userInfo = [sessionIdKey: notification.sessionId]
        return UNNotificationRequest(identifier: "reply-\(notification.sessionId)", content: content, trigger: nil)
    }

    /// Issue #45: the incoming message of a communication notification, so Siri "Announce Notifications" can
    /// read it. The content is the notification body: with "Show Message Preview" off it has no message text.
    static func messageIntent(for notification: CatchUpNotification) -> INSendMessageIntent {
        let hermes = INPerson(personHandle: INPersonHandle(value: "hermes", type: .unknown), nameComponents: nil,
                              displayName: "Hermes", image: nil, contactIdentifier: nil, customIdentifier: "hermes")
        return INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText,
                                   content: notification.body,
                                   speakableGroupName: INSpeakableString(spokenPhrase: notification.title),
                                   conversationIdentifier: notification.sessionId, serviceName: nil,
                                   sender: hermes, attachments: nil)
    }

    /// The request with communication content. If iOS refuses the update, the plain request goes.
    static func communicationRequest(for notification: CatchUpNotification) async -> UNNotificationRequest {
        let plain = request(for: notification)
        let intent = messageIntent(for: notification)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()
        guard let content = try? plain.content.updating(from: intent) else { return plain }
        return UNNotificationRequest(identifier: plain.identifier, content: content, trigger: nil)
    }

    func post(_ notification: CatchUpNotification) async {
        try? await center.add(Self.communicationRequest(for: notification))
    }

    func setBadge(_ count: Int) async {
        try? await center.setBadgeCount(count)
    }
}

/// The app state of local notifications (issue #15): the permission, the badge and the tap route.
@MainActor @Observable
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    /// The iOS permission. Settings shows "Notifications Off" when it is `.denied`.
    private(set) var status: UNAuthorizationStatus = .notDetermined
    /// The stored id of a notification that the owner tapped. The root opens it, then clears it.
    var pendingSessionId: String?

    @ObservationIgnored let poster: LocalNotificationPoster
    @ObservationIgnored private let center: any NotificationCentering
    @ObservationIgnored private let defaults: UserDefaults

    init(center: any NotificationCentering = SystemNotificationCenter(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
        poster = LocalNotificationPoster(center: center)
        super.init()
    }

    /// "Show Message Preview" in Settings > Notifications. Off by default (owner decision 2026-11-16).
    var showsPreview: Bool {
        get {
            access(keyPath: \.showsPreview)
            return NotificationSettings.showsPreview(defaults)
        }
        set {
            withMutation(keyPath: \.showsPreview) {
                defaults.set(newValue, forKey: NotificationSettings.showPreviewKey)
            }
        }
    }

    /// Issue #45: "Use Siri When Locked" in Settings > Notifications. Off by default (owner decision 2026-11-17).
    var usesSiriWhenLocked: Bool {
        get {
            access(keyPath: \.usesSiriWhenLocked)
            return SiriSettings.usesSiriWhenLocked(defaults)
        }
        set {
            withMutation(keyPath: \.usesSiriWhenLocked) {
                defaults.set(newValue, forKey: SiriSettings.useWhenLockedKey)
            }
        }
    }

    /// Ask once, after the first reply arrives. Never at first launch.
    static func shouldAsk(status: UNAuthorizationStatus, asked: Bool) -> Bool {
        status == .notDetermined && !asked
    }

    func refreshStatus() async {
        status = await center.authorizationStatus()
    }

    /// The chat calls this when a reply ends. The first call asks for alert, sound and badge.
    func requestAfterFirstReply() {
        guard !defaults.bool(forKey: NotificationSettings.askedKey) else { return }
        Task {
            await refreshStatus()
            guard Self.shouldAsk(status: status, asked: defaults.bool(forKey: NotificationSettings.askedKey))
            else { return }
            defaults.set(true, forKey: NotificationSettings.askedKey)
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshStatus()
        }
    }

    func setBadge(_ count: Int) {
        let poster = self.poster
        Task { await poster.setBadge(count) }
    }

    /// A tap on a notification. The App Lock cover stays on top until the owner unlocks.
    func open(userInfo: [AnyHashable: Any]) {
        guard let id = userInfo[LocalNotificationPoster.sessionIdKey] as? String, !id.isEmpty else { return }
        pendingSessionId = id
    }

    // MARK: UNUserNotificationCenterDelegate

    /// The app is active: the chat shows the reply, so no banner.
    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification)
        async -> UNNotificationPresentationOptions {
        []
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo[LocalNotificationPoster.sessionIdKey] as? String
        await MainActor.run { open(userInfo: id.map { [LocalNotificationPoster.sessionIdKey: $0] } ?? [:]) }
    }
}
