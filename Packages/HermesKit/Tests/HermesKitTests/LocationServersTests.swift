import Foundation
import Testing
@testable import HermesKit

/// Issue #92: location goes only to the servers with "Share Location" on, never to the active server alone.
@Suite struct LocationServersTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func fix(_ lat: Double = 37.3349, at time: Date = t0) -> LocationFix {
        LocationFix(latitude: lat, longitude: -122.009, horizontalAccuracy: 10, timestamp: time)!
    }

    private struct Rig {
        let fanOut: LocationFanOut
        let servers: InMemoryServerListStore
        let settings: InMemoryLocationServerSettingsStore
        let uploaders: [UUID: ScriptedLocationUploader]
        let home: ServerProfile
        let team: ServerProfile

        func payloads(_ server: ServerProfile) -> Int { uploaders[server.id]?.payloads.count ?? 0 }
    }

    /// "Home" is the migrated server (sharing on from the old switch). "Ouro" is a new team server.
    private func make(legacyEnabled: Bool = true, failure: LocationUploadError? = nil) -> Rig {
        let home = ServerProfile(id: ServerProfile.legacyID, host: "100.64.0.1", displayName: "Home", hostKey: .sample)
        let team = ServerProfile(host: "100.64.0.2", displayName: "Ouro", hostKey: .otherSample)
        let servers = InMemoryServerListStore(ServerList(servers: [home, team], activeID: home.id))
        let settings = InMemoryLocationServerSettingsStore(.migrated(legacyEnabled: legacyEnabled))
        let uploaders = [home.id: ScriptedLocationUploader(), team.id: ScriptedLocationUploader(failure: failure)]
        let stores = [home.id: InMemoryLocationStateStore(), team.id: InMemoryLocationStateStore()]
        let fanOut = LocationFanOut(servers: servers, settings: settings,
                                    store: { stores[$0] ?? InMemoryLocationStateStore() },
                                    uploader: { uploaders[$0] ?? ScriptedLocationUploader(failure: .notSetUp) },
                                    now: { Self.t0 })
        return Rig(fanOut: fanOut, servers: servers, settings: settings, uploaders: uploaders, home: home, team: team)
    }

    private func activate(_ rig: Rig, _ server: ServerProfile) throws {
        var list = try rig.servers.load()
        list.activate(id: server.id)
        try rig.servers.save(list)
    }

    // Regression test (issue #92): a switch to a server with sharing off sends it no fix.
    @Test func aSwitchToAServerWithSharingOffSendsItNoFix() async throws {
        let rig = make()
        try activate(rig, rig.team)
        await rig.fanOut.submit(fix(), precision: .precise)
        #expect(rig.payloads(rig.team) == 0)
        #expect(rig.payloads(rig.home) == 1)
        await rig.fanOut.flush(precision: .precise)
        #expect(rig.payloads(rig.team) == 0)
    }

    @Test func aNewServerStartsWithSharingOff() {
        let settings = LocationServerSettings.migrated(legacyEnabled: true)
        #expect(settings.isSharing(ServerProfile.legacyID))
        #expect(!settings.isSharing(UUID()))
        #expect(LocationServerSettings().sharingIDs.isEmpty)
    }

    @Test func eachServerWithSharingOnGetsTheFixWhateverServerIsActive() async throws {
        let rig = make()
        var settings = rig.settings.load()
        settings.setSharing(true, server: rig.team.id)
        rig.settings.save(settings)
        try activate(rig, rig.team)
        let results = await rig.fanOut.submit(fix(), precision: .precise)
        #expect(results == [rig.home.id: .sent, rig.team.id: .sent])
        settings.setSharing(false, server: rig.home.id)
        rig.settings.save(settings)
        try activate(rig, rig.home)
        await rig.fanOut.submit(fix(38, at: Self.t0), precision: .precise, force: true)
        #expect(rig.payloads(rig.home) == 1)
        #expect(rig.payloads(rig.team) == 2)
    }

    @Test func noServerWithSharingOnSendsNothing() async {
        let rig = make(legacyEnabled: false)
        let results = await rig.fanOut.submit(fix(), precision: .precise, force: true)
        #expect(results.isEmpty)
        #expect(rig.payloads(rig.home) == 0)
        #expect(rig.payloads(rig.team) == 0)
    }

    @Test func aRemovedServerGetsNoFix() async throws {
        let rig = make()
        var list = try rig.servers.load()
        list.remove(id: rig.home.id)
        try rig.servers.save(list)
        // The id stays in the settings, but a removed server is never a target.
        #expect(rig.settings.load().isSharing(rig.home.id))
        #expect(await rig.fanOut.targets().isEmpty)
        await rig.fanOut.submit(fix(), precision: .precise, force: true)
        #expect(rig.payloads(rig.home) == 0)
    }

    @Test func eachServerHasItsOwnPendingFixAndRateLimit() async {
        let rig = make()
        var settings = rig.settings.load()
        settings.setSharing(true, server: rig.team.id)
        rig.settings.save(settings)
        rig.uploaders[rig.team.id]?.failure = .connection(.unreachable)
        let first = await rig.fanOut.submit(fix(), precision: .precise)
        #expect(first[rig.home.id] == .sent)
        #expect(first[rig.team.id] == .failed(.connection(.unreachable)))
        #expect(await rig.fanOut.status(server: rig.team.id).waitingForConnection)
        #expect(await !rig.fanOut.status(server: rig.home.id).waitingForConnection)
        // The team server comes back. Its pending fix goes. The home server rate limit holds a second fix.
        rig.uploaders[rig.team.id]?.failure = nil
        let second = await rig.fanOut.submit(fix(37.3350), precision: .precise)
        #expect(second[rig.home.id] == .deferred)
        #expect(second[rig.team.id] == .sent)
    }

    // A team server installed with `--no-location`: the gate refuses, sharing turns off, no second try.
    @Test func aGateThatRefusesLocationTurnsSharingOffWithNoLoop() async {
        let rig = make(failure: .connection(.gateError(LocationUploadError.locationOffCode)))
        var settings = rig.settings.load()
        settings.setSharing(true, server: rig.team.id)
        rig.settings.save(settings)
        let results = await rig.fanOut.submit(fix(), precision: .precise, force: true)
        #expect(results[rig.team.id] == .failed(.connection(.gateError("location-off"))))
        #expect(!rig.settings.load().isSharing(rig.team.id))
        #expect(rig.settings.load().isSharing(rig.home.id))
        let status = await rig.fanOut.status(server: rig.team.id)
        #expect(status.lastError == "This server does not accept location.")
        #expect(!status.waitingForConnection)
        await rig.fanOut.submit(fix(38), precision: .precise, force: true)
        await rig.fanOut.flush(precision: .precise)
        #expect(rig.payloads(rig.team) == 1)
        #expect(!LocationUploadError.connection(.gateError("location-off")).isRetryable)
    }

    @Test func combinedStatusShowsTheLatestUploadOfTheSharingServers() async {
        let rig = make()
        #expect(await rig.fanOut.combinedStatus() == LocationShareStatus())
        await rig.fanOut.submit(fix(), precision: .precise)
        #expect(await rig.fanOut.combinedStatus().lastSentAt == Self.t0)
    }

    // MARK: Migration and stores

    @Test func theOldSwitchGoesToTheMigratedServerOnly() throws {
        let defaults = try #require(UserDefaults(suiteName: "loc92-\(UUID().uuidString)"))
        defaults.set(true, forKey: DefaultsLocationServerSettingsStore.legacyEnabledKey)
        let store = DefaultsLocationServerSettingsStore(defaults: defaults)
        #expect(store.load().sharingIDs == [ServerProfile.legacyID])
        // The migration runs once. A later change stays, also when the old switch is still on.
        store.save(LocationServerSettings())
        #expect(DefaultsLocationServerSettingsStore(defaults: defaults).load().sharingIDs.isEmpty)
        #expect(defaults.bool(forKey: DefaultsLocationServerSettingsStore.legacyEnabledKey))
    }

    @Test func theOldSwitchOffMigratesToNoServer() throws {
        let defaults = try #require(UserDefaults(suiteName: "loc92-\(UUID().uuidString)"))
        let store = DefaultsLocationServerSettingsStore(defaults: defaults)
        #expect(store.load().sharingIDs.isEmpty)
        let id = UUID()
        var settings = store.load()
        settings.setSharing(true, server: id)
        store.save(settings)
        #expect(DefaultsLocationServerSettingsStore(defaults: defaults).load().sharingIDs == [id])
    }

    @Test func theMigratedServerKeepsTheOldStateFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "loc92-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacyURL = folder.appending(path: "location-state.json")
        FileLocationStateStore(fileURL: legacyURL).save(LocationShareState(lastSentAt: Self.t0))
        let legacy = FileLocationStateStore(server: ServerProfile.legacyID, folder: folder.appending(path: "Location"),
                                            legacyURL: legacyURL)
        #expect(legacy.load().lastSentAt == Self.t0)
        legacy.save(LocationShareState(lastSentAt: Self.t0.addingTimeInterval(60)))
        #expect(legacy.load().lastSentAt == Self.t0.addingTimeInterval(60))
        // The old file stays for an older build. A new server never reads it.
        #expect(FileLocationStateStore(fileURL: legacyURL).load().lastSentAt == Self.t0)
        let other = FileLocationStateStore(server: UUID(), folder: folder.appending(path: "Location"), legacyURL: legacyURL)
        #expect(other.load() == LocationShareState())
    }

    @Test func theServerUploaderConnectsToItsOwnServerNotTheActiveOne() async throws {
        let keys = KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: SoftwareKeyFactory())
        _ = try keys.createKey()
        let home = ServerProfile(id: ServerProfile.legacyID, host: "100.64.0.1", hostKey: .sample)
        let team = ServerProfile(host: "100.64.0.2", hostKey: .otherSample)
        let servers = InMemoryServerListStore(ServerList(servers: [home, team], activeID: team.id))
        // The fake server sends the home host key. The team pin does not match it, so a connect to the team
        // server fails before authentication.
        let transport = ScriptedSSHTransport(hostKey: .sample, pingReply: .success("PONG 3\n"))
        let uploader = GateLocationUploader.forServer(home.id, connector: HostConnector(transport: transport),
                                                      servers: servers, keys: keys)
        try await uploader.upload(LocationPayload.encode(fix(), precision: .precise))
        #expect(transport.record.commands == [.ping, .location])
        let removed = GateLocationUploader.forServer(UUID(), connector: HostConnector(transport: transport),
                                                     servers: servers, keys: keys)
        await #expect(throws: LocationUploadError.notSetUp) {
            try await removed.upload(Data("{}".utf8))
        }
    }
}
