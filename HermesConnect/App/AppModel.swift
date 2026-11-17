import Foundation
import HermesKit
import Observation
import UIKit

/// The app state for setup, Settings and App Lock. Storage is behind protocols, so tests use fakes.
@MainActor @Observable
final class AppModel {
    enum KeyState: Equatable {
        case none
        case creating
        case ready
        case failed
    }

    /// The shared connection status (issue #3). Issues #4, #5 and #15 add stages.
    enum ConnectionState: Equatable {
        /// Not set up, or no connect was started.
        case idle
        case connecting
        case connected(gateVersion: String)
        /// The last connect failed, or the owner did not trust the server. Nil means no error (Cancel).
        case offline(SSHConnectionError?)
        /// The server sent a host key that is not the pinned key. The app did not authenticate.
        case hostKeyChanged(saved: HostKey, received: HostKey)
    }

    private(set) var profile: ServerProfile?
    private(set) var deviceKey: DeviceKey?
    private(set) var keyState: KeyState = .none
    private(set) var lock: AppLockPolicy
    private(set) var connection: ConnectionState = .idle
    /// A host key that waits for the owner to trust it. The trust sheet shows while it is set.
    private(set) var pendingTrust: HostKey?
    /// True while the "Server Identity Changed" screen shows.
    var showsHostKeyError = false

    @ObservationIgnored private let keyStore: any DeviceKeyStore
    @ObservationIgnored private let profileStore: any ServerProfileStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let connector: HostConnector
    @ObservationIgnored private var session: (any SSHSession)?
    /// Counts connect attempts. A result from an old attempt is dropped (the server changed, or a disconnect ran).
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored let deviceName: String

    static let appLockDefaultsKey = "appLockEnabled"

    init(keyStore: any DeviceKeyStore, profileStore: any ServerProfileStore,
         defaults: UserDefaults = .standard, deviceName: String, transport: any SSHTransport) {
        self.keyStore = keyStore
        self.profileStore = profileStore
        self.defaults = defaults
        self.connector = HostConnector(transport: transport)
        self.deviceName = deviceName
        let enabled = defaults.object(forKey: Self.appLockDefaultsKey) as? Bool ?? true
        lock = AppLockPolicy(isEnabled: enabled)
        profile = try? profileStore.load()
        if let key = try? keyStore.loadKey() {
            deviceKey = key
            keyState = .ready
        }
    }

    /// The app on a device: the Keychain (Secure Enclave when present) and Application Support.
    static func live() -> AppModel {
        let profileStore: any ServerProfileStore = (try? FileServerProfileStore.applicationSupport())
            ?? InMemoryServerProfileStore()
        return AppModel(keyStore: KeychainDeviceKeyStore.system(), profileStore: profileStore,
                        deviceName: UIDevice.current.name, transport: CitadelSSHTransport())
    }

    var isSetUp: Bool { profile != nil && deviceKey != nil }

    var openSSHKey: OpenSSHPublicKey? {
        deviceKey?.openSSH(comment: OpenSSHPublicKey.defaultComment(deviceName: deviceName))
    }

    var installGuide: ServerInstallGuide? {
        guard let openSSHKey else { return nil }
        return ServerInstallGuide(publicKeyLine: openSSHKey.line, user: profile?.user ?? ServerProfile.defaultUser)
    }

    // MARK: Device key

    /// Load the key, or create it if there is no key. Screen 2 of setup calls this when it opens.
    func ensureKey() async {
        guard deviceKey == nil, keyState != .creating else { return }
        keyState = .creating
        let store = keyStore
        let result = await Task.detached { Result { try store.loadOrCreateKey() } }.value
        apply(result)
    }

    /// Delete the key and make a new one. The owner must install the new public key on the server.
    func resetKey() async {
        await disconnect()
        keyState = .creating
        deviceKey = nil
        let store = keyStore
        let result = await Task.detached { Result { try store.resetKey() } }.value
        apply(result)
    }

    private func apply(_ result: Result<DeviceKey, any Error>) {
        switch result {
        case .success(let key):
            deviceKey = key
            keyState = .ready
        case .failure:
            deviceKey = nil
            keyState = .failed
        }
    }

    // MARK: Server profile

    /// Save the profile. A different server (host, port or user) loses the pin, so the owner must trust it again.
    func saveProfile(_ profile: ServerProfile) throws {
        var profile = profile
        let newServer = self.profile.map { profile.isDifferentServer(from: $0) } ?? false
        if newServer { profile.hostKey = nil }
        try profileStore.save(profile)
        self.profile = profile
        if newServer {
            pendingTrust = nil
            showsHostKeyError = false
            connection = .idle
            attempt += 1
            if let old = session {
                session = nil
                Task { await old.close() }
            }
        }
    }

    // MARK: Connection

    /// Connect with the pinned host key and run the gate `ping`.
    /// No pin: show the trust sheet. A changed key: show the error screen. The app never authenticates in those cases.
    func connect() async {
        guard let profile, let deviceKey, connection != .connecting, pendingTrust == nil else { return }
        await closeSession()
        attempt += 1
        let current = attempt
        connection = .connecting
        do {
            let result = try await connector.connect(profile: profile, key: deviceKey)
            guard current == attempt else {
                await result.session.close()
                return
            }
            session = result.session
            connection = .connected(gateVersion: result.gateVersion)
        } catch {
            guard current == attempt else { return }
            switch error {
            case .hostKeyUnknown(let key):
                pendingTrust = key
            case .hostKeyChanged(let saved, let received):
                connection = .hostKeyChanged(saved: saved, received: received)
                showsHostKeyError = true
            default:
                connection = .offline(error)
            }
        }
    }

    /// The owner compared the fingerprint and tapped "Trust Server". Save the full key, then connect.
    func trustPendingHostKey() async {
        guard let key = pendingTrust, var profile else { return }
        profile.hostKey = key
        do {
            try profileStore.save(profile)
        } catch {
            pendingTrust = nil
            connection = .offline(nil)
            return
        }
        self.profile = profile
        pendingTrust = nil
        connection = .idle
        await connect()
    }

    /// The owner tapped "Cancel" on the trust sheet. Stop the connect and show "Offline".
    func cancelTrust() {
        pendingTrust = nil
        connection = .offline(nil)
    }

    /// Delete the pin. The next connect asks the owner to trust the server again.
    func forgetHostKey() async throws {
        guard var profile else { return }
        profile.hostKey = nil
        try profileStore.save(profile)
        self.profile = profile
        showsHostKeyError = false
        await disconnect()
    }

    func disconnect() async {
        attempt += 1
        connection = .idle
        await closeSession()
    }

    private func closeSession() async {
        guard let session else { return }
        self.session = nil
        await session.close()
    }

    // MARK: App Lock

    func setAppLockEnabled(_ enabled: Bool) {
        lock.setEnabled(enabled)
        defaults.set(enabled, forKey: Self.appLockDefaultsKey)
    }

    func didEnterBackground(at date: Date = .now) { lock.didEnterBackground(at: date) }
    func willEnterForeground(at date: Date = .now) { lock.willEnterForeground(at: date) }
    func unlockSucceeded() { lock.unlockSucceeded() }
}

extension AppModel {
    /// A model with in-memory stores and a software key, for previews.
    static func preview(setUp: Bool, hostKey: HostKey? = nil,
                        transport: any SSHTransport = ScriptedSSHTransport(hostKey: .sample)) -> AppModel {
        let keyStore = KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: SoftwareKeyFactory())
        let profiles = InMemoryServerProfileStore(setUp ? ServerProfile(host: "vps.example.com", hostKey: hostKey) : nil)
        if setUp { _ = try? keyStore.createKey() }
        return AppModel(keyStore: keyStore, profileStore: profiles,
                        defaults: UserDefaults(suiteName: "preview") ?? .standard, deviceName: "iPhone",
                        transport: transport)
    }

    /// Set a connection state directly, for previews and screenshots.
    func previewConnection(_ state: ConnectionState, pendingTrust: HostKey? = nil) {
        connection = state
        self.pendingTrust = pendingTrust
    }
}
