import Foundation
import HermesKit
import Testing
import UIKit
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

@Suite struct AppLockTextTests {
    @Test(arguments: Authenticator.Biometry.allCases)
    func toggleFooterAndButtonUseOneName(biometry: Authenticator.Biometry) {
        let name = Authenticator.methodName(for: biometry)
        #expect(Authenticator.appLockToggleTitle(for: biometry) == "App Lock (\(name))")
        #expect(Authenticator.appLockFooter(for: biometry) == "Require \(name) when Hermes opens.")
        #expect(Authenticator.unlockButtonTitle(for: biometry) == "Unlock with \(name)")
    }

    @Test func passcodeOnlyWithoutBiometry() {
        #expect(Authenticator.methodName(for: .faceID) == "Face ID")
        #expect(Authenticator.methodName(for: .touchID) == "Touch ID")
        #expect(Authenticator.methodName(for: .opticID) == "Optic ID")
        #expect(Authenticator.methodName(for: .none) == "Passcode")
    }
}

@MainActor
@Suite struct ExactTextTests {
    private let key = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk= hermesconnect@iPhone"

    @Test func keepsExactCharactersAndTurnsOffHyphenation() throws {
        let text = ExactText.attributed(key, font: .monospacedSystemFont(ofSize: 13, weight: .regular), color: .label)
        #expect(text.string == key)
        let style = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.hyphenationFactor == 0)
        #expect(!style.usesDefaultHyphenation)
        #expect(style.lineBreakMode == .byCharWrapping)
    }

    @Test func wrappedLinesJoinToTheExactKey() {
        let storage = NSTextStorage(attributedString: ExactText.attributed(
            key, font: .monospacedSystemFont(ofSize: 13, weight: .regular), color: .label))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 160, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = NSLineBreakMode.byCharWrapping
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var lines: [String] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, range, _ in
            let chars = layout.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            lines.append((storage.string as NSString).substring(with: chars))
        }
        #expect(lines.count > 3)
        #expect(lines.joined() == key)
    }
}
