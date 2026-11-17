import Foundation
import HermesKit
import InputBarAccessoryView
import Testing
import UIKit
@testable import HermesConnect

/// Issue #68: the slash suggestion panel above the composer. Offline model with a cached catalog. No server.
@MainActor
@Suite(.serialized) struct SlashSuggestionUITests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SlashSuggestionUITests")
    private static let catalog = [
        SlashCatalogEntry(name: "model", aliases: ["m"], summary: "Switch the model"),
        SlashCatalogEntry(name: "help", summary: "Show the commands"),
        SlashCatalogEntry(name: "skills", summary: "Search and install skills"),
        SlashCatalogEntry(name: "summarize", summary: "Summarize this chat"),
        SlashCatalogEntry(name: "compress", summary: "Compress the context"),
        SlashCatalogEntry(name: "status", summary: "Show the session status"),
    ]

    private func show() throws -> (ChatViewController, UIWindow, ChatViewModel) {
        let cache = InMemorySlashCatalogCacheStore(servers: ["s": Self.catalog])
        SlashSuggestions.shared = SlashSuggestionModel(transport: nil, cache: cache, serverKey: { "s" })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        // One message: an empty chat focuses the field by itself in `viewDidAppear`.
        let message = ChatMessage(id: "m0", role: .assistant, text: "Hello", date: Date(timeIntervalSince1970: 1_763_290_000),
                                  reply: .complete)
        let model = ChatViewModel(transport: OfflineChatTransport(), messages: [message])
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(), voiceFolder: folder)
        controller.autoPlayEnabled = { false }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (controller, window, model)
    }

    private func type(_ text: String, in controller: ChatViewController) {
        // The same path as a key: InputTextView posts the text change notification.
        controller.messageInputBar.inputTextView.text = text
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met")
    }

    private func cells(_ panel: SlashSuggestionPanelView) -> [SlashSuggestionCell] {
        (0..<panel.table.numberOfRows(inSection: 0)).compactMap {
            panel.table.dataSource?.tableView(panel.table, cellForRowAt: IndexPath(row: $0, section: 0))
                as? SlashSuggestionCell
        }
    }

    @Test func aSlashShowsThePanelAboveTheFieldAndTheKeyboardTapHidesIt() async throws {
        let (controller, window, _) = try show()
        defer { window.isHidden = true }
        let field = controller.messageInputBar.inputTextView
        let panel = controller.slashSuggestions.panel
        #expect(field.becomeFirstResponder())
        try #require(field.isFirstResponder, "the composer did not take the focus")
        #expect(panel.superview === controller.messageInputBar.topStackView)
        #expect(panel.isHidden)

        type("/", in: controller)
        try await waitUntil { !panel.isHidden }
        #expect(panel.table.numberOfRows(inSection: 0) == 8)
        window.layoutIfNeeded()
        let panelFrame = panel.convert(panel.bounds, to: window)
        let fieldFrame = field.convert(field.bounds, to: window)
        #expect(panelFrame.maxY <= fieldFrame.minY)
        // 4.5 rows show, so the list scrolls.
        let rowHeight = SlashSuggestionCell.rowHeight(traits: panel.traitCollection)
        #expect(panel.table.bounds.height <= rowHeight * 4.5 + 1)
        #expect(panel.table.isScrollEnabled)

        type("/mo", in: controller)
        try await waitUntil { panel.table.numberOfRows(inSection: 0) == 1 }
        type("hello", in: controller)
        try await waitUntil { panel.isHidden }

        // Issue #65: the tap on the thread hides the keyboard, and the panel with it.
        type("/he", in: controller)
        try await waitUntil { !panel.isHidden }
        controller.threadTapped()
        #expect(!field.isFirstResponder)
        try await waitUntil { panel.isHidden }
        // Focus again: the panel comes back for the same text.
        #expect(field.becomeFirstResponder())
        try await waitUntil { !panel.isHidden }
    }

    @Test func aTapPutsTheCommandInTheFieldAndSendsNothing() async throws {
        let (controller, window, model) = try show()
        defer { window.isHidden = true }
        let field = controller.messageInputBar.inputTextView
        let panel = controller.slashSuggestions.panel
        #expect(field.becomeFirstResponder())
        type("/su", in: controller)
        try await waitUntil { panel.table.numberOfRows(inSection: 0) == 1 }
        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 0, section: 0))
        #expect(field.text == "/summarize ")
        #expect(field.isFirstResponder)
        #expect(model.messages.map(\.id) == ["m0"])
        #expect(controller.messageInputBar.sendButton.isEnabled)
        // Offline: an argument has no local rows, so the panel hides.
        try await waitUntil { panel.isHidden }
    }

    @Test func rowsAreButtonsWithTheCommandAndDescriptionAndStatusRowsAreNotTappable() async throws {
        let (controller, window, _) = try show()
        defer { window.isHidden = true }
        let field = controller.messageInputBar.inputTextView
        let panel = controller.slashSuggestions.panel
        #expect(field.becomeFirstResponder())
        type("/mo", in: controller)
        try await waitUntil { panel.table.numberOfRows(inSection: 0) == 1 && !panel.isHidden }
        let row = try #require(cells(panel).first)
        #expect(row.accessibilityLabel == "/model, Switch the model")
        #expect(row.accessibilityHint == "Puts the command in the message field.")
        #expect(row.accessibilityTraits.contains(.button))

        type("/zzz", in: controller)
        try await waitUntil { panel.shownState == .noMatch }
        let status = try #require(cells(panel).first)
        #expect(status.accessibilityLabel == "No matching commands")
        #expect(!status.accessibilityTraits.contains(.button))
        #expect(panel.tableView(panel.table, shouldHighlightRowAt: IndexPath(row: 0, section: 0)) == false)
        panel.tableView(panel.table, didSelectRowAt: IndexPath(row: 0, section: 0))
        #expect(field.text == "/zzz")
    }

    @Test func theEndOfTheEditHidesThePanelAndTextWithNoFocusDoesNotOpenIt() async throws {
        let (controller, window, _) = try show()
        defer { window.isHidden = true }
        let field = controller.messageInputBar.inputTextView
        let panel = controller.slashSuggestions.panel
        // A text change with no focus (a draft, a prefill) does not open the panel.
        try #require(!field.isFirstResponder)
        type("/help", in: controller)
        #expect(controller.slashSuggestions.model.state == .hidden)

        #expect(field.becomeFirstResponder())
        try await waitUntil { !panel.isHidden }
        // A memo records, or the keyboard hides: the field ends the edit.
        NotificationCenter.default.post(name: UITextView.textDidEndEditingNotification, object: field)
        try await waitUntil { panel.isHidden }
    }

    @Test func thePanelHeightFollowsTheRules() {
        let large = UIContentSizeCategory.large
        let ax5 = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        // Few rows: the rows decide.
        #expect(SlashPanelLayout.height(contentHeight: 120, rowHeight: 56, category: large, freeHeight: 800) == 120)
        // Many rows: 4.5 rows, or 2.5 rows at AX sizes.
        #expect(SlashPanelLayout.height(contentHeight: 900, rowHeight: 56, category: large, freeHeight: 800) == 252)
        #expect(SlashPanelLayout.height(contentHeight: 900, rowHeight: 100, category: ax5, freeHeight: 2000) == 250)
        // A small free space: 40 percent of it.
        #expect(SlashPanelLayout.height(contentHeight: 900, rowHeight: 56, category: large, freeHeight: 300) == 120)
        #expect(SlashSuggestionCell.rowHeight(traits: UITraitCollection(preferredContentSizeCategory: .extraSmall))
            >= SlashPanelLayout.minRowHeight)
    }
}
