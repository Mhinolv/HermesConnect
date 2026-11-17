import Foundation
import Testing
@testable import HermesKit

@Suite struct ServerProfileTests {
    @Test func defaults() {
        let profile = ServerProfile(host: "  vps.example.com ")
        #expect(profile.host == "vps.example.com")
        #expect(profile.port == 22)
        #expect(profile.user == "hermes")
        #expect(profile.displayName == "vps.example.com")
        #expect(profile.version == ServerProfile.currentVersion)
        #expect(profile.isValid)
    }

    @Test(arguments: ["", "   ", "user@host", "ssh://host", "a b", "host/path"])
    func invalidHosts(host: String) {
        #expect(!ServerProfile.isValidHost(host))
    }

    @Test(arguments: ["vps.example.com", "203.0.113.7", "2001:db8::1", "hermes"])
    func validHosts(host: String) {
        #expect(ServerProfile.isValidHost(host))
    }

    @Test(arguments: [(0, false), (1, true), (22, true), (65535, true), (65536, false), (-1, false)])
    func ports(port: Int, valid: Bool) {
        #expect(ServerProfile.isValidPort(port) == valid)
    }

    @Test func decodeFillsMissingFieldsWithDefaults() throws {
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(#"{"host":"h"}"#.utf8))
        #expect(profile == ServerProfile(host: "h"))
    }

    /// Issue #18: a version 2 file has no port pin and no algorithms. It still loads.
    @Test func versionTwoFileLoadsWithoutPinAndAlgorithms() throws {
        let json = #"{"version":2,"host":"h","port":22,"user":"hermes","displayName":"h"}"#
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        #expect(profile.host == "h")
        #expect(profile.servePort == nil)
        #expect(profile.lastAlgorithms == nil)
    }

    @Test func portPinAndAlgorithmsRoundTrip() throws {
        let pair = SSHNegotiatedAlgorithms(cipher: "aes256-gcm@openssh.com", keyExchange: "curve25519-sha256")
        let profile = ServerProfile(host: "h", hostKey: .sample, servePort: 47_123, lastAlgorithms: pair)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        #expect(decoded.version == 3)
    }

    @Test func badPortPinAndAlgorithmsReadAsNone() throws {
        let json = #"{"version":3,"host":"h","servePort":70000,"lastAlgorithms":{"cipher":1}}"#
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        #expect(profile.servePort == nil)
        #expect(profile.lastAlgorithms == nil)
    }

    @Test func decodeKeepsUnknownFieldsHarmless() throws {
        let json = #"{"version":1,"host":"h","port":2222,"user":"hermes","displayName":"Box","future":true}"#
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        #expect(profile.port == 2222)
        #expect(profile.displayName == "Box")
    }
}

@Suite struct FileServerProfileStoreTests {
    private func makeStore() -> FileServerProfileStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hk-profile-\(UUID().uuidString)")
        return FileServerProfileStore(fileURL: dir.appending(path: "HermesConnect/server-profile.json"))
    }

    @Test func loadReturnsNilWhenNoFile() throws {
        #expect(try makeStore().load() == nil)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let profile = ServerProfile(host: "vps.example.com", port: 2222, displayName: "VPS")
        try store.save(profile)
        #expect(try store.load() == profile)
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains(#""port" : 2222"#))
    }

    @Test func deleteRemovesTheFile() throws {
        let store = makeStore()
        try store.save(ServerProfile(host: "h"))
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
    }
}

@Suite struct AppLockPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func lockedOnLaunchWhenEnabled() {
        #expect(AppLockPolicy(isEnabled: true).isLocked)
        #expect(!AppLockPolicy(isEnabled: false).isLocked)
    }

    @Test func unlockThenShortBackgroundStaysUnlocked() {
        var policy = AppLockPolicy(isEnabled: true)
        policy.unlockSucceeded()
        policy.didEnterBackground(at: start)
        policy.willEnterForeground(at: start.addingTimeInterval(299))
        #expect(!policy.isLocked)
    }

    @Test func backgroundForFiveMinutesLocks() {
        var policy = AppLockPolicy(isEnabled: true)
        policy.unlockSucceeded()
        policy.didEnterBackground(at: start)
        policy.willEnterForeground(at: start.addingTimeInterval(AppLockPolicy.relockInterval))
        #expect(policy.isLocked)
        #expect(policy.backgroundedAt == nil)
    }

    @Test func foregroundWithoutBackgroundDoesNotLock() {
        var policy = AppLockPolicy(isEnabled: true)
        policy.unlockSucceeded()
        policy.willEnterForeground(at: start.addingTimeInterval(10_000))
        #expect(!policy.isLocked)
    }

    @Test func disabledNeverLocks() {
        var policy = AppLockPolicy(isEnabled: false)
        policy.didEnterBackground(at: start)
        policy.willEnterForeground(at: start.addingTimeInterval(10_000))
        #expect(!policy.isLocked)
    }

    @Test func disableUnlocksAndEnableWaitsForNextReturn() {
        var policy = AppLockPolicy(isEnabled: true)
        policy.setEnabled(false)
        #expect(!policy.isLocked)
        policy.setEnabled(true)
        #expect(!policy.isLocked)
        policy.didEnterBackground(at: start)
        policy.willEnterForeground(at: start.addingTimeInterval(600))
        #expect(policy.isLocked)
    }
}
