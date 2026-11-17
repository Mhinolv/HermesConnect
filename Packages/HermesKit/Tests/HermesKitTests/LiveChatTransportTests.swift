import Foundation
import Testing
@testable import HermesKit

private let token = String(repeating: "0f", count: 32)

/// Builds clients on scripted sockets, one socket per endpoint. No network.
private final class ClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [FakeGatewaySocket] = []
    var sockets: [FakeGatewaySocket] { lock.withLock { _sockets } }

    func make(_ endpoint: GatewayEndpoint) -> GatewayClient {
        let socket = FakeGatewaySocket()
        lock.withLock { _sockets.append(socket) }
        return GatewayClient(endpoint: endpoint, connector: FakeGatewayConnector(socket),
                             configuration: .init(heartbeatInterval: nil, readyTimeout: .seconds(5)))
    }

    /// Waits for socket `index`, then does the handshake on it.
    func handshake(_ index: Int) async throws -> FakeGatewaySocket {
        let socket = try await self.socket(index)
        socket.pushReady()
        socket.reply(to: try await socket.waitForRequest("client.capabilities"), result: "{}")
        return socket
    }

    func socket(_ index: Int) async throws -> FakeGatewaySocket {
        for _ in 0..<500 {
            if sockets.count > index { return sockets[index] }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FakeTimeout(what: "socket \(index)")
    }
}

@MainActor
private func waitFor(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw FakeTimeout(what: "condition")
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LiveChatTransportTests {
    private func endpoint(_ port: Int) throws -> GatewayEndpoint { try GatewayEndpoint(port: port, token: token) }

    @Test func noEndpointMeansNotConnected() async throws {
        let transport = LiveChatTransport()
        #expect(transport.status == .notConnected)
        await #expect(throws: GatewayError.notConnected) {
            try await transport.startSession(source: "ios", idempotencyKey: "k")
        }
    }

    @Test func endpointConnectsAndSends() async throws {
        let factory = ClientFactory()
        let transport = LiveChatTransport(makeClient: factory.make)
        transport.setEndpoint(try endpoint(8123))
        #expect(transport.status == .connecting)
        let socket = try await factory.handshake(0)
        try await waitFor { transport.status == .ready }

        async let ref = transport.startSession(source: "ios", idempotencyKey: "k1")
        let create = try await socket.waitForRequest("session.create")
        socket.reply(to: create, result: #"{"session_id":"live1","stored_session_id":"st1","message_count":0,"messages":[]}"#)
        #expect(try await ref == ChatSessionRef(liveId: "live1", storedId: "st1"))

        // The same endpoint again keeps the client.
        transport.setEndpoint(try endpoint(8123))
        #expect(factory.sockets.count == 1)
    }

    @Test func eventsOfTheCurrentClientAreForwarded() async throws {
        let factory = ClientFactory()
        let transport = LiveChatTransport(makeClient: factory.make)
        var iterator = transport.events.makeAsyncIterator()
        transport.setEndpoint(try endpoint(8123))
        let socket = try await factory.handshake(0)
        try await waitFor { transport.status == .ready }
        socket.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"live1","payload":{}}}"#)
        while let item = await iterator.next() {
            if case .event(let event) = item {
                #expect(event.type == "message.start")
                break
            }
        }
    }

    @Test func staleTokenRenewsOnceThenRecovers() async throws {
        let factory = ClientFactory()
        let transport = LiveChatTransport(makeClient: factory.make)
        var renewals = 0
        transport.onStaleToken = { renewals += 1 }
        transport.setEndpoint(try endpoint(8123))
        let first = try await factory.handshake(0)
        try await waitFor { transport.status == .ready }

        first.serverClose(closeCode: 4401)
        try await waitFor { transport.status == .reconnecting }
        try await waitFor { renewals == 1 }

        // #4 closes the old endpoint, then reports the new one.
        transport.setEndpoint(nil)
        #expect(transport.status == .reconnecting)
        transport.setEndpoint(try endpoint(9123))
        _ = try await factory.handshake(1)
        try await waitFor { transport.status == .ready }
        #expect(renewals == 1)
    }

    @Test func secondRefusalAfterRenewalFails() async throws {
        let factory = ClientFactory()
        let transport = LiveChatTransport(makeClient: factory.make)
        var renewals = 0
        transport.onStaleToken = { renewals += 1 }
        transport.setEndpoint(try endpoint(8123))
        (try await factory.socket(0)).serverClose(closeCode: 4403)
        try await waitFor { transport.status == .reconnecting }

        transport.setEndpoint(try endpoint(9123))
        (try await factory.socket(1)).serverClose(closeCode: 4401)
        try await waitFor { transport.status == .failed }
        #expect(renewals == 1)

        transport.retry()
        #expect(transport.status == .reconnecting)
        try await waitFor { renewals == 2 }
    }

    @Test func otherDropsAreNotStale() async throws {
        let factory = ClientFactory()
        let transport = LiveChatTransport(makeClient: factory.make)
        var renewals = 0
        transport.onStaleToken = { renewals += 1 }
        transport.setEndpoint(try endpoint(8123))
        let socket = try await factory.handshake(0)
        try await waitFor { transport.status == .ready }
        socket.serverClose(closeCode: 1011)
        try await waitFor { transport.status == .notConnected }
        #expect(renewals == 0)
    }

    @Test func staleTokenClassification() {
        #expect(LiveChatTransport.isStaleToken(GatewayError.disconnected(.unauthorized)))
        #expect(LiveChatTransport.isStaleToken(GatewayError.disconnected(.forbidden)))
        #expect(LiveChatTransport.isStaleToken(HermesAPIError.http(status: 403)))
        #expect(LiveChatTransport.isStaleToken(HermesAPIError.unauthorized))
        #expect(!LiveChatTransport.isStaleToken(GatewayError.disconnected(.heartbeatTimeout)))
        #expect(!LiveChatTransport.isStaleToken(HermesAPIError.http(status: 500)))
    }
}
