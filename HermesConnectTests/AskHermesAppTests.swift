import AppIntents
import Foundation
import HermesKit
import Testing
@testable import HermesConnect

/// Issue #16: the "Ask Hermes" App Shortcut in the app target.
@MainActor
@Suite(.serialized) struct AskHermesAppTests {
    @Test func oneShortcutWithTheDesignPhrasesAndSymbol() {
        let shortcuts = HermesShortcuts.appShortcuts
        #expect(shortcuts.count == 1)
        #expect(HermesShortcuts.shortcutTileColor == .blue)
        #expect(String(localized: AskHermesIntent.title) == "Ask Hermes")
    }

    @Test func theIntentOpensTheApp() {
        #expect(AskHermesIntent.supportedModes == .foreground)
    }

    @Test func runPostsTheMessageToTheAppInbox() async throws {
        let inbox = AskHermesInbox.shared
        _ = inbox.next(isSetUp: true, isLocked: false)
        _ = try await AskHermesIntent(message: "  Where is my car?  ").perform()
        #expect(inbox.pending?.text == "Where is my car?")
        // Clean up: the shared inbox lives for the whole test run.
        _ = inbox.next(isSetUp: true, isLocked: false)
        #expect(inbox.pending == nil)
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
