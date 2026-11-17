import Foundation

/// `commands.catalog` params (`contracts/tools_commands.py:203-205`). Issue #68 sends none: the catalog is
/// kept for each server, not for each session.
struct CommandsCatalogParams: Encodable, Sendable, Equatable {}

/// The part of `commands.catalog` that the suggestions use (`contracts/tools_commands.py:230-243`).
/// `pairs` is `[["/model", "Switch the model"], …]`. `canon` maps each lower-case name and alias to its
/// command: `{"/m": "/model"}`. A bad pair is dropped, and a missing key is empty.
public struct CommandsCatalogResult: Decodable, Sendable, Equatable {
    public var pairs: [[String]]
    public var canon: [String: String]

    public init(pairs: [[String]] = [], canon: [String: String] = [:]) {
        self.pairs = pairs
        self.canon = canon
    }

    private enum CodingKeys: String, CodingKey { case pairs, canon }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows: [JSONValue] = (try? container.decodeIfPresent([JSONValue].self, forKey: .pairs)) ?? []
        pairs = rows.compactMap { row in
            guard case .array(let items) = row else { return nil }
            let strings = items.compactMap(\.stringValue)
            return strings.count >= 1 && strings.count == items.count ? strings : nil
        }
        canon = (try? container.decodeIfPresent([String: String].self, forKey: .canon)) ?? [:]
    }
}

/// `complete.slash` params (`contracts/profiles_vault_complete_foreign_subagents.py:50-56`).
struct CompleteSlashParams: Encodable, Sendable, Equatable {
    var text: String
}

/// One row of `complete.slash` (`contracts/profiles_vault_complete_foreign_subagents.py:24-30`).
public struct SlashCompletionItem: Decodable, Sendable, Equatable {
    /// The text to insert: `/model` for a command, or an argument stub (`gpt-5`) after a space.
    public var text: String
    public var display: String
    public var meta: String

    public init(text: String, display: String = "", meta: String = "") {
        self.text = text
        self.display = display
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey { case text, display, meta }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        display = (try? container.decodeIfPresent(String.self, forKey: .display)) ?? ""
        meta = (try? container.decodeIfPresent(String.self, forKey: .meta)) ?? ""
    }
}

/// The answer of `complete.slash`. `replaceFrom` is the column (in Unicode scalars, as in Python) that the
/// chosen item replaces from. A bad item is dropped.
public struct SlashCompletionResult: Decodable, Sendable, Equatable {
    public var items: [SlashCompletionItem]
    public var replaceFrom: Int?

    public init(items: [SlashCompletionItem] = [], replaceFrom: Int? = nil) {
        self.items = items
        self.replaceFrom = replaceFrom
    }

    private enum CodingKeys: String, CodingKey { case items, replaceFrom = "replace_from" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? container.decodeIfPresent(LossyArray<SlashCompletionItem>.self, forKey: .items))?.items ?? []
        replaceFrom = try? container.decodeIfPresent(Int.self, forKey: .replaceFrom)
    }
}

/// Issue #68: what the slash suggestions need from the gateway. `GatewayClient` and `LiveChatTransport` conform.
public protocol SlashCompletionTransport: Sendable {
    /// Connection states and events. The suggestions load the catalog on connect and on `skills.changed`.
    var events: AsyncStream<GatewayClientEvent> { get }
    /// `commands.catalog {}`.
    func commandsCatalog() async throws -> CommandsCatalogResult
    /// `complete.slash {text}`.
    func completeSlash(text: String) async throws -> SlashCompletionResult
}

extension GatewayClient: SlashCompletionTransport {
    public func commandsCatalog() async throws -> CommandsCatalogResult {
        try await call("commands.catalog", params: CommandsCatalogParams())
    }

    public func completeSlash(text: String) async throws -> SlashCompletionResult {
        try await call("complete.slash", params: CompleteSlashParams(text: text))
    }
}

extension LiveChatTransport: SlashCompletionTransport {
    public func commandsCatalog() async throws -> CommandsCatalogResult {
        try await readyClient().commandsCatalog()
    }

    public func completeSlash(text: String) async throws -> SlashCompletionResult {
        try await readyClient().completeSlash(text: text)
    }
}
