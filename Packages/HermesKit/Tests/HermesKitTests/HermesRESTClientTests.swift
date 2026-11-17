import Foundation
import Synchronization
import Testing
@testable import HermesKit

private let testToken = String(repeating: "ab", count: 32)

/// Answers every request with one scripted response and records the requests. No network.
private final class FakeHTTPLoader: HTTPDataLoading, Sendable {
    private let requests = Mutex<[URLRequest]>([])
    private let status: Int
    private let body: String

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    var recorded: [URLRequest] { requests.withLock { $0 } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.withLock { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

@Suite struct GatewayEndpointTests {
    @Test func buildsTheWebSocketURL() throws {
        let endpoint = try GatewayEndpoint(baseURL: URL(string: "http://127.0.0.1:41234")!, token: testToken)
        #expect(endpoint.webSocketURL.absoluteString == "ws://127.0.0.1:41234/api/ws?token=\(testToken)")
    }

    @Test(arguments: ["http://example.com:80", "http://10.0.0.5:8000", "ftp://127.0.0.1:21", "ws://127.0.0.1:1"])
    func refusesNonLoopbackOrWrongScheme(url: String) {
        #expect(throws: GatewayError.invalidEndpoint) { try GatewayEndpoint(baseURL: URL(string: url)!, token: testToken) }
    }

    @Test(arguments: ["", "a b", "tok&en=1", "tök"])
    func refusesBadTokens(token: String) {
        #expect(throws: GatewayError.invalidEndpoint) { try GatewayEndpoint(port: 8000, token: token) }
    }

    @Test(arguments: [0, 65536])
    func refusesBadPorts(port: Int) {
        #expect(throws: GatewayError.invalidEndpoint) { try GatewayEndpoint(port: port, token: testToken) }
    }

    @Test func descriptionHidesTheToken() throws {
        let endpoint = try GatewayEndpoint(port: 8000, token: testToken)
        #expect(!String(describing: endpoint).contains(testToken))
        #expect(!String(reflecting: endpoint).contains(testToken))
        #expect(String(describing: endpoint).contains("<redacted>"))
    }
}

@Suite struct HermesRESTClientTests {
    @Test func sessionsSendsTokenHeaderAndQuery() async throws {
        let loader = FakeHTTPLoader(body: #"""
        {"sessions":[{"id":"k1","title":"Trip","preview":"Book it","source":"photon","started_at":1763290000,
        "last_active":1763290100.5,"message_count":4,"is_active":false,"archived":false,"pinned":true,
        "profile":"default","model":"gpt-x"}],"total":1,"limit":40,"offset":0,"storage":{}}
        """#)
        let client = HermesRESTClient(endpoint: try GatewayEndpoint(port: 8123, token: testToken), loader: loader)
        let page = try await client.sessions(SessionsQuery(excludeSources: ["cron", "tool"]))
        #expect(page.total == 1)
        #expect(page.sessions.first?.pinned == true)
        #expect(page.sessions.first?.lastActive == 1763290100.5)

        let request = try #require(loader.recorded.first)
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == testToken)
        #expect(request.url?.absoluteString
            == "http://127.0.0.1:8123/api/sessions?limit=40&offset=0&order=recent&exclude_sources=cron,tool")
        #expect(request.url?.query?.contains(testToken) == false)
    }

    @Test func messagesPageUsesStoredIdAndLatestOrder() async throws {
        let loader = FakeHTTPLoader(body: #"""
        {"session_id":"20261116_120000_ab12","profile":"default","messages":[{"role":"user","text":"Hi","row_id":1}],
        "pagination":{"limit":100,"offset":100,"order":"latest","returned":1}}
        """#)
        let client = HermesRESTClient(endpoint: try GatewayEndpoint(port: 8123, token: testToken), loader: loader)
        let page = try await client.messages(storedSessionId: "20261116_120000_ab12", offset: 100)
        #expect(page.messages.first?.text == "Hi")
        #expect(page.pagination.returned == 1)
        let url = try #require(loader.recorded.first?.url)
        #expect(url.absoluteString == "http://127.0.0.1:8123/api/sessions/20261116_120000_ab12/messages"
            + "?limit=100&offset=100&order=latest&inline_images=false")
    }

    @Test func storedIdIsPathEncoded() async throws {
        let loader = FakeHTTPLoader(status: 404, body: #"{"detail":"Not found"}"#)
        let client = HermesRESTClient(endpoint: try GatewayEndpoint(port: 8123, token: testToken), loader: loader)
        await #expect(throws: HermesAPIError.notFound) { try await client.messages(storedSessionId: "a/b c") }
        #expect(loader.recorded.first?.url?.path(percentEncoded: true) == "/api/sessions/a%2Fb%20c/messages")
    }

    @Test(arguments: [(401, HermesAPIError.unauthorized), (500, .http(status: 500))])
    func httpErrors(status: Int, error: HermesAPIError) async throws {
        let client = HermesRESTClient(endpoint: try GatewayEndpoint(port: 8123, token: testToken),
                                      loader: FakeHTTPLoader(status: status, body: #"{"detail":"Unauthorized"}"#))
        await #expect(throws: error) { try await client.sessions() }
    }

    @Test func badBodyIsInvalidResponse() async throws {
        let client = HermesRESTClient(endpoint: try GatewayEndpoint(port: 8123, token: testToken),
                                      loader: FakeHTTPLoader(body: "<html>"))
        await #expect(throws: HermesAPIError.invalidResponse) { try await client.sessions() }
    }
}
