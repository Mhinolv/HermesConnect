import Foundation

/// One inbound WebSocket message.
public enum GatewayWebSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// The socket closed or failed. `closeCode` is the WebSocket close code (4401 bad credential,
/// 4403 not allowed: `web_routers/chat_ws.py:102-113`). `httpStatus` is the upgrade response status.
/// No field holds the URL, because the URL holds the token.
public struct GatewayWebSocketClosed: Error, Sendable, Equatable {
    public var closeCode: Int?
    public var httpStatus: Int?
    public var urlErrorCode: Int?

    public init(closeCode: Int? = nil, httpStatus: Int? = nil, urlErrorCode: Int? = nil) {
        self.closeCode = closeCode
        self.httpStatus = httpStatus
        self.urlErrorCode = urlErrorCode
    }
}

/// An open text WebSocket. Tests use a fake. The app uses `URLSessionGatewayWebSocket`.
public protocol GatewayWebSocket: Sendable {
    func send(_ text: String) async throws
    /// Waits for the next message. Throws `GatewayWebSocketClosed` when the socket ends.
    func receive() async throws -> GatewayWebSocketMessage
    func close(code: Int)
}

/// Opens a `GatewayWebSocket` to a URL.
public protocol GatewayWebSocketConnecting: Sendable {
    func connect(to url: URL) async throws -> any GatewayWebSocket
}

/// `URLSessionWebSocketTask` transport. It sends no `Origin` header, as the server wants
/// (docs/hermes-protocol.md 2.2).
public struct URLSessionGatewayConnector: GatewayWebSocketConnecting {
    /// Big enough for a `session.resume` snapshot with history. The server cap is 384 MiB
    /// (`web_server_boundary.py:24-26`). The URLSession default is 1 MiB.
    public static let maximumMessageSize = 64 * 1024 * 1024

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(to url: URL) async throws -> any GatewayWebSocket {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        task.resume()
        return URLSessionGatewayWebSocket(task: task)
    }
}

final class URLSessionGatewayWebSocket: GatewayWebSocket, @unchecked Sendable {
    // URLSessionWebSocketTask is thread-safe. The class only forwards calls to it.
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw closedError(for: error)
        }
    }

    func receive() async throws -> GatewayWebSocketMessage {
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .data(data)
            @unknown default: return .data(Data())
            }
        } catch {
            throw closedError(for: error)
        }
    }

    func close(code: Int) {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
    }

    /// Keeps only the codes. A `URLError` holds the failing URL, which holds the token.
    private func closedError(for error: any Error) -> GatewayWebSocketClosed {
        let code = task.closeCode
        return GatewayWebSocketClosed(
            closeCode: code == .invalid ? nil : code.rawValue,
            httpStatus: (task.response as? HTTPURLResponse)?.statusCode,
            urlErrorCode: (error as? URLError)?.code.rawValue)
    }
}
