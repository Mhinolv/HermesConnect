import Foundation

/// Issue #83: the active server changed. The app closes the old link, resets the lists, then connects.
public struct ServerChange: Sendable, Equatable {
    /// The server that was active. Nil before setup.
    public var from: UUID?
    /// The server that is active now. Nil when the last server was removed.
    public var to: UUID?

    public init(from: UUID?, to: UUID?) {
        self.from = from
        self.to = to
    }

    /// The same id with a new host, port or user (#66 server detail). The old unread rows do not apply.
    public var isSameServer: Bool { from == to }
}

/// Issue #83: what each server keeps while another server is active. One server is connected at a time, so
/// the entry of a server that is not active stays as it was when the owner switched away.
/// Issue #84: each server has its own cache folder. Background refresh updates the entry of a server that is not active.
public struct ServerStateBook: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// The stored ids with the blue dot: chats and cron runs. The app icon badge counts them.
        public var unreadIds: [String]
        /// The unread chats (no cron runs). The server menu shows them.
        public var unreadChats: Int
        /// Issue #39: the sessions with queued messages. They send on the next connect to this server only.
        public var outboxIds: [String]

        public init(unreadIds: [String] = [], unreadChats: Int = 0, outboxIds: [String] = []) {
            self.unreadIds = unreadIds
            self.unreadChats = unreadChats
            self.outboxIds = outboxIds
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            unreadIds = (try? container.decodeIfPresent([String].self, forKey: .unreadIds)) ?? []
            unreadChats = max((try? container.decodeIfPresent(Int.self, forKey: .unreadChats)) ?? 0, 0)
            outboxIds = (try? container.decodeIfPresent([String].self, forKey: .outboxIds)) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case unreadIds, unreadChats, outboxIds
        }

        var isEmpty: Bool { unreadIds.isEmpty && unreadChats == 0 && outboxIds.isEmpty }

        /// Issue #84: the entry of a server that is not active, from its cache folder. Background refresh
        /// updates it, so the menu and the app icon badge count the new replies of that server.
        public init(cachedRows rows: [SessionListItem], outbox: [String]) {
            self.init(unreadIds: rows.filter(\.isUnread).map(\.id),
                      unreadChats: SessionListItem.chats(rows).filter(\.isUnread).count,
                      outboxIds: outbox.filter { $0 != SessionCache.newChatId })
        }
    }

    public private(set) var entries: [UUID: Entry]

    public init(entries: [UUID: Entry] = [:]) {
        self.entries = entries
    }

    /// Tolerant decode: bad data gives an empty book. Counts are not worth a failed launch.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? container.decodeIfPresent([String: Entry].self, forKey: .entries)) ?? [:]
        entries = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let raw = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) })
        try container.encode(raw, forKey: .entries)
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    public func entry(for id: UUID) -> Entry {
        entries[id] ?? Entry()
    }

    /// Keep the state of one server. Returns `false` when nothing changed.
    @discardableResult
    public mutating func record(_ state: Entry, for id: UUID) -> Bool {
        guard entry(for: id) != state else { return false }
        entries[id] = state.isEmpty ? nil : state
        return true
    }

    /// The outbox ids of every server but `id`. The connected server must not send them.
    public func outboxIds(except id: UUID?) -> Set<String> {
        Set(entries.filter { $0.key != id }.flatMap(\.value.outboxIds))
    }

    /// Forget a server that the owner removed, and the servers that are not in `ids`.
    public mutating func keep(only ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    /// The app icon badge: the unread sessions of all servers. `activeID` uses the live count of the list.
    public func badgeCount(activeID: UUID?, activeCount: Int) -> Int {
        entries.reduce(activeCount) { total, item in
            item.key == activeID ? total : total + item.value.unreadIds.count
        }
    }

    /// True when a server other than `activeID` has unread chats (the blue dot next to the chevron).
    public func othersHaveUnread(activeID: UUID?) -> Bool {
        entries.contains { $0.key != activeID && $0.value.unreadChats > 0 }
    }
}

/// Issue #83: the server menu in the title of the Chats list and the Jobs list (design notes, "Switcher").
public struct ServerMenu: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var unreadChats: Int
        public var isActive: Bool

        /// "3 unread", or nil with no unread chats.
        public var subtitle: String? { unreadChats > 0 ? "\(unreadChats) unread" : nil }

        /// "<name>, 3 unread, selected".
        public var accessibilityLabel: String {
            var parts = [name]
            if let subtitle { parts.append(subtitle) }
            if isActive { parts.append("selected") }
            return parts.joined(separator: ", ")
        }
    }

    public var items: [Item]
    /// The blue dot next to the chevron: another server has unread chats.
    public var showsDot: Bool

    /// `activeChats`: the live count of unread chats of the active server.
    public init(list: ServerList, book: ServerStateBook, activeChats: Int) {
        let activeID = list.active?.id
        items = list.servers.map { server in
            let isActive = server.id == activeID
            return Item(id: server.id, name: server.name,
                        unreadChats: isActive ? activeChats : book.entry(for: server.id).unreadChats, isActive: isActive)
        }
        showsDot = items.contains { !$0.isActive && $0.unreadChats > 0 }
    }

    /// One server: no menu, and the title stays "Hermes".
    public var showsMenu: Bool { items.count > 1 }

    /// The title of the Chats list: "Hermes" with one server, else the name of the active server.
    public func title(default fallback: String = "Hermes") -> String {
        guard showsMenu, let active = items.first(where: \.isActive) else { return fallback }
        return active.name
    }

    /// "<name>, server" for VoiceOver. A dot adds "unread on other servers".
    public func titleAccessibilityLabel(default fallback: String = "Hermes") -> String {
        let label = "\(title(default: fallback)), server"
        return showsDot ? "\(label), unread on other servers" : label
    }

    /// VoiceOver says this after a switch.
    public static func switchAnnouncement(_ name: String) -> String { "Switched to \(name)" }
}
