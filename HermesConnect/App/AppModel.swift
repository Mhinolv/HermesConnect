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

    private(set) var profile: ServerProfile?
    private(set) var deviceKey: DeviceKey?
    private(set) var keyState: KeyState = .none
    private(set) var lock: AppLockPolicy

    @ObservationIgnored private let keyStore: any DeviceKeyStore
    @ObservationIgnored private let profileStore: any ServerProfileStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let deviceName: String

    static let appLockDefaultsKey = "appLockEnabled"

    init(keyStore: any DeviceKeyStore, profileStore: any ServerProfileStore,
         defaults: UserDefaults = .standard, deviceName: String) {
        self.keyStore = keyStore
        self.profileStore = profileStore
        self.defaults = defaults
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
                        deviceName: UIDevice.current.name)
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

    func saveProfile(_ profile: ServerProfile) throws {
        try profileStore.save(profile)
        self.profile = profile
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
    static func preview(setUp: Bool) -> AppModel {
        let keyStore = KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: SoftwareKeyFactory())
        let profiles = InMemoryServerProfileStore(setUp ? ServerProfile(host: "vps.example.com") : nil)
        if setUp { _ = try? keyStore.createKey() }
        return AppModel(keyStore: keyStore, profileStore: profiles,
                        defaults: UserDefaults(suiteName: "preview") ?? .standard, deviceName: "iPhone")
    }
}
