import Foundation
import HermesKit
import MessageKit
import Testing
import UIKit
@testable import HermesConnect

/// Issue #39: the outbox bubble: `clock` and "Will send when connected" under each queued message.
@MainActor
@Suite(.serialized) struct OutboxUITests {
    private let date = Date(timeIntervalSince1970: 1_763_370_000)

    private func makeController() -> ChatViewController {
        let messages = [
            ChatMessage(id: "u1", role: .user, text: "Hi", date: date, delivery: .delivered, userRowId: 1),
            ChatMessage(id: "q1", role: .user, text: "Book a table", date: date.addingTimeInterval(5), delivery: .queued),
            ChatMessage(id: "q2", role: .user, text: "Add it to my calendar", date: date.addingTimeInterval(9),
                        delivery: .queued),
        ]
        let model = ChatViewModel(transport: DemoChatTransport(scenario: .thread), messages: messages)
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(),
                                            voiceFolder: FileManager.default.temporaryDirectory)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        return controller
    }

    private func cell(_ controller: ChatViewController, section: Int) throws -> MessageContentCell {
        let collection = controller.messagesCollectionView
        collection.layoutIfNeeded()
        return try #require(collection.cellForItem(at: IndexPath(item: 0, section: section)) as? MessageContentCell)
    }

    @Test func eachQueuedBubbleShowsTheClockCaption() throws {
        let controller = makeController()
        for section in [1, 2] {
            let cell = try cell(controller, section: section)
            let caption = try #require(cell.messageBottomLabel.attributedText)
            #expect(caption.string.hasSuffix("Will send when connected"))
            var hasIcon = false
            caption.enumerateAttribute(.attachment, in: NSRange(location: 0, length: caption.length)) { value, _, _ in
                if (value as? NSTextAttachment)?.image != nil { hasIcon = true }
            }
            #expect(hasIcon)
            #expect(cell.accessibilityLabel?.hasSuffix("Will send when connected") == true)
            #expect(cell.accessibilityHint == "Double-tap for options.")
        }
        // The delivered message above the outbox keeps "Delivered".
        #expect(try cell(controller, section: 0).messageBottomLabel.attributedText?.string == "Delivered")
        #expect(ChatCaptionRow.symbolName(.queued) == "clock")
    }
}
