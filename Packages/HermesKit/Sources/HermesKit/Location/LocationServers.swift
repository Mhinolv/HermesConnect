import Foundation

/// Issue #92: the servers that get the location of the owner. "Share Location" in each server detail.
///
/// A new server is not in the set, so its sharing is off. The active server does not matter: each fix goes to
/// each saved server in the set, and never to a server that is not in it.
public struct LocationServerSettings: Sendable, Equatable {
    public var sharingIDs: Set<UUID>

    public init(sharingIDs: Set<UUID> = []) {
        self.sharingIDs = sharingIDs
    }

    public func isSharing(_ id: UUID) -> Bool { sharingIDs.contains(id) }

    public mutating func setSharing(_ on: Bool, server id: UUID) {
        if on { sharingIDs.insert(id) } else { sharingIDs.remove(id) }
    }

    /// The saved servers with sharing on, in the order of the list. An id of a removed server does not count.
    public func targets(in list: ServerList) -> [UUID] {
        list.servers.map(\.id).filter(sharingIDs.contains)
    }

    /// The first start of a build with issue #92. Builds before it had one switch for the active server
    /// ("Share Location Automatically"). Its value goes to the migrated server (`ServerProfile.legacyID`) only,
    /// so the owner sees no new prompt there. Each other server starts with sharing off.
    public static func migrated(legacyEnabled: Bool) -> LocationServerSettings {
        LocationServerSettings(sharingIDs: legacyEnabled ? [ServerProfile.legacyID] : [])
    }
}

/// Saves `LocationServerSettings`. The background upload reads it after a relaunch.
public protocol LocationServerSettingsStore: Sendable {
    func load() -> LocationServerSettings
    func save(_ settings: LocationServerSettings)
}

/// The settings in `UserDefaults`, the same place as the switch of the builds before issue #92.
public final class DefaultsLocationServerSettingsStore: LocationServerSettingsStore, @unchecked Sendable {
    /// The ids of the servers with sharing on, as UUID strings.
    public static let key = "locationSharingServers"
    /// The one switch of the builds before issue #92. Only the migration reads it. It stays for an older build.
    public static let legacyEnabledKey = "locationSharingEnabled"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> LocationServerSettings {
        lock.withLock {
            guard let saved = defaults.stringArray(forKey: Self.key) else {
                let settings = LocationServerSettings.migrated(legacyEnabled: defaults.bool(forKey: Self.legacyEnabledKey))
                write(settings)
                return settings
            }
            return LocationServerSettings(sharingIDs: Set(saved.compactMap(UUID.init(uuidString:))))
        }
    }

    public func save(_ settings: LocationServerSettings) {
        lock.withLock { write(settings) }
    }

    private func write(_ settings: LocationServerSettings) {
        defaults.set(settings.sharingIDs.map(\.uuidString).sorted(), forKey: Self.key)
    }
}

/// A `LocationServerSettingsStore` in memory, for tests and previews.
public final class InMemoryLocationServerSettingsStore: LocationServerSettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: LocationServerSettings

    public init(_ settings: LocationServerSettings = LocationServerSettings()) {
        self.settings = settings
    }

    public func load() -> LocationServerSettings { lock.withLock { settings } }
    public func save(_ settings: LocationServerSettings) { lock.withLock { self.settings = settings } }
}

/// Issue #92: sends each fix to each server with sharing on. Each server has its own `LocationSharing`, so
/// each server has its own pending fix, its own rate limit and its own "Last Sent".
///
/// The servers and the settings load again for each send, so a switch or a change in Settings counts at once,
/// also after a relaunch in the background. If a gate refuses location (`location-off`, gate `--no-location`),
/// sharing turns off for that server. The app does not try again.
public actor LocationFanOut {
    private let servers: any ServerListStore
    private let settings: any LocationServerSettingsStore
    private let makeStore: @Sendable (UUID) -> any LocationStateStore
    private let makeUploader: @Sendable (UUID) -> any LocationUploading
    private let rateLimit: LocationRateLimit
    private let now: @Sendable () -> Date
    private var sharings: [UUID: LocationSharing] = [:]

    public init(servers: any ServerListStore, settings: any LocationServerSettingsStore,
                store: @escaping @Sendable (UUID) -> any LocationStateStore,
                uploader: @escaping @Sendable (UUID) -> any LocationUploading,
                rateLimit: LocationRateLimit = LocationRateLimit(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.servers = servers
        self.settings = settings
        makeStore = store
        makeUploader = uploader
        self.rateLimit = rateLimit
        self.now = now
    }

    /// The saved servers with sharing on, in the order of the list.
    public func targets() -> [UUID] {
        guard let list = try? servers.load() else { return [] }
        return settings.load().targets(in: list)
    }

    /// A new fix. It goes to each server with sharing on. `force` skips the rate limit.
    @discardableResult
    public func submit(_ fix: LocationFix, precision: LocationPrecision, force: Bool = false) async -> [UUID: LocationSendResult] {
        await each { sharing in await sharing.submit(fix, precision: precision, force: force) }
    }

    /// Send the pending fix of each server with sharing on, if its rate limit allows it.
    @discardableResult
    public func flush(precision: LocationPrecision) async -> [UUID: LocationSendResult] {
        await each { sharing in await sharing.flush(precision: precision) }
    }

    /// Sharing for this server turned off, or the server was removed. Drop its pending fix.
    public func discardPending(server id: UUID) async {
        await sharing(for: id).discardPending()
    }

    public func status(server id: UUID) async -> LocationShareStatus {
        await sharing(for: id).status
    }

    /// Settings > Location: the latest upload of the servers with sharing on.
    public func combinedStatus() async -> LocationShareStatus {
        var combined = LocationShareStatus()
        for id in targets() {
            let status = await sharing(for: id).status
            if let sent = status.lastSentAt, sent > (combined.lastSentAt ?? .distantPast) { combined.lastSentAt = sent }
            if combined.lastError == nil { combined.lastError = status.lastError }
            combined.waitingForConnection = combined.waitingForConnection || status.waitingForConnection
        }
        return combined
    }

    private func sharing(for id: UUID) -> LocationSharing {
        if let sharing = sharings[id] { return sharing }
        let sharing = LocationSharing(store: makeStore(id), uploader: makeUploader(id), rateLimit: rateLimit, now: now)
        sharings[id] = sharing
        return sharing
    }

    /// Run `work` for each target at the same time, so that all uploads fit in one background task.
    private func each(_ work: @escaping @Sendable (LocationSharing) async -> LocationSendResult) async -> [UUID: LocationSendResult] {
        let targets = targets().map { ($0, sharing(for: $0)) }
        var results: [UUID: LocationSendResult] = [:]
        await withTaskGroup(of: (UUID, LocationSendResult).self) { group in
            for (id, sharing) in targets {
                group.addTask { (id, await work(sharing)) }
            }
            for await (id, result) in group { results[id] = result }
        }
        for (id, result) in results where result == .failed(.connection(.gateError(LocationUploadError.locationOffCode))) {
            var saved = settings.load()
            saved.setSharing(false, server: id)
            settings.save(saved)
        }
        return results
    }
}

extension GateLocationUploader {
    /// Issue #92: an uploader for one saved server. Each upload loads that server and the device key, so it
    /// also works after a relaunch in the background. A removed server gives `notSetUp`.
    public static func forServer(_ id: UUID, connector: HostConnector, servers: any ServerListStore,
                                 keys: any DeviceKeyStore) -> GateLocationUploader {
        GateLocationUploader(connector: connector) {
            guard let profile = (try? servers.load())?.server(id: id), let key = try? keys.loadKey() else { return nil }
            return LocationCredentials(profile: profile, key: key)
        }
    }
}

extension FileLocationStateStore {
    /// Issue #92: the state of one server, `HermesConnect/Location/<server id>.json` in Application Support.
    /// The migrated server first reads the one state file of the builds before (`location-state.json`).
    public static func applicationSupport(server id: UUID) throws -> FileLocationStateStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return FileLocationStateStore(server: id, folder: base.appending(path: "HermesConnect/Location"),
                                      legacyURL: base.appending(path: "HermesConnect/location-state.json"))
    }

    public init(server id: UUID, folder: URL, legacyURL: URL) {
        self.init(fileURL: folder.appending(path: "\(id.uuidString).json"),
                  fallbackURL: id == ServerProfile.legacyID ? legacyURL : nil)
    }
}
