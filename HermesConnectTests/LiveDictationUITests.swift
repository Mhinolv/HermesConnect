import HermesKit
import InputBarAccessoryView
import Testing
import UIKit
@testable import HermesConnect

/// Issue #170: a recognizer that the test drives.
@MainActor
private final class ScriptedSpeechSource: LiveSpeechSource {
    private var continuation: AsyncThrowingStream<LiveDictationEvent, any Error>.Continuation?
    var failure: LiveDictationFailure?
    var lastResults: [LiveDictationEvent] = []

    func start() async throws(LiveDictationFailure) -> AsyncThrowingStream<LiveDictationEvent, any Error> {
        if let failure { throw failure }
        let (stream, continuation) = AsyncThrowingStream<LiveDictationEvent, any Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func finish() async {
        for event in lastResults { continuation?.yield(event) }
        continuation?.finish()
    }

    func cancel() { continuation?.finish() }
    func send(_ event: LiveDictationEvent) { continuation?.yield(event) }
}

@MainActor
@Suite(.serialized) struct LiveDictationUITests {
    private func makeController(_ source: ScriptedSpeechSource, transport: any ChatTransport = OfflineChatTransport())
        -> (ChatViewController, ChatViewModel) {
        ChatViewController.makeDictationSource = { source }
        let model = ChatViewModel(transport: transport)
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(),
                                            voiceFolder: FileManager.default.temporaryDirectory
                                                .appendingPathComponent("LiveDictationUITests"))
        controller.loadViewIfNeeded()
        ChatViewController.makeDictationSource = { AppleLiveDictationSource() }
        return (controller, model)
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    @Test func theDictateKeySitsLeftOfTheMicAndOfSend() {
        let (controller, _) = makeController(ScriptedSpeechSource())
        let bar = controller.messageInputBar
        #expect(bar.rightStackViewItems.first as? UIView === controller.dictateButton)
        #expect(controller.dictateButton.accessibilityLabel == "Dictate")
        controller.inputBar(bar, textViewTextDidChangeTo: "hi")
        #expect(bar.rightStackViewItems.first as? UIView === controller.dictateButton)
        #expect(bar.rightStackViewItems.last as? UIView === bar.sendButton)
    }

    @Test func partialWordsShowInTheBoxThenStayForEditing() async {
        let source = ScriptedSpeechSource()
        source.lastResults = [.final("Book the flight.")]
        let (controller, model) = makeController(source)
        let textView = controller.messageInputBar.inputTextView
        textView.text = "Note:"
        controller.inputBar(controller.messageInputBar, textViewTextDidChangeTo: "Note:")
        controller.dictateButton.sendActions(for: .touchUpInside)
        await settle { controller.dictation.state == .listening }
        #expect(controller.dictateButton.accessibilityLabel == "Stop Dictation")

        source.send(.partial("Book the"))
        await settle { textView.text == "Note: Book the" }
        let color = textView.attributedText.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? UIColor
        #expect(color == .secondaryLabel)

        controller.dictateButton.sendActions(for: .touchUpInside)
        await settle { controller.dictation.state == .idle }
        #expect(textView.text == "Note: Book the flight.")
        let final = textView.attributedText.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? UIColor
        #expect(final == .label)
        #expect(model.messages.isEmpty, "dictation never sends")
        #expect(controller.dictateButton.accessibilityLabel == "Dictate")
    }

    @Test func typingStopsTheDictationAndKeepsTheTypedText() async {
        let source = ScriptedSpeechSource()
        let (controller, _) = makeController(source)
        let bar = controller.messageInputBar
        controller.dictateButton.sendActions(for: .touchUpInside)
        await settle { controller.dictation.state == .listening }
        source.send(.partial("hello"))
        await settle { bar.inputTextView.text == "hello" }
        bar.inputTextView.text = "hello!"
        controller.inputBar(bar, textViewTextDidChangeTo: "hello!")
        #expect(!controller.dictation.isActive)
        source.send(.final("hello world"))
        await Task.yield()
        #expect(bar.inputTextView.text == "hello!")
    }

    @Test func aTapOnTheDictateKeyNeverStartsAMemo() throws {
        let (controller, _) = makeController(ScriptedSpeechSource())
        // The mic takes touches only in a window (`micPressShouldReceive`).
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let bar = controller.messageInputBar
        bar.layoutIfNeeded()
        let dictate = controller.dictateButton.convert(controller.dictateButton.bounds, to: bar)
        let mic = try #require(bar.rightStackView.arrangedSubviews.last)
        let micFrame = mic.convert(mic.bounds, to: bar)
        #expect(controller.micPressShouldReceive(at: CGPoint(x: micFrame.midX, y: micFrame.midY)))
        #expect(!controller.micPressShouldReceive(at: CGPoint(x: dictate.maxX - 1, y: dictate.midY)))
        #expect(!controller.micPressShouldReceive(at: CGPoint(x: dictate.midX, y: dictate.midY)))
    }

    @Test func theMicDoesNotStartAMemoDuringDictation() async {
        let source = ScriptedSpeechSource()
        let (controller, _) = makeController(source)
        controller.dictateButton.sendActions(for: .touchUpInside)
        await settle { controller.dictation.state == .listening }
        #expect(!controller.micPressShouldReceive(at: .zero))
        #expect(controller.recordingBarMode == nil)
    }

    @Test func noModelKeepsTheTextAndEndsTheDictation() async {
        let source = ScriptedSpeechSource()
        source.failure = .modelNotInstalled
        let (controller, _) = makeController(source)
        controller.dictateButton.sendActions(for: .touchUpInside)
        await settle { controller.dictation.state == .idle }
        #expect(controller.dictateButton.accessibilityLabel == "Dictate")
    }
}
