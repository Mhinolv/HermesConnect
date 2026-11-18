import AppIntents
import HermesKit

/// Issue #45: what the two Siri shortcuts call. The app gives `SiriService`, and tests give a fake.
@MainActor
protocol SiriServing: AnyObject {
    /// Sends the text, waits for the reply, and returns what Siri says.
    func ask(_ text: String) async -> String
    /// Returns what Siri says for the unread replies.
    func read() async -> String
}

/// The service of this process. The app sets it at launch, also for a launch in the background.
@MainActor
enum SiriRuntime {
    static var service: (any SiriServing)?
}

/// Issue #16 and #45: the "Ask Hermes" App Shortcut. It runs in the background: Siri sends the text and speaks
/// the reply, and the app does not open (owner decision 2026-11-17, replaces the #16 "opens the app" decision).
struct AskHermesIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Hermes"
    static let description = IntentDescription("Send a message to your agent. Siri speaks the reply.")
    /// The app does not open. `openAppWhenRun` is deprecated in iOS 26.
    static let supportedModes: IntentModes = .background

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
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = await SiriRuntime.service?.ask(message) ?? SiriDialog.notSetUp
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Issue #45: the "Read Hermes" App Shortcut. Siri reads 3 or fewer unread replies in the background.
struct ReadHermesIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Hermes"
    static let description = IntentDescription("Siri reads the new replies from your agent.")
    static let supportedModes: IntentModes = .background

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = await SiriRuntime.service?.read() ?? SiriDialog.notSetUp
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct HermesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskHermesIntent(),
                    phrases: ["Ask \(.applicationName)", "Message \(.applicationName)"],
                    shortTitle: "Ask Hermes",
                    systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: ReadHermesIntent(),
                    phrases: ["Read \(.applicationName)", "Read my \(.applicationName) messages",
                              "What did \(.applicationName) say"],
                    shortTitle: "Read Hermes",
                    systemImageName: "speaker.wave.2.bubble")
        // Issue #124: the owner can make a Shortcuts app shortcut named "Hands Free" that runs this intent.
        AppShortcut(intent: StartHandsFreeIntent(),
                    phrases: ["Start Hands-Free in \(.applicationName)", "Hands-Free with \(.applicationName)",
                              "Start \(.applicationName) Hands-Free"],
                    shortTitle: "Start Hands-Free",
                    systemImageName: "waveform")
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}

extension AskHermesInbox {
    /// The inbox of the app process. `RootView` takes from it. Since #45 the intent no longer posts to it.
    static let shared = AskHermesInbox()
}
