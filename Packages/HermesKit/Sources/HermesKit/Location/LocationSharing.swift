import Foundation

/// The saved state of location sharing. Version 1. Unknown or missing fields decode to defaults.
public struct LocationShareState: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public var version: Int
    /// The latest fix that the gate did not accept yet. The app keeps only this one (no queue of old fixes).
    public var pending: LocationFix?
    /// The last fix that the gate accepted, as Core Location gave it (for the rate limit).
    public var lastSent: LocationFix?
    public var lastSentAt: Date?
    /// The text of the last failure, for Settings. It never holds coordinates or server output.
    public var lastError: String?

    public init(pending: LocationFix? = nil, lastSent: LocationFix? = nil, lastSentAt: Date? = nil,
                lastError: String? = nil) {
        version = Self.currentVersion
        self.pending = pending
        self.lastSent = lastSent
        self.lastSentAt = lastSentAt
        self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey {
        case version, pending, lastSent, lastSentAt, lastError
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        pending = try? container.decodeIfPresent(LocationFix.self, forKey: .pending)
        lastSent = try? container.decodeIfPresent(LocationFix.self, forKey: .lastSent)
        lastSentAt = try? container.decodeIfPresent(Date.self, forKey: .lastSentAt)
        lastError = try? container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// What Settings > Location shows.
public struct LocationShareStatus: Sendable, Equatable {
    public var lastSentAt: Date?
    public var lastError: String?
    /// True if a fix waits because the last upload failed. Settings shows "Waiting for connection".
    public var waitingForConnection: Bool

    public init(lastSentAt: Date? = nil, lastError: String? = nil, waitingForConnection: Bool = false) {
        self.lastSentAt = lastSentAt
        self.lastError = lastError
        self.waitingForConnection = waitingForConnection
    }
}

/// The result of one `submit` or `flush`.
public enum LocationSendResult: Sendable, Equatable {
    /// The gate answered `OK`.
    case sent
    /// The rate limit holds the fix. It stays as the pending fix.
    case deferred
    /// The upload failed. A retryable failure keeps the fix as the pending fix.
    case failed(LocationUploadError)
    /// Nothing to send.
    case nothing
}

/// Sends location fixes through the gate `location` command (issue #13).
///
/// - Only the latest unsent fix is kept. A new fix replaces an older pending fix.
/// - At most one upload per 2 minutes, unless the owner moved more than 500 m (`LocationRateLimit`).
/// - If the upload fails, the fix stays pending. `flush` sends it on the next connect or app start.
/// - One upload runs at a time. A fix that comes during an upload waits as the pending fix.
public actor LocationSharing {
    private let store: any LocationStateStore
    private let uploader: any LocationUploading
    private let rateLimit: LocationRateLimit
    private let now: @Sendable () -> Date
    private var state: LocationShareState
    private var uploading = false
    /// The owner asked to send the pending fix now. The rate limit does not apply to it.
    private var forceNext = false

    public init(store: any LocationStateStore, uploader: any LocationUploading,
                rateLimit: LocationRateLimit = LocationRateLimit(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.uploader = uploader
        self.rateLimit = rateLimit
        self.now = now
        state = store.load()
    }

    public var status: LocationShareStatus {
        LocationShareStatus(lastSentAt: state.lastSentAt, lastError: state.lastError,
                            waitingForConnection: state.pending != nil && state.lastError != nil)
    }

    /// A new fix from Core Location. `force` skips the rate limit (the owner asked to send it now).
    public func submit(_ fix: LocationFix, precision: LocationPrecision, force: Bool = false) async -> LocationSendResult {
        if let pending = state.pending, pending.timestamp > fix.timestamp, !force {
            // An older fix (for example a late visit) never replaces a newer pending fix.
            return await send(precision: precision, force: false)
        }
        state.pending = fix
        save()
        return await send(precision: precision, force: force)
    }

    /// Send the pending fix, if the rate limit allows it. Call it on connect and when the app opens.
    public func flush(precision: LocationPrecision) async -> LocationSendResult {
        await send(precision: precision, force: false)
    }

    /// The owner turned sharing off. Drop the pending fix. Keep the time of the last upload for Settings.
    public func discardPending() {
        state.pending = nil
        state.lastError = nil
        save()
    }

    private func send(precision: LocationPrecision, force: Bool) async -> LocationSendResult {
        if force { forceNext = true }
        guard state.pending != nil else { return .nothing }
        // The running upload sends this fix when it ends (see the loop).
        guard !uploading else { return .deferred }
        uploading = true
        defer { uploading = false }
        var result = LocationSendResult.nothing
        while let fix = state.pending {
            let forced = forceNext
            guard forced || rateLimit.allows(fix, lastSent: state.lastSent, lastSentAt: state.lastSentAt, now: now()) else {
                return result == .sent ? .sent : .deferred
            }
            forceNext = false
            do {
                try await uploader.upload(LocationPayload.encode(fix, precision: precision))
            } catch {
                state.lastError = error.description
                if !error.isRetryable, state.pending == fix { state.pending = nil }
                save()
                return .failed(error)
            }
            state.lastSent = fix
            state.lastSentAt = now()
            state.lastError = nil
            if state.pending == fix { state.pending = nil }
            save()
            result = .sent
            // If a newer fix came during the upload, the loop sends it when the rate limit allows it.
        }
        return result
    }

    private func save() {
        store.save(state)
    }
}

// MARK: - Store

/// Saves `LocationShareState`. The background upload reads it after a relaunch.
public protocol LocationStateStore: Sendable {
    func load() -> LocationShareState
    func save(_ state: LocationShareState)
}

/// The state as JSON in Application Support (`HermesConnect/location-state.json`).
/// iOS protects the file until the first unlock, the same class as the device key (research.md D1).
public struct FileLocationStateStore: LocationStateStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func applicationSupport() throws -> FileLocationStateStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return FileLocationStateStore(fileURL: base.appending(path: "HermesConnect/location-state.json"))
    }

    public func load() -> LocationShareState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(LocationShareState.self, from: data) else {
            return LocationShareState()
        }
        return state
    }

    public func save(_ state: LocationShareState) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(state).write(to: fileURL, options: options)
    }
}

/// A `LocationStateStore` in memory, for tests and previews.
public final class InMemoryLocationStateStore: LocationStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: LocationShareState

    public init(_ state: LocationShareState = LocationShareState()) {
        self.state = state
    }

    public func load() -> LocationShareState { lock.withLock { state } }
    public func save(_ state: LocationShareState) { lock.withLock { self.state = state } }
}
