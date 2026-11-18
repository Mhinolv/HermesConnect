import AppIntents
import Foundation
import HermesKit
import Testing
import UserNotifications
@testable import HermesConnect

/// Issues #16 and #45: the "Ask Hermes" and "Read Hermes" App Shortcuts in the app target.
@MainActor
@Suite(.serialized) struct AskHermesAppTests {
    @Test func twoShortcutsWithTheDesignPhrasesAndSymbols() {
        let shortcuts = HermesShortcuts.appShortcuts
        #expect(shortcuts.count == 3)
        #expect(HermesShortcuts.shortcutTileColor == .blue)
        #expect(String(localized: AskHermesIntent.title) == "Ask Hermes")
        #expect(String(localized: ReadHermesIntent.title) == "Read Hermes")
    }

    /// Owner decision (2026-11-17): both shortcuts run in the background. Siri speaks, and the app does not open.
    @Test func bothIntentsRunInTheBackground() {
        #expect(AskHermesIntent.supportedModes == .background)
        #expect(ReadHermesIntent.supportedModes == .background)
    }

    @Test func readShortcutHasTheDesignPhrases() throws {
        let url = try #require(Bundle(for: AppModel.self).url(forResource: "extract", withExtension: "actionsdata",
                                                               subdirectory: "Metadata.appintents"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("ReadHermesIntent"))
        #expect(text.contains("speaker.wave.2.bubble"))
        #expect(text.contains("What did ${applicationName} say"))
        #expect(text.contains("Read my ${applicationName} messages"))
    }

    @Test func askGivesTheServiceDialogAndPostsNothingToTheInbox() async throws {
        let fake = FakeSiriService()
        let old = SiriRuntime.service
        SiriRuntime.service = fake
        defer { SiriRuntime.service = old }
        _ = AskHermesInbox.shared.next(isSetUp: true, isLocked: false)
        _ = try await AskHermesIntent(message: "Where is my car?").perform()
        _ = try await ReadHermesIntent().perform()
        #expect(fake.asks == ["Where is my car?"])
        #expect(fake.reads == 1)
        #expect(AskHermesInbox.shared.pending == nil)
    }

    @Test func serviceSaysSetUpFirstWithNoSetup() async {
        let service = siriService(setUp: false, locked: false)
        #expect(await service.ask("Hi") == "Set up Hermes in the app first.")
        #expect(await service.read() == "Set up Hermes in the app first.")
    }

    @Test func lockedIPhoneWithTheToggleOffSaysUnlock() async throws {
        let defaults = try #require(UserDefaults(suiteName: "siri-lock-\(UUID().uuidString)"))
        let service = siriService(setUp: true, locked: true, defaults: defaults)
        #expect(await service.ask("Hi") == "Unlock your iPhone to use Hermes.")
        #expect(await service.read() == "Unlock your iPhone to use Hermes.")
    }

    @Test func useSiriWhenLockedIsOffByDefaultAndSaved() throws {
        let defaults = try #require(UserDefaults(suiteName: "siri-toggle-\(UUID().uuidString)"))
        let controller = NotificationController(center: FakeSiriNotificationCenter(), defaults: defaults)
        #expect(!controller.usesSiriWhenLocked)
        controller.usesSiriWhenLocked = true
        #expect(defaults.bool(forKey: SiriSettings.useWhenLockedKey))
        #expect(NotificationSettingsSection.siriTitle == "Use Siri When Locked")
        #expect(NotificationSettingsSection.siriFooter
            == "Siri can read and send Hermes messages while your iPhone is locked.")
    }

    /// Issue #45: a reply notification is a communication notification. With preview off it has no message text.
    @Test func replyNotificationCarriesAnIncomingMessage() {
        let row = SessionListItem(id: "k1", title: "Trip")
        let on = LocalNotificationPoster.messageIntent(
            for: CatchUpNotification(session: row, reply: "Flight at 9", showsPreview: true))
        #expect(on.content == "Flight at 9")
        #expect(on.conversationIdentifier == "k1")
        #expect(on.speakableGroupName?.spokenPhrase == "Trip")
        #expect(on.sender?.displayName == "Hermes")
        let off = LocalNotificationPoster.messageIntent(
            for: CatchUpNotification(session: row, reply: "Flight at 9", showsPreview: false))
        #expect(off.content == "New message from Hermes")
    }

    private func siriService(setUp: Bool, locked: Bool,
                             defaults: UserDefaults = UserDefaults(suiteName: "siri-\(UUID().uuidString)")!)
        -> SiriService {
        let model = AppModel.preview(setUp: setUp, hostKey: .sample)
        let notifications = NotificationController(center: FakeSiriNotificationCenter(), defaults: defaults)
        return SiriService(model: model, link: LiveChatTransport(), sessions: ChatLaunch.makeOfflineSessions(),
                           notifications: notifications, isDeviceLocked: { locked }, isAppActive: { true })
    }

    /// Owner decision (2026-11-17): "Message" is required, so Siri asks for the text when the owner does not say it.
    @Test func messageIsRequiredAndSiriAsksForIt() throws {
        let url = try #require(Bundle(for: AppModel.self).url(forResource: "extract", withExtension: "actionsdata",
                                                               subdirectory: "Metadata.appintents"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let actions = try #require(root["actions"] as? [String: Any])
        let intent = try #require(actions["AskHermesIntent"] as? [String: Any])
        let parameters = try #require(intent["parameters"] as? [[String: Any]])
        let message = try #require(parameters.first { $0["name"] as? String == "message" })
        #expect(message["isOptional"] as? Bool == false)
        #expect(String(localized: AskHermesIntent.askPrompt) == "What do you want to ask Hermes?")
        // The value is a plain `String`, not `String?`.
        let text: String = AskHermesIntent(message: "Hi").message
        #expect(text == "Hi")
    }

    @Test func routesMapToTheChatStack() {
        #expect(ChatRoute(AskHermesRoute.session("k1")) == .session("k1"))
        #expect(ChatRoute(AskHermesRoute.newChat(key: "n1")) == .new("n1"))
    }
}

@MainActor private final class FakeSiriService: SiriServing {
    var asks: [String] = []
    var reads = 0

    func ask(_ text: String) async -> String {
        asks.append(text)
        return "Reply"
    }

    func read() async -> String {
        reads += 1
        return "Read"
    }
}

private struct FakeSiriNotificationCenter: NotificationCentering {
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization(options _: UNAuthorizationOptions) async throws -> Bool { true }
    func add(_: UNNotificationRequest) async throws {}
    func setBadgeCount(_: Int) async throws {}
}
