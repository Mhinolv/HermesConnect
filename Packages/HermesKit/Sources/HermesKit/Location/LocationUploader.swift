import Foundation

/// Why a location upload failed. The text never holds coordinates or server output other than the gate code.
public enum LocationUploadError: Error, Sendable, Equatable, CustomStringConvertible {
    /// There is no server profile or no device key yet.
    case notSetUp
    /// The SSH connection or the gate command failed.
    case connection(SSHConnectionError)
    /// The upload took longer than the background time limit.
    case timedOut

    /// False if a second try with the same fix cannot work. The app then drops that fix.
    public var isRetryable: Bool {
        if case .connection(.gateError("bad-location")) = self { return false }
        return true
    }

    public var description: String {
        switch self {
        case .notSetUp: "Hermes is not set up."
        case .connection(let error): error.description
        case .timedOut: "The server did not answer in time."
        }
    }
}

/// Sends one location payload to the server.
public protocol LocationUploading: Sendable {
    func upload(_ payload: Data) async throws(LocationUploadError)
}

/// The server and the key for a background upload.
public struct LocationCredentials: Sendable {
    public var profile: ServerProfile
    public var key: DeviceKey

    public init(profile: ServerProfile, key: DeviceKey) {
        self.profile = profile
        self.key = key
    }
}

/// Opens its own SSH connection with the pinned host key, runs the gate `location` command with the
/// payload on stdin, expects `OK`, then closes the connection. It does not start `hermes serve`.
/// The device key has no per-use Face ID (research.md D1), so this works in the background after the first unlock.
public struct GateLocationUploader: LocationUploading {
    /// iOS gives a background task about 30 s. The upload must end before that.
    public static let defaultTimeout: Duration = .seconds(25)

    private let connector: HostConnector
    private let credentials: @Sendable () async -> LocationCredentials?
    private let timeout: Duration

    public init(connector: HostConnector, timeout: Duration = Self.defaultTimeout,
                credentials: @escaping @Sendable () async -> LocationCredentials?) {
        self.connector = connector
        self.credentials = credentials
        self.timeout = timeout
    }

    public func upload(_ payload: Data) async throws(LocationUploadError) {
        guard let credentials = await credentials() else { throw .notSetUp }
        let connector = connector
        do {
            try await withDeadline(timeout) {
                let connection = try await connector.connect(profile: credentials.profile, key: credentials.key)
                let reply: String
                do {
                    // The app cancels the upload when iOS ends the background time.
                    try Task.checkCancellation()
                    let body = LocationPayload.forGate(payload, gateVersion: connection.gateVersion)
                    reply = try await connection.session.execute(.location, stdin: body)
                } catch {
                    await connection.session.close()
                    throw error
                }
                await connection.session.close()
                guard reply.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
                    throw SSHConnectionError.unexpectedReply
                }
            }
        } catch let error as SSHConnectionError {
            throw .connection(error)
        } catch is DeadlineExceeded {
            throw .timedOut
        } catch is CancellationError {
            // iOS ended the background time. The fix stays unsent.
            throw .timedOut
        } catch {
            throw .connection(.unreachable)
        }
    }
}

/// A fake `LocationUploading` for tests and previews. It records each payload.
public final class ScriptedLocationUploader: LocationUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var _payloads: [Data] = []
    private var _failure: LocationUploadError?
    private var _gate: (@Sendable () async -> Void)?

    public init(failure: LocationUploadError? = nil) {
        _failure = failure
    }

    public var payloads: [Data] { lock.withLock { _payloads } }

    /// The error that the next uploads give, or nil for `OK`.
    public var failure: LocationUploadError? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    /// Runs inside each upload before it ends. Tests use it to hold an upload open.
    public var duringUpload: (@Sendable () async -> Void)? {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }

    public func upload(_ payload: Data) async throws(LocationUploadError) {
        let hook = lock.withLock { () -> (@Sendable () async -> Void)? in
            _payloads.append(payload)
            return _gate
        }
        await hook?()
        if let failure { throw failure }
        // A cancelled real upload never reaches `OK`.
        if Task.isCancelled { throw .timedOut }
    }
}
