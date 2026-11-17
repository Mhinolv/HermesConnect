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
                        defaults: suite, deviceName: "Test iPhone",
                        transport: ScriptedSSHTransport(hostKey: .sample))
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
        #expect(model.installGuide?.authorizedKeysLine?.hasSuffix(line) == true)
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

@MainActor
@Suite struct ConnectionTests {
    private struct Setup {
        let model: AppModel
        let transport: ScriptedSSHTransport
        let profiles: InMemoryServerProfileStore
        let http: ScriptedHermesHTTP
        let keyStore: KeychainDeviceKeyStore
        let serve: ServeBootstrap

        /// A new model on the same stores and server: the app after a relaunch.
        @MainActor func relaunch() -> AppModel {
            AppModel(keyStore: keyStore, profileStore: profiles,
                     defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                     deviceName: "Test iPhone", transport: transport, serve: serve)
        }
    }

    private func makeModel(pin: HostKey? = nil, serverKey: HostKey = .sample,
                           failure: SSHConnectionError? = nil) async -> Setup {
        let keyStore = KeychainDeviceKeyStore(secrets: InMemorySecretStore(), factory: SoftwareKeyFactory())
        let profiles = InMemoryServerProfileStore(ServerProfile(host: "vps.example.com", hostKey: pin))
        let transport = ScriptedSSHTransport(hostKey: serverKey, connectFailure: failure)
        let http = ScriptedHermesHTTP()
        let serve = ServeBootstrap(loader: http, configuration: .init(serveTimeout: .seconds(5), healthAttempts: 1,
                                                                      healthRetryDelay: .milliseconds(1)))
        let model = AppModel(keyStore: keyStore, profileStore: profiles,
                             defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                             deviceName: "Test iPhone", transport: transport, serve: serve)
        await model.ensureKey()
        return Setup(model: model, transport: transport, profiles: profiles, http: http, keyStore: keyStore, serve: serve)
    }

    @Test func firstConnectAsksForTrustAndSavesNothing() async throws {
        let setup = await makeModel()
        await setup.model.connect()
        #expect(setup.model.pendingTrust == .sample)
        #expect(setup.model.connection == .connecting)
        #expect(setup.transport.record.authentications == 0)
        #expect(try setup.profiles.load()?.hostKey == nil)
    }

    @Test func trustSavesTheFullKeyAndConnects() async throws {
        let setup = await makeModel()
        await setup.model.connect()
        await setup.model.trustPendingHostKey()
        #expect(setup.model.pendingTrust == nil)
        #expect(try setup.profiles.load()?.hostKey == .sample)
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(setup.transport.record.authentications == 1)
        #expect(setup.transport.record.commands == [.ping, .serve])
    }

    @Test func cancelStopsTheConnectAndShowsOffline() async throws {
        let setup = await makeModel()
        await setup.model.connect()
        setup.model.cancelTrust()
        #expect(setup.model.pendingTrust == nil)
        #expect(setup.model.connection == .offline(nil))
        #expect(try setup.profiles.load()?.hostKey == nil)
        #expect(setup.transport.record.authentications == 0)
    }

    @Test func changedKeyBlocksAndShowsTheErrorScreen() async throws {
        let setup = await makeModel(pin: .sample, serverKey: .otherSample)
        await setup.model.connect()
        #expect(setup.model.connection == .hostKeyChanged(saved: .sample, received: .otherSample))
        #expect(setup.model.showsHostKeyError)
        #expect(setup.model.pendingTrust == nil)
        #expect(setup.transport.record.authentications == 0)
        #expect(try setup.profiles.load()?.hostKey == .sample)
    }

    @Test func forgetHostKeyAsksForTrustAgain() async throws {
        let setup = await makeModel(pin: .sample, serverKey: .otherSample)
        await setup.model.connect()
        try await setup.model.forgetHostKey()
        #expect(!setup.model.showsHostKeyError)
        #expect(setup.model.connection == .idle)
        #expect(try setup.profiles.load()?.hostKey == nil)
        await setup.model.connect()
        #expect(setup.model.pendingTrust == .otherSample)
    }

    @Test func networkFailureIsOffline() async {
        let setup = await makeModel(pin: .sample, failure: .unreachable)
        await setup.model.connect()
        #expect(setup.model.connection == .offline(.unreachable))
    }

    @Test func newServerLosesThePin() async throws {
        let setup = await makeModel(pin: .sample)
        await setup.model.connect()
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        var profile = try #require(setup.model.profile)
        profile.displayName = "Box"
        try setup.model.saveProfile(profile)
        #expect(setup.model.profile?.hostKey == .sample)
        profile.host = "other.example.com"
        try setup.model.saveProfile(profile)
        #expect(setup.model.profile?.hostKey == nil)
        #expect(setup.model.connection == .idle)
    }

    // MARK: Issue #4: Hermes serve bootstrap

    @Test func connectStartsHermesAndGivesTheLoopbackEndpoint() async throws {
        let setup = await makeModel(pin: .sample)
        await setup.model.connect()
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(setup.transport.record.commands == [.ping, .serve])
        #expect(setup.transport.record.forwardPorts == [41_001])
        let endpoint = try #require(setup.model.hermesEndpoint)
        #expect(endpoint.baseURL.host() == "127.0.0.1")
        #expect(setup.http.paths == ["/api/health", "/api/ssh/ownership"])
    }

    @Test func reconnectReusesTheServerWithTheSameToken() async throws {
        let setup = await makeModel(pin: .sample)
        await setup.model.connect()
        let first = try #require(setup.transport.record.stdins.last ?? nil)
        await setup.model.disconnect()
        #expect(setup.model.hermesEndpoint == nil)
        #expect(setup.transport.record.closedForwards == 1)
        await setup.model.connect()
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(setup.transport.record.stdins.last == first)
        #expect(setup.transport.record.spawns == 1)
        #expect(setup.transport.record.reuses == 1)
    }

    @Test func renewSendsANewToken() async throws {
        let setup = await makeModel(pin: .sample)
        await setup.model.connect()
        let first = try #require(setup.transport.record.stdins.last ?? nil)
        await setup.model.renewHermesSession()
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(setup.transport.record.stdins.last != first)
        #expect(setup.transport.record.spawns == 2)
    }

    /// Issue #29: a fixed-port gate (version 2) must print the slot port that the app saw before.
    @Test func fixedPortGateRefusesAChangedPortUntilResetDeviceKey() async throws {
        let setup = await makeModel(pin: .sample)
        setup.transport.pingReply = .success("PONG 2\n")
        await setup.model.connect()
        #expect(setup.model.connection == .connected(gateVersion: "2"))
        await setup.model.disconnect()

        setup.transport.serverAlive = false  // The fake gate spawns again on another port.
        await setup.model.connect()
        #expect(setup.model.connection == .notStarted(.gateError("port-changed")))
        #expect(setup.model.hermesEndpoint == nil)
        #expect(setup.transport.record.forwardPorts == [41_001], "no forward to the changed port")

        await setup.model.resetKey()
        await setup.model.connect()
        #expect(setup.model.connection == .connected(gateVersion: "2"))
    }

    /// Issue #18: the port pin is saved per profile, so a relaunch keeps it. Only Reset Device Key clears it.
    @Test func portPinSurvivesARelaunchAndForgetHostKey() async throws {
        let setup = await makeModel(pin: .sample)
        setup.transport.pingReply = .success("PONG 2\n")
        await setup.model.connect()
        #expect(setup.model.connection == .connected(gateVersion: "2"))
        #expect(try setup.profiles.load()?.servePort == 41_001)
        await setup.model.disconnect()

        let relaunched = setup.relaunch()
        setup.transport.serverAlive = false  // The fake gate spawns again on another port.
        await relaunched.connect()
        #expect(relaunched.connection == .notStarted(.gateError("port-changed")))

        try await relaunched.forgetHostKey()
        #expect(try setup.profiles.load()?.servePort == 41_001)

        await relaunched.resetKey()
        #expect(try setup.profiles.load()?.servePort == nil)
        #expect(relaunched.profile?.servePort == nil)
    }

    @Test func newServerClearsThePortPinAndTheAlgorithms() async throws {
        let setup = await makeModel(pin: .sample)
        setup.transport.pingReply = .success("PONG 2\n")
        await setup.model.connect()
        var profile = try #require(setup.model.profile)
        #expect(profile.servePort != nil)
        #expect(profile.lastAlgorithms != nil)
        profile.host = "other.example.com"
        try setup.model.saveProfile(profile)
        #expect(try setup.profiles.load()?.servePort == nil)
        #expect(try setup.profiles.load()?.lastAlgorithms == nil)
    }

    /// Issue #18: Settings > Server shows the last negotiated pair, also when offline.
    @Test func connectSavesTheNegotiatedAlgorithms() async throws {
        let setup = await makeModel(pin: .sample)
        #expect(setup.model.profile?.lastAlgorithms == nil)
        await setup.model.connect()
        let expected = SSHNegotiatedAlgorithms(cipher: "aes256-gcm@openssh.com", keyExchange: "curve25519-sha256")
        #expect(try setup.profiles.load()?.lastAlgorithms == expected)

        await setup.model.disconnect()
        setup.transport.algorithms = nil  // A connection that cannot tell keeps the last pair.
        await setup.model.connect()
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(setup.model.profile?.lastAlgorithms == expected)

        await setup.model.disconnect()
        setup.transport.connectFailure = .unreachable
        await setup.model.connect()
        #expect(setup.model.connection == .offline(.unreachable))
        #expect(setup.model.profile?.lastAlgorithms?.displayText == "aes256-gcm@openssh.com · curve25519-sha256")
    }

    @Test func noAllowedAlgorithmsIsNotStarted() {
        #expect(AppModel.failureState(for: .noAllowedAlgorithms) == .notStarted(.noAllowedAlgorithms))
    }

    @Test(arguments: ["hermes-not-found", "update-required", "not-allowed", "bad-token", "exit 2"])
    func gateRefusalIsNotStarted(code: String) async {
        let setup = await makeModel(pin: .sample)
        setup.transport.serveFailure = .gateError(code)
        await setup.model.connect()
        #expect(setup.model.connection == .notStarted(.gateError(code)))
        #expect(setup.model.hermesEndpoint == nil)
        #expect(setup.transport.record.closedSessions == 1)
        #expect(!setup.model.showsHermesStartError)
    }

    @Test(arguments: ["serve-timeout", "serve-exited", "update-in-progress"])
    func busyServerIsOffline(code: String) async {
        let setup = await makeModel(pin: .sample)
        setup.transport.serveFailure = .gateError(code)
        await setup.model.connect()
        #expect(setup.model.connection == .offline(.gateError(code)))
    }

    @Test func refusedKeyIsNotStarted() async {
        let setup = await makeModel(pin: .sample, failure: .authenticationFailed)
        await setup.model.connect()
        #expect(setup.model.connection == .notStarted(.authenticationFailed))
    }

    @Test func noHealthAnswerIsOffline() async {
        let setup = await makeModel(pin: .sample)
        setup.http.healthy = false
        await setup.model.connect()
        #expect(setup.model.connection == .offline(.hermesNotReady))
        #expect(setup.model.hermesEndpoint == nil)
        #expect(setup.transport.record.closedForwards == 1)
    }

    @Test func rejectedTokenIsOfflineAndTheRetryUsesANewToken() async throws {
        let setup = await makeModel(pin: .sample)
        setup.http.ownershipStatus = 401
        await setup.model.connect()
        #expect(setup.model.connection == .offline(.sessionTokenRejected))
        let first = try #require(setup.transport.record.stdins.last ?? nil)
        setup.http.ownershipStatus = 200
        await setup.model.connect()
        #expect(setup.model.connection == .connected(gateVersion: "1"))
        #expect(setup.transport.record.stdins.last != first)
    }

    @Test func gateFailureAlertTextHasNoServerDetails() {
        #expect(HermesStartAlert.title == "Hermes Did Not Start")
        #expect(HermesStartAlert.message == "The server refused the request. Check the install steps in Settings.")
    }

    @Test func trustInstructionsNameTheKeyFile() {
        #expect(TrustServerSheet.hostKeyFile(for: .sample) == "ssh_host_ed25519_key.pub")
        let ecdsa = HostKey(algorithm: "ecdsa-sha2-nistp256", blob: Data())
        #expect(TrustServerSheet.hostKeyFile(for: ecdsa) == "ssh_host_ecdsa_key.pub")
    }
}

@MainActor
@Suite struct ChatScreenTests {
    private let messages = [
        ChatMessage(id: "1", role: .user, text: "hi **there**", date: .now, delivery: .delivered),
        ChatMessage(id: "2", role: .assistant, text: "See [docs](https://example.com)", date: .now, reply: .complete),
    ]

    @Test func controllerShowsOneSectionPerMessage() {
        let controller = ChatViewController(model: ChatViewModel(transport: OfflineChatTransport(), messages: messages))
        controller.loadViewIfNeeded()
        #expect(controller.messagesCollectionView.numberOfSections == 2)
    }

    @Test func bubbleTextStylesMarkdownAndKeepsLinks() throws {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let outgoing = ChatBubbleText.make(messages[0], traits: traits)
        #expect(outgoing.string == "hi there")
        let bold = try #require(outgoing.attribute(.font, at: 4, effectiveRange: nil) as? UIFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        let incoming = ChatBubbleText.make(messages[1], traits: traits)
        #expect(incoming.string == "See docs")
        #expect(incoming.attribute(ChatBubbleText.linkKey, at: 5, effectiveRange: nil) as? URL
            == URL(string: "https://example.com"))
    }

    @Test func offlineTransportFailsTheSend() async {
        let model = ChatViewModel(transport: OfflineChatTransport())
        await model.send("hello")?.value
        #expect(model.messages.first?.delivery == .failed)
    }
}

@MainActor
@Suite struct ChatFixRoundTests {
    private func longThread() -> [ChatMessage] {
        let base = Date(timeIntervalSince1970: 1_763_288_100)
        return (0..<16).map { index in
            ChatMessage(id: "m\(index)", role: index.isMultiple(of: 2) ? .user : .assistant,
                        text: String(repeating: "Long reply text that wraps. ", count: 1 + index % 4),
                        date: base.addingTimeInterval(Double(index) * 30),
                        delivery: index.isMultiple(of: 2) ? .delivered : nil,
                        reply: index.isMultiple(of: 2) ? nil : .complete)
        }
    }

    @Test func bottomOffsetMath() {
        let insets = UIEdgeInsets(top: 100, left: 0, bottom: 80, right: 0)
        #expect(ChatScroll.bottomOffset(contentHeight: 2000, viewHeight: 800, insets: insets) == 1280)
        // Short content stays at the top.
        #expect(ChatScroll.bottomOffset(contentHeight: 300, viewHeight: 800, insets: insets) == -100)
        #expect(ChatScroll.isNearBottom(offset: 1250, contentHeight: 2000, viewHeight: 800, insets: insets))
        #expect(!ChatScroll.isNearBottom(offset: 1000, contentHeight: 2000, viewHeight: 800, insets: insets))
    }

    /// QA #25 defect 1: a long thread at every text size opens with the last bubble above the composer.
    @Test(arguments: [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge])
    func longThreadOpensAtTheBottom(size: UIContentSizeCategory) async throws {
        let controller = ChatViewController(model: ChatViewModel(transport: OfflineChatTransport(),
                                                                 messages: longThread()))
        controller.traitOverrides.preferredContentSizeCategory = size
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<20 {
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let collection = controller.messagesCollectionView
        let visibleBottom = collection.contentOffset.y + collection.bounds.height - collection.adjustedContentInset.bottom
        #expect(collection.contentSize.height > collection.bounds.height)
        #expect(abs(visibleBottom - collection.contentSize.height) < 1)
        // The composer covers no content: the bottom inset reaches the composer top.
        let composerTop = controller.inputContainerView.convert(controller.inputContainerView.bounds, to: collection).minY
        #expect(collection.contentSize.height <= composerTop + 1)
        #expect(controller.isPinnedToBottom)
    }

    @Test func subtitlePrefersFailedConnectionStages() {
        #expect(ChatLaunch.subtitle(link: .reconnecting, connection: .startingHermes) == .reconnecting)
        #expect(ChatLaunch.subtitle(link: .reconnecting, connection: .offline(nil)) == .connection)
        #expect(ChatLaunch.subtitle(link: .failed, connection: .connected(gateVersion: "1")) == .chatFailed)
        #expect(ChatLaunch.subtitle(link: .ready, connection: .connected(gateVersion: "1")) == .connection)
        #expect(ChatLaunch.subtitle(link: nil, connection: .idle) == .connection)
    }

    @Test func staleTokenAsksAppForANewSession() async throws {
        var renewals = 0
        let link = ChatLaunch.makeLink { renewals += 1 }
        await link.onStaleToken?()
        #expect(renewals == 1)
    }
}
