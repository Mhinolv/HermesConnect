import Foundation

/// Why a gateway connection ended. #15 reads it to pick the reconnect policy.
public enum GatewayDisconnectReason: Sendable, Equatable {
    /// The app called `disconnect()`.
    case clientClosed
    /// HTTP 401 or close code 4401: the token is not valid. The server restarted, so run #4 again.
    case unauthorized
    /// HTTP 403 or close code 4403: chat is disabled, or the request is not allowed.
    case forbidden
    /// Too many unanswered heartbeats, or no inbound frame for the silence deadline (45 s).
    case heartbeatTimeout
    /// The socket opened, but `gateway.ready` did not come in time.
    case readyTimeout
    /// The socket closed with this close code (`nil` when unknown).
    case closed(code: Int?)
    /// The transport failed (`URLError` code when known). No text, because it can hold the URL.
    case transportFailed(code: Int?)

    /// `true` when the token can be stale, so #4 runs again with a new token ("Starting Hermes…").
    /// 4401/401 and 4403/403 both count: uvicorn can refuse a stale token with HTTP 403 before
    /// the accept (QA follow-up of PR #23).
    public var needsNewToken: Bool { self == .unauthorized || self == .forbidden }

    /// `true` when a reconnect with the same token can work (#15 owns the policy).
    public var shouldReconnect: Bool {
        switch self {
        case .clientClosed, .unauthorized, .forbidden: false
        case .heartbeatTimeout, .readyTimeout, .closed, .transportFailed: true
        }
    }

    init(_ closed: GatewayWebSocketClosed) {
        if closed.closeCode == 4401 || closed.httpStatus == 401 {
            self = .unauthorized
        } else if closed.closeCode == 4403 || closed.httpStatus == 403 {
            self = .forbidden
        } else if let code = closed.closeCode {
            self = .closed(code: code)
        } else {
            self = .transportFailed(code: closed.urlErrorCode)
        }
    }
}

/// The state of the gateway connection. The #3 subtitle reads it.
public enum GatewayConnectionState: Sendable, Equatable {
    case idle
    /// The socket is open and the client waits for `gateway.ready` ("Connecting…").
    case connecting
    /// `gateway.ready` came in and `client.capabilities` is sent ("Connected").
    case connected(GatewayReady)
    /// The connection ended. #15 decides about the reconnect.
    case disconnected(GatewayDisconnectReason)
}

/// One item of `GatewayClient.events`.
public enum GatewayClientEvent: Sendable, Equatable {
    case state(GatewayConnectionState)
    case event(GatewayEvent)
    case serverRequest(GatewayServerRequest)
}

public enum GatewayError: Error, Sendable, Equatable {
    case invalidEndpoint
    case notConnected
    case alreadyConnected
    case disconnected(GatewayDisconnectReason)
    case timeout(method: String)
    /// A JSON-RPC error answer. `message` is server text (docs/hermes-protocol.md 3.1).
    case rpc(code: Int, message: String)
    case invalidResponse(method: String)
    case unsupportedServerRequest(String)
}

/// The keepalive method. `gateway.ping` answers `{"ok":true}` on the WS reader (`tui_gateway/ws.py:708-712`).
/// Legacy `ping` answers `{"pong":true}` (`tui_gateway/methods_voice.py:544-548`).
public enum GatewayHeartbeatMethod: String, Sendable {
    case gatewayPing = "gateway.ping"
    case legacyPing = "ping"
}
