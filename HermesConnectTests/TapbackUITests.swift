import Foundation
import HermesKit
import MessageKit
import Testing
import UIKit
@testable import HermesConnect

/// Issue #11: agent ack badges, owner tapbacks, the capsule and the VoiceOver actions.
@MainActor
@Suite(.serialized) struct TapbackUITests {
    private let date = Date(timeIntervalSince1970: 1_763_290_000)

    private func messages() -> [ChatMessage] {
        [
            ChatMessage(id: "u1", role: .user, text: "Book the train", date: date, delivery: .delivered, userRowId: 1,
                        agentAck: .done, tapback: .exclamation),
            ChatMessage(id: "a1", role: .assistant, text: "Booked.", date: date.addingTimeInterval(5), reply: .complete,
                        promptId: "u1", tapback: .heart),
            ChatMessage(id: "u2", role: .user, text: "/usage", date: date.addingTimeInterval(9), delivery: .delivered,
                        userRowId: 3),
            ChatMessage(id: "a2", role: .assistant, text: "41%", date: date.addingTimeInterval(10), reply: .complete,
                        promptId: "u2"),
        ]
    }

    private func makeController() -> (ChatViewController, ChatViewModel, InMemorySessionCacheStore) {
        let cache = InMemorySessionCacheStore(transcripts: ["st1": messages()])
        let model = ChatViewModel(transport: DemoChatTransport(scenario: .thread), storedSessionId: "st1", cache: cache)
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(),
                                            voiceFolder: FileManager.default.temporaryDirectory)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        return (controller, model, cache)
    }

    private func cell(_ controller: ChatViewController, section: Int) throws -> MessageContentCell {
        let collection = controller.messagesCollectionView
        collection.layoutIfNeeded()
        return try #require(collection.cellForItem(at: IndexPath(item: 0, section: section)) as? MessageContentCell)
    }

    private func badgeSymbols(_ cell: MessageContentCell) -> [String] {
        let overlay = cell.contentView.subviews.compactMap { $0 as? ReactionBadgeOverlay }.first
        guard let overlay, !overlay.isHidden else { return [] }
        return overlay.subviews.compactMap { ($0 as? ReactionBadgeView)?.symbolName }.sorted()
    }

    @Test func badgesShowTheAckAndTheTapback() throws {
        let (controller, _, _) = makeController()
        #expect(badgeSymbols(try cell(controller, section: 0)) == ["exclamationmark.2", "hand.thumbsup.fill"])
        #expect(badgeSymbols(try cell(controller, section: 1)) == ["heart.fill"])
        // A slash command has no ack.
        #expect(badgeSymbols(try cell(controller, section: 2)).isEmpty)
        #expect(badgeSymbols(try cell(controller, section: 3)).isEmpty)
    }

    @Test func badgeSitsOnTheTopCornersOfTheBubble() throws {
        let cell = try cell(makeController().0, section: 0)
        let overlay = try #require(cell.contentView.subviews.compactMap { $0 as? ReactionBadgeOverlay }.first)
        overlay.layoutIfNeeded()
        let bubble = cell.messageContainerView.frame
        let views = overlay.subviews.compactMap { $0 as? ReactionBadgeView }
        let ack = try #require(views.first { $0.symbolName == "hand.thumbsup.fill" })
        let tapback = try #require(views.first { $0.symbolName == "exclamationmark.2" })
        #expect(ack.frame.size == CGSize(width: 28, height: 28))
        #expect(ack.frame.midX < bubble.minX + 14)
        #expect(tapback.frame.midX > bubble.maxX - 14)
        #expect(ack.frame.minY == bubble.minY - ReactionBadge.overhang)
        // The row reserves the space above the bubble.
        #expect(bubble.minY >= ReactionBadge.overhang)
    }

    @Test func voiceOverReadsTheReactionsAndHasReactActions() throws {
        let (controller, model, cache) = makeController()
        let first = try cell(controller, section: 0)
        #expect(first.accessibilityLabel?.contains("Hermes reacted thumbs up, You reacted exclamation") == true)
        let names = first.accessibilityCustomActions?.map(\.name) ?? []
        #expect(names.contains("React Heart"))
        #expect(names.contains("React Question"))
        #expect(names.contains("Remove Reaction"))
        let none = try cell(controller, section: 3)
        #expect(none.accessibilityLabel?.hasPrefix("Hermes, 41%") == true, "\(none.accessibilityLabel ?? "")")
        let noneNames = none.accessibilityCustomActions?.map(\.name) ?? []
        #expect(noneNames.contains("React Thumbs Up"))
        #expect(!noneNames.contains("Remove Reaction"))

        let react = try #require(none.accessibilityCustomActions?.first { $0.name == "React Thumbs Up" })
        _ = react.actionHandler?(react)
        #expect(model.messages.first { $0.id == "a2" }?.tapback == .thumbsUp)
        #expect(cache.loadTranscript(sessionId: "st1").first { $0.id == "a2" }?.tapback == .thumbsUp)
    }

    @Test func capsuleSetsTheTapbackAndATapOnTheSelectedOneRemovesIt() throws {
        let (controller, model, _) = makeController()
        controller.showTapbackPicker(messageId: "a2")
        let picker = try #require(controller.tapbackPicker)
        let buttons = picker.capsule.contentView.subviews.compactMap { $0 as? UIButton }
        #expect(buttons.count == 6)
        #expect(buttons.allSatisfy { $0.frame.width == 44 && $0.frame.height == 44 })
        picker.capsule.onSelect?(.haha)
        #expect(model.messages.first { $0.id == "a2" }?.tapback == .haha)
        #expect(controller.tapbackPicker == nil)

        controller.showTapbackPicker(messageId: "a2")
        let again = try #require(controller.tapbackPicker)
        let labels = again.capsule.contentView.subviews.compactMap { ($0 as? UIButton)?.accessibilityLabel }
        #expect(labels.contains("Remove Ha Ha"))
        again.capsule.onSelect?(.haha)
        #expect(model.messages.first { $0.id == "a2" }?.tapback == nil)
    }

    @Test func capsuleStaysOnTheScreen() {
        let size = CGSize(width: 272, height: 52)
        let bounds = CGRect(x: 0, y: 60, width: 402, height: 700)
        let incoming = TapbackCapsuleView.frame(size: size, above: CGRect(x: 10, y: 300, width: 80, height: 40),
                                                outgoing: false, in: bounds)
        #expect(incoming.minX == 10)
        #expect(incoming.maxY == 292)
        let outgoing = TapbackCapsuleView.frame(size: size, above: CGRect(x: 300, y: 300, width: 92, height: 40),
                                                outgoing: true, in: bounds)
        #expect(outgoing.maxX == 392)
        // No room above: the capsule goes under the bubble.
        let top = TapbackCapsuleView.frame(size: size, above: CGRect(x: 10, y: 70, width: 80, height: 40),
                                           outgoing: false, in: bounds)
        #expect(top.minY == 118)
        let wide = TapbackCapsuleView.frame(size: size, above: CGRect(x: 380, y: 300, width: 20, height: 40),
                                            outgoing: false, in: bounds)
        #expect(wide.maxX <= 394)
    }

    @Test func onlyTheFirstPartOfAMessageGetsBadges() {
        let photo = ChatAttachment(id: "x", kind: .photo, name: "IMG.jpg", byteCount: 1,
                                   fileURL: URL(fileURLWithPath: "/tmp/IMG.jpg"), mimeType: "image/jpeg")
        let message = ChatMessage(id: "u1", role: .user, text: "Look", date: date, delivery: .delivered,
                                  attachments: [photo], agentAck: .seen, tapback: .heart)
        let parts = ChatBubbleParts.parts(for: ChatTimeline.rows(for: [message]))
        #expect(ReactionBadge.badges(for: parts[0].row).map(\.symbolName) == ["eyes", "heart.fill"])
        #expect(ReactionBadge.badges(for: parts[1].row).isEmpty)
        // A reply never shows an agent ack.
        var reply = ChatMessage(id: "a1", role: .assistant, text: "Hi", date: date, reply: .complete)
        reply.agentAck = .done
        #expect(ReactionBadge.badges(for: ChatTimeline.rows(for: [reply])[0]).isEmpty)
    }

    @Test func noTapbackOnABubbleThatStillSends() {
        #expect(!ChatViewController.canReact(ChatMessage(id: "p", role: .user, text: "x", date: date,
                                                         delivery: .sending)))
        #expect(!ChatViewController.canReact(ChatMessage(id: "r", role: .assistant, text: "x", date: date,
                                                         reply: .streaming)))
        #expect(ChatViewController.canReact(ChatMessage(id: "f", role: .user, text: "x", date: date,
                                                        delivery: .failed)))
    }
}
