import Foundation

/// The cron calls of the Jobs tab (issue #73). Read-only: no Run now, pause or resume (owner decision).
/// `LiveChatTransport` sends them as REST on the forwarded port. Tests give a fake.
public protocol CronTransport: Sendable {
    /// Connection states and events. `cron.changed`, `sessions.changed` and a connect refresh the lists.
    var events: AsyncStream<GatewayClientEvent> { get }
    /// `GET /api/cron/jobs`.
    func fetchCronJobs() async throws -> [CronJob]
    /// `GET /api/cron/jobs/{id}/runs?limit=`, newest first.
    func fetchCronRuns(jobId: String, limit: Int) async throws -> [CronRun]
    /// `GET /api/sessions/{id}/messages` of an agent run, oldest first. It does not resume the session.
    func fetchRunTranscript(sessionId: String) async throws -> [TranscriptMessage]
}

public enum CronAPI {
    /// The run history of the job screen (issue #73 design notes). The server caps it at 100.
    public static let runsLimit = 50
    /// The rows of one run transcript. The server caps it at 500.
    public static let transcriptLimit = 500
}

/// A server refusal with its `detail` text, for the "Couldn't Load Jobs" view.
public struct CronAPIError: Error, Sendable, Equatable {
    public var status: Int
    public var detail: String

    public init(status: Int, detail: String) {
        self.status = status
        self.detail = detail
    }
}

extension HermesRESTClient {
    /// `GET /api/cron/jobs` (`web_routers/cron.py:741-743`). A job that does not decode is dropped.
    public func cronJobs() async throws -> [CronJob] {
        try await cronGet("/api/cron/jobs", query: [], as: LossyArray<CronJob>.self).items
    }

    /// `GET /api/cron/jobs/{id}/runs?limit=` (`cron.py:751-753`). The server caps `limit` at 100.
    public func cronRuns(jobId: String, limit: Int = CronAPI.runsLimit) async throws -> [CronRun] {
        let path = "/api/cron/jobs/\(try Self.cronPathComponent(jobId))/runs"
        let query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        return try await cronGet(path, query: query, as: CronRunsPage.self).runs
    }

    static func cronPathComponent(_ id: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw HermesAPIError.notFound
        }
        return encoded
    }

    /// A GET that keeps the server `detail` text of a refusal (FastAPI `{"detail": "..."}`).
    private func cronGet<Output: Decodable>(_ path: String, query: [URLQueryItem],
                                            as _: Output.Type) async throws -> Output {
        let (data, response) = try await loader.data(for: request(path: path, query: query))
        guard let http = response as? HTTPURLResponse else { throw HermesAPIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw HermesAPIError.unauthorized
        default:
            let detail = (try? JSONDecoder().decode(CronErrorDetail.self, from: data))?.detail ?? ""
            if !detail.isEmpty { throw CronAPIError(status: http.statusCode, detail: detail) }
            if http.statusCode == 404 { throw HermesAPIError.notFound }
            throw HermesAPIError.http(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Output.self, from: data)
        } catch {
            throw HermesAPIError.invalidResponse
        }
    }
}

private struct CronErrorDetail: Decodable {
    var detail: String?
}

extension LiveChatTransport: CronTransport {}

/// The text of a failed load, for the error view of the Jobs tab and the job screen.
public enum CronErrorText {
    public static func message(for error: any Error) -> String {
        switch error {
        case let error as CronAPIError: return error.detail
        case GatewayError.notConnected: return "Hermes is not connected."
        case HermesAPIError.unauthorized, HermesAPIError.http(status: 403): return "Hermes refused the session."
        case HermesAPIError.notFound: return "Hermes does not have this job."
        case HermesAPIError.http(let status): return "Hermes answered with error \(status)."
        case HermesAPIError.invalidResponse: return "Hermes sent an answer that the app cannot read."
        case is URLError: return "Hermes did not answer."
        default: return "Hermes did not answer."
        }
    }
}
