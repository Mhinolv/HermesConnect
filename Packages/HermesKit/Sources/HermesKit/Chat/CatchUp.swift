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

/// Issue #84: the server of a notification.
public struct NotificationServer: Sendable, Equatable {
    public var id: UUID
    /// The server name (`ServerProfile.name`).
    public var name: String
    /// True when the owner has two or more servers. Then the title and the sender show the server name.
    public var showsName: Bool

    public init(id: UUID, name: String, showsName: Bool) {
        self.id = id
        self.name = name
        self.showsName = showsName
    }

    /// The server of `profile` in a list of `serverCount` servers.
    public init(_ profile: ServerProfile, serverCount: Int) {
        self.init(id: profile.id, name: profile.name, showsName: serverCount > 1)
    }
}

/// One local notification for a session with a new reply (issue #15 design notes).
public struct CatchUpNotification: Sendable, Equatable {
    /// The stored id. A tap opens this session.
    public var sessionId: String
    /// The session title, or "Untitled". Issue #84: "<server name>: <chat title>" with two or more servers.
    public var title: String
    /// "New message from Hermes", or the first 100 characters of the reply when the preview is on.
    public var body: String
    /// Issue #84: the server of the session. Nil for a notification with no server (tests, older code).
    public var serverID: UUID?
    /// Issue #84: the sender name that Siri announces. "Hermes", or the server name with two or more servers.
    public var senderName: String

    public static let defaultBody = "New message from Hermes"
    public static let previewLength = 100
    public static let defaultSender = "Hermes"

    public init(sessionId: String, title: String, body: String, serverID: UUID? = nil,
                senderName: String = CatchUpNotification.defaultSender) {
        self.sessionId = sessionId
        self.title = title
        self.body = body
        self.serverID = serverID
        self.senderName = senderName
    }

    /// Message preview is off by default (owner decision 2026-11-16). Then the body has no message text.
    /// Issue #84: the server name comes first in the title, so VoiceOver reads it first.
    public init(session: SessionListItem, reply: String, showsPreview: Bool, server: NotificationServer? = nil) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = showsPreview && !trimmed.isEmpty ? String(trimmed.prefix(Self.previewLength)) : Self.defaultBody
        let named = server?.showsName == true ? server : nil
        let title = named.map { "\($0.name): \(session.displayTitle)" } ?? session.displayTitle
        self.init(sessionId: session.id, title: title, body: body, serverID: server?.id,
                  senderName: named?.name ?? Self.defaultSender)
    }

    /// The thread of the notification: "<server id>/<session id>". With no server: the session id.
    public var threadIdentifier: String {
        serverID.map { "\($0.uuidString)/\(sessionId)" } ?? sessionId
    }

    /// One request per session and server: a newer reply replaces the older notification of the same session.
    public var requestIdentifier: String { "reply-\(threadIdentifier)" }
}

/// Issue #84: what a tap on a notification does.
public enum NotificationRoute: Sendable, Equatable {
    /// The session is on the active server: open it.
    case open(sessionId: String)
    /// The session is on another server: switch to it (#83), then open the session.
    case switchThenOpen(server: UUID, sessionId: String)
    /// The server was removed: show the Chats list.
    case showList

    /// A notification with no server id (builds before #84) opens on the active server, as before.
    public static func resolve(sessionId: String, serverID: UUID?, activeID: UUID?,
                               servers: Set<UUID>) -> NotificationRoute {
        guard let serverID, serverID != activeID else { return .open(sessionId: sessionId) }
        return servers.contains(serverID) ? .switchThenOpen(server: serverID, sessionId: sessionId) : .showList
    }
}

/// Issue #84: one connection at a time. Each background refresh checks the active server, then one other server,
/// in turn.
public enum BackgroundRotation {
    /// The `UserDefaults` key of the server that the last run checked.
    public static let lastServerKey = "backgroundRefreshLastServer"

    /// The other server for this run: the next one after `last` in list order. The active server is never
    /// the other server. Nil with one server.
    public static func next(servers: [UUID], active: UUID?, last: UUID?) -> UUID? {
        let others = servers.filter { $0 != active }
        guard !others.isEmpty else { return nil }
        guard let last, let index = servers.firstIndex(of: last) else { return others[0] }
        let after = servers[(index + 1)...] + servers[..<index]
        return after.first { $0 != active } ?? others[0]
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
    /// Issue #84: `server` names the server in the notification. `setsBadge` false: the app sets the badge of
    /// all servers itself.
    public func run(showsPreview: Bool, openSessionId: String? = nil, server: NotificationServer? = nil,
                    setsBadge: Bool = true) async throws -> CatchUpResult {
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
            await notifier.post(CatchUpNotification(session: row, reply: reply, showsPreview: showsPreview,
                                                    server: server))
            notified.append(id)
        }
        let unread = Set(cached.filter(\.isUnread).map(\.id))
        let merged = CatchUp.markUnread(fresh, unread: unread, newContent: Set(changed), openSessionId: openSessionId)
        cache.saveSessions(merged)
        let count = merged.filter(\.isUnread).count
        if setsBadge { await notifier.setBadge(count) }
        return CatchUpResult(changed: changed, notified: notified, unreadCount: count)
    }
}
