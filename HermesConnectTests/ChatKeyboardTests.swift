import Foundation
import HermesKit
import InputBarAccessoryView
import MessageKit
import Testing
import UIKit
@testable import HermesConnect

/// Issue #60: the composer sits on the keyboard with only its padding, and the last bubble has 10 pt to the composer.
/// The tests post the keyboard notifications. The real keyboard does not show in a test run.
@MainActor
@Suite(.serialized) struct ChatKeyboardTests {
    private let date = Date(timeIntervalSince1970: 1_763_290_000)
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatKeyboardTests")
    private let keyboardHeight: CGFloat = 336

    /// A thread that is taller than the screen. The last message is from Hermes, with no footnote under it.
    private func messages(_ count: Int = 30) -> [ChatMessage] {
        (0..<count).map { index in
            let role: ChatMessage.Role = index % 2 == 0 ? .user : .assistant
            return ChatMessage(id: "m\(index)", role: role, text: "Message \(index)",
                               date: date.addingTimeInterval(Double(index)), delivery: role == .user ? .delivered : nil,
                               reply: role == .user ? nil : .complete, userRowId: index)
        }
    }

    /// The controller in a window of the test app scene, so that the window has the home indicator inset.
    private func show(_ messages: [ChatMessage]) throws -> (ChatViewController, UIWindow) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let model = ChatViewModel(transport: OfflineChatTransport(), messages: messages)
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(), voiceFolder: folder)
        controller.autoPlayEnabled = { false }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (controller, window)
    }

    private func settle(_ window: UIWindow) async throws {
        // MessageKit sets the thread inset and the pinned scroll on the next turns of the main queue.
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(80))
            window.layoutIfNeeded()
        }
    }

    private func postKeyboard(_ names: [Notification.Name], top: CGFloat, in window: UIWindow) {
        let bounds = window.bounds
        let end = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        for name in names {
            NotificationCenter.default.post(name: name, object: nil, userInfo: [
                UIResponder.keyboardFrameBeginUserInfoKey: NSValue(cgRect: end.offsetBy(dx: 0, dy: end.height)),
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: end),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
                UIResponder.keyboardAnimationCurveUserInfoKey: 7,
                UIResponder.keyboardIsLocalUserInfoKey: true,
            ])
        }
    }

    /// Opens the keyboard. `hostCountsKeyboard`: the safe area of the composer keeps the 34 pt home indicator inset
    /// with the keyboard up, as the app log showed in the SwiftUI host (owner screenshot: a band under the field).
    private func openKeyboard(_ controller: ChatViewController, _ window: UIWindow, hostCountsKeyboard: Bool) {
        let top = window.bounds.height - keyboardHeight
        if hostCountsKeyboard { controller.additionalSafeAreaInsets.bottom = keyboardHeight }
        postKeyboard([UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillChangeFrameNotification],
                     top: top, in: window)
        window.layoutIfNeeded()
    }

    private func closeKeyboard(_ controller: ChatViewController, _ window: UIWindow) {
        controller.additionalSafeAreaInsets.bottom = 0
        postKeyboard([UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification],
                     top: window.bounds.height, in: window)
        window.layoutIfNeeded()
    }

    private func frame(_ view: UIView, in window: UIWindow) -> CGRect {
        view.convert(view.bounds, to: window)
    }

    /// The bubble of the last message, in window points.
    private func lastBubble(_ controller: ChatViewController, in window: UIWindow) throws -> CGRect {
        let collection = controller.messagesCollectionView
        let section = collection.numberOfSections - 1
        let cell = try #require(collection.cellForItem(at: IndexPath(item: 0, section: section)) as? MessageContentCell,
                                "the last bubble is not on the screen")
        return cell.messageContainerView.convert(cell.messageContainerView.bounds, to: window)
    }

    private func centerY(_ view: UIView, in window: UIWindow) -> CGFloat { frame(view, in: window).midY }

    // MARK: Composer padding

    @Test(arguments: [true, false])
    func composerSitsOnTheKeyboardWithOnlyItsPadding(hostCountsKeyboard: Bool) async throws {
        let (controller, window) = try show(messages())
        defer { window.isHidden = true }
        try await settle(window)
        openKeyboard(controller, window, hostCountsKeyboard: hostCountsKeyboard)
        try await settle(window)
        let bar = controller.messageInputBar
        let keyboardTop = window.bounds.height - keyboardHeight
        let field = frame(bar.inputTextView, in: window)
        #expect(abs(frame(bar, in: window).maxY - keyboardTop) <= 1, "bar \(frame(bar, in: window))")
        // Only the normal 8 pt padding under the field. No home indicator band.
        let band = keyboardTop - field.maxY
        #expect(abs(band - bar.padding.bottom) <= 1, "space under the field: \(band)")
        // Issue #49: `+`, field and mic stay on one center line.
        let plus = try #require(bar.leftStackView.arrangedSubviews.first)
        let mic = try #require(bar.rightStackView.arrangedSubviews.first)
        #expect(abs(centerY(plus, in: window) - field.midY) <= 1)
        #expect(abs(centerY(mic, in: window) - field.midY) <= 1)
        closeKeyboard(controller, window)
    }

    @Test func composerClearsTheHomeIndicatorWithTheKeyboardDownAndAfterTheKeyboard() async throws {
        let (controller, window) = try show(messages())
        defer { window.isHidden = true }
        try await settle(window)
        let bar = controller.messageInputBar
        let home = window.safeAreaInsets.bottom
        #expect(home > 0, "the test window has no home indicator inset")
        func check(_ moment: String) {
            let field = frame(bar.inputTextView, in: window)
            let space = window.bounds.height - home - field.maxY
            #expect(abs(space - bar.padding.bottom) <= 1, "\(moment): space above the home indicator \(space)")
            #expect(abs(frame(bar, in: window).maxY - window.bounds.height) <= 1, "\(moment): bar \(frame(bar, in: window))")
        }
        check("before the keyboard")
        openKeyboard(controller, window, hostCountsKeyboard: true)
        try await settle(window)
        closeKeyboard(controller, window)
        try await settle(window)
        check("after the keyboard")
    }

    // MARK: Gap to the last bubble

    @Test(arguments: [false, true])
    func lastBubbleHas10PointsToTheComposer(keyboardUp: Bool) async throws {
        let (controller, window) = try show(messages())
        defer { window.isHidden = true }
        try await settle(window)
        if keyboardUp {
            openKeyboard(controller, window, hostCountsKeyboard: true)
            try await settle(window)
        }
        // The thread stays at the bottom, so the last message shows above the composer.
        #expect(controller.isPinnedToBottom)
        let bar = frame(controller.messageInputBar, in: window)
        let bubble = try lastBubble(controller, in: window)
        let gap = bar.minY - bubble.maxY
        #expect(abs(gap - ChatComposerLayout.threadGap) <= 1, "keyboard up \(keyboardUp): gap \(gap)")
        if keyboardUp { closeKeyboard(controller, window) }
    }

    // MARK: Hide the keyboard (issue #65)

    /// Opens the composer with a draft. Returns the text view, which is the first responder.
    private func focusComposer(_ controller: ChatViewController, draft: String) throws -> UITextView {
        let field = controller.messageInputBar.inputTextView
        field.text = draft
        #expect(field.becomeFirstResponder())
        try #require(field.isFirstResponder, "the composer did not take the focus")
        return field
    }

    private func taps(_ controller: ChatViewController, count: Int) -> [UITapGestureRecognizer] {
        (controller.messagesCollectionView.gestureRecognizers ?? [])
            .compactMap { $0 as? UITapGestureRecognizer }.filter { $0.numberOfTapsRequired == count }
    }

    @Test func singleTapOnTheThreadWaitsForTheDoubleTapAndHidesTheKeyboard() async throws {
        let (controller, window) = try show(messages())
        defer { window.isHidden = true }
        try await settle(window)
        let field = try focusComposer(controller, draft: "Draft text")
        let tap = try #require(taps(controller, count: 1).first { $0.name == ChatKeyboardDismiss.tapName },
                               "the thread has no tap that hides the keyboard")
        let doubleTap = try #require(taps(controller, count: 2).first)
        let bubbleTap = try #require(taps(controller, count: 1).first { $0 !== tap }, "MessageKit's bubble tap")
        // A double-tap opens the tapbacks and does not hide the keyboard.
        #expect(tap.delegate?.gestureRecognizer?(tap, shouldRequireFailureOf: doubleTap) == true)
        // Links, the voice play control and the bubble options still get the tap.
        #expect(tap.delegate?.gestureRecognizer?(tap, shouldRecognizeSimultaneouslyWith: bubbleTap) == true)
        #expect(!tap.cancelsTouchesInView)

        controller.threadTapped()
        #expect(!field.isFirstResponder)
        #expect(field.text == "Draft text")
        // With the keyboard down, a tap changes nothing.
        controller.threadTapped()
        #expect(!field.isFirstResponder)
    }

    @Test func doubleTapOpensTheTapbackPickerAndKeepsTheKeyboard() async throws {
        let (controller, window) = try show(messages(4))
        defer { window.isHidden = true }
        try await settle(window)
        let field = try focusComposer(controller, draft: "Draft text")
        controller.showTapbackPicker(messageId: "m3")
        #expect(controller.tapbackPicker != nil)
        #expect(field.isFirstResponder)
        field.resignFirstResponder()
    }

    /// 30 messages: the thread is at the bottom. 2 messages: the thread is shorter than the screen.
    @Test(arguments: [30, 2])
    func dragDownOnTheThreadHidesTheKeyboard(count: Int) async throws {
        let (controller, window) = try show(messages(count))
        defer { window.isHidden = true }
        try await settle(window)
        #expect(controller.isPinnedToBottom)
        // A short thread still scrolls, so a drag reaches it.
        #expect(controller.messagesCollectionView.alwaysBounceVertical)
        let field = try focusComposer(controller, draft: "Draft text")
        // Small, upward and sideways drags keep the keyboard.
        for keep in [CGPoint(x: 0, y: 8), CGPoint(x: 0, y: -80), CGPoint(x: 80, y: 30)] {
            controller.threadDragged(by: keep)
            #expect(field.isFirstResponder, "drag \(keep) hid the keyboard")
        }
        controller.threadDragged(by: CGPoint(x: 4, y: 40))
        #expect(!field.isFirstResponder)
        #expect(field.text == "Draft text")
    }

    // MARK: Space math

    @Test func bottomSpaceIsThePaddingPlusTheComposerPartOverTheHomeIndicator() {
        let space = { (maxY: CGFloat, home: CGFloat) in
            ChatComposerLayout.bottomSpace(padding: 8, composerMaxY: maxY, windowHeight: 956, homeIndicator: home)
        }
        #expect(space(956, 34) == 42) // keyboard down
        #expect(space(620, 34) == 8) // keyboard up
        #expect(space(939, 34) == 25) // keyboard half way down: part of the home indicator
        #expect(space(980, 34) == 42) // never more than the home indicator
        #expect(space(956, 0) == 8) // no home indicator (iPhone SE, landscape)
    }
}
