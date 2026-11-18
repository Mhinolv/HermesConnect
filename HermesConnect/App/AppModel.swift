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

    /// Issue #66: every saved server and the active server. One server is connected at a time.
    private(set) var serverList: ServerList
    /// The active server: the one the app connects to. Nil before setup.
    var profile: ServerProfile? { serverList.active }
    var servers: [ServerProfile] { serverList.servers }
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
    /// Issue #83: the unread rows and the outbox of the servers that are not active.
    private(set) var serverBook: ServerStateBook
    /// Issue #83: the app resets the lists here when the active server changes. It runs before the new connect.
    @ObservationIgnored var onActiveServerChange: (@MainActor (ServerChange) -> Void)?
    /// Issue #84: the owner removed a server. The app deletes its cache folder and its notifications.
    /// It runs after the switch to the next server.
    @ObservationIgnored var onServerRemoved: (@MainActor (ServerProfile) -> Void)?

    @ObservationIgnored private let keyStore: any DeviceKeyStore
    @ObservationIgnored private let serverStore: any ServerListStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let connector: HostConnector
    @ObservationIgnored private let serve: ServeBootstrap
    @ObservationIgnored private var session: (any SSHSession)?
    @ObservationIgnored private var hermes: HermesServe?
    /// The token of the last spawn, in memory only. The next connect sends it again, so the gate reuses the server.
    @ObservationIgnored private var serveToken: SessionToken?
    /// Counts connect attempts. A result from an old attempt is dropped (the server changed, or a disconnect ran).
    @ObservationIgnored private var attempt = 0
    /// Issue #83: the close of the old server link. The next connect waits for it, so two links never overlap.
    @ObservationIgnored private var pendingClose: Task<Void, Never>?
    /// Issue #83: counts switches. Only the last of fast switches connects.
    @ObservationIgnored private var switchCount = 0
    @ObservationIgnored let deviceName: String

    static let appLockDefaultsKey = "appLockEnabled"
    static let serverBookDefaultsKey = "serverStateBook"

    init(keyStore: any DeviceKeyStore, serverStore: any ServerListStore,
         defaults: UserDefaults = .standard, deviceName: String, transport: any SSHTransport,
         serve: ServeBootstrap = ServeBootstrap()) {
        self.keyStore = keyStore
        self.serverStore = serverStore
        self.defaults = defaults
        self.connector = HostConnector(transport: transport)
        self.serve = serve
        self.deviceName = deviceName
        let enabled = defaults.object(forKey: Self.appLockDefaultsKey) as? Bool ?? true
        lock = AppLockPolicy(isEnabled: enabled)
        // Issue #66: the first load migrates the old single profile, with its pin, to the list.
        let list = (try? serverStore.load()) ?? ServerList()
        serverList = list
        var book = defaults.data(forKey: Self.serverBookDefaultsKey)
            .flatMap { try? JSONDecoder().decode(ServerStateBook.self, from: $0) } ?? ServerStateBook()
        book.keep(only: Set(list.servers.map(\.id)))
        serverBook = book
        if let key = try? keyStore.loadKey() {
            deviceKey = key
            keyState = .ready
        }
    }

    /// The app on a device: the Keychain (Secure Enclave when present) and Application Support.
    static func live() -> AppModel {
        let serverStore: any ServerListStore = (try? FileServerListStore.applicationSupport())
            ?? InMemoryServerListStore()
        return AppModel(keyStore: KeychainDeviceKeyStore.system(), serverStore: serverStore,
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
        // One key serves all servers (issue #66). A new key gets a new slot on each server, so a new slot port.
        var list = serverList
        list.modifyAll { $0.servePort = nil }
        commitQuietly(list)
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

    // MARK: Servers (issue #66)

    /// Setup and Settings: save the active server. With no server, the profile becomes the first server.
    /// A different server (host, port or user) loses the pin, so the owner must trust it again.
    /// It also loses the port pin and the last SSH algorithms: they belong to the old server.
    func saveProfile(_ profile: ServerProfile) throws {
        guard let active = self.profile else {
            try addServer(profile)
            return
        }
        var profile = profile
        profile.id = active.id
        try updateServer(profile)
    }

    /// "Add Server": save a new server at the end of the list. It becomes the active server
    /// (orchestrator decision 2026-11-17), so the old connection closes. The device key stays.
    func addServer(_ profile: ServerProfile) throws {
        var list = serverList
        try list.add(profile)
        let old = self.profile?.id
        try commit(list)
        if old != nil {
            resetConnection(ServerChange(from: old, to: profile.id))
        } else {
            // Issue #84: the first server. Nothing to close, but the lists take its cache folder.
            onActiveServerChange?(ServerChange(from: nil, to: profile.id))
        }
    }

    /// Server detail "Done": save one server. Other servers do not change.
    func updateServer(_ profile: ServerProfile) throws {
        var list = serverList
        let change = try list.update(profile)
        try commit(list)
        if change == .newServer, profile.id == self.profile?.id {
            resetConnection(ServerChange(from: profile.id, to: profile.id))
        }
    }

    /// "Remove Server": forget the server and its pin. The device key stays. If it was the active server,
    /// the connection closes and the first other server becomes active. No server left: "Set Up Hermes".
    func removeServer(id: UUID) throws {
        let wasActive = profile?.id == id
        guard let removed = serverList.server(id: id) else { return }
        var list = serverList
        list.remove(id: id)
        try commit(list)
        var book = serverBook
        book.keep(only: Set(list.servers.map(\.id)))
        saveBook(book)
        if wasActive { resetConnection(ServerChange(from: id, to: list.active?.id)) }
        onServerRemoved?(removed)
    }

    // MARK: Switch (issue #83)

    /// The owner picked a server in the title menu. Save the active id, close the old link fully, then connect
    /// the new server. Fast switches end on the last choice: an earlier switch does not connect.
    func switchServer(to id: UUID) async {
        guard id != profile?.id, serverList.server(id: id) != nil else { return }
        let old = profile?.id
        var list = serverList
        list.activate(id: id)
        commitQuietly(list)
        resetConnection(ServerChange(from: old, to: id))
        switchCount += 1
        let mine = switchCount
        await pendingClose?.value
        guard mine == switchCount, profile?.id == id else { return }
        await connect()
    }

    /// Keep the state of a server that is not active now. The app calls it on a switch.
    func recordServerState(_ state: ServerStateBook.Entry, for id: UUID) {
        guard serverList.server(id: id) != nil else { return }
        var book = serverBook
        guard book.record(state, for: id) else { return }
        saveBook(book)
    }

    /// The server menu of the Chats and Jobs titles. `activeChats`: the live unread chats of the active server.
    func serverMenu(activeChats: Int) -> ServerMenu {
        ServerMenu(list: serverList, book: serverBook, activeChats: activeChats)
    }

    /// The app icon badge: the unread chats of all servers. Issue #122: cron runs do not count.
    func badgeCount(_ sessions: SessionListModel) -> Int {
        serverBook.badgeCount(activeID: profile?.id, activeCount: sessions.chatsUnreadCount)
    }

    private func saveBook(_ book: ServerStateBook) {
        guard book != serverBook else { return }
        serverBook = book
        defaults.set(try? JSONEncoder().encode(book), forKey: Self.serverBookDefaultsKey)
    }

    /// True when a saved server other than `excluding` has the same host, port and user.
    func containsServer(like profile: ServerProfile, excluding: UUID? = nil) -> Bool {
        serverList.containsServer(like: profile, excluding: excluding)
    }

    /// Save the list, then keep it in memory. A save that fails throws and changes nothing.
    private func commit(_ list: ServerList) throws {
        try serverStore.save(list)
        serverList = list
    }

    /// Keep the list in memory, and save it. A save that fails keeps the change in memory: the next change tries again.
    private func commitQuietly(_ list: ServerList) {
        guard list != serverList else { return }
        serverList = list
        try? serverStore.save(list)
    }

    /// The active server changed, or its host, port or user changed. Close the old connection.
    /// The token belongs to the old server. Settings connects again when it closes.
    /// Issue #83: the app resets its lists first. The next connect waits until the old link is closed.
    private func resetConnection(_ change: ServerChange) {
        pendingTrust = nil
        showsHostKeyError = false
        showsHermesStartError = false
        connection = .idle
        attempt += 1
        serveToken = nil
        let old = (session, hermes)
        session = nil
        hermes = nil
        hermesEndpoint = nil
        onActiveServerChange?(change)
        let previous = pendingClose
        pendingClose = Task {
            await previous?.value
            await old.1?.forward.close()
            await old.0?.close()
        }
    }

    // MARK: Connection

    /// Connect with the pinned host key, run the gate `ping`, then start or reuse Hermes (issue #4).
    /// No pin: show the trust sheet. A changed key: show the error screen. The app never authenticates in those cases.
    func connect() async {
        guard isSetUp, !isConnecting, pendingTrust == nil else { return }
        await closeSession()
        // Issue #83: the active server can change while the old link closes. Read it after the close.
        guard let profile, let deviceKey, !isConnecting, pendingTrust == nil else { return }
        let serverID = profile.id
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
                updateServer(id: serverID) { $0.lastAlgorithms = algorithms }
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
            updateServer(id: serverID) { $0.servePort = pinsPort ? running.remotePort : nil }
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
        guard let key = pendingTrust, let profile else { return }
        var list = serverList
        list.modify(id: profile.id) { $0.hostKey = key }
        do {
            try commit(list)
        } catch {
            pendingTrust = nil
            connection = .offline(nil)
            return
        }
        pendingTrust = nil
        connection = .idle
        await connect()
    }

    /// The owner tapped "Cancel" on the trust sheet. Stop the connect and show "Offline".
    func cancelTrust() {
        pendingTrust = nil
        connection = .offline(nil)
    }

    /// Delete the pin of one server (the active server when `id` is nil). The next connect to that server
    /// asks the owner to trust it again. The pins of other servers stay.
    func forgetHostKey(id: UUID? = nil) async throws {
        guard let target = id ?? profile?.id, serverList.server(id: target) != nil else { return }
        var list = serverList
        list.modify(id: target) { $0.hostKey = nil }
        try commit(list)
        // The port pin stays: it belongs to the device key slot, not to the host key (issue #18).
        guard target == profile?.id else { return }
        showsHostKeyError = false
        await disconnect()
    }

    /// Change one saved server. A save that fails keeps the change in memory: the next change tries again.
    private func updateServer(id: UUID, _ change: (inout ServerProfile) -> Void) {
        var list = serverList
        list.modify(id: id, change)
        commitQuietly(list)
    }

    // MARK: Background refresh of another server (issue #84)

    /// Connect to a server that is not active, run `body` with its Hermes endpoint, then close that link.
    /// - The active server stays active. Its link closes first: one link at a time (owner decision on #66).
    /// - A server with no pin, a changed host key, or any error is skipped. Nothing asks the owner in the background.
    /// - A connect of the active server waits until this link is closed.
    func withBackgroundLink(to id: UUID, _ body: @escaping @MainActor (GatewayEndpoint) async -> Bool) async -> Bool {
        guard isSetUp, id != profile?.id, let server = serverList.server(id: id), server.hostKey != nil,
              let deviceKey else { return false }
        await disconnect()
        let connector = self.connector
        let serve = self.serve
        let previous = pendingClose
        let work = Task { @MainActor [weak self] () -> Bool in
            await previous?.value
            guard !Task.isCancelled,
                  let result = try? await connector.connect(profile: server, key: deviceKey) else { return false }
            var ok = false
            let pinsPort = ServeBootstrap.pinsPort(gateVersion: result.gateVersion)
            if !Task.isCancelled,
               let running = try? await serve.start(on: result.session, reuse: nil,
                                                    pinnedPort: pinsPort ? server.servePort : nil) {
                self?.updateServer(id: id) { $0.servePort = pinsPort ? running.remotePort : nil }
                ok = await body(running.endpoint)
                await running.forward.close()
            }
            await result.session.close()
            return ok
        }
        pendingClose = Task { _ = await work.value }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
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

    private var isConnecting: Bool { connection == .connecting || connection == .startingHermes }

    private func closeSession() async {
        // Issue #83: the link of the old server closes fully before a new connect starts.
        await pendingClose?.value
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
        let profiles = InMemoryServerListStore(profile: setUp ? ServerProfile(host: "vps.example.com", hostKey: hostKey) : nil)
        if setUp { _ = try? keyStore.createKey() }
        return AppModel(keyStore: keyStore, serverStore: profiles,
                        defaults: UserDefaults(suiteName: "preview") ?? .standard, deviceName: "iPhone",
                        transport: transport, serve: ServeBootstrap(loader: http))
    }

    /// Issue #66: a model with many servers, for previews and screenshots.
    static func preview(servers: [ServerProfile], activeIndex: Int) -> AppModel {
        let keyStore = KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: SoftwareKeyFactory())
        _ = try? keyStore.createKey()
        let active = servers.indices.contains(activeIndex) ? servers[activeIndex].id : nil
        return AppModel(keyStore: keyStore, serverStore: InMemoryServerListStore(ServerList(servers: servers, activeID: active)),
                        defaults: UserDefaults(suiteName: "preview") ?? .standard, deviceName: "iPhone",
                        transport: ScriptedSSHTransport(hostKey: .sample), serve: ServeBootstrap(loader: ScriptedHermesHTTP()))
    }

    /// Set a connection state directly, for previews and screenshots.
    func previewConnection(_ state: ConnectionState, pendingTrust: HostKey? = nil) {
        connection = state
        self.pendingTrust = pendingTrust
    }
}
