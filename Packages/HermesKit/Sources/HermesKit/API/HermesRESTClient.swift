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

/// `GET /api/health` result (`web_routers/status.py:119-130`). It is public: no token.
public struct HermesHealth: Decodable, Sendable, Equatable {
    public var ok: Bool?
    public var version: String?
}

/// `GET /api/ssh/ownership` result (`web_routers/status.py:109-116`, docs/hermes-protocol.md 1.3 step 12).
public struct SSHOwnershipProof: Decodable, Sendable, Equatable {
    public var ok: Bool?
    public var sshOwnerNonce: String?
    public var protocolVersion: Int?
    public var runtimeIntact: Bool?

    /// `ok` is true, the nonce is 16 hex, the protocol is 1, and `runtimeIntact` is not false.
    /// The gate keeps the nonce, so the app checks only its form.
    public var isValid: Bool {
        guard ok == true, protocolVersion == 1, runtimeIntact != false, let nonce = sshOwnerNonce,
              nonce.count == 16, nonce.allSatisfy(\.isHexDigit) else { return false }
        return true
    }
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

    /// `GET /api/health`, with no token. A 2xx answer means that the server runs.
    public func health() async throws -> HermesHealth {
        try await get("/api/health", query: [], authenticated: false)
    }

    /// `GET /api/status` with the token. The fallback health check (`backend-health.ts:79-104`).
    public func status() async throws {
        let _: JSONValue = try await get("/api/status", query: [])
    }

    /// `GET /api/ssh/ownership` with the token. 401, 403 and 404 mean a stale token.
    public func sshOwnership() async throws -> SSHOwnershipProof {
        try await get("/api/ssh/ownership", query: [])
    }

    /// `POST /api/audio/transcribe` with the clip as a base64 data URL (docs/hermes-protocol.md 3.9).
    /// Returns the transcript, trimmed. An empty string means that the server found no speech.
    /// The clip and the transcript never go to a log.
    public func transcribe(audio: Data, mimeType: String = VoiceMemoLimits.mimeType) async throws -> String {
        guard !audio.isEmpty, audio.count <= VoiceMemoLimits.maxUploadBytes else { throw VoiceMemoError.badClip }
        var request = request(path: "/api/audio/transcribe", query: [], timeout: Self.transcribeTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TranscribeRequest(
            dataURL: "data:\(mimeType);base64,\(audio.base64EncodedString())", mimeType: mimeType))
        let result: TranscribeResponse = try await load(request)
        guard result.ok != false else { throw HermesAPIError.invalidResponse }
        return (result.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A 10-minute clip can take the provider a long time. The other calls use 15 s.
    static let transcribeTimeout: TimeInterval = 120

    private struct TranscribeRequest: Encodable {
        var dataURL: String
        var mimeType: String
        enum CodingKeys: String, CodingKey { case dataURL = "data_url", mimeType = "mime_type" }
    }

    private struct TranscribeResponse: Decodable {
        var ok: Bool?
        var transcript: String?
    }

    func request(path: String, query: [URLQueryItem], authenticated: Bool = true,
                 timeout: TimeInterval = 15) -> URLRequest {
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = timeout
        if authenticated { request.setValue(endpoint.token, forHTTPHeaderField: "X-Hermes-Session-Token") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get<Output: Decodable>(_ path: String, query: [URLQueryItem],
                                        authenticated: Bool = true) async throws -> Output {
        try await load(request(path: path, query: query, authenticated: authenticated))
    }

    private func load<Output: Decodable>(_ request: URLRequest) async throws -> Output {
        let (data, response) = try await loader.data(for: request)
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

// MARK: - Test and preview loader

/// A fake `HTTPDataLoading` for app tests and previews. It answers the #4 checks
/// (`/api/health`, `/api/status`, `/api/ssh/ownership`) like a healthy Hermes. No network.
public final class ScriptedHermesHTTP: HTTPDataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var _ownershipStatus = 200
    private var _healthy = true
    private var _paths: [String] = []

    public init() {}

    /// `false`: every request fails, as if Hermes does not answer.
    public var healthy: Bool {
        get { lock.withLock { _healthy } }
        set { lock.withLock { _healthy = newValue } }
    }

    /// The status of `GET /api/ssh/ownership`. 401 simulates a stale token.
    public var ownershipStatus: Int {
        get { lock.withLock { _ownershipStatus } }
        set { lock.withLock { _ownershipStatus = newValue } }
    }

    public var paths: [String] { lock.withLock { _paths } }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        let (healthy, ownership) = lock.withLock { () -> (Bool, Int) in
            _paths.append(path)
            return (_healthy, _ownershipStatus)
        }
        guard healthy, let url = request.url else { throw URLError(.cannotConnectToHost) }
        let (status, body) = switch path {
        case "/api/ssh/ownership":
            (ownership, #"{"ok":true,"sshOwnerNonce":"0123456789abcdef","protocolVersion":1,"runtimeIntact":true}"#)
        case "/api/health": (200, #"{"ok":true}"#)
        default: (200, "{}")
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
