import Foundation
import Observation

/// Issue #68: one command of the suggestion catalog: `commands.catalog` merged with `SlashCommandCatalog.local`.
/// Names and aliases have no slash and keep the server case.
public struct SlashCatalogEntry: Codable, Sendable, Equatable {
    public var name: String
    public var aliases: [String]
    public var summary: String

    public init(name: String, aliases: [String] = [], summary: String = "") {
        self.name = name
        self.aliases = aliases
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey { case name, aliases, summary }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        guard !name.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "empty name")
        }
        aliases = (try? container.decodeIfPresent([String].self, forKey: .aliases)) ?? []
        summary = (try? container.decodeIfPresent(String.self, forKey: .summary)) ?? ""
    }
}

/// Issue #68: one row of the suggestion panel.
public struct SlashSuggestion: Sendable, Equatable, Identifiable {
    /// The text that a tap puts in the composer from `replaceFrom`: `/model`, or an argument (`gpt-5`).
    public let text: String
    /// The row title: `/model`.
    public let title: String
    /// The description, or empty.
    public let detail: String

    public var id: String { text }

    public init(text: String, title: String, detail: String) {
        self.text = text
        self.title = title
        self.detail = detail
    }

    /// The VoiceOver label: "/model, Switch the model".
    public var accessibilityLabel: String { detail.isEmpty ? title : "\(title), \(detail)" }
}

/// Issue #68: what the panel above the composer shows.
public enum SlashPanelState: Sendable, Equatable {
    case hidden
    /// No catalog yet and no local match: one row with a spinner, "Loading commands…".
    case loading
    /// One row that is not tappable: "No matching commands".
    case noMatch
    /// `replaceFrom` is the column (Unicode scalars) that a tap replaces from.
    case rows([SlashSuggestion], replaceFrom: Int)

    public var isShown: Bool { self != .hidden }

    public var rows: [SlashSuggestion] {
        if case .rows(let rows, _) = self { return rows }
        return []
    }

    public static let loadingText = "Loading commands…"
    public static let noMatchText = "No matching commands"
}

/// Issue #68: the pure rules of the suggestions. No state.
public enum SlashSuggestionFilter {
    /// Local rows stop here. A bare `/` lists the whole catalog, and the server ranks its own list.
    public static let maxLocalRows = 50

    /// The catalog of `commands.catalog`. `canon` gives the aliases. Rows with no name are dropped, and the first
    /// row of a name wins.
    public static func entries(from result: CommandsCatalogResult) -> [SlashCatalogEntry] {
        var aliases: [String: [String]] = [:]
        for (alias, command) in result.canon.sorted(by: { $0.key < $1.key }) {
            let alias = bare(alias)
            let command = bare(command)
            guard !alias.isEmpty, alias.lowercased() != command.lowercased() else { continue }
            aliases[command.lowercased(), default: []].append(alias)
        }
        var seen: Set<String> = []
        var entries: [SlashCatalogEntry] = []
        for pair in result.pairs {
            let name = bare(pair[0])
            guard !name.isEmpty, !name.contains(where: \.isWhitespace), seen.insert(name.lowercased()).inserted
            else { continue }
            let summary = pair.count > 1 ? pair[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            entries.append(SlashCatalogEntry(name: name, aliases: aliases[name.lowercased()] ?? [], summary: summary))
        }
        return entries
    }

    /// The server catalog with the local commands of #67. A local command wins over a server row of the same
    /// name or alias. Local commands come first.
    public static func merged(server: [SlashCatalogEntry],
                              local: [SlashCommandCatalog.Entry] = SlashCommandCatalog.local) -> [SlashCatalogEntry] {
        let localEntries = local.map { SlashCatalogEntry(name: $0.name, aliases: $0.aliases, summary: $0.summary) }
        let taken = Set(localEntries.flatMap { [$0.name] + $0.aliases }.map { $0.lowercased() })
        return localEntries + server.filter { !taken.contains($0.name.lowercased()) }
    }

    /// The command token after `/` while the owner types it: `/mo` gives `mo`. `nil` when the panel hides
    /// (no `/` first, or a newline) or when the text is past the command (`/model gpt`).
    public static func commandQuery(_ text: String) -> String? {
        guard showsPanel(for: text) else { return nil }
        let token = text.dropFirst()
        guard !token.contains(where: \.isWhitespace) else { return nil }
        return String(token)
    }

    /// The panel can show: the text starts with `/` and has no newline.
    public static func showsPanel(for text: String) -> Bool {
        text.hasPrefix("/") && !text.contains(where: \.isNewline)
    }

    /// The local rows for `query`: names, then aliases, that start with it, then names and aliases that
    /// contain it. Catalog order inside each group. A match on an alias shows the command.
    public static func rows(for query: String, in entries: [SlashCatalogEntry],
                            limit: Int = maxLocalRows) -> [SlashSuggestion] {
        let query = query.lowercased()
        func rank(_ entry: SlashCatalogEntry) -> Int? {
            let name = entry.name.lowercased()
            let aliases = entry.aliases.map { $0.lowercased() }
            if query.isEmpty || name.hasPrefix(query) { return 0 }
            if aliases.contains(where: { $0.hasPrefix(query) }) { return 1 }
            if name.contains(query) || aliases.contains(where: { $0.contains(query) }) { return 2 }
            return nil
        }
        let ranked = entries.enumerated().compactMap { index, entry in rank(entry).map { ($0, index, entry) } }
        return ranked.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(limit).map { _, _, entry in
            SlashSuggestion(text: "/" + entry.name, title: "/" + entry.name, detail: entry.summary)
        }
    }

    /// The rows of a `complete.slash` answer, in server order. An empty `meta` takes the catalog description.
    public static func rows(for result: SlashCompletionResult, catalog: [SlashCatalogEntry]) -> [SlashSuggestion] {
        var seen: Set<String> = []
        return result.items.compactMap { item in
            guard !item.text.isEmpty, seen.insert(item.text).inserted else { return nil }
            let title = item.display.isEmpty ? item.text : item.display
            var detail = item.meta.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty, item.text.hasPrefix("/") {
                let name = bare(item.text).lowercased()
                let entry = catalog.first { entry in
                    entry.name.lowercased() == name || entry.aliases.contains { $0.lowercased() == name }
                }
                detail = entry?.summary ?? ""
            }
            return SlashSuggestion(text: item.text, title: title, detail: detail)
        }
    }

    /// The composer text after a tap: the text before `replaceFrom`, then the row text, then one space.
    /// A command row (`/model`) replaces the whole command token, also when the server says column 1.
    public static func apply(_ suggestion: SlashSuggestion, to text: String, replaceFrom: Int) -> String {
        let scalars = text.unicodeScalars
        var from = max(0, min(replaceFrom, scalars.count))
        if suggestion.text.hasPrefix("/"), from <= 1 { from = 0 }
        let head = String(String.UnicodeScalarView(scalars.prefix(from)))
        return head + suggestion.text + " "
    }

    /// The command name with no leading slash and no outer white space.
    static func bare(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "/" })
    }
}

/// Issue #68: the slash suggestions above the composer. One model for the app: it keeps the catalog of the
/// connected server. The chat screen calls `update(text:)` on each change of the composer text.
///
/// - The catalog loads on connect and on `skills.changed`, and goes to the cache of the server.
/// - Each key filters the catalog at once. After `debounce` with no key, `complete.slash` replaces the rows.
/// - Offline: the cached catalog, no server call. No cache: the local commands only.
/// - The names in the log are counts only. Composer text never goes to the log.
@MainActor @Observable
public final class SlashSuggestionModel {
    public private(set) var state: SlashPanelState = .hidden
    /// `true` after the first catalog of this server (from the cache or the server).
    public private(set) var hasCatalog = false

    @ObservationIgnored private let transport: (any SlashCompletionTransport)?
    @ObservationIgnored private let cache: any SlashCatalogCacheStore
    @ObservationIgnored private let serverKey: @MainActor () -> String?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var catalog: [SlashCatalogEntry] = SlashSuggestionFilter.merged(server: [])
    /// The server key of `catalog`. A new key loads that server's cache.
    @ObservationIgnored private var loadedServer: String?
    @ObservationIgnored private var isConnected = false
    @ObservationIgnored private var text = ""
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var completeTask: Task<Void, Never>?
    @ObservationIgnored private let log = HermesLog(category: "slash")

    /// `transport` `nil`: local commands only (previews). `serverKey` names the server of the cache.
    public init(transport: (any SlashCompletionTransport)?, cache: any SlashCatalogCacheStore,
                serverKey: @escaping @MainActor () -> String?, debounce: Duration = .milliseconds(150)) {
        self.transport = transport
        self.cache = cache
        self.serverKey = serverKey
        self.debounce = debounce
        loadCachedCatalog()
    }

    /// Reads the events: a connect and `skills.changed` load the catalog. Safe to call more than once.
    public func start() {
        guard eventTask == nil, let transport else { return }
        let stream = transport.events
        eventTask = Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                self.handle(item)
            }
        }
    }

    func handle(_ item: GatewayClientEvent) {
        switch item {
        case .state(.connected):
            isConnected = true
            loadCatalog()
        case .state(.disconnected), .state(.idle), .state(.connecting):
            isConnected = false
        case .event(let event) where event.type == "skills.changed":
            loadCatalog()
        default:
            break
        }
    }

    /// `commands.catalog`. A failure keeps the catalog that shows.
    public func loadCatalog() {
        guard let transport else { return }
        catalogTask?.cancel()
        catalogTask = Task { [weak self] in
            do {
                let result = try await transport.commandsCatalog()
                guard !Task.isCancelled else { return }
                self?.catalogLoaded(SlashSuggestionFilter.entries(from: result))
            } catch {
                self?.log.notice("commands.catalog failed")
            }
        }
    }

    private func catalogLoaded(_ entries: [SlashCatalogEntry]) {
        let server = serverKey()
        if let server { cache.save(entries, server: server) }
        loadedServer = server
        catalog = SlashSuggestionFilter.merged(server: entries)
        hasCatalog = true
        log.info("commands.catalog: \(entries.count) commands")
        refilter()
    }

    private func loadCachedCatalog() {
        let server = serverKey()
        loadedServer = server
        guard let server, let entries = cache.load(server: server) else {
            catalog = SlashSuggestionFilter.merged(server: [])
            hasCatalog = false
            return
        }
        catalog = SlashSuggestionFilter.merged(server: entries)
        hasCatalog = true
    }

    /// The composer text changed. Filters the catalog at once and plans the `complete.slash` call.
    public func update(text newText: String) {
        if serverKey() != loadedServer { loadCachedCatalog() }
        text = newText
        completeTask?.cancel()
        completeTask = nil
        guard SlashSuggestionFilter.showsPanel(for: newText) else {
            state = .hidden
            return
        }
        refilter()
        guard isConnected, let transport else {
            // Offline: no server call. An argument has no local rows.
            if SlashSuggestionFilter.commandQuery(newText) == nil { state = .hidden }
            return
        }
        let debounce = self.debounce
        completeTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            do {
                let result = try await transport.completeSlash(text: newText)
                guard !Task.isCancelled else { return }
                self?.completed(result, for: newText)
            } catch {
                guard !Task.isCancelled else { return }
                self?.completeFailed(for: newText)
            }
        }
    }

    /// Hides the panel: the keyboard hid, the owner sent, or a memo records. The next `update` shows it again.
    public func hide() {
        completeTask?.cancel()
        completeTask = nil
        state = .hidden
    }

    /// The composer text after a tap on `suggestion`. Nothing is sent.
    public func accept(_ suggestion: SlashSuggestion, in text: String) -> String {
        guard case .rows(_, let replaceFrom) = state else {
            return SlashSuggestionFilter.apply(suggestion, to: text, replaceFrom: 0)
        }
        return SlashSuggestionFilter.apply(suggestion, to: text, replaceFrom: replaceFrom)
    }

    /// The local rows for the current text. Past the command token, the rows that show stay until the server
    /// answers.
    private func refilter() {
        guard SlashSuggestionFilter.showsPanel(for: text) else { return }
        guard let query = SlashSuggestionFilter.commandQuery(text) else {
            if case .rows = state { return }
            state = .hidden
            return
        }
        let rows = SlashSuggestionFilter.rows(for: query, in: catalog)
        if !rows.isEmpty {
            state = .rows(rows, replaceFrom: 0)
        } else if !hasCatalog, isConnected {
            state = .loading
        } else {
            state = .noMatch
        }
    }

    private func completed(_ result: SlashCompletionResult, for sent: String) {
        guard sent == text else { return }
        let rows = SlashSuggestionFilter.rows(for: result, catalog: catalog)
        let isCommand = SlashSuggestionFilter.commandQuery(sent) != nil
        if rows.isEmpty {
            // After a space, no items: the panel hides. A command with no match says so.
            state = isCommand ? .noMatch : .hidden
            return
        }
        state = .rows(rows, replaceFrom: result.replaceFrom ?? 1)
    }

    /// The server call failed: the local rows stay. An argument has none, so the panel hides.
    private func completeFailed(for sent: String) {
        guard sent == text else { return }
        log.notice("complete.slash failed")
        if SlashSuggestionFilter.commandQuery(sent) == nil {
            state = .hidden
        } else if state == .loading {
            state = .noMatch
        }
    }
}
