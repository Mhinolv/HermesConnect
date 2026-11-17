import Foundation

/// Why a received file did not download (issue #12 design notes, "States").
public enum ReceivedFileError: Error, Sendable, Equatable {
    /// The file is larger than the limit of the call. The owner confirms ("Download 120 MB?").
    case tooLarge(byteCount: Int)
    /// 403 or 404: "File not available".
    case notAvailable
    /// No Hermes endpoint: "Connect to download".
    case offline
}

/// Downloads one file to a local temporary file. Tests use a fake. The app uses `URLSessionFileDownloader`.
public protocol HTTPFileDownloading: Sendable {
    /// `maxBytes`: when the response says that the body is larger, the download stops with
    /// `ReceivedFileError.tooLarge`. The caller owns the returned file and moves or removes it.
    func download(_ request: URLRequest, maxBytes: Int?,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse)
}

/// What the chat screen needs to download a received file. `LiveChatTransport` conforms.
public protocol ReceivedFileDownloading: Sendable {
    /// `GET /api/fs/download` for `path` in the session `storedSessionId`. Returns a temporary file.
    func downloadReceivedFile(path: String, storedSessionId: String?, maxBytes: Int?,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

extension HermesRESTClient {
    /// `GET /api/fs/download?path=&session_id=` with the token header (docs/hermes-protocol.md 5.2, 7.5).
    /// The token never goes in the URL. The path is the one that the tag gave: the server decides what it serves.
    public func downloadRequest(path: String, storedSessionId: String?) -> URLRequest {
        var query = [URLQueryItem(name: "path", value: path)]
        if let storedSessionId, !storedSessionId.isEmpty {
            query.append(URLQueryItem(name: "session_id", value: storedSessionId))
        }
        var request = request(path: "/api/fs/download", query: query, timeout: 60)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        // `URLComponents` leaves `+` and `&` inside a value as they are. Encode them, so the server reads the path.
        if let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            request.url = components.url
        }
        return request
    }

    /// Downloads a received file to a temporary file. 403 and 404 throw `.notAvailable`. A redirect is an error.
    public func downloadFile(path: String, storedSessionId: String?, maxBytes: Int?,
                             using loader: any HTTPFileDownloading = URLSessionFileDownloader(),
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let (file, response) = try await loader.download(downloadRequest(path: path, storedSessionId: storedSessionId),
                                                         maxBytes: maxBytes, progress: progress)
        switch response.statusCode {
        case 200..<300:
            return file
        default:
            try? FileManager.default.removeItem(at: file)
            switch response.statusCode {
            case 401: throw HermesAPIError.unauthorized
            case 403, 404, 410: throw ReceivedFileError.notAvailable
            default: throw HermesAPIError.http(status: response.statusCode)
            }
        }
    }
}

/// A `URLSession` download task with a delegate (issue #12):
/// - It does not follow 3xx (docs/hermes-protocol.md 5.2, `gateway-download-transport.ts:39-43`).
/// - It stops when `Content-Length` is over `maxBytes`, before the body is on the phone.
/// - It writes to disk, so a large file never sits in memory. The bytes never go to a log.
public struct URLSessionFileDownloader: HTTPFileDownloading {
    public init() {}

    public func download(_ request: URLRequest, maxBytes: Int?,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse) {
        let delegate = FileDownloadDelegate(maxBytes: maxBytes, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int?
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), any Error>?
    private var file: URL?
    private var tooLarge: Int?

    init(maxBytes: Int?, progress: @escaping @Sendable (Double) -> Void) {
        self.maxBytes = maxBytes
        self.progress = progress
    }

    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<(URL, HTTPURLResponse), any Error>) {
        lock.withLock { self.continuation = continuation }
        if Task.isCancelled { task.cancel() }
        task.resume()
    }

    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        let ok = (downloadTask.response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
        if ok, let maxBytes, expected > Int64(maxBytes) {
            lock.withLock { tooLarge = Int(expected) }
            downloadTask.cancel()
            return
        }
        guard expected > 0 else { return }
        progress(min(1, Double(written) / Double(expected)))
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system removes `location` when this call returns. Move it first.
        let target = FileManager.default.temporaryDirectory.appending(path: "download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: target)
            lock.withLock { file = target }
        } catch {
            lock.withLock { file = nil }
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, file, tooLarge) = lock.withLock { () -> (CheckedContinuation<(URL, HTTPURLResponse), any Error>?, URL?, Int?) in
            defer { self.continuation = nil }
            return (self.continuation, self.file, self.tooLarge)
        }
        guard let continuation else { return }
        if let tooLarge {
            continuation.resume(throwing: ReceivedFileError.tooLarge(byteCount: tooLarge))
        } else if let error {
            continuation.resume(throwing: error)
        } else if let response = task.response as? HTTPURLResponse, let file {
            continuation.resume(returning: (file, response))
        } else {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation.resume(throwing: HermesAPIError.invalidResponse)
        }
    }
}

