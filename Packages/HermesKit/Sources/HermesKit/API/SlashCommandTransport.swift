import Foundation

/// `slash.exec` params (`contracts/tools_commands.py:303-306`).
public struct SlashExecParams: Encodable, Sendable, Equatable {
    public var sessionId: String
    public var command: String

    public init(sessionId: String, command: String) {
        self.sessionId = sessionId
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", command
    }
}

/// `command.dispatch` params (`contracts/tools_commands.py:279-283`).
public struct CommandDispatchParams: Encodable, Sendable, Equatable {
    public var name: String
    public var arg: String?
    public var sessionId: String?

    public init(name: String, arg: String?, sessionId: String?) {
        self.name = name
        self.arg = arg
        self.sessionId = sessionId
    }

    private enum CodingKeys: String, CodingKey {
        case name, arg, sessionId = "session_id"
    }
}

/// The answer of `slash.exec` and of `command.dispatch` (`contracts/tools_commands.py:286-325`): plain text in
/// `output`, or a directive with `type`. An unknown `type` decodes as plain output.
public struct SlashExecResult: Decodable, Sendable, Equatable {
    public enum Kind: String, Decodable, Sendable {
        case exec, alias, plugin, send, skill, prefill
    }

    public var output: String?
    public var warning: String?
    public var type: Kind?
    public var target: String?
    public var message: String?
    public var notice: String?
    public var display: String?

    public init(output: String? = nil, warning: String? = nil, type: Kind? = nil, target: String? = nil,
                message: String? = nil, notice: String? = nil, display: String? = nil) {
        self.output = output
        self.warning = warning
        self.type = type
        self.target = target
        self.message = message
        self.notice = notice
        self.display = display
    }

    private enum CodingKeys: String, CodingKey {
        case output, warning, type, target, message, notice, display
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        output = try? container.decodeIfPresent(String.self, forKey: .output)
        warning = try? container.decodeIfPresent(String.self, forKey: .warning)
        type = (try? container.decodeIfPresent(String.self, forKey: .type)).flatMap { $0.flatMap(Kind.init(rawValue:)) }
        target = try? container.decodeIfPresent(String.self, forKey: .target)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        notice = try? container.decodeIfPresent(String.self, forKey: .notice)
        display = try? container.decodeIfPresent(String.self, forKey: .display)
    }
}

/// `slash.exec` error: the command is a skill, bundle or plugin. Call `command.dispatch` (protocol 3.11).
public let slashUseDispatchCode = 4018

/// What the slash flow needs from the gateway (issue #67). `GatewayClient` and `LiveChatTransport` conform.
/// A chat transport without it shows "Commands are not available." in a red card.
public protocol SlashCommandTransport: Sendable {
    /// `slash.exec {session_id, command}`.
    func execSlash(sessionId: String, command: String) async throws -> SlashExecResult
    /// `command.dispatch {name, arg, session_id}`.
    func dispatchCommand(sessionId: String, name: String, arg: String?) async throws -> SlashExecResult
    /// `session.usage {session_id}`.
    func sessionUsage(sessionId: String) async throws -> SessionUsage
}

extension GatewayClient: SlashCommandTransport {
    public func execSlash(sessionId: String, command: String) async throws -> SlashExecResult {
        try await call("slash.exec", params: SlashExecParams(sessionId: sessionId, command: command))
    }

    public func dispatchCommand(sessionId: String, name: String, arg: String?) async throws -> SlashExecResult {
        try await call("command.dispatch", params: CommandDispatchParams(name: name, arg: arg, sessionId: sessionId))
    }

    public func sessionUsage(sessionId: String) async throws -> SessionUsage {
        try await call("session.usage", params: SessionIdParams(sessionId: sessionId))
    }
}

extension LiveChatTransport: SlashCommandTransport {
    public func execSlash(sessionId: String, command: String) async throws -> SlashExecResult {
        try await readyClient().execSlash(sessionId: sessionId, command: command)
    }

    public func dispatchCommand(sessionId: String, name: String, arg: String?) async throws -> SlashExecResult {
        try await readyClient().dispatchCommand(sessionId: sessionId, name: name, arg: arg)
    }

    public func sessionUsage(sessionId: String) async throws -> SessionUsage {
        try await readyClient().sessionUsage(sessionId: sessionId)
    }
}
