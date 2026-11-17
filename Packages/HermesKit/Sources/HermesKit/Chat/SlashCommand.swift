import Foundation

/// Issue #67: a slash command that the owner typed (docs/hermes-protocol.md 3.11).
///
/// The rule is the one of the desktop client (`apps/shared/src/slash.ts`): `/` at position 0, a name with no
/// second `/`, then white space or the end. `/usr/local` and `run /clean` are prose, not commands.
public struct SlashCommand: Sendable, Equatable {
    /// The text as the owner typed it, trimmed.
    public let text: String
    /// The name in lower case, with no slash. Empty for a bare `/`.
    public let name: String
    /// The argument with the outer white space removed. The inner text stays as it is.
    public let arg: String

    /// `nil` when the text is not a slash command.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.drop { $0 == "/" }
        let nameEnd = body.firstIndex(where: \.isWhitespace) ?? body.endIndex
        let name = body[..<nameEnd]
        // A second slash in the first word (`/usr/local`) is a path, not a command.
        guard !trimmed.dropFirst().prefix(while: { !$0.isWhitespace }).contains("/") else { return nil }
        text = trimmed
        self.name = name.lowercased()
        arg = body[nameEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The command as the cards show it: `/usage`.
    public var display: String { "/" + name }
}

/// Issue #67: the commands that the app runs itself, not on the server. Issue #68 (suggestions while the owner
/// types) reads `SlashCommandCatalog.local` and merges it with the server `commands.catalog`.
public enum SlashCommandCatalog {
    public enum Action: Sendable, Equatable {
        /// Push a new chat. The server `/new` would only reset the slash worker.
        case newChat
        /// `session.usage` for this session.
        case usage
    }

    public struct Entry: Sendable, Equatable {
        public let name: String
        public let aliases: [String]
        public let summary: String
        public let action: Action
    }

    /// The local commands. The desktop client handles the same names on the client side.
    public static let local: [Entry] = [
        Entry(name: "new", aliases: ["reset", "clear"], summary: "Start a new chat", action: .newChat),
        Entry(name: "usage", aliases: [], summary: "Show the token usage of this chat", action: .usage),
    ]

    /// The local action for `name`, or `nil` when the server runs the command.
    public static func localAction(for name: String) -> Action? {
        local.first { $0.name == name || $0.aliases.contains(name) }?.action
    }
}

/// What the app does with the answer of `slash.exec` or `command.dispatch` (`tools_commands.py:267-325`).
public enum SlashOutcome: Sendable, Equatable {
    /// `exec`, `plugin`, or plain worker text: a command card. `warning` comes first when the server sent one.
    case output(String)
    /// `send` or `skill`: `prompt.submit` with `message`. The owner bubble shows `display`.
    case send(message: String, display: String?, notice: String?)
    /// `prefill`: put `message` in the composer. Nothing is sent.
    case prefill(message: String, notice: String?)
    /// `alias`: run `/target` with the same argument.
    case alias(target: String)

    /// `nil` for a result that is not valid (for example `send` with no `message`).
    public init?(_ result: SlashExecResult) {
        switch result.type {
        case nil, .exec?, .plugin?:
            let body = result.output.flatMap { $0.isEmpty ? nil : $0 } ?? "(no output)"
            if let warning = result.warning, !warning.isEmpty {
                self = .output("warning: \(warning)\n\(body)")
            } else {
                self = .output(body)
            }
        case .send?:
            guard let message = result.message else { return nil }
            self = .send(message: message, display: result.display, notice: result.notice)
        case .skill?:
            guard let message = result.message, !message.isEmpty else { return nil }
            self = .send(message: message, display: result.display, notice: result.notice)
        case .prefill?:
            guard let message = result.message else { return nil }
            self = .prefill(message: message, notice: result.notice)
        case .alias?:
            guard let target = result.target, !target.isEmpty else { return nil }
            self = .alias(target: target)
        }
    }
}

/// `session.usage` (`methods_session.py:1443-1451`): `{calls, input, output, total, credits_lines?}`.
public struct SessionUsage: Decodable, Sendable, Equatable {
    public var calls: Int
    public var input: Int
    public var output: Int
    public var total: Int
    public var creditsLines: [String]

    public init(calls: Int = 0, input: Int = 0, output: Int = 0, total: Int = 0, creditsLines: [String] = []) {
        self.calls = calls
        self.input = input
        self.output = output
        self.total = total
        self.creditsLines = creditsLines
    }

    private enum CodingKeys: String, CodingKey {
        case calls, input, output, total, creditsLines = "credits_lines"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        calls = Self.number(container, .calls)
        input = Self.number(container, .input)
        output = Self.number(container, .output)
        total = Self.number(container, .total)
        creditsLines = ((try? container.decodeIfPresent([String].self, forKey: .creditsLines)) ?? nil) ?? []
    }

    /// The server can send a count as an integer or as a float. A missing or bad field is 0.
    private static func number(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key), value.isFinite { return Int(value) }
        return 0
    }

    /// The text of the command card, as the desktop shows it
    /// (`use-prompt-actions/utils.ts`): "Usage: 3 calls · 1,200 in / 340 out · 1,540 total".
    public func text(locale: Locale = .current) -> String {
        let style = IntegerFormatStyle<Int>(locale: locale)
        let calls = calls.formatted(style)
        var lines = ["Usage: \(calls) \(self.calls == 1 ? "call" : "calls") · \(input.formatted(style)) in / "
            + "\(output.formatted(style)) out · \(total.formatted(style)) total"]
        lines += creditsLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}

/// Issue #67: the text of a command card.
public enum SlashOutputText {
    /// Removes the ANSI color codes of the slash worker (desktop `index.ts` strips them too) and trims.
    public static func clean(_ text: String) -> String {
        text.replacing(/\u{1B}\[[0-9;?]*[ -\/]*[@-~]/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The slash worker answers an unknown command with plain output ("Unknown command: /foo"), not an error.
    public static func isUnknownCommand(_ text: String) -> Bool {
        text.lowercased().hasPrefix("unknown command")
    }
}

/// Issue #67: the local card of a command. It shows the output or the error of a command. It never goes to
/// Hermes and the cache does not keep it.
public struct ChatCommandCard: Sendable, Equatable {
    /// The command as the owner typed it, for the card header: `/usage`.
    public var command: String
    public var output: String
    /// A red card with `exclamationmark.triangle`: an unknown command or a server error.
    public var isError: Bool

    public init(command: String, output: String, isError: Bool = false) {
        self.command = command
        self.output = output
        self.isError = isError
    }
}

/// Issue #67: the text that the composer gets from the chat model. A new `id` each time, so the same text
/// twice still reaches the composer.
public struct ComposerFill: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// A `prefill` result: the text replaces the composer text.
        case prefill
        /// A command failed: the typed text goes back into an empty composer.
        case restore
    }

    public let id: String
    public let text: String
    public let reason: Reason
}

/// Issue #67: `/new` asks the screen to push a new chat. Each request has a new `id`.
public struct NewChatRequest: Sendable, Equatable, Identifiable {
    public let id: String
}
