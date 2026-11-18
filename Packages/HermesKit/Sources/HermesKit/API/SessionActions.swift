import Foundation

/// What rename, archive and delete need from the server (issue #64). `LiveChatTransport` conforms.
/// A sessions transport without it (offline, previews) fails each action with `SessionActionError.notSupported`.
public protocol SessionActionsTransport: Sendable {
    /// `PATCH /api/sessions/{stored id}` with `title`. The session does not have to be live.
    func renameSession(storedId: String, title: String) async throws
    /// `session.archive {session_id: <stored>, archived}`. `false` unarchives.
    func setSessionArchived(storedId: String, archived: Bool) async throws
    /// `session.close {session_id: <live>}`. The stored row stays.
    func closeSession(liveId: String) async throws
    /// `session.delete {session_id: <stored>}`. Not found (4007) is a success. Live elsewhere (4023):
    /// `DELETE /api/sessions/{stored id}`, so the owner never sees 4023.
    func deleteSession(storedId: String) async throws
    /// `GET /api/sessions?archived=only&order=recent`: the newest archived rows and the total count.
    func fetchArchivedSessions(limit: Int) async throws -> ArchivedSessions
    /// Issue #94: `PATCH /api/sessions/{stored id}` with `unread`. The read state of the desktop app follows.
    func setSessionUnread(storedId: String, unread: Bool) async throws
}

/// One page of archived sessions (issue #64).
public struct ArchivedSessions: Sendable, Equatable {
    public var sessions: [SessionListItem]
    public var total: Int

    public init(sessions: [SessionListItem], total: Int) {
        self.sessions = sessions
        self.total = total
    }
}

/// `session.delete` error codes (`methods_session.py:1167-1192`).
public enum SessionDeleteCode {
    /// The session is live in the server process.
    public static let live = 4023
    /// No stored session with this id.
    public static let notFound = 4007
}

/// A failed session action (issue #64).
public enum SessionActionError: Error, Sendable, Equatable {
    /// The transport has no session actions (offline or preview).
    case notSupported
    /// The new title is empty after trimming.
    case emptyTitle
    /// The server refused the change. `detail` is the server text.
    case refused(status: Int, detail: String)

    /// The text of the error alert: the server message when there is one.
    public static func message(for error: any Error) -> String {
        switch error {
        case SessionActionError.notSupported, GatewayError.notConnected, GatewayError.disconnected:
            return "Hermes is not connected. Try again when the connection is back."
        case SessionActionError.emptyTitle:
            return "Enter a title."
        case SessionActionError.refused(_, let detail):
            return detail
        case GatewayError.rpc(_, let message) where !message.isEmpty:
            return message
        case GatewayError.timeout:
            return "Hermes did not answer. Try again."
        case HermesAPIError.notFound:
            return "Hermes does not have this chat."
        case HermesAPIError.unauthorized:
            return "Hermes refused the session. Try again."
        case HermesAPIError.http(let status):
            return "Hermes answered with error \(status)."
        default:
            return "Try again."
        }
    }
}

// MARK: WebSocket calls

struct SessionArchiveParams: Encodable, Sendable {
    var sessionId: String
    var archived: Bool
    private enum CodingKeys: String, CodingKey { case sessionId = "session_id", archived }
}

struct SessionArchiveResult: Decodable, Sendable {
    var archived: Bool?
}

struct SessionCloseResult: Decodable, Sendable {
    var closed: Bool?
}

struct SessionDeleteResult: Decodable, Sendable {
    var deleted: String?
}

extension GatewayClient {
    /// `session.archive` with a stored id (`methods_session.py:1246-1273`).
    public func archiveSession(storedId: String, archived: Bool) async throws {
        _ = try await call("session.archive", params: SessionArchiveParams(sessionId: storedId, archived: archived),
                           as: SessionArchiveResult.self)
    }

    /// `session.close` with a live id (`methods_session.py:2177-2181`).
    public func closeSession(liveId: String) async throws {
        _ = try await call("session.close", params: SessionIdParams(sessionId: liveId), as: SessionCloseResult.self)
    }

    /// `session.delete` with a stored id (`methods_session.py:1167-1192`). Errors 4023 and 4007 are thrown.
    public func deleteStoredSession(storedId: String) async throws {
        _ = try await call("session.delete", params: SessionIdParams(sessionId: storedId), as: SessionDeleteResult.self)
    }
}

extension LiveChatTransport: SessionActionsTransport {
    public func renameSession(storedId: String, title: String) async throws {
        try await withREST { try await $0.renameSession(storedSessionId: storedId, title: title) }
    }

    public func setSessionArchived(storedId: String, archived: Bool) async throws {
        try await readyClient().archiveSession(storedId: storedId, archived: archived)
    }

    public func closeSession(liveId: String) async throws {
        try await readyClient().closeSession(liveId: liveId)
    }

    public func deleteSession(storedId: String) async throws {
        do {
            try await readyClient().deleteStoredSession(storedId: storedId)
        } catch GatewayError.rpc(let code, _) where code == SessionDeleteCode.notFound {
            return
        } catch GatewayError.rpc(let code, _) where code == SessionDeleteCode.live {
            // Live in another client of this server (for example the desktop app). The REST path deletes it.
            try await withREST { try await $0.deleteSession(storedSessionId: storedId) }
        }
    }

    public func setSessionUnread(storedId: String, unread: Bool) async throws {
        try await withREST { try await $0.setSessionUnread(storedSessionId: storedId, unread: unread) }
    }

    public func fetchArchivedSessions(limit: Int) async throws -> ArchivedSessions {
        let page = try await withREST {
            try await $0.sessions(SessionsQuery(limit: limit, order: .recent, archived: .only))
        }
        return ArchivedSessions(sessions: page.sessions.map(SessionListItem.init(summary:)), total: page.total)
    }
}

extension SessionListItem {
    /// A `GET /api/sessions` row (issue #64, the Archived list).
    public init(summary: SessionSummary) {
        self.init(id: summary.id, title: summary.title, preview: summary.preview,
                  startedAt: summary.startedAt.map { Date(timeIntervalSince1970: $0) },
                  messageCount: summary.messageCount, source: summary.source)
    }
}
