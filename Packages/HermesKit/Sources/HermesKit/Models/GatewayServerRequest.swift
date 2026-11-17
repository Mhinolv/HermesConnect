import Foundation

/// A JSON-RPC id. The server sends string ids on its requests (docs/hermes-protocol.md 3.1).
public enum JSONRPCID: Hashable, Sendable, Codable, CustomStringConvertible {
    case int(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case .int(let value): String(value)
        case .string(let value): value
        }
    }
}

/// `ApprovalChoice` (`tui_gateway/contracts/server_requests.py:165-169`).
public enum ApprovalChoice: String, Sendable, Codable, CaseIterable {
    case once, session, always, deny
}

/// `approval` request params (`contracts/server_requests.py:172-187`). The server redacts `command`.
public struct ApprovalRequest: Decodable, Sendable, Equatable {
    public var sessionId: String
    public var requestId: String
    public var command: String
    public var description: String
    /// Choices that the server offers. Unknown values are dropped.
    public var choices: [ApprovalChoice]
    public var allowSession: Bool?
    public var allowPermanent: Bool?
    public var toolName: String?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", requestId = "request_id", command, description, choices
        case allowSession = "allow_session", allowPermanent = "allow_permanent", toolName = "tool_name"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        requestId = try container.decode(String.self, forKey: .requestId)
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        let raw = try container.decodeIfPresent([String].self, forKey: .choices) ?? []
        choices = raw.compactMap(ApprovalChoice.init(rawValue:))
        allowSession = try container.decodeIfPresent(Bool.self, forKey: .allowSession)
        allowPermanent = try container.decodeIfPresent(Bool.self, forKey: .allowPermanent)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
    }
}

/// The answer to an `approval` request (`contracts/server_requests.py:190-192`).
public struct ApprovalAnswer: Encodable, Sendable, Equatable {
    public var choice: ApprovalChoice
    /// `true` resolves every pending approval of the session.
    public var all: Bool?

    public init(choice: ApprovalChoice, all: Bool? = nil) {
        self.choice = choice
        self.all = all
    }
}

/// A server-to-client request: a frame with an `id` and a `method` that is not `event`.
/// Answer it on the same id with `GatewayClient.respond(to:result:)` or `reject(_:code:message:)`.
public struct GatewayServerRequest: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case approval(ApprovalRequest)
        /// `clarify`, `sudo` and `secret`: the app answers them with the raw params (#6 and later).
        case clarify, sudo, secret
    }

    /// Methods that this client handles. The client answers other methods with `-32601` at once
    /// (docs/hermes-protocol.md 3.11, "any other").
    public static let supportedMethods: Set<String> = ["approval", "clarify", "sudo", "secret"]

    public var id: JSONRPCID
    public var method: String
    public var sessionId: String?
    public var params: JSONValue
    public var kind: Kind

    public init(id: JSONRPCID, method: String, params: JSONValue) throws {
        self.id = id
        self.method = method
        self.params = params
        self.sessionId = params["session_id"]?.stringValue
        switch method {
        case "approval":
            let data = try JSONEncoder().encode(params)
            kind = .approval(try JSONDecoder().decode(ApprovalRequest.self, from: data))
        case "clarify": kind = .clarify
        case "sudo": kind = .sudo
        case "secret": kind = .secret
        default: throw GatewayError.unsupportedServerRequest(method)
        }
    }
}
