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

    @ObservationIgnored private let transport: any SessionsTransport
    @ObservationIgnored private let chatTransport: any ChatTransport
    @ObservationIgnored private let cache: any SessionCacheStore
    @ObservationIgnored private var chats: [String: ChatViewModel] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?

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
        let merged = rows.map { row in
            var row = row
            if unread.contains(row.id) { row.isUnread = true }
            return row
        }
        hasLoaded = true
        guard merged != sessions else { return }
        sessions = merged
        cache.saveSessions(merged)
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

    /// Uses `chat` for the session `id` (the DEBUG demo seeds its thread this way).
    public func register(_ chat: ChatViewModel, for id: String) {
        chat.startEvents()
        chats[id] = chat
    }

    /// A new, empty chat. The first send calls `session.create` (`source: "ios"`). `key` names the route.
    public func newChat(key: String) -> ChatViewModel {
        if let chat = chats[key] { return chat }
        let chat = ChatViewModel(transport: chatTransport, cache: cache)
        chat.startEvents()
        chats[key] = chat
        return chat
    }
}
