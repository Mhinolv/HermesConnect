import Foundation
import Synchronization
import Testing
@testable import HermesKit

// Issue #95: select many chats and archive them in one action. Fakes only. No test connects to a server.

/// A sessions transport that records archive calls. Ids in `failures` throw. `hold()` stops each call until
/// `release()`. No network.
private final class ArchiveFakeTransport: SessionsTransport, SessionActionsTransport, Sendable {
    private struct State {
        var rows: [SessionListItem]
        var calls: [String] = []
        var failures: Set<String> = []
        var archived = ArchivedSessions(sessions: [], total: 0)
        var holds = false
        var gate: CheckedContinuation<Void, Never>?
    }

    private let state: Mutex<State>
    let events: AsyncStream<GatewayClientEvent>

    init(rows: [SessionListItem], failures: Set<String> = []) {
        state = Mutex(State(rows: rows, failures: failures))
        events = AsyncStream { _ in }
    }

    var rows: [SessionListItem] {
        get { state.withLock { $0.rows } }
        set { state.withLock { $0.rows = newValue } }
    }

    var calls: [String] { state.withLock { $0.calls } }
    var archived: ArchivedSessions {
        get { state.withLock { $0.archived } }
        set { state.withLock { $0.archived = newValue } }
    }

    func hold() { state.withLock { $0.holds = true } }

    func release() {
        let gate = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.holds = false
            defer { state.gate = nil }
            return state.gate
        }
        gate?.resume()
    }

    func fetchSessions() async throws -> [SessionListItem] { rows }
    func fetchMostRecentSessionId() async throws -> String? { nil }

    func setSessionArchived(storedId: String, archived: Bool) async throws {
        state.withLock { $0.calls.append("archive \(storedId)") }
        await withCheckedContinuation { continuation in
            let waits = state.withLock { state -> Bool in
                guard state.holds else { return false }
                state.gate = continuation
                return true
            }
            if !waits { continuation.resume() }
        }
        if state.withLock({ $0.failures.contains(storedId) }) {
            throw GatewayError.rpc(code: 5007, message: "database is locked")
        }
    }

    func renameSession(storedId _: String, title _: String) async throws {}
    func closeSession(liveId _: String) async throws {}
    func deleteSession(storedId _: String) async throws {}
    func setSessionUnread(storedId _: String, unread _: Bool) async throws {}

    func fetchArchivedSessions(limit: Int) async throws -> ArchivedSessions {
        let page = archived
        return ArchivedSessions(sessions: Array(page.sessions.prefix(limit)), total: page.total)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BatchArchiveTests {
    private let rows = [
        SessionListItem(id: "c5", title: "Trip", preview: "Book it", source: "ios", isUnread: true),
        SessionListItem(id: "c4", title: "Dinner", preview: "7:30 PM", source: "photon"),
        SessionListItem(id: "cron_j1_1", title: "Digest", source: "cron"),
        SessionListItem(id: "c3", title: "Logs", preview: "journalctl", source: "desktop"),
        SessionListItem(id: "c2", title: "Taxes", preview: "1099", source: "ios"),
        SessionListItem(id: "c1", title: "Books", preview: "Next meeting", source: "ios"),
    ]

    private func model(_ transport: ArchiveFakeTransport, cache: InMemorySessionCacheStore? = nil) -> SessionListModel {
        SessionListModel(transport: transport, chatTransport: FakeChatTransport(),
                         cache: cache ?? InMemorySessionCacheStore(sessions: rows))
    }

    @Test func everyChatArchivesInListOrderAndCounts() async {
        let transport = ArchiveFakeTransport(rows: rows)
        let cache = InMemorySessionCacheStore(sessions: rows)
        let list = model(transport, cache: cache)
        let result = await list.archive(["c2", "c5", "c4"])
        #expect(result == BatchArchiveResult(archived: ["c5", "c4", "c2"]))
        #expect(transport.calls == ["archive c5", "archive c4", "archive c2"])
        #expect(list.sessions.map(\.id) == ["cron_j1_1", "c3", "c1"])
        #expect(cache.loadSessions().map(\.id) == ["cron_j1_1", "c3", "c1"])
        #expect(list.archivedCount == 3)
    }

    @Test func theRowsLeaveAtOnceBeforeTheServerAnswers() async {
        let transport = ArchiveFakeTransport(rows: rows)
        let list = model(transport)
        transport.hold()
        let task = Task { await list.archive(["c5", "c4"]) }
        while transport.calls.isEmpty { await Task.yield() }
        #expect(list.session(id: "c5") == nil)
        #expect(list.session(id: "c4") == nil)
        // A refresh while the calls run keeps the rows out.
        await list.refresh()
        #expect(list.session(id: "c4") == nil)
        transport.release()
        while transport.calls.count < 2 { await Task.yield() }
        transport.release()
        _ = await task.value
        #expect(list.sessions.map(\.id) == ["cron_j1_1", "c3", "c2", "c1"])
    }

    @Test func aFailureContinuesAndPutsTheFailedRowsBackInTheirPlaces() async {
        let transport = ArchiveFakeTransport(rows: rows, failures: ["c4", "c2"])
        let cache = InMemorySessionCacheStore(sessions: rows)
        let list = model(transport, cache: cache)
        let result = await list.archive(["c5", "c4", "c3", "c2"])
        #expect(result.archived == ["c5", "c3"])
        #expect(result.failed == ["c4", "c2"])
        #expect(transport.calls.count == 4, "the calls after a failure still go")
        #expect(list.sessions.map(\.id) == ["c4", "cron_j1_1", "c2", "c1"])
        #expect(cache.loadSessions().map(\.id) == ["c4", "cron_j1_1", "c2", "c1"])
        #expect(list.archivedCount == 2)
        // The failed rows are not kept out of the next refresh.
        await list.refresh()
        #expect(list.session(id: "c4") != nil)
    }

    @Test func allFailKeepsEveryRow() async {
        let transport = ArchiveFakeTransport(rows: rows, failures: ["c5", "c4"])
        let list = model(transport)
        let result = await list.archive(["c5", "c4"])
        #expect(result.archived.isEmpty)
        #expect(result.failed == ["c5", "c4"])
        #expect(list.sessions == rows, "the rows come back with their dots")
        #expect(list.archivedCount == 0)
    }

    @Test func archivedChatsStayOutAfterARefreshAndARelaunch() async {
        let transport = ArchiveFakeTransport(rows: rows)
        let cache = InMemorySessionCacheStore(sessions: rows, activeSessionId: "c4")
        let list = model(transport, cache: cache)
        _ = await list.archive(["c5", "c4"])
        // The server leaves archived rows out of `session.list`.
        transport.rows = rows.filter { !["c5", "c4"].contains($0.id) }
        await list.refresh()
        #expect(list.session(id: "c5") == nil)
        #expect(cache.loadActiveSessionId() == nil, "launch does not open an archived chat")
        let relaunched = model(transport, cache: cache)
        #expect(relaunched.session(id: "c4") == nil)
    }

    @Test func aLoadedArchivedListGetsTheRowsOnTop() async {
        let transport = ArchiveFakeTransport(rows: rows)
        transport.archived = ArchivedSessions(sessions: [SessionListItem(id: "old1", title: "Old")], total: 1)
        let list = model(transport)
        await list.refreshArchived()
        _ = await list.archive(["c4", "c5"])
        #expect(list.archivedSessions.map(\.id) == ["c5", "c4", "old1"])
        #expect(list.archivedCount == 3)
    }

    @Test func unknownAndRepeatedIdsAreSkipped() async {
        let transport = ArchiveFakeTransport(rows: rows)
        let list = model(transport)
        #expect(await list.archive([]) == BatchArchiveResult())
        #expect(await list.archive(["gone"]) == BatchArchiveResult())
        #expect(await list.archive(["c1", "c1", "gone"]) == BatchArchiveResult(archived: ["c1"]))
        #expect(transport.calls == ["archive c1"])
    }

    @Test func aServerSwitchStopsTheRunWithNoRowsBack() async {
        let transport = ArchiveFakeTransport(rows: rows, failures: ["c5"])
        let list = model(transport, cache: InMemorySessionCacheStore(sessions: rows))
        transport.hold()
        let task = Task { await list.archive(["c5", "c4", "c3"]) }
        while transport.calls.isEmpty { await Task.yield() }
        list.switchServer(carryingUnread: [])
        transport.release()
        let result = await task.value
        #expect(result.interrupted)
        #expect(transport.calls == ["archive c5"], "no call goes to the new server")
        #expect(list.session(id: "c5") == nil, "a failed row of the old server does not come back")
    }

    @Test func aTransportWithNoActionsFailsEveryRowAndKeepsThem() async {
        let list = SessionListModel(transport: FakeSessionsTransport(rows: rows), chatTransport: FakeChatTransport(),
                                    cache: InMemorySessionCacheStore(sessions: rows))
        let result = await list.archive(["c5", "c4"])
        #expect(result.failed == ["c5", "c4"])
        #expect(list.sessions == rows)
    }
}

@Suite struct ChatSelectionTests {
    private let rows = ["a", "b", "c", "d"].map { SessionListItem(id: $0, title: $0) }

    @Test func selectAllTakesOnlyTheRowsThatShow() {
        var selection = ChatSelection()
        let matches = Array(rows.prefix(2))
        #expect(!selection.allSelected(matches))
        selection.toggleAll(matches)
        #expect(selection.ids == ["a", "b"])
        #expect(selection.allSelected(matches))
        #expect(!selection.allSelected(rows))
        // "Deselect All" clears the rows that show.
        selection.toggleAll(matches)
        #expect(selection.ids.isEmpty)
        #expect(!selection.allSelected([]), "an empty list is never all selected")
    }

    @Test func theCountUsesTheRowsThatShowInListOrder() {
        let selection = ChatSelection(ids: ["d", "b", "x"])
        #expect(selection.selected(in: rows) == ["b", "d"])
        #expect(selection.selected(in: Array(rows.prefix(2))) == ["b"])
    }

    @Test func aChatThatGoesAwayLeavesTheSelection() {
        var selection = ChatSelection(ids: ["a", "c"])
        selection.keep(only: rows.filter { $0.id != "c" })
        #expect(selection.ids == ["a"])
        // A new row shows unselected.
        selection.keep(only: rows + [SessionListItem(id: "e")])
        #expect(selection.ids == ["a"])
    }
}
