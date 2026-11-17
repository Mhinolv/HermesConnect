import AppIntents
import HermesKit

/// Issue #16: the one "Ask Hermes" App Shortcut. It opens the app and sends the "Message" text at once
/// (owner decision 2026-11-16). The root waits for setup and App Lock (`AskHermesInbox`).
/// A text of only spaces opens the chat and sends nothing.
struct AskHermesIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Hermes"
    static let description = IntentDescription("Open Hermes and send a message to your agent.")
    /// The app opens. `openAppWhenRun` is deprecated in iOS 26.
    static let supportedModes: IntentModes = .foreground

    /// Siri asks this when the owner does not say the text.
    static let askPrompt: LocalizedStringResource = "What do you want to ask Hermes?"

    /// Required (owner decision 2026-11-17): the owner uses the shortcut hands-free, so Siri asks for the text.
    @Parameter(title: "Message", requestValueDialog: IntentDialog(AskHermesIntent.askPrompt))
    var message: String

    init() {}

    init(message: String) {
        self.message = message
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AskHermesInbox.shared.post(message: message)
        return .result()
    }
}

struct HermesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskHermesIntent(),
                    phrases: ["Ask \(.applicationName)", "Message \(.applicationName)"],
                    shortTitle: "Ask Hermes",
                    systemImageName: "bubble.left.and.text.bubble.right")
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}

extension AskHermesInbox {
    /// The inbox of the app process. The intent posts to it, and `RootView` takes from it.
    static let shared = AskHermesInbox()
}
