import Foundation

/// The local end of the SSH forward to `hermes serve`, plus the session token.
/// #4 makes it from the forwarded port. Tests make it from a fake port.
/// `description` hides the token, so a print or a log line cannot leak it.
public struct GatewayEndpoint: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let baseURL: URL
    let token: String

    /// - Parameters:
    ///   - baseURL: `http://127.0.0.1:<local port>`. Only loopback hosts are accepted, because the
    ///     WebSocket is plain `ws://` and the token goes in its query.
    ///   - token: The 64-hex session token of the spawn (docs/hermes-protocol.md 1.6).
    public init(baseURL: URL, token: String) throws {
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = baseURL.host(percentEncoded: false)?.lowercased(),
              Self.loopbackHosts.contains(host) else {
            throw GatewayError.invalidEndpoint
        }
        guard !token.isEmpty, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw GatewayError.invalidEndpoint
        }
        self.baseURL = baseURL
        self.token = token
    }

    public init(port: Int, token: String) throws {
        guard (1...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw GatewayError.invalidEndpoint
        }
        try self.init(baseURL: url, token: token)
    }

    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// `ws://127.0.0.1:<port>/api/ws?token=<token>` (`apps/desktop/electron/connection-config.ts:91-97`).
    public var webSocketURL: URL { webSocketURL(path: "/api/ws") }

    /// Issue #97: the audio sockets use the same `?token=` as `/api/ws` (`web_server_chat.py:352-363`).
    /// `ws://127.0.0.1:<port>/api/audio/speak-stream?token=<token>`.
    public var speakStreamURL: URL { webSocketURL(path: "/api/audio/speak-stream") }

    func webSocketURL(path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = path
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url!
    }

    public var description: String { "GatewayEndpoint(\(baseURL.absoluteString), token: <redacted>)" }
    public var debugDescription: String { description }
}
