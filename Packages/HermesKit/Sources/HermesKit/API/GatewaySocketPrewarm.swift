import Foundation

/// Issue #181: opens the gateway socket of a new endpoint while `ServeBootstrap` runs the ownership check.
///
/// - `ServeBootstrap` calls `open(_:)` just before the ownership check, and `discard(_:)` when the check fails.
/// - `PrewarmedGatewayConnector` takes the socket for the same URL. The socket gets no frame from the app before
///   that, because the app gives the endpoint to the chat link only after the ownership check passed.
/// - A socket that nobody takes in `lifetime` closes.
/// - The URL holds the token. This type keeps it in memory only and never logs it.
public final class GatewaySocketPrewarm: @unchecked Sendable {
    /// The prewarm of the app. `ServeBootstrap(socketPrewarm: .shared)` fills it. `PrewarmedGatewayConnector` reads it.
    public static let shared = GatewaySocketPrewarm()

    private struct Entry {
        var id: Int
        var socket: Task<(any GatewayWebSocket)?, Never>
        var expiry: Task<Void, Never>
    }

    private let lock = NSLock()
    private let connector: any GatewayWebSocketConnecting
    private let lifetime: Duration
    private var entries: [URL: Entry] = [:]
    private var nextID = 0

    public init(connector: any GatewayWebSocketConnecting = URLSessionGatewayConnector(),
                lifetime: Duration = .seconds(10)) {
        self.connector = connector
        self.lifetime = lifetime
    }

    /// The number of sockets that wait for a client. For tests.
    var waitingCount: Int { lock.withLock { entries.count } }

    /// Start to open a socket to `url`. An older socket to the same URL closes.
    public func open(_ url: URL) {
        let connector = connector
        let lifetime = lifetime
        let socket = Task { () -> (any GatewayWebSocket)? in try? await connector.connect(to: url) }
        let old = lock.withLock { () -> Entry? in
            nextID += 1
            let id = nextID
            let expiry = Task { [weak self] in
                try? await Task.sleep(for: lifetime)
                guard !Task.isCancelled else { return }
                self?.expire(url, id: id)
            }
            defer { entries[url] = Entry(id: id, socket: socket, expiry: expiry) }
            return entries[url]
        }
        if let old { Self.close(old) }
    }

    /// Close the socket to `url`, if one waits.
    public func discard(_ url: URL) {
        if let entry = lock.withLock({ entries.removeValue(forKey: url) }) { Self.close(entry) }
    }

    /// The socket to `url`, or nil when none waits. The caller owns it after this call.
    public func take(_ url: URL) async -> (any GatewayWebSocket)? {
        guard let entry = lock.withLock({ entries.removeValue(forKey: url) }) else { return nil }
        entry.expiry.cancel()
        return await entry.socket.value
    }

    private func expire(_ url: URL, id: Int) {
        let entry = lock.withLock { () -> Entry? in
            guard entries[url]?.id == id else { return nil }
            return entries.removeValue(forKey: url)
        }
        if let entry { Self.close(entry) }
    }

    private static func close(_ entry: Entry) {
        entry.expiry.cancel()
        Task { await entry.socket.value?.close(code: 1000) }
    }
}

/// Issue #181: the gateway connector of the app. It gives the socket that `GatewaySocketPrewarm` opened for the
/// same URL. Else it opens a new socket with `fallback`.
public struct PrewarmedGatewayConnector: GatewayWebSocketConnecting {
    private let prewarm: GatewaySocketPrewarm
    private let fallback: any GatewayWebSocketConnecting

    public init(prewarm: GatewaySocketPrewarm = .shared,
                fallback: any GatewayWebSocketConnecting = URLSessionGatewayConnector()) {
        self.prewarm = prewarm
        self.fallback = fallback
    }

    public func connect(to url: URL) async throws -> any GatewayWebSocket {
        if let socket = await prewarm.take(url) { return socket }
        return try await fallback.connect(to: url)
    }
}
