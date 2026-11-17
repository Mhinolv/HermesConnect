import Foundation
import HermesKit
import Testing
@testable import HermesConnect

@MainActor
@Test func appLaunchesRootView() {
    _ = RootView()
}

private struct FailingKeyStore: DeviceKeyStore {
    struct Failure: Error {}
    func loadKey() throws -> DeviceKey? { nil }
    func createKey() throws -> DeviceKey { throw Failure() }
    func deleteKey() throws {}
}

@MainActor
@Suite struct AppModelTests {
    private func makeModel(keyStore: (any DeviceKeyStore)? = nil,
                           profile: ServerProfile? = nil,
                           defaults: UserDefaults? = nil) -> AppModel {
        let store = keyStore ?? KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: SoftwareKeyFactory())
        let suite = defaults ?? UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return AppModel(keyStore: store, profileStore: InMemoryServerProfileStore(profile),
                        defaults: suite, deviceName: "Test iPhone")
    }

    @Test func firstRunIsNotSetUp() {
        let model = makeModel()
        #expect(!model.isSetUp)
        #expect(model.keyState == .none)
        #expect(model.installGuide == nil)
    }

    @Test func setupCreatesKeyAndSavesProfile() async throws {
        let model = makeModel()
        await model.ensureKey()
        #expect(model.keyState == .ready)
        #expect(!model.isSetUp)
        try model.saveProfile(ServerProfile(host: "vps.example.com"))
        #expect(model.isSetUp)
        let line = try #require(model.openSSHKey?.line)
        #expect(line.hasPrefix("ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABB"))
        #expect(line.hasSuffix(" hermesconnect@Test-iPhone"))
        #expect(model.installGuide?.authorizedKeysLine.hasSuffix(line) == true)
    }

    @Test func ensureKeyKeepsTheExistingKey() async throws {
        let model = makeModel()
        await model.ensureKey()
        let first = model.openSSHKey
        await model.ensureKey()
        #expect(model.openSSHKey == first)
    }

    @Test func resetMakesANewKey() async throws {
        let model = makeModel()
        await model.ensureKey()
        let old = try #require(model.openSSHKey)
        await model.resetKey()
        #expect(model.keyState == .ready)
        #expect(model.openSSHKey != old)
    }

    @Test func keyFailureShowsFailedState() async {
        let model = makeModel(keyStore: FailingKeyStore())
        await model.ensureKey()
        #expect(model.keyState == .failed)
        #expect(model.deviceKey == nil)
    }

    @Test func appLockIsOnByDefaultAndLockedOnLaunch() {
        let model = makeModel()
        #expect(model.lock.isEnabled)
        #expect(model.lock.isLocked)
    }

    @Test func appLockToggleIsSavedAndUnlocks() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let model = makeModel(defaults: defaults)
        model.setAppLockEnabled(false)
        #expect(!model.lock.isLocked)
        let relaunched = makeModel(defaults: defaults)
        #expect(!relaunched.lock.isEnabled)
        #expect(!relaunched.lock.isLocked)
    }

    @Test func relockAfterFiveMinutesInBackground() {
        let model = makeModel()
        model.unlockSucceeded()
        let start = Date()
        model.didEnterBackground(at: start)
        model.willEnterForeground(at: start.addingTimeInterval(60))
        #expect(!model.lock.isLocked)
        model.didEnterBackground(at: start)
        model.willEnterForeground(at: start.addingTimeInterval(301))
        #expect(model.lock.isLocked)
    }
}
