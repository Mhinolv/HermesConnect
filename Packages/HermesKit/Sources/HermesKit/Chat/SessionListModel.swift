import Foundation
import Observation

/// The state of the session list, the root screen (issue #7).
///
/// - The cached list shows at once. `refresh()` puts the `session.list` rows in place, in server order
///   (most recent activity first), with the same ids, so the list does not jump.
/// - A connect and the `sessions.changed` event refresh the list. `session.title` renames a row.
/// - The model keeps one `ChatViewModel` per session, so a reply that streams behind the list still ends.
/// - Issue #64: rename, archive, unarchive and delete. The row changes at once. A failure puts it back and throws.
@MainActor @Observable
public final class SessionListModel {
    public private(set) var sessions: [SessionListItem]
    /// `true` after the first `session.list` answer, or when the cache has rows.
    public private(set) var hasLoaded: Bool
    public private(set) var isRefreshing = false
    /// Issue #15: the stored id of the chat on the screen. A refresh never gives it the blue dot.
    /// It follows the chat, so a New Chat counts as soon as `session.create` gives it an id (QA #38 defect 2).
    public var openSessionId: String? { openChatModel?.storedSessionId }
    /// Issue #64: the rows that the list does not show. #73 hides cron runs here.
    public var filter = SessionListFilter()
    /// Issue #64: the number of archived sessions. The "Archived" row shows when it is more than 0.
    public private(set) var archivedCount = 0
    /// Issue #64: the rows of the Archived list, newest first. `refreshArchived()` loads them.
    public private(set) var archivedSessions: [SessionListItem] = []
    /// Issue #64: `true` after the first answer of `refreshArchived()`.
    public private(set) var hasLoadedArchived = false

    @ObservationIgnored private let transport: any SessionsTransport
    @ObservationIgnored private let chatTransport: any ChatTransport
    @ObservationIgnored private let cache: any SessionCacheStore
    /// Issue #44: each chat gets the voice memo transcription of Settings > Voice.
    @ObservationIgnored private let transcription: VoiceTranscription
    @ObservationIgnored private var chats: [String: ChatViewModel] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private weak var openChatModel: ChatViewModel?
    /// Issue #64: rows with an archive or delete call in progress. A refresh does not bring them back.
    @ObservationIgnored private var pendingRemovals: Set<String> = []
    /// Issue #83: counts server switches. A `session.list` answer from the old server is dropped.
    @ObservationIgnored private var generation = 0
    /// Issue #83: the unread ids of the server that is active again. The next load gives them the blue dot.
    @ObservationIgnored private var carriedUnread: Set<String> = []
    /// Issue #83: the outbox sessions of the servers that are not active. A connect never sends them.
    @ObservationIgnored public private(set) var heldOutboxIds: Set<String> = []

    /// `transport` and `chatTransport` are the same `LiveChatTransport` in the app. Tests give fakes.
    public init(transport: any SessionsTransport, chatTransport: any ChatTransport, cache: any SessionCacheStore,
                transcription: VoiceTranscription = .server) {
        self.transport = transport
        self.transcription = transcription
        self.chatTransport = chatTransport
        self.cache = cache
        let cached = cache.loadSessions()
        sessions = cached
        hasLoaded = !cached.isEmpty
    }

    /// The rows that match the search text (title or preview) and the list filter. An empty query gives every row.
    /// Issue #73: no cron runs. The Jobs tab shows them. Catch-up and the app badge still count them.
    public func filtered(_ query: String) -> [SessionListItem] {
        sessions.filter { !$0.isCronRun && filter.includes($0) && $0.matches(query) }
    }

    public func session(id: String) -> SessionListItem? {
        sessions.first { $0.id == id }
    }

    /// The session that the owner opened last, from the cache. The app pushes it at once on launch.
    public var cachedActiveSessionId: String? { cache.loadActiveSessionId() }

    /// Issue #78: the cached active session, or `nil` when it is a cron run. An older build could save one.
    /// Launch, Ask Hermes and Siri use it, so nothing opens or sends into a cron run.
    public var cachedActiveChatId: String? {
        guard let id = cachedActiveSessionId, !isCronRun(id) else { return nil }
        return id
    }

    /// Issue #78: the chat to send into when no cached chat is active. `session.most_recent` (never a cron
    /// run), else the newest cached chat row. `nil`: start a new chat.
    public func mostRecentChatId() async -> String? {
        if let id = await mostRecentSessionId() { return id }
        return chatRows.first?.id
    }

    /// A cron run row. With no row, the legacy run id `cron_<job id>_<time>` tells.
    private func isCronRun(_ id: String) -> Bool {
        guard let row = session(id: id) else { return id.hasPrefix("cron_") }
        return row.isCronRun
    }

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
        let current = generation
        guard var rows = try? await transport.fetchSessions(), current == generation else { return }
        rows.removeAll { pendingRemovals.contains($0.id) }
        let unread = Set(sessions.filter(\.isUnread).map(\.id)).union(carriedUnread)
        carriedUnread = []
        // Issue #15: a row with more messages than the shown row has new content (blue dot).
        let newContent = Set(CatchUp.changedSessions(cached: sessions, fresh: rows))
        let merged = CatchUp.markUnread(rows, unread: unread, newContent: newContent, openSessionId: openSessionId)
        hasLoaded = true
        if merged != sessions {
            sessions = merged
            cache.saveSessions(merged)
        }
        // Issue #64: after the list, so the list never waits for it.
        await loadArchivedCount()
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

    // MARK: Cron runs (issue #73)

    /// The rows of the chats list: every row but the cron runs.
    public var chatRows: [SessionListItem] { SessionListItem.chats(sessions) }

    /// The badge of the Chats tab.
    public var chatsUnreadCount: Int { chatRows.filter(\.isUnread).count }

    /// The cron runs with the blue dot. The Jobs tab shows them on the job rows, and its badge counts them.
    public var unreadCronRuns: [SessionListItem] { sessions.filter { $0.isCronRun && $0.isUnread } }

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
        applyCarriedUnread()
        return result
    }

    /// Issue #83: a catch-up does not know the carried ids. Put the blue dots back after it.
    private func applyCarriedUnread() {
        guard !carriedUnread.isEmpty else { return }
        let carried = carriedUnread
        carriedUnread = []
        let marked = CatchUp.markUnread(sessions, unread: carried, newContent: [], openSessionId: openSessionId)
        guard marked != sessions else { return }
        sessions = marked
        cache.saveSessions(marked)
    }

    /// `session.most_recent`, or `nil` when the server has no session or does not answer.
    public func mostRecentSessionId() async -> String? {
        (try? await transport.fetchMostRecentSessionId()) ?? nil
    }

    // MARK: Server switch (issue #83)

    /// The state of the active server for the server book: the unread rows and the outbox.
    /// Before the first load after a switch, the unread rows of `fallback` stay.
    public func serverState(fallback: ServerStateBook.Entry = .init()) -> ServerStateBook.Entry {
        let outbox = cache.outboxSessionIds().filter { $0 != SessionCache.newChatId && !heldOutboxIds.contains($0) }
        guard hasLoaded else {
            return ServerStateBook.Entry(unreadIds: fallback.unreadIds, unreadChats: fallback.unreadChats,
                                         outboxIds: outbox)
        }
        return ServerStateBook.Entry(unreadIds: sessions.filter(\.isUnread).map(\.id), unreadChats: chatsUnreadCount,
                                     outboxIds: outbox)
    }

    /// The active server changed. The rows, the chat models and the active id belong to the old server.
    /// - Every chat model stops, so none resumes or sends on the new server. Drafts and transcripts stay.
    /// - The list shows the redacted rows until the new server answers. A late answer of the old server is dropped.
    /// - `carryingUnread`: the blue dots of the new server from the last time it was active.
    /// - `heldOutboxes`: the outbox sessions of the other servers. They wait for their own server.
    /// - The new chat with no server row (`newChatId`) belongs to the old server. It moves to `parkNewChatAs`.
    ///   With no key, it is removed: its queued messages never show or send on another server (QA 90-1).
    /// - `restoreNewChatFrom`: the parked new chat of the new server comes back, with its outbox.
    public func switchServer(carryingUnread: [String], heldOutboxes: Set<String>, parkNewChatAs parkId: String? = nil,
                             restoreNewChatFrom restoreId: String? = nil) {
        generation += 1
        for chat in chats.values { chat.stopEvents() }
        chats = [:]
        openChatModel = nil
        refreshTask = nil
        carriedUnread = Set(carryingUnread)
        heldOutboxIds = heldOutboxes
        sessions = []
        hasLoaded = false
        archivedCount = 0
        archivedSessions = []
        hasLoadedArchived = false
        // The cache has one folder for now (#84 makes one for each server). Its rows and its active id
        // belong to the old server: a relaunch must not show them, and catch-up must not count them as new.
        cache.saveSessions([])
        cache.saveActiveSessionId(nil)
        moveNewChat(from: SessionCache.newChatId, to: parkId)
        if let restoreId { moveNewChat(from: restoreId, to: SessionCache.newChatId) }
    }

    /// Move the transcript and the draft of a new chat to another key. `nil` removes them.
    /// Only `newChatId` is in the outbox: a parked new chat never sends.
    private func moveNewChat(from source: String, to target: String?) {
        let messages = cache.loadTranscript(sessionId: source)
        let draft = cache.loadDraft(sessionId: source)
        cache.removeSession(sessionId: source)
        guard let target, !messages.isEmpty || !draft.isEmpty else { return }
        cache.saveTranscript(messages, sessionId: target)
        cache.saveDraft(draft, sessionId: target)
        if target == SessionCache.newChatId, messages.contains(where: { $0.delivery == .queued }) {
            cache.saveOutbox(true, sessionId: target)
        }
    }

    /// Issue #83: the owner removed a server that is not active. Its parked new chat goes too.
    public func removeParkedNewChat(_ parkId: String) {
        cache.removeSession(sessionId: parkId)
    }

    /// The outbox of a removed server never sends. Its queued messages stay in their transcripts.
    public func dropOutboxes(_ ids: [String]) {
        for id in ids { cache.saveOutbox(false, sessionId: id) }
    }

    /// Launch: hold the outbox of the other servers before the first connect.
    public func holdOutboxes(_ ids: Set<String>) {
        heldOutboxIds = ids
    }

    /// Launch: the blue dots of the active server, when the cache lost them.
    public func carryUnread(_ ids: [String]) {
        carriedUnread.formUnion(ids)
    }

    // MARK: Events

    /// Applies one item of the event stream.
    public func receive(_ item: GatewayClientEvent) {
        switch item {
        case .state(.connected):
            Task { await refresh() }
            sendOutboxes()
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

    /// Issue #39: after a relaunch, the chats with messages in the outbox send them on connect, also the chats
    /// that the owner does not open. A chat model that is open already sends its own on the same connect.
    /// The new-chat slot is not here: launch opens it (`hasCachedNewChat`).
    /// Issue #83: the outbox of a server that is not active stays in the cache until that server connects.
    public func sendOutboxes() {
        for id in cache.outboxSessionIds() where id != SessionCache.newChatId && !heldOutboxIds.contains(id)
            && existingChat(for: id) == nil {
            let chat = chat(for: id)
            Task { await chat.open() }
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

    // MARK: Rename, archive, delete (issue #64)

    private var actions: (any SessionActionsTransport)? { transport as? any SessionActionsTransport }

    /// Renames a session. The row and the open chat show the new title at once. A failure puts the old
    /// title back and throws. The server writes `state.db`, so the desktop app shows the title too.
    public func rename(_ id: String, to newTitle: String) async throws {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw SessionActionError.emptyTitle }
        guard let actions else { throw SessionActionError.notSupported }
        let oldRowTitle = session(id: id)?.title
        let chat = existingChat(for: id)
        let oldChatTitle = chat?.title
        setRowTitle(id, title)
        chat?.applyTitle(title)
        do {
            try await actions.renameSession(storedId: id, title: title)
        } catch {
            // Put the old title back, unless a newer title came in while the call ran.
            if session(id: id)?.title == title { setRowTitle(id, oldRowTitle) }
            if chat?.title == title { chat?.applyTitle(oldChatTitle) }
            throw error
        }
    }

    /// Archives a session (`session.archive`). The row leaves the list at once. A failure puts it back and throws.
    public func archive(_ id: String) async throws {
        guard let actions else { throw SessionActionError.notSupported }
        let removed = removeRow(id)
        pendingRemovals.insert(id)
        defer { pendingRemovals.remove(id) }
        do {
            try await actions.setSessionArchived(storedId: id, archived: true)
        } catch {
            restore(removed)
            throw error
        }
        // QA #76: launch and Ask Hermes open the active id. An archived chat must not open there.
        if cache.loadActiveSessionId() == id { cache.saveActiveSessionId(nil) }
        archivedCount += 1
        if hasLoadedArchived, let row = removed.row, !archivedSessions.contains(where: { $0.id == id }) {
            archivedSessions.insert(row, at: 0)
        }
    }

    /// Unarchives a session from the Archived list. A failure puts the row back and throws.
    /// On success the main list loads again, so the row shows in its place.
    public func unarchive(_ id: String) async throws {
        guard let actions else { throw SessionActionError.notSupported }
        let removed = removeRow(id)
        do {
            try await actions.setSessionArchived(storedId: id, archived: false)
        } catch {
            restore(removed)
            throw error
        }
        await refresh()
    }

    /// Deletes a session on the server, from the main list or the Archived list. The row leaves at once.
    /// - An open or live chat closes first (`session.close`), so the server does not refuse with 4023.
    /// - On success the chat model, the transcript, the draft and the active id leave the cache.
    /// - A failure puts the row back and throws.
    public func delete(_ id: String) async throws {
        guard let actions else { throw SessionActionError.notSupported }
        let removed = removeRow(id)
        pendingRemovals.insert(id)
        defer { pendingRemovals.remove(id) }
        do {
            if let chat = existingChat(for: id), let live = chat.liveSessionId {
                // A close that fails (for example an old live id) does not stop the delete.
                try? await actions.closeSession(liveId: live)
                chat.liveSessionClosed()
            }
            try await actions.deleteSession(storedId: id)
        } catch {
            restore(removed)
            throw error
        }
        forget(id)
        cache.removeSession(sessionId: id)
    }

    /// Loads the Archived list (`archived=only`). A failure keeps the rows that show.
    public func refreshArchived() async {
        guard let actions, let page = try? await actions.fetchArchivedSessions(limit: Self.archivedPageSize)
        else { return }
        archivedSessions = page.sessions.filter { !pendingRemovals.contains($0.id) }
        archivedCount = max(page.total - (page.sessions.count - archivedSessions.count), archivedSessions.count)
        hasLoadedArchived = true
    }

    /// The server caps a page at 100 rows.
    static let archivedPageSize = 100

    private func loadArchivedCount() async {
        guard let actions, let page = try? await actions.fetchArchivedSessions(limit: 1) else { return }
        if archivedCount != page.total { archivedCount = page.total }
    }

    private func existingChat(for id: String) -> ChatViewModel? {
        chats[id] ?? chats.values.first { $0.storedSessionId == id }
    }

    private func setRowTitle(_ id: String, _ title: String?) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].title != title else { return }
        sessions[index].title = title
        cache.saveSessions(sessions)
    }

    /// A row that an action took out of a list, with its place.
    private struct RemovedRow {
        var row: SessionListItem?
        var index: Int?
        var archivedRow: SessionListItem?
        var archivedIndex: Int?
    }

    private func removeRow(_ id: String) -> RemovedRow {
        var removed = RemovedRow()
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            removed.row = sessions.remove(at: index)
            removed.index = index
            cache.saveSessions(sessions)
        }
        if let index = archivedSessions.firstIndex(where: { $0.id == id }) {
            removed.archivedRow = archivedSessions.remove(at: index)
            removed.archivedIndex = index
            archivedCount = max(archivedCount - 1, 0)
        }
        return removed
    }

    private func restore(_ removed: RemovedRow) {
        if let row = removed.row, let index = removed.index, !sessions.contains(where: { $0.id == row.id }) {
            sessions.insert(row, at: min(index, sessions.count))
            cache.saveSessions(sessions)
        }
        if let row = removed.archivedRow, let index = removed.archivedIndex,
           !archivedSessions.contains(where: { $0.id == row.id }) {
            archivedSessions.insert(row, at: min(index, archivedSessions.count))
            archivedCount += 1
        }
    }

    // MARK: Chats

    /// The chat of a stored session. The same id gives the same model. A new chat that got this
    /// stored id from `session.create` is the same model too.
    public func chat(for id: String) -> ChatViewModel {
        if let chat = existingChat(for: id) { return chat }
        let title = session(id: id).map(\.displayTitle)
        let chat = ChatViewModel(transport: chatTransport, storedSessionId: id, title: title, cache: cache,
                                 transcription: transcription)
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
        let chat = ChatViewModel(transport: chatTransport, cache: cache, keepsNewChat: keeps,
                                 transcription: transcription)
        chat.startEvents()
        chats[key] = chat
        return chat
    }
}

/// Issue #64: which rows the session list shows. The server already leaves out archived rows.
/// #73 (Jobs tab) adds `"cron"` to `hiddenSources`.
public struct SessionListFilter: Sendable, Equatable {
    /// Rows with one of these `source` values do not show.
    public var hiddenSources: Set<String>

    public init(hiddenSources: Set<String> = []) {
        self.hiddenSources = hiddenSources
    }

    public func includes(_ item: SessionListItem) -> Bool {
        guard let source = item.source else { return true }
        return !hiddenSources.contains(source)
    }
}
