import Foundation
import Testing
@testable import HermesKit

/// Answers by URL path. Records each request. No network.
final class FakeHermesHTTP: HTTPDataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (status: Int, body: String)]
    private var _requests: [URLRequest] = []
    /// Called for `/api/ssh/ownership`. Gives the status for the token header.
    var ownershipStatus: (@Sendable (String?) -> Int)?

    static let goodOwnership = #"{"ok":true,"sshOwnerNonce":"0123456789abcdef","protocolVersion":1,"runtimeIntact":true}"#

    init(routes: [String: (status: Int, body: String)] = [
        "/api/health": (200, #"{"ok":true,"version":"0.9"}"#),
        "/api/status": (200, "{}"),
        "/api/ssh/ownership": (200, FakeHermesHTTP.goodOwnership),
    ]) {
        self.routes = routes
    }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var paths: [String] { requests.compactMap { $0.url?.path } }

    func set(_ path: String, status: Int, body: String = "{}") {
        lock.withLock { routes[path] = (status, body) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        var route = lock.withLock { () -> (status: Int, body: String)? in
            _requests.append(request)
            return routes[path]
        }
        if path == "/api/ssh/ownership", let ownershipStatus, var current = route {
            current.status = ownershipStatus(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"))
            route = current
        }
        guard let route else { throw URLError(.cannotConnectToHost) }
        let response = HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: nil)!
        return (Data(route.body.utf8), response)
    }
}

@Suite struct ServeBootstrapTests {
    private let fast = ServeBootstrap.Configuration(serveTimeout: .seconds(5), healthAttempts: 3,
                                                    healthRetryDelay: .milliseconds(1))

    private func session(_ transport: ScriptedSSHTransport) async throws -> any SSHSession {
        try await transport.connect(to: SSHEndpoint(host: "vps.example.com", port: 22, user: "hermes"),
                                    key: SoftwareKeyFactory().makeKeyForTests()) { _ in }
    }

    @Test func freshSpawnGivesAReachableLocalPort() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let http = FakeHermesHTTP()
        let serve = try await ServeBootstrap(loader: http, configuration: fast)
            .start(on: try await session(transport), reuse: nil)

        #expect(transport.record.commands == [.serve])
        #expect(transport.record.spawns == 1)
        #expect(transport.record.forwardPorts == [41_001])
        #expect(serve.endpoint.baseURL.absoluteString == "http://127.0.0.1:\(serve.forward.localPort)")
        #expect(http.paths == ["/api/health", "/api/ssh/ownership"])
        // The token goes on stdin only. It is 64 lowercase hex and has no newline.
        let stdin = try #require(transport.record.stdins.first ?? nil)
        #expect(SessionToken.isValid(stdin))
        #expect(String(decoding: stdin, as: UTF8.self) == serve.token.value)
        // The public health check has no token. The ownership check has it.
        #expect(http.requests[0].value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
        #expect(http.requests[1].value(forHTTPHeaderField: "X-Hermes-Session-Token") == serve.token.value)
    }

    @Test func reuseSendsTheSameTokenAndTheGateKeepsTheServer() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let bootstrap = ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
        let first = try await bootstrap.start(on: try await session(transport), reuse: nil)
        let second = try await bootstrap.start(on: try await session(transport), reuse: first.token)

        #expect(second.token == first.token)
        #expect(transport.record.spawns == 1)
        #expect(transport.record.reuses == 1)
        #expect(transport.record.forwardPorts == [41_001, 41_001])
    }

    @Test func deadServerWithTheSameTokenSpawnsAgain() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let bootstrap = ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
        let first = try await bootstrap.start(on: try await session(transport), reuse: nil)
        transport.serverAlive = false
        _ = try await bootstrap.start(on: try await session(transport), reuse: first.token)
        #expect(transport.record.spawns == 2)
        #expect(transport.record.forwardPorts == [41_001, 41_002])
    }

    @Test(arguments: [401, 403, 404])
    func staleReuseTokenGetsOneNewToken(status: Int) async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let stale = SessionToken(hex: String(repeating: "a", count: 64))!
        let http = FakeHermesHTTP()
        http.ownershipStatus = { $0 == stale.value ? status : 200 }
        let serve = try await ServeBootstrap(loader: http, configuration: fast)
            .start(on: try await session(transport), reuse: stale)

        #expect(serve.token != stale)
        #expect(transport.record.commands == [.serve, .serve])
        #expect(transport.record.spawns == 2)
        #expect(transport.record.closedForwards == 1)
    }

    @Test func refusedNewTokenStops() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let http = FakeHermesHTTP()
        http.set("/api/ssh/ownership", status: 401)
        await #expect(throws: SSHConnectionError.sessionTokenRejected) {
            try await ServeBootstrap(loader: http, configuration: fast).start(on: try await session(transport), reuse: nil)
        }
        #expect(transport.record.commands == [.serve])
        #expect(transport.record.closedForwards == 1)
    }

    @Test func badOwnershipProofIsRejected() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let http = FakeHermesHTTP()
        http.set("/api/ssh/ownership", status: 200, body: #"{"ok":true,"sshOwnerNonce":"x","protocolVersion":1}"#)
        await #expect(throws: SSHConnectionError.sessionTokenRejected) {
            try await ServeBootstrap(loader: http, configuration: fast).start(on: try await session(transport), reuse: nil)
        }
    }

    @Test func healthFallsBackToStatus() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let http = FakeHermesHTTP()
        http.set("/api/health", status: 503)
        _ = try await ServeBootstrap(loader: http, configuration: fast).start(on: try await session(transport), reuse: nil)
        #expect(http.paths == ["/api/health", "/api/status", "/api/ssh/ownership"])
    }

    @Test func noHealthAnswerIsNotReadyAndClosesTheForward() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let http = FakeHermesHTTP(routes: [:])
        await #expect(throws: SSHConnectionError.hermesNotReady) {
            try await ServeBootstrap(loader: http, configuration: fast).start(on: try await session(transport), reuse: nil)
        }
        #expect(http.paths.count == 6)
        #expect(transport.record.closedForwards == 1)
    }

    @Test(arguments: ["hermes-not-found", "update-required", "serve-timeout", "not-allowed"])
    func gateErrorsPassThroughWithNoForward(code: String) async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        transport.serveFailure = .gateError(code)
        await #expect(throws: SSHConnectionError.gateError(code)) {
            try await ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
                .start(on: try await session(transport), reuse: nil)
        }
        #expect(transport.record.forwardPorts.isEmpty)
    }

    @Test func forwardFailureIsReported() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        transport.forwardFailure = .forwardFailed
        await #expect(throws: SSHConnectionError.forwardFailed) {
            try await ServeBootstrap(loader: FakeHermesHTTP(), configuration: fast)
                .start(on: try await session(transport), reuse: nil)
        }
    }

    @Test func slowGateIsNotReady() async throws {
        struct HangingSession: SSHSession {
            func execute(_ command: GateCommand, stdin: Data?) async throws -> String {
                try await Task.sleep(for: .seconds(30))
                return "PORT 1"
            }
            func openLoopbackForward(remotePort: Int) async throws -> any LoopbackForward {
                throw SSHConnectionError.forwardFailed
            }
            func close() async {}
        }
        let config = ServeBootstrap.Configuration(serveTimeout: .milliseconds(50))
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: SSHConnectionError.hermesNotReady) {
            try await ServeBootstrap(loader: FakeHermesHTTP(), configuration: config).start(on: HangingSession(), reuse: nil)
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test(arguments: [("PORT 41234\n", 41234), ("PORT 1", 1), ("PORT 65535\r\n", 65535)])
    func parsePortAcceptsOneLine(reply: String, port: Int) {
        #expect(ServeBootstrap.parsePort(reply) == port)
    }

    @Test(arguments: ["", "PORT", "PORT 0", "PORT 65536", "PORT -1", "PORT 12a", "PORT 1\nPORT 2", "port 80",
                      "PONG 1", "PORT ١٢"])
    func parsePortRefusesOtherText(reply: String) {
        #expect(ServeBootstrap.parsePort(reply) == nil)
    }

    @Test func mintedTokensAreLowercaseHexAndDiffer() {
        let first = SessionToken.mint()
        let second = SessionToken.mint()
        #expect(SessionToken.isValid(Data(first.value.utf8)))
        #expect(first != second)
    }

    @Test func tokenTextIsRedacted() {
        let token = SessionToken.mint()
        #expect(!String(describing: token).contains(token.value))
        #expect(!String(reflecting: token).contains(token.value))
        #expect(!"\(token)".contains(token.value))
    }

    @Test(arguments: [String(repeating: "A", count: 64), String(repeating: "a", count: 63),
                      String(repeating: "a", count: 65), String(repeating: "g", count: 64)])
    func tokenRuleMatchesTheGate(text: String) {
        #expect(!SessionToken.isValid(Data(text.utf8)))
        #expect(SessionToken(hex: text) == nil)
    }

    @Test func gateCommandLineHasNoToken() {
        #expect(GateCommand.serve.rawValue == "serve")
    }

    @Test func retryableGateCodes() {
        #expect(ServeBootstrap.retryableGateCodes == ["serve-timeout", "serve-exited", "update-in-progress"])
    }

    @Test func forwardTargetsTheServerLoopbackOnly() throws {
        let request = try CitadelLoopbackForward.channelRequest(remotePort: 41234, originatorPort: 50000)
        #expect(request.targetHost == "127.0.0.1")
        #expect(request.targetPort == 41234)
        #expect(LoopbackForwardTarget.remoteHost == "127.0.0.1")
    }
}

extension SoftwareKeyFactory {
    func makeKeyForTests() -> DeviceKey {
        let store = KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: self)
        return try! store.createKey()
    }
}
