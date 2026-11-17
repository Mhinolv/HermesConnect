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
        /// The gate `serve` runs: it starts or reuses Hermes (issue #4).
        case startingHermes
        /// The gate answered `ping`, Hermes passed the health check, and the loopback forward is open.
        case connected(gateVersion: String)
        /// The last connect failed, or the owner did not trust the server. Nil means no error (Cancel).
        case offline(SSHConnectionError?)
        /// The server refused the key or the gate command. A retry does not help (issue #4).
        case notStarted(SSHConnectionError)
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
    /// True while the "Hermes Did Not Start" alert shows (issue #4).
    var showsHermesStartError = false
    /// The local loopback URL and the token of the running Hermes. #6 and #15 give it to the #5 clients.
    /// Nil when Hermes is not ready.
    private(set) var hermesEndpoint: GatewayEndpoint?

    @ObservationIgnored private let keyStore: any DeviceKeyStore
    @ObservationIgnored private let profileStore: any ServerProfileStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let connector: HostConnector
    @ObservationIgnored private let serve: ServeBootstrap
    @ObservationIgnored private var session: (any SSHSession)?
    @ObservationIgnored private var hermes: HermesServe?
    /// The token of the last spawn, in memory only. The next connect sends it again, so the gate reuses the server.
    @ObservationIgnored private var serveToken: SessionToken?
    /// Counts connect attempts. A result from an old attempt is dropped (the server changed, or a disconnect ran).
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored let deviceName: String

    static let appLockDefaultsKey = "appLockEnabled"

    init(keyStore: any DeviceKeyStore, profileStore: any ServerProfileStore,
         defaults: UserDefaults = .standard, deviceName: String, transport: any SSHTransport,
         serve: ServeBootstrap = ServeBootstrap()) {
        self.keyStore = keyStore
        self.profileStore = profileStore
        self.defaults = defaults
        self.connector = HostConnector(transport: transport)
        self.serve = serve
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
        updateProfile { $0.servePort = nil }  // A new key gets a new slot on the server, so a new slot port.
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
    /// It also loses the port pin and the last SSH algorithms: they belong to the old server.
    func saveProfile(_ profile: ServerProfile) throws {
        var profile = profile
        let newServer = self.profile.map { profile.isDifferentServer(from: $0) } ?? false
        if newServer {
            profile.hostKey = nil
            profile.servePort = nil
            profile.lastAlgorithms = nil
        }
        try profileStore.save(profile)
        self.profile = profile
        if newServer {
            pendingTrust = nil
            showsHostKeyError = false
            connection = .idle
            attempt += 1
            serveToken = nil
            let old = (session, hermes)
            session = nil
            hermes = nil
            hermesEndpoint = nil
            Task {
                await old.1?.forward.close()
                await old.0?.close()
            }
        }
    }

    // MARK: Connection

    /// Connect with the pinned host key, run the gate `ping`, then start or reuse Hermes (issue #4).
    /// No pin: show the trust sheet. A changed key: show the error screen. The app never authenticates in those cases.
    func connect() async {
        guard let profile, let deviceKey, connection != .connecting, connection != .startingHermes,
              pendingTrust == nil else { return }
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
            connection = .startingHermes
            if let algorithms = result.algorithms {
                updateProfile { $0.lastAlgorithms = algorithms }
            }
            let pinsPort = ServeBootstrap.pinsPort(gateVersion: result.gateVersion)
            let running = try await serve.start(on: result.session, reuse: serveToken,
                                                pinnedPort: pinsPort ? profile.servePort : nil)
            guard current == attempt else {
                await running.forward.close()
                return
            }
            hermes = running
            serveToken = running.token
            // Issue #29 and #18: the port pin is saved in the profile, so a relaunch keeps it.
            updateProfile { $0.servePort = pinsPort ? running.remotePort : nil }
            hermesEndpoint = running.endpoint
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
                if error == .sessionTokenRejected { serveToken = nil }
                await closeSession()
                connection = Self.failureState(for: error)
            }
        }
    }

    /// A refusal of the key or of the gate command is "Not connected" with the alert.
    /// Network failures, timeouts and a busy server are "Offline" (tap to retry).
    static func failureState(for error: SSHConnectionError) -> ConnectionState {
        switch error {
        case .authenticationFailed, .unusableKey, .noAllowedAlgorithms:
            return .notStarted(error)
        case .gateError(let code) where !ServeBootstrap.retryableGateCodes.contains(code):
            return .notStarted(error)
        default:
            return .offline(error)
        }
    }

    /// #6 and #15 call this when Hermes refuses the token (`GatewayDisconnectReason.needsNewToken`, HTTP 401 or 403).
    /// The next `serve` gets a new token, so the gate replaces the server.
    func renewHermesSession() async {
        serveToken = nil
        await disconnect()
        await connect()
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
        // The port pin stays: it belongs to the device key slot, not to the host key (issue #18).
        showsHostKeyError = false
        await disconnect()
    }

    /// Change the saved profile. A save that fails keeps the change in memory: the next change tries again.
    private func updateProfile(_ change: (inout ServerProfile) -> Void) {
        guard var updated = profile else { return }
        change(&updated)
        guard updated != profile else { return }
        profile = updated
        try? profileStore.save(updated)
    }

    // MARK: Foreground reconcile (issue #15)

    enum ForegroundAction: Equatable {
        case none
        /// No connection: connect with the pin and the gate.
        case connect
        /// The connection can be dead after a suspend: close it, then connect again. The token stays,
        /// so the gate reuses the running Hermes.
        case reconnect
    }

    /// The server reaps an idle live session 20 s after its socket drops. After a longer time away, the
    /// SSH session can look open but be dead, so the app connects again.
    static let staleAfter: TimeInterval = 20

    /// What to do when the app comes back to the foreground. A state that waits for the owner
    /// (trust sheet, changed host key, "Hermes Did Not Start") does nothing.
    static func foregroundAction(connection: ConnectionState, link: ChatLinkStatus?,
                                 away: TimeInterval) -> ForegroundAction {
        switch connection {
        // The owner tapped "Cancel" on the trust sheet (`.offline(nil)`): wait for a tap on "Offline".
        case .offline(nil): return .none
        case .idle, .offline: return .connect
        case .connecting, .startingHermes, .notStarted, .hostKeyChanged: return .none
        case .connected:
            if link == .notConnected || away >= staleAfter { return .reconnect }
            return .none
        }
    }

    /// The root calls this when the scene is active again after the background.
    func reconnectOnForeground(link: ChatLinkStatus?, away: TimeInterval) async {
        guard isSetUp, pendingTrust == nil else { return }
        switch Self.foregroundAction(connection: connection, link: link, away: away) {
        case .none: return
        case .connect: await connect()
        case .reconnect:
            await disconnect()
            await connect()
        }
    }

    func disconnect() async {
        attempt += 1
        connection = .idle
        await closeSession()
    }

    private func closeSession() async {
        hermesEndpoint = nil
        if let hermes {
            self.hermes = nil
            await hermes.forward.close()
        }
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
                        transport: any SSHTransport = ScriptedSSHTransport(hostKey: .sample),
                        http: any HTTPDataLoading = ScriptedHermesHTTP()) -> AppModel {
        let keyStore = KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: SoftwareKeyFactory())
        let profiles = InMemoryServerProfileStore(setUp ? ServerProfile(host: "vps.example.com", hostKey: hostKey) : nil)
        if setUp { _ = try? keyStore.createKey() }
        return AppModel(keyStore: keyStore, profileStore: profiles,
                        defaults: UserDefaults(suiteName: "preview") ?? .standard, deviceName: "iPhone",
                        transport: transport, serve: ServeBootstrap(loader: http))
    }

    /// Set a connection state directly, for previews and screenshots.
    func previewConnection(_ state: ConnectionState, pendingTrust: HostKey? = nil) {
        connection = state
        self.pendingTrust = pendingTrust
    }
}
