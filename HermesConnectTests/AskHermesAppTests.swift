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
        _ = try await AskHermesIntent(message: nil).perform()
        #expect(inbox.pending != nil)
        #expect(inbox.pending?.text == nil)
        // Clean up: the shared inbox lives for the whole test run.
        _ = inbox.next(isSetUp: true, isLocked: false)
        #expect(inbox.pending == nil)
    }

    @Test func routesMapToTheChatStack() {
        #expect(ChatRoute(AskHermesRoute.session("k1")) == .session("k1"))
        #expect(ChatRoute(AskHermesRoute.newChat(key: "n1")) == .new("n1"))
    }
}
