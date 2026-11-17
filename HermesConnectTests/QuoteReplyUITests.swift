import Foundation
import HermesKit
import MessageKit
import Testing
import UIKit
@testable import HermesConnect

/// Issue #17: the composer quote box, the quote line in the bubble, the swipe, the menu and VoiceOver.
@MainActor
@Suite(.serialized) struct QuoteReplyUITests {
    private let date = Date(timeIntervalSince1970: 1_763_290_000)

    private func messages() -> [ChatMessage] {
        let quote = ChatQuote(messageId: "a1", author: .assistant, time: "9:41 AM", excerpt: "The call is at 3:00 PM.")
        return [
            ChatMessage(id: "u1", role: .user, text: "When is the call?", date: date, delivery: .delivered, userRowId: 1),
            ChatMessage(id: "a1", role: .assistant, text: "The call is at 3:00 PM.", date: date.addingTimeInterval(5),
                        reply: .complete, promptId: "u1"),
            ChatMessage(id: "u2", role: .user, text: "Move it to 4", date: date.addingTimeInterval(9),
                        delivery: .delivered, userRowId: 3, quote: quote),
            ChatMessage(id: "u3", role: .user, text: "And this one", date: date.addingTimeInterval(12),
                        delivery: .delivered, userRowId: 5,
                        quote: ChatQuote(messageId: "gone", author: .assistant, time: "8:00 AM", excerpt: "Old text")),
        ]
    }

    private func makeController(readOnly: Bool = false) -> (ChatViewController, ChatViewModel) {
        let cache = InMemorySessionCacheStore(transcripts: ["st1": messages()])
        let model = ChatViewModel(transport: DemoChatTransport(scenario: .thread), storedSessionId: "st1", cache: cache)
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(),
                                            voiceFolder: FileManager.default.temporaryDirectory, readOnly: readOnly)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        return (controller, model)
    }

    private func cell(_ controller: ChatViewController, section: Int) throws -> MessageContentCell {
        let collection = controller.messagesCollectionView
        collection.layoutIfNeeded()
        return try #require(collection.cellForItem(at: IndexPath(item: 0, section: section)) as? MessageContentCell)
    }

    @Test func replyShowsTheQuoteBoxAndCancelRemovesIt() throws {
        let (controller, model) = makeController()
        #expect(controller.quoteView.isHidden)
        controller.startReply(to: "a1")
        #expect(!controller.quoteView.isHidden)
        #expect(controller.quoteView.titleText == "Replying to Hermes")
        #expect(controller.quoteView.excerptText == "The call is at 3:00 PM.")
        #expect(controller.quoteView.cancelButton.accessibilityLabel == "Cancel Reply")
        controller.quoteView.cancelButton.sendActions(for: .touchUpInside)
        #expect(model.replyQuote == nil)
        controller.startReply(to: "u1")
        #expect(controller.quoteView.titleText == "Replying to You")
    }

    @Test func theBubbleShowsOneQuoteLineAndNoMarkers() throws {
        let (controller, _) = makeController()
        let bubble = try #require(controller.messagesCollectionView.messagesDataSource?
            .messageForItem(at: IndexPath(item: 0, section: 2), in: controller.messagesCollectionView) as? ChatBubble)
        #expect(bubble.text.string == "The call is at 3:00 PM.\nMove it to 4")
        #expect(bubble.text.attribute(ChatQuoteText.tapKey, at: 0, effectiveRange: nil) != nil)
        let font = try #require(bubble.text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(font.pointSize == UIFont.preferredFont(forTextStyle: .footnote).pointSize)
        let style = try #require(bubble.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.lineBreakMode == .byTruncatingTail)
        #expect(!bubble.text.string.contains(">"))
    }

    /// QA #80 defect 1: a reply of a photo only shows the quote line in its own text bubble.
    @Test func aPhotoOnlyReplyShowsTheQuoteLine() throws {
        let photo = ChatAttachment(id: "p1", kind: .photo, name: "IMG_1.jpg", byteCount: 10,
                                   fileURL: URL(fileURLWithPath: "/tmp/IMG_1.jpg"), mimeType: "image/jpeg")
        let quote = ChatQuote(messageId: "a1", author: .assistant, time: "9:41 AM", excerpt: "The call is at 3:00 PM.")
        let sent = ChatMessage(id: "u9", role: .user, text: "", date: date, delivery: .delivered, attachments: [photo],
                               quote: quote)
        let text = ChatBubbleText.make(sent, traits: UITraitCollection(preferredContentSizeCategory: .large))
        #expect(text.string == "The call is at 3:00 PM.")
        #expect(text.attribute(ChatQuoteText.tapKey, at: 0, effectiveRange: nil) != nil)
    }

    @Test func voiceOverReadsTheQuoteFirstAndHasReplyActions() throws {
        let (controller, _) = makeController()
        let quoted = try cell(controller, section: 2)
        #expect(quoted.accessibilityLabel?.hasPrefix("Reply to Hermes: The call is at 3:00 PM., You, Move it to 4") == true,
                "\(quoted.accessibilityLabel ?? "")")
        let names = quoted.accessibilityCustomActions?.map(\.name) ?? []
        #expect(names.contains("Reply"))
        #expect(names.contains("Show Original Message"))
        let plain = try cell(controller, section: 1)
        let reply = try #require(plain.accessibilityCustomActions?.first { $0.name == "Reply" })
        _ = reply.actionHandler?(reply)
        #expect(controller.quoteView.excerptText == "The call is at 3:00 PM.")
    }

    @Test func theMenuHasReply() throws {
        let (controller, model) = makeController()
        let row = try #require(ChatTimeline.rows(for: model.messages).first { $0.id == "a1" })
        let action = try #require(controller.replyMenuAction(for: row))
        #expect(action.title == "Reply")
        #expect(action.image == UIImage(systemName: "arrowshape.turn.up.left"))
        action.performWithSender(nil, target: nil)
        #expect(model.replyQuote?.messageId == "a1")
        #expect(controller.collectionView(controller.messagesCollectionView,
                                          contextMenuConfigurationForItemsAt: [IndexPath(item: 0, section: 1)],
                                          point: .zero) != nil)
    }

    @Test func aTapOnTheQuoteFindsTheOriginalOrShowsTheNotice() throws {
        let (controller, model) = makeController()
        #expect(model.quotedMessageId(of: "u2") == "a1")
        #expect(model.quotedMessageId(of: "u3") == nil)
        controller.showQuotedMessage(for: "u3")
        let pill = try #require(controller.view.subviews.compactMap { $0 as? ChatNoticePill }.first)
        #expect(!pill.isHidden)
        #expect(pill.accessibilityLabel == "Original message not loaded")
        controller.showQuotedMessage(for: "u2")
        #expect(!controller.isPinnedToBottom)
    }

    @Test func theSwipeMovesTheBubbleSlowerPast60Points() {
        #expect(ChatSwipeReply.offset(for: -20) == 0)
        #expect(ChatSwipeReply.offset(for: 40) == 40)
        #expect(ChatSwipeReply.offset(for: 60) == 60)
        #expect(ChatSwipeReply.offset(for: 100) == 72)
        #expect(ChatSwipeReply.offset(for: 400) == ChatSwipeReply.maxOffset)
    }

    @Test func theRunScreenHasNoReply() throws {
        let (controller, model) = makeController(readOnly: true)
        controller.startReply(to: "a1")
        #expect(model.replyQuote == nil)
        let names = try cell(controller, section: 1).accessibilityCustomActions?.map(\.name) ?? []
        #expect(!names.contains("Reply"))
    }
}
