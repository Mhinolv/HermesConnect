import Foundation

/// One row of the session list (issue #7). It comes from `session.list` and the app caches it.
public struct SessionListItem: Identifiable, Sendable, Equatable, Codable {
    /// The stored id (docs/hermes-protocol.md 3.3). `session.resume` takes it.
    public let id: String
    public var title: String?
    public var preview: String?
    public var startedAt: Date?
    public var messageCount: Int?
    /// The platform of the session: `ios`, `desktop`, `photon` (iMessage), `cron`, ...
    public var source: String?
    /// #15 sets it. The row shows a blue dot.
    public var isUnread: Bool

    public init(id: String, title: String? = nil, preview: String? = nil, startedAt: Date? = nil,
                messageCount: Int? = nil, source: String? = nil, isUnread: Bool = false) {
        self.id = id
        self.title = title
        self.preview = preview
        self.startedAt = startedAt
        self.messageCount = messageCount
        self.source = source
        self.isUnread = isUnread
    }

    /// A `session.list` row.
    public init(row: SessionListRow) {
        self.init(id: row.id, title: row.title, preview: row.preview,
                  startedAt: row.startedAt.map { Date(timeIntervalSince1970: $0) },
                  messageCount: row.messageCount, source: row.source)
    }

    /// The title that the row shows. An empty title is "Untitled".
    public var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// The source label before the preview, or `nil` for a session of this app.
    public var sourceBadge: SourceBadge? {
        guard let source, !source.isEmpty, source != ChatSource.iOS else { return nil }
        if source == "cron" { return SourceBadge(symbol: "clock", text: "Cron") }
        let name = source == "photon" ? "iMessage" : source.prefix(1).uppercased() + source.dropFirst()
        return SourceBadge(symbol: "bubble.left", text: name)
    }

    /// Issue #73: a cron run. The Jobs tab shows it, the chats list does not.
    public var isCronRun: Bool { source == "cron" }

    /// Issue #73: the rows of the chats list. Cron runs go to the Jobs tab.
    public static func chats(_ rows: [SessionListItem]) -> [SessionListItem] {
        rows.filter { !$0.isCronRun }
    }

    /// `true` when `query` is in the title or the preview. An empty query matches every row.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return displayTitle.localizedStandardContains(query) || (preview ?? "").localizedStandardContains(query)
    }

    // Tolerant decoding: a cache file from an older or newer build still loads (missing keys get defaults).
    private enum CodingKeys: String, CodingKey { case id, title, preview, startedAt, messageCount, source, isUnread }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        isUnread = try container.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
    }

    /// The small label before the preview: an SF Symbol and a name.
    public struct SourceBadge: Sendable, Equatable {
        public var symbol: String
        public var text: String
    }
}
