import Foundation

/// Issue #15: what changed on the server while the app was away (research D5).
///
/// - The app compares the `session.list` rows with the cached rows. A row with more messages has new content.
/// - A session with new content gets the #7 blue dot. A local notification goes out only when the newest
///   shown row of that session is an assistant reply that the cache does not have.
/// - The reply text goes into a notification only when the owner turned on "Show Message Preview".
public enum CatchUp {
    /// The stored ids of the rows in `fresh` that have new content, in server order.
    /// A row with a higher `message_count` than its cached row has new content. A new row has new content
    /// only when the cache had rows: the first load of the list is not "new".
    public static func changedSessions(cached: [SessionListItem], fresh: [SessionListItem]) -> [String] {
        guard !cached.isEmpty else { return [] }
        let counts = Dictionary(cached.map { ($0.id, $0.messageCount ?? 0) }, uniquingKeysWith: { first, _ in first })
        return fresh.compactMap { row in
            let count = row.messageCount ?? 0
            guard let old = counts[row.id] else { return count > 0 ? row.id : nil }
            return count > old ? row.id : nil
        }
    }

    /// The text of the newest reply in `transcript` when it is new: the last shown row is an assistant reply,
    /// and its text is not the text of the last cached reply. `nil` when the agent did not answer yet.
    public static func newReply(in transcript: [TranscriptMessage], cached: [ChatMessage]) -> String? {
        let shown = ChatHistory.messages(from: transcript, fallbackDate: Date(timeIntervalSince1970: 0))
        guard let last = shown.last, last.role == .assistant, !last.text.isEmpty else { return nil }
        let lastCached = cached.last { $0.role == .assistant }
        return lastCached?.text == last.text ? nil : last.text
    }

    /// The fresh rows with the blue dot: a row keeps its dot, and a row in `newContent` gets one.
    /// The session that is open on the screen never gets a dot.
    public static func markUnread(_ fresh: [SessionListItem], unread: Set<String>, newContent: Set<String>,
                                  openSessionId: String?) -> [SessionListItem] {
        fresh.map { row in
            var row = row
            if row.id != openSessionId, unread.contains(row.id) || newContent.contains(row.id) { row.isUnread = true }
            return row
        }
    }
}

/// One local notification for a session with a new reply (issue #15 design notes).
public struct CatchUpNotification: Sendable, Equatable {
    /// The stored id. The app sets it as the `threadIdentifier`, and a tap opens this session.
    public var sessionId: String
    /// The session title, or "Untitled".
    public var title: String
    /// "New message from Hermes", or the first 100 characters of the reply when the preview is on.
    public var body: String

    public static let defaultBody = "New message from Hermes"
    public static let previewLength = 100

    public init(sessionId: String, title: String, body: String) {
        self.sessionId = sessionId
        self.title = title
        self.body = body
    }

    /// Message preview is off by default (owner decision 2026-11-16). Then the body has no message text.
    public init(session: SessionListItem, reply: String, showsPreview: Bool) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = showsPreview && !trimmed.isEmpty ? String(trimmed.prefix(Self.previewLength)) : Self.defaultBody
        self.init(sessionId: session.id, title: session.displayTitle, body: body)
    }
}

/// The notification settings (Settings > Notifications).
public enum NotificationSettings {
    /// `UserDefaults` key of "Show Message Preview". No value means off (owner decision 2026-11-16).
    public static let showPreviewKey = "notificationShowPreview"
    /// `UserDefaults` key: `true` after the app asked for notification permission once.
    public static let askedKey = "notificationPermissionAsked"

    public static func showsPreview(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: showPreviewKey) as? Bool ?? false
    }
}

/// Posts local notifications and sets the app badge. The app wraps `UNUserNotificationCenter`. Tests use a fake.
public protocol LocalNotifying: Sendable {
    func post(_ notification: CatchUpNotification) async
    func setBadge(_ count: Int) async
}

/// The result of one catch-up run.
public struct CatchUpResult: Sendable, Equatable {
    /// The sessions with new content (blue dot).
    public var changed: [String]
    /// The sessions that got a notification.
    public var notified: [String]
    /// The number of sessions with the blue dot. The app badge shows it.
    public var unreadCount: Int

    public init(changed: [String] = [], notified: [String] = [], unreadCount: Int = 0) {
        self.changed = changed
        self.notified = notified
        self.unreadCount = unreadCount
    }
}

/// One background catch-up (BGAppRefresh): `session.list`, then `session.resume` and `session.history`
/// for each changed session (at most `maxSessions`). The reply text never goes to a log.
public struct CatchUpRefresher: Sendable {
    public static let maxSessions = 5

    private let sessions: any SessionsTransport
    private let chats: any ChatTransport
    private let cache: any SessionCacheStore
    private let notifier: any LocalNotifying

    public init(sessions: any SessionsTransport, chats: any ChatTransport, cache: any SessionCacheStore,
                notifier: any LocalNotifying) {
        self.sessions = sessions
        self.chats = chats
        self.cache = cache
        self.notifier = notifier
    }

    /// Throws only when `session.list` fails. Then the cache does not change.
    /// A session whose history fails gets the blue dot but no notification.
    public func run(showsPreview: Bool, openSessionId: String? = nil) async throws -> CatchUpResult {
        let cached = cache.loadSessions()
        let fresh = try await sessions.fetchSessions()
        let changed = CatchUp.changedSessions(cached: cached, fresh: fresh).filter { $0 != openSessionId }
        var notified: [String] = []
        for id in changed.prefix(Self.maxSessions) {
            guard let row = fresh.first(where: { $0.id == id }),
                  let live = try? await chats.resumeSession(storedId: id, source: ChatSource.iOS),
                  let transcript = try? await chats.history(sessionId: live.liveId),
                  let reply = CatchUp.newReply(in: transcript, cached: cache.loadTranscript(sessionId: id))
            else { continue }
            await notifier.post(CatchUpNotification(session: row, reply: reply, showsPreview: showsPreview))
            notified.append(id)
        }
        let unread = Set(cached.filter(\.isUnread).map(\.id))
        let merged = CatchUp.markUnread(fresh, unread: unread, newContent: Set(changed), openSessionId: openSessionId)
        cache.saveSessions(merged)
        let count = merged.filter(\.isUnread).count
        await notifier.setBadge(count)
        return CatchUpResult(changed: changed, notified: notified, unreadCount: count)
    }
}
