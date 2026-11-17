import Foundation
import HermesKit
import Testing
@testable import HermesConnect

/// Issue #66: more than one server in the app model. One device key, one pin for each server.
@MainActor
@Suite struct ServerListAppTests {
    private struct Setup {
        let model: AppModel
        let store: InMemoryServerListStore
        let transport: ScriptedSSHTransport
        let keyStore: KeychainDeviceKeyStore
    }

    private func makeModel(_ servers: [ServerProfile], active: Int = 0, store: (any ServerListStore)? = nil) async -> Setup {
        let keyStore = KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: SoftwareKeyFactory())
        let list = ServerList(servers: servers, activeID: servers.indices.contains(active) ? servers[active].id : nil)
        let memory = InMemoryServerListStore(list)
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let serve = ServeBootstrap(loader: ScriptedHermesHTTP(),
                                   configuration: .init(serveTimeout: .seconds(5), healthAttempts: 1,
                                                        healthRetryDelay: .milliseconds(1)))
        let model = AppModel(keyStore: keyStore, serverStore: store ?? memory,
                             defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                             deviceName: "Test iPhone", transport: transport, serve: serve)
        await model.ensureKey()
        return Setup(model: model, store: memory, transport: transport, keyStore: keyStore)
    }

    private let home = ServerProfile(host: "home.example.com", displayName: "Home", hostKey: .sample)
    private let lab = ServerProfile(host: "lab.example.com", hostKey: .otherSample)

    /// The owner's phone today: one `server-profile.json` with a pin and a port pin. After the update the
    /// server shows in the list, is active, and connects with no trust sheet and the same device key.
    @Test func migratedServerConnectsWithNoNewSetupOrPrompt() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "app-servers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileServerListStore(fileURL: dir.appending(path: "servers.json"),
                                        legacyURL: dir.appending(path: "server-profile.json"))
        var old = ServerProfile(host: "vps.example.com", hostKey: .sample, servePort: 41_001)
        old.version = 3
        try FileServerProfileStore(fileURL: store.legacyURL).save(old)
        // The file of the build before #66 has no id.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.legacyURL)) as! [String: Any]
        json.removeValue(forKey: "id")
        try JSONSerialization.data(withJSONObject: json).write(to: store.legacyURL)

        let setup = await makeModel([], store: store)
        let key = setup.model.openSSHKey
        #expect(setup.model.isSetUp)
        #expect(setup.model.servers.count == 1)
        #expect(setup.model.profile?.id == ServerProfile.legacyID)
        setup.transport.pingReply = .success("PONG 2\n")
        await setup.model.connect()
        #expect(setup.model.pendingTrust == nil, "no new host-key prompt")
        #expect(setup.model.connection == .connected(gateVersion: "2"), "the gate accepts the saved slot port")
        #expect(setup.model.openSSHKey == key, "no new key")
        #expect(try store.load().active?.hostKey == .sample)
        #expect(FileManager.default.fileExists(atPath: store.legacyURL.path), "an older build still connects")
    }

    @Test func addServerKeepsTheFirstPinAndSwitchesToTheNewServer() async throws {
        let setup = await makeModel([home])
        await setup.model.connect()
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        let key = setup.model.openSSHKey
        try setup.model.addServer(lab)
        #expect(setup.model.servers.map(\.id) == [home.id, lab.id])
        #expect(setup.model.profile?.id == lab.id)
        #expect(setup.model.connection == .idle, "the old connection closes")
        #expect(setup.model.hermesEndpoint == nil)
        #expect(setup.model.openSSHKey == key, "one device key for all servers")
        #expect(try setup.store.load().server(id: home.id)?.hostKey == .sample)
    }

    @Test func addServerRefusesADuplicateAndChangesNothing() async throws {
        let setup = await makeModel([home])
        #expect(setup.model.containsServer(like: ServerProfile(host: "HOME.example.com")))
        #expect(throws: ServerList.Failure.duplicate) { try setup.model.addServer(ServerProfile(host: "home.example.com")) }
        #expect(setup.model.servers.count == 1)
    }

    @Test func editOfAnotherServerKeepsTheActiveConnection() async throws {
        let setup = await makeModel([home, lab])
        await setup.model.connect()
        var moved = lab
        moved.host = "lab2.example.com"
        try setup.model.updateServer(moved)
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(setup.model.serverList.server(id: lab.id)?.hostKey == nil, "a new host loses its pin")
        #expect(setup.model.serverList.server(id: home.id)?.hostKey == .sample)
    }

    @Test func renameOfTheActiveServerKeepsTheConnectionAndThePin() async throws {
        let setup = await makeModel([home, lab])
        await setup.model.connect()
        var renamed = home
        renamed.displayName = "Office"
        try setup.model.updateServer(renamed)
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(setup.model.profile?.name == "Office")
        #expect(setup.model.profile?.hostKey == .sample)
    }

    @Test func newHostOnTheActiveServerResetsTheConnection() async throws {
        let setup = await makeModel([home, lab])
        await setup.model.connect()
        var moved = home
        moved.host = "new.example.com"
        try setup.model.updateServer(moved)
        #expect(setup.model.connection == .idle)
        #expect(setup.model.profile?.hostKey == nil)
        #expect(setup.model.serverList.server(id: lab.id)?.hostKey == .otherSample)
    }

    @Test func removeAnotherServerKeepsTheConnection() async throws {
        let setup = await makeModel([home, lab])
        await setup.model.connect()
        try setup.model.removeServer(id: lab.id)
        #expect(setup.model.servers.map(\.id) == [home.id])
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(try setup.store.load().servers.count == 1)
    }

    @Test func removeTheActiveServerSwitchesToTheFirstOther() async throws {
        let setup = await makeModel([home, lab], active: 1)
        try setup.model.removeServer(id: lab.id)
        #expect(setup.model.profile?.id == home.id)
        #expect(setup.model.connection == .idle)
        #expect(setup.model.isSetUp)
    }

    @Test func removeTheLastServerReturnsToSetUpAndKeepsTheKey() async throws {
        let setup = await makeModel([home])
        let key = setup.model.openSSHKey
        try setup.model.removeServer(id: home.id)
        #expect(!setup.model.isSetUp, "the root shows Set Up Hermes")
        #expect(setup.model.profile == nil)
        #expect(setup.model.openSSHKey == key, "the device key stays")
        #expect(try setup.store.load().isEmpty)
    }

    @Test func aSaveThatFailsChangesNothing() async throws {
        let setup = await makeModel([home])
        setup.store.failsSaves = true
        #expect(throws: (any Error).self) { try setup.model.addServer(lab) }
        #expect(throws: (any Error).self) { try setup.model.removeServer(id: home.id) }
        #expect(setup.model.servers.map(\.id) == [home.id])
    }

    @Test func forgetHostKeyOfAnotherServerKeepsTheActivePinAndConnection() async throws {
        let setup = await makeModel([home, lab])
        await setup.model.connect()
        try await setup.model.forgetHostKey(id: lab.id)
        #expect(setup.model.serverList.server(id: lab.id)?.hostKey == nil)
        #expect(setup.model.profile?.hostKey == .sample)
        #expect(setup.model.connection == .connected(gateVersion: "1"))
    }

    @Test func trustSavesThePinOnTheActiveServerOnly() async throws {
        let setup = await makeModel([ServerProfile(host: "home.example.com"), lab])
        await setup.model.connect()
        #expect(setup.model.pendingTrust == .sample)
        await setup.model.trustPendingHostKey()
        #expect(setup.model.profile?.hostKey == .sample)
        #expect(setup.model.serverList.server(id: lab.id)?.hostKey == .otherSample)
    }

    @Test func resetDeviceKeyClearsThePortPinOfEveryServer() async throws {
        var first = home
        first.servePort = 41_001
        var second = lab
        second.servePort = 41_002
        let setup = await makeModel([first, second])
        await setup.model.resetKey()
        #expect(try setup.store.load().servers.allSatisfy { $0.servePort == nil })
        #expect(try setup.store.load().servers.map(\.hostKey) == [.sample, .otherSample], "the pins stay")
    }

    @Test func rowLabelNamesTheServerTheHostAndActive() {
        #expect(ServerRow.accessibilityLabel(server: home, isActive: true) == "Home, home.example.com, Active")
        #expect(ServerRow.accessibilityLabel(server: lab, isActive: false) == "lab.example.com")
    }

    @Test func removeDialogUsesTheServerName() {
        #expect(ServerDetailView.removeDialogTitle(home) == "Remove \u{201C}Home\u{201D}?")
        #expect(ServerDetailView.removeMessage
                == "This iPhone forgets the server, its host key and its chats. The chats stay on the server.")
    }
}
