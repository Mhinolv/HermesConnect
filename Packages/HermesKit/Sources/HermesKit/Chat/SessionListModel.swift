import Foundation
import Observation

/// The state of the session list, the root screen (issue #7).
///
/// - The cached list shows at once. `refresh()` puts the `session.list` rows in place, in server order
///   (most recent activity first), with the same ids, so the list does not jump.
/// - A connect and the `sessions.changed` event refresh the list. `session.title` renames a row.
/// - The model keeps one `ChatViewModel` per session, so a reply that streams behind the list still ends.
@MainActor @Observable
public final class SessionListModel {
    public private(set) var sessions: [SessionListItem]
    /// `true` after the first `session.list` answer, or when the cache has rows.
    public private(set) var hasLoaded: Bool
    public private(set) var isRefreshing = false
    /// Issue #15: the stored id of the chat on the screen. A refresh never gives it the blue dot.
    /// It follows the chat, so a New Chat counts as soon as `session.create` gives it an id (QA #38 defect 2).
    public var openSessionId: String? { openChatModel?.storedSessionId }

    @ObservationIgnored private let transport: any SessionsTransport
    @ObservationIgnored private let chatTransport: any ChatTransport
    @ObservationIgnored private let cache: any SessionCacheStore
    @ObservationIgnored private var chats: [String: ChatViewModel] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private weak var openChatModel: ChatViewModel?

    /// `transport` and `chatTransport` are the same `LiveChatTransport` in the app. Tests give fakes.
    public init(transport: any SessionsTransport, chatTransport: any ChatTransport, cache: any SessionCacheStore) {
        self.transport = transport
        self.chatTransport = chatTransport
        self.cache = cache
        let cached = cache.loadSessions()
        sessions = cached
        hasLoaded = !cached.isEmpty
    }

    /// The rows that match the search text (title or preview). An empty query gives every row.
    public func filtered(_ query: String) -> [SessionListItem] {
        sessions.filter { $0.matches(query) }
    }

    public func session(id: String) -> SessionListItem? {
        sessions.first { $0.id == id }
    }

    /// The session that the owner opened last, from the cache. The app pushes it at once on launch.
    public var cachedActiveSessionId: String? { cache.loadActiveSessionId() }

    /// Issue #36: a new chat with no server row kept memos (for example a failed memo while offline).
    /// The app opens that chat at launch.
    public var hasCachedNewChat: Bool { !cache.loadTranscript(sessionId: SessionCache.newChatId).isEmpty }

    // MARK: Network

    /// `session.list`. Calls at the same time share one request. A failure keeps the cached list.
    public func refresh() async {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await load() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func load() async {
        isRefreshing = true
        defer { isRefreshing = false }
        guard let rows = try? await transport.fetchSessions() else { return }
        let unread = Set(sessions.filter(\.isUnread).map(\.id))
        // Issue #15: a row with more messages than the shown row has new content (blue dot).
        let newContent = Set(CatchUp.changedSessions(cached: sessions, fresh: rows))
        let merged = CatchUp.markUnread(rows, unread: unread, newContent: newContent, openSessionId: openSessionId)
        hasLoaded = true
        guard merged != sessions else { return }
        sessions = merged
        cache.saveSessions(merged)
    }

    /// The chat screen of `chat` appeared. Its session loses the blue dot and gets no new one.
    public func openChat(_ chat: ChatViewModel?) {
        openChatModel = chat
        if let id = chat?.storedSessionId { markRead(id) }
    }

    /// The chat screen of `chat` went away. Another chat that is open stays open.
    public func closeChat(_ chat: ChatViewModel) {
        if openChatModel === chat { openChatModel = nil }
    }

    /// Issue #15: the number of sessions with the blue dot. The app badge shows it.
    public var unreadCount: Int { sessions.filter(\.isUnread).count }

    /// Issue #15: the owner opened the session. Its blue dot goes away.
    public func markRead(_ id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].isUnread else { return }
        sessions[index].isUnread = false
        cache.saveSessions(sessions)
    }

    /// Issue #15: one background catch-up (BGAppRefresh). It posts the notifications and sets the badge.
    /// Then the list shows the new rows and dots. Returns `nil` when `session.list` fails.
    @discardableResult
    public func catchUp(showsPreview: Bool, notifier: any LocalNotifying) async -> CatchUpResult? {
        cache.saveSessions(sessions)
        let refresher = CatchUpRefresher(sessions: transport, chats: chatTransport, cache: cache, notifier: notifier)
        guard let result = try? await refresher.run(showsPreview: showsPreview, openSessionId: openSessionId)
        else { return nil }
        sessions = cache.loadSessions()
        hasLoaded = true
        return result
    }

    /// `session.most_recent`, or `nil` when the server has no session or does not answer.
    public func mostRecentSessionId() async -> String? {
        (try? await transport.fetchMostRecentSessionId()) ?? nil
    }

    // MARK: Events

    /// Applies one item of the event stream.
    public func receive(_ item: GatewayClientEvent) {
        switch item {
        case .state(.connected):
            Task { await refresh() }
        case .event(let event):
            switch event.kind {
            case .sessionsChanged:
                Task { await refresh() }
            case .sessionTitle(let payload):
                rename(payload.sessionId, to: payload.title)
            default:
                break
            }
        default:
            break
        }
    }

    /// Reads gateway events for the life of the model. A second call does nothing.
    public func startEvents() {
        guard eventTask == nil else { return }
        let stream = transport.events
        eventTask = Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                self.receive(item)
            }
        }
    }

    private func rename(_ id: String, to title: String) {
        guard !title.isEmpty, let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].title != title else { return }
        sessions[index].title = title
        cache.saveSessions(sessions)
    }

    // MARK: Chats

    /// The chat of a stored session. The same id gives the same model. A new chat that got this
    /// stored id from `session.create` is the same model too.
    public func chat(for id: String) -> ChatViewModel {
        if let chat = chats[id] ?? chats.values.first(where: { $0.storedSessionId == id }) { return chat }
        let title = session(id: id).map(\.displayTitle)
        let chat = ChatViewModel(transport: chatTransport, storedSessionId: id, title: title, cache: cache)
        chat.startEvents()
        chats[id] = chat
        return chat
    }

    /// Drops a session that the server does not have (`session.resume` error 4007): the row, the chat
    /// model and the active id. A later `refresh()` brings the row back if the server still lists it.
    public func forget(_ id: String) {
        chats = chats.filter { key, chat in key != id && chat.storedSessionId != id }
        if cache.loadActiveSessionId() == id { cache.saveActiveSessionId(nil) }
        guard sessions.contains(where: { $0.id == id }) else { return }
        sessions.removeAll { $0.id == id }
        cache.saveSessions(sessions)
    }

    /// Uses `chat` for the session `id` (the DEBUG demo seeds its thread this way).
    public func register(_ chat: ChatViewModel, for id: String) {
        chat.startEvents()
        chats[id] = chat
    }

    /// A new, empty chat. The first send calls `session.create` (`source: "ios"`). `key` names the route.
    /// Issue #36: one new chat at a time keeps its memos in the cache until its first prompt is accepted.
    /// It shows the memos that a new chat kept before a quit. An empty holder gives the slot to this chat.
    public func newChat(key: String) -> ChatViewModel {
        if let chat = chats[key] { return chat }
        chats.values.forEach { $0.yieldNewChat() }
        let keeps = !chats.values.contains { $0.keepsNewChat }
        let chat = ChatViewModel(transport: chatTransport, cache: cache, keepsNewChat: keeps)
        chat.startEvents()
        chats[key] = chat
        return chat
    }
}
