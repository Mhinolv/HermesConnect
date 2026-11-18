import Foundation
import HermesKit
import Testing
import UIKit
import UserNotifications
@testable import HermesConnect

/// Issue #104: the approval card, the "Approval needed" row and the background notification.
@MainActor
@Suite struct ApprovalCardUITests {
    private let request = ApprovalRequest(sessionId: "s1", requestId: "a1",
                                          command: String(repeating: "gcal events update --flag value ", count: 12),
                                          description: "Move \"Dentist\" to Friday 3:00 PM")

    private func traits(_ size: UIContentSizeCategory) -> UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: size)
    }

    @Test func waitingCardHasOneButtonPerChoiceWithDenyLast() {
        let card = ChatApprovalCard(request: request, serverRequestId: .string("srq-1"))
        let frames = ChatApprovalCardLayout.frames(card, expanded: false, traits: traits(.large), width: 340)
        #expect(frames.buttons.count == 4)
        #expect(card.choices.last == .deny)
        #expect(frames.buttons.allSatisfy { $0.height >= ChatApprovalCardLayout.minButtonHeight })
        #expect(frames.result == nil)
        let tops = frames.buttons.map(\.minY)
        #expect(tops == tops.sorted())
    }

    @Test func answeredCardHasNoButtonsAndAResultLine() {
        let card = ChatApprovalCard(request: request, serverRequestId: nil, state: .answered(.once))
        let frames = ChatApprovalCardLayout.frames(card, expanded: false, traits: traits(.large), width: 340)
        #expect(frames.buttons.isEmpty)
        #expect(frames.result != nil)
        #expect(card.resultText == "Allowed once")
    }

    @Test func longCommandIsCutAtThreeLinesUntilTapped() {
        let card = ChatApprovalCard(request: request, serverRequestId: nil)
        #expect(ChatApprovalCardLayout.commandIsCut(card, traits: traits(.large), width: 340))
        let cut = ChatApprovalCardLayout.size(card, expanded: false, traits: traits(.large), maxWidth: 340)
        let full = ChatApprovalCardLayout.size(card, expanded: true, traits: traits(.large), maxWidth: 340)
        #expect(full.height > cut.height)
    }

    @Test func cardGrowsWithTheLargestTextSize() {
        let card = ChatApprovalCard(request: request, serverRequestId: nil)
        let regular = ChatApprovalCardLayout.size(card, expanded: false, traits: traits(.large), maxWidth: 340)
        let ax5 = ChatApprovalCardLayout.size(card, expanded: false,
                                              traits: traits(.accessibilityExtraExtraExtraLarge), maxWidth: 340)
        #expect(ax5.height > regular.height)
    }

    @Test func chatRowShowsApprovalNeeded() {
        let item = SessionListItem(id: "1", title: "Plans", preview: "Book it")
        #expect(SessionRowText.accessibilityLabel(item, needsApproval: true).hasSuffix("Approval needed"))
        #expect(!SessionRowText.accessibilityLabel(item, needsApproval: true).contains("Book it"))
    }

    @Test func listModelKnowsTheChatThatWaits() throws {
        let sessions = SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                                        cache: InMemorySessionCacheStore(sessions: [], activeSessionId: nil))
        let card = ChatApprovalCard(request: request, serverRequestId: nil)
        let chat = ChatViewModel(transport: OfflineChatTransport(), storedSessionId: "st1", messages: [
            ChatMessage(id: "ap1", role: .assistant, text: "", date: Date(), approval: card),
        ])
        sessions.register(chat, for: "st1")
        #expect(sessions.needsApproval("st1"))
        #expect(!sessions.needsApproval("other"))
    }

    @Test func backgroundApprovalPostsANotificationThatOpensTheChat() async throws {
        let center = FakeNotificationCenter()
        let suite = "ApprovalCardUITests.notification"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let controller = NotificationController(center: center, defaults: defaults)
        let alert = ApprovalAlert(id: "ap1", storedSessionId: "st1", title: "Plans")
        controller.postApproval(alert, server: nil, isActive: true)
        controller.postApproval(alert, server: nil, isActive: false)
        let deadline = ContinuousClock.now + .seconds(5)
        while center.added.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(center.added.count == 1)
        let content = try #require(center.added.first?.content)
        #expect(content.title == "Hermes asks for approval")
        #expect(content.body == "Plans. Open the chat to answer.")
        #expect(!content.body.contains("gcal"))
        controller.open(userInfo: content.userInfo)
        #expect(controller.pendingSessionId == "st1")
    }

    /// The thread opens at its end: the whole card, with the Deny button, is above the composer.
    @Test func waitingCardAtTheEndIsFullyAboveTheComposer() throws {
        let start = Date(timeIntervalSince1970: 1_763_290_000)
        var messages: [ChatMessage] = (0..<12).map { index in
            ChatMessage(id: "o\(index)", role: index % 2 == 0 ? .user : .assistant, text: "Older message \(index)",
                        date: start, delivery: index % 2 == 0 ? .delivered : nil,
                        reply: index % 2 == 0 ? nil : .complete)
        }
        messages.append(ChatMessage(id: "ap1", role: .assistant, text: "", date: start.addingTimeInterval(5),
                                    approval: ChatApprovalCard(request: request, serverRequestId: .string("srq-1"))))
        let model = ChatViewModel(transport: OfflineChatTransport(), messages: messages)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ApprovalCardUITests")
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(), voiceFolder: folder)
        controller.autoPlayEnabled = { false }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let collection = controller.messagesCollectionView
        controller.view.layoutIfNeeded()
        collection.layoutIfNeeded()
        let last = collection.numberOfSections - 1
        let cell = try #require(collection.cellForItem(at: IndexPath(item: 0, section: last)) as? ChatApprovalCell)
        let card = cell.contentView.convert(cell.messageContainerView.frame, to: collection)
        let deny = try #require(cell.buttons.last)
        let denyFrame = deny.convert(deny.bounds, to: collection)
        let visibleBottom = collection.contentOffset.y + collection.bounds.height - collection.adjustedContentInset.bottom
        #expect(denyFrame.maxY <= card.maxY + 0.5, "the Deny button is inside the card")
        #expect(card.maxY <= visibleBottom + 1, "card \(card), visible bottom \(visibleBottom)")
    }
}
