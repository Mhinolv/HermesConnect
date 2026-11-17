import Foundation
import Testing
@testable import HermesKit

/// Issue #66: more than one Hermes server. One device key, one pin for each server.
@Suite struct ServerListTests {
    private let algorithms = SSHNegotiatedAlgorithms(cipher: "aes256-gcm@openssh.com", keyExchange: "curve25519-sha256")

    private func pinned(_ host: String, key: HostKey = .sample) -> ServerProfile {
        ServerProfile(host: host, hostKey: key, servePort: 41_001, lastAlgorithms: algorithms)
    }

    @Test func emptyListHasNoActiveServer() {
        let list = ServerList()
        #expect(list.isEmpty)
        #expect(list.active == nil)
    }

    @Test func addAppendsInOrderAndMakesTheNewServerActive() throws {
        var list = ServerList()
        let first = pinned("one.example.com")
        let second = ServerProfile(host: "two.example.com", displayName: "Lab")
        try list.add(first)
        #expect(list.active?.id == first.id)
        try list.add(second)
        #expect(list.servers.map(\.host) == ["one.example.com", "two.example.com"])
        #expect(list.active?.id == second.id)
        #expect(list.server(id: first.id)?.hostKey == .sample, "the first pin stays")
    }

    @Test(arguments: [
        ServerProfile(host: "one.example.com"),
        ServerProfile(host: "ONE.example.com"),
        ServerProfile(host: " one.example.com "),
    ])
    func addRefusesTheSameHostPortAndUser(profile: ServerProfile) throws {
        var list = ServerList()
        try list.add(pinned("one.example.com"))
        #expect(throws: ServerList.Failure.duplicate) { try list.add(profile) }
        #expect(list.servers.count == 1)
    }

    @Test func anotherPortIsAnotherServer() throws {
        var list = ServerList()
        try list.add(pinned("one.example.com"))
        try list.add(ServerProfile(host: "one.example.com", port: 2222))
        #expect(list.servers.count == 2)
        #expect(list.containsServer(like: ServerProfile(host: "one.example.com", port: 2222)))
        #expect(!list.containsServer(like: ServerProfile(host: "one.example.com", port: 2223)))
    }

    @Test func renameKeepsThePinAndChangesNoOtherServer() throws {
        var list = ServerList()
        let first = pinned("one.example.com")
        let second = pinned("two.example.com", key: .otherSample)
        try list.add(first)
        try list.add(second)
        var renamed = first
        renamed.displayName = "Home"
        #expect(try list.update(renamed) == .sameServer)
        #expect(list.server(id: first.id)?.name == "Home")
        #expect(list.server(id: first.id)?.hostKey == .sample)
        #expect(list.server(id: first.id)?.servePort == 41_001)
        #expect(list.server(id: second.id) == second)
        #expect(list.active?.id == second.id, "an edit does not switch")
    }

    @Test(arguments: [("other.example.com", 22, "hermes"), ("one.example.com", 2222, "hermes"),
                      ("one.example.com", 22, "root")])
    func newHostPortOrUserClearsOnlyThatPin(host: String, port: Int, user: String) throws {
        var list = ServerList()
        let first = pinned("one.example.com")
        let second = pinned("two.example.com", key: .otherSample)
        try list.add(first)
        try list.add(second)
        var moved = first
        moved.host = host
        moved.port = port
        moved.user = user
        #expect(try list.update(moved) == .newServer)
        let saved = try #require(list.server(id: first.id))
        #expect(saved.hostKey == nil)
        #expect(saved.servePort == nil)
        #expect(saved.lastAlgorithms == nil)
        #expect(list.server(id: second.id)?.hostKey == .otherSample)
    }

    @Test func updateRefusesAnUnknownIdAndADuplicate() throws {
        var list = ServerList()
        let first = pinned("one.example.com")
        try list.add(first)
        try list.add(pinned("two.example.com"))
        #expect(throws: ServerList.Failure.notFound) { try list.update(ServerProfile(host: "x.example.com")) }
        var clash = first
        clash.host = "two.example.com"
        #expect(throws: ServerList.Failure.duplicate) { try list.update(clash) }
        #expect(list.server(id: first.id)?.host == "one.example.com")
    }

    @Test func removeOneServerKeepsTheOthers() throws {
        var list = ServerList()
        let first = pinned("one.example.com")
        let second = pinned("two.example.com", key: .otherSample)
        let third = pinned("three.example.com")
        for server in [first, second, third] { try list.add(server) }
        list.activate(id: first.id)
        list.remove(id: second.id)
        #expect(list.servers.map(\.id) == [first.id, third.id])
        #expect(list.active?.id == first.id, "removing another server does not switch")
    }

    @Test func removeTheActiveServerMakesTheFirstOtherServerActive() throws {
        var list = ServerList()
        let first = pinned("one.example.com")
        let second = pinned("two.example.com")
        try list.add(first)
        try list.add(second)
        list.remove(id: second.id)
        #expect(list.active?.id == first.id)
        list.remove(id: first.id)
        #expect(list.isEmpty)
        #expect(list.active == nil)
        #expect(list.activeID == nil)
    }

    @Test func activateIgnoresAnUnknownId() throws {
        var list = ServerList()
        let first = pinned("one.example.com")
        try list.add(first)
        list.activate(id: UUID())
        #expect(list.active?.id == first.id)
    }

    @Test func modifyAllClearsEveryPortPinAndKeepsThePins() throws {
        var list = ServerList()
        try list.add(pinned("one.example.com"))
        try list.add(pinned("two.example.com", key: .otherSample))
        list.modifyAll { $0.servePort = nil }
        #expect(list.servers.allSatisfy { $0.servePort == nil })
        #expect(list.servers.map(\.hostKey) == [.sample, .otherSample])
    }

    @Test func nameFallsBackToTheHost() {
        #expect(ServerProfile(host: "h.example.com", displayName: "  ").name == "h.example.com")
        #expect(ServerProfile(host: "h.example.com", displayName: "Box").name == "Box")
    }

    @Test func roundTripKeepsIdsPinsAndTheActiveServer() throws {
        var list = ServerList()
        try list.add(pinned("one.example.com"))
        try list.add(pinned("two.example.com", key: .otherSample))
        let decoded = try JSONDecoder().decode(ServerList.self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
    }

    @Test func decodeDropsABadEntryAndADanglingActiveId() throws {
        let good = UUID()
        let json = #"{"version":1,"activeID":"\#(UUID().uuidString)","servers":[7,"#
            + #"{"id":"\#(good.uuidString)","host":"one.example.com"}]}"#
        let list = try JSONDecoder().decode(ServerList.self, from: Data(json.utf8))
        #expect(list.servers.map(\.id) == [good])
        #expect(list.active?.id == good)
    }

    @Test func decodeOfAnEmptyObjectIsAnEmptyList() throws {
        let list = try JSONDecoder().decode(ServerList.self, from: Data("{}".utf8))
        #expect(list.isEmpty)
    }
}

/// Issue #66: `servers.json`, and the migration of `server-profile.json` from builds before #66.
@Suite struct FileServerListStoreTests {
    private struct Files {
        let dir: URL
        var store: FileServerListStore {
            FileServerListStore(fileURL: dir.appending(path: "HermesConnect/servers.json"),
                                legacyURL: dir.appending(path: "HermesConnect/server-profile.json"))
        }
        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeFiles() -> Files {
        Files(dir: FileManager.default.temporaryDirectory.appending(path: "hk-servers-\(UUID().uuidString)"))
    }

    /// The bytes of `server-profile.json` as the build before #66 writes them (version 3, sorted keys, no id).
    private func legacyJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let key = try #require(String(data: encoder.encode(HostKey.sample), encoding: .utf8))
        return #"{"displayName":"vps.example.com","host":"vps.example.com","hostKey":\#(key),"#
            + #""lastAlgorithms":{"cipher":"aes256-gcm@openssh.com","keyExchange":"curve25519-sha256"},"#
            + #""port":2222,"servePort":47123,"user":"hermes","version":3}"#
    }

    private func writeLegacy(_ files: Files, _ json: String) throws {
        let url = files.store.legacyURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    @Test func noFilesIsAnEmptyList() throws {
        let files = makeFiles()
        defer { files.remove() }
        #expect(try files.store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: files.store.fileURL.path), "load writes nothing")
    }

    @Test func migrationKeepsThePinPortPinAndAlgorithms() throws {
        let files = makeFiles()
        defer { files.remove() }
        try writeLegacy(files, legacyJSON())

        let list = try files.store.load()
        let server = try #require(list.active)
        #expect(list.servers.count == 1)
        #expect(server.id == ServerProfile.legacyID)
        #expect(server.host == "vps.example.com")
        #expect(server.port == 2222)
        #expect(server.user == "hermes")
        #expect(server.name == "vps.example.com")
        #expect(server.hostKey == .sample, "no new host-key prompt")
        #expect(server.servePort == 47_123, "the gate slot port stays, so the gate does not refuse the connect")
        #expect(server.lastAlgorithms?.cipher == "aes256-gcm@openssh.com")
    }

    /// Owner rule: never reset the connection. An older build still reads the old file after the migration.
    @Test func migrationWritesTheListAndKeepsTheOldFileAsItIs() throws {
        let files = makeFiles()
        defer { files.remove() }
        try writeLegacy(files, legacyJSON())
        _ = try files.store.load()
        #expect(FileManager.default.fileExists(atPath: files.store.fileURL.path))
        #expect(try String(contentsOf: files.store.legacyURL, encoding: .utf8) == legacyJSON())
    }

    @Test func aSecondLaunchDoesNotMigrateAgain() throws {
        let files = makeFiles()
        defer { files.remove() }
        try writeLegacy(files, legacyJSON())
        var list = try files.store.load()
        try list.add(ServerProfile(host: "lab.example.com"))
        try files.store.save(list)
        // An older build changes the old file. The new build still reads `servers.json` only.
        try writeLegacy(files, #"{"version":3,"host":"changed.example.com"}"#)
        #expect(try files.store.load() == list)
        #expect(try files.store.load().servers.map(\.host) == ["vps.example.com", "lab.example.com"])
    }

    @Test func aPinChangeOfTheLegacyServerGoesToTheOldFile() throws {
        let files = makeFiles()
        defer { files.remove() }
        try writeLegacy(files, legacyJSON())
        var list = try files.store.load()
        list.modify(id: ServerProfile.legacyID) { $0.hostKey = .otherSample }
        try files.store.save(list)
        let old = try #require(try FileServerProfileStore(fileURL: files.store.legacyURL).load())
        #expect(old.hostKey == .otherSample)
        #expect(old.host == "vps.example.com")
        #expect(old.servePort == 47_123)
    }

    @Test func otherChangesLeaveTheOldFileAsItIs() throws {
        let files = makeFiles()
        defer { files.remove() }
        try writeLegacy(files, legacyJSON())
        var list = try files.store.load()
        try list.add(ServerProfile(host: "lab.example.com", hostKey: .otherSample))
        list.modify(id: ServerProfile.legacyID) {
            $0.lastAlgorithms = SSHNegotiatedAlgorithms(cipher: "chacha20-poly1305@openssh.com", keyExchange: "x")
        }
        try files.store.save(list)
        list.remove(id: ServerProfile.legacyID)
        try files.store.save(list)
        #expect(try String(contentsOf: files.store.legacyURL, encoding: .utf8) == legacyJSON())
    }

    @Test func aNewInstallWritesNoOldFile() throws {
        let files = makeFiles()
        defer { files.remove() }
        var list = ServerList()
        try list.add(ServerProfile(id: ServerProfile.legacyID, host: "h.example.com"))
        try files.store.save(list)
        #expect(!FileManager.default.fileExists(atPath: files.store.legacyURL.path))
    }

    @Test func twoMigrationsGiveTheSameId() throws {
        let one = makeFiles()
        let two = makeFiles()
        defer { one.remove(); two.remove() }
        try writeLegacy(one, legacyJSON())
        try writeLegacy(two, legacyJSON())
        #expect(try one.store.load() == two.store.load())
    }

    @Test func migrationOfAVersionOneFileWithNoPin() throws {
        let files = makeFiles()
        defer { files.remove() }
        try writeLegacy(files, #"{"version":1,"host":"old.example.com","port":22,"user":"hermes","displayName":"Box"}"#)
        let server = try #require(files.store.load().active)
        #expect(server.name == "Box")
        #expect(server.hostKey == nil)
    }

    @Test func theNewFileWinsOverAnOldFile() throws {
        let files = makeFiles()
        defer { files.remove() }
        var list = ServerList()
        try list.add(ServerProfile(host: "new.example.com"))
        try files.store.save(list)
        try writeLegacy(files, legacyJSON())
        #expect(try files.store.load() == list)
    }

    @Test func removingTheLastServerDoesNotBringBackTheOldProfile() throws {
        let files = makeFiles()
        defer { files.remove() }
        try writeLegacy(files, legacyJSON())
        var list = try files.store.load()
        list.remove(id: ServerProfile.legacyID)
        try files.store.save(list)
        #expect(try files.store.load().isEmpty)
    }

    @Test func aBadOldFileThrowsAndStays() throws {
        let files = makeFiles()
        defer { files.remove() }
        try writeLegacy(files, "not json")
        #expect(throws: (any Error).self) { try files.store.load() }
        #expect(FileManager.default.fileExists(atPath: files.store.legacyURL.path))
    }

    @Test func saveThenLoadRoundTripsManyServers() throws {
        let files = makeFiles()
        defer { files.remove() }
        var list = ServerList()
        try list.add(ServerProfile(host: "one.example.com", hostKey: .sample))
        try list.add(ServerProfile(host: "two.example.com", port: 2222, displayName: "Lab", hostKey: .otherSample))
        try files.store.save(list)
        #expect(try files.store.load() == list)
        let json = try String(contentsOf: files.store.fileURL, encoding: .utf8)
        #expect(json.contains(#""activeID""#))
    }

    @Test func inMemoryStoreCanFailSaves() throws {
        let store = InMemoryServerListStore(profile: ServerProfile(host: "h"))
        store.failsSaves = true
        #expect(throws: InMemoryServerListStore.SaveFailure.self) { try store.save(ServerList()) }
        #expect(try store.load().servers.count == 1)
    }
}
