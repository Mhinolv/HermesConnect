import Foundation

/// Loads one HTTP request. Tests use a fake. The app uses `URLSessionHTTPLoader`.
public protocol HTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionHTTPLoader: HTTPDataLoading {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public enum HermesAPIError: Error, Sendable, Equatable {
    /// HTTP 401: the token is not valid. The server restarted, so run #4 again.
    case unauthorized
    case notFound
    case http(status: Int)
    case invalidResponse
}

/// One row of `GET /api/sessions` (`hermes_cli/web_routers/sessions.py:182-241`).
public struct SessionSummary: Decodable, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var preview: String?
    public var source: String?
    public var startedAt: Double?
    public var lastActive: Double?
    public var messageCount: Int?
    public var isActive: Bool?
    public var archived: Bool?
    public var pinned: Bool?
    public var profile: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, preview, source, startedAt = "started_at", lastActive = "last_active"
        case messageCount = "message_count", isActive = "is_active", archived, pinned, profile
    }
}

/// `GET /api/sessions` result.
public struct SessionsPage: Decodable, Sendable, Equatable {
    public var sessions: [SessionSummary]
    public var total: Int
    public var limit: Int
    public var offset: Int
}

/// Query of `GET /api/sessions`. The server caps `limit` at 100.
public struct SessionsQuery: Sendable, Equatable {
    public enum Order: String, Sendable { case created, recent }

    public var limit: Int
    public var offset: Int
    public var order: Order
    public var source: String?
    public var excludeSources: [String]

    public init(limit: Int = 40, offset: Int = 0, order: Order = .recent, source: String? = nil,
                excludeSources: [String] = []) {
        self.limit = limit
        self.offset = offset
        self.order = order
        self.source = source
        self.excludeSources = excludeSources
    }

    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(min(max(limit, 0), 100))),
                     URLQueryItem(name: "offset", value: String(max(offset, 0))),
                     URLQueryItem(name: "order", value: order.rawValue)]
        if let source { items.append(URLQueryItem(name: "source", value: source)) }
        if !excludeSources.isEmpty {
            items.append(URLQueryItem(name: "exclude_sources", value: excludeSources.joined(separator: ",")))
        }
        return items
    }
}

/// One history page of `GET /api/sessions/{id}/messages` (`web_routers/sessions.py:746-790`).
public struct SessionMessagesPage: Decodable, Sendable, Equatable {
    public struct Pagination: Decodable, Sendable, Equatable {
        public var limit: Int
        public var offset: Int
        public var order: String
        public var returned: Int
    }

    public var sessionId: String
    public var messages: [TranscriptMessage]
    public var pagination: Pagination

    private enum CodingKeys: String, CodingKey { case sessionId = "session_id", messages, pagination }
}

/// REST calls on the same forwarded port, with header `X-Hermes-Session-Token`
/// (docs/hermes-protocol.md 2.1, 3.5). Use it for paged lists and paged history.
public struct HermesRESTClient: Sendable {
    public let endpoint: GatewayEndpoint
    private let loader: any HTTPDataLoading

    public init(endpoint: GatewayEndpoint, loader: any HTTPDataLoading = URLSessionHTTPLoader()) {
        self.endpoint = endpoint
        self.loader = loader
    }

    /// `GET /api/sessions`.
    public func sessions(_ query: SessionsQuery = SessionsQuery()) async throws -> SessionsPage {
        try await get("/api/sessions", query: query.queryItems)
    }

    /// `GET /api/sessions/{stored id}/messages`. With `order: "latest"` the offset counts back
    /// from the newest row (docs/hermes-protocol.md 3.5). The server caps `limit` at 500.
    public func messages(storedSessionId: String, limit: Int = 100, offset: Int = 0,
                         order: String = "latest", inlineImages: Bool = false) async throws -> SessionMessagesPage {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard !storedSessionId.isEmpty,
              let encodedId = storedSessionId.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw HermesAPIError.notFound
        }
        return try await get("/api/sessions/\(encodedId)/messages", query: [
            URLQueryItem(name: "limit", value: String(min(max(limit, 0), 500))),
            URLQueryItem(name: "offset", value: String(max(offset, 0))),
            URLQueryItem(name: "order", value: order),
            URLQueryItem(name: "inline_images", value: inlineImages ? "true" : "false"),
        ])
    }

    func request(path: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue(endpoint.token, forHTTPHeaderField: "X-Hermes-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get<Output: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Output {
        let (data, response) = try await loader.data(for: request(path: path, query: query))
        guard let http = response as? HTTPURLResponse else { throw HermesAPIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw HermesAPIError.unauthorized
        case 404: throw HermesAPIError.notFound
        default: throw HermesAPIError.http(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Output.self, from: data)
        } catch {
            throw HermesAPIError.invalidResponse
        }
    }
}
