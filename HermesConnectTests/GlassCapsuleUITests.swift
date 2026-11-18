import Foundation
import HermesKit
import Testing
import UIKit
@testable import HermesConnect

/// Issue #103: the Glass Capsule recorder. A fake microphone and a fake joiner, no audio hardware.
/// Set `HERMES_SCREENS_DIR` (with the `TEST_RUNNER_` prefix for `xcodebuild`) to write the screens of each state.
@MainActor
@Suite(.serialized) struct GlassCapsuleUITests {
    private let date = Date(timeIntervalSince1970: 1_763_290_000)
    private static var keep: [UIWindow] = []

    private struct Screen {
        let controller: ChatViewController
        let model: ChatViewModel
        let recorder: FakeVoiceRecorder
        let window: UIWindow
    }

    private func thread(_ memo: VoiceMemo? = nil) -> [ChatMessage] {
        var messages = [
            ChatMessage(id: "a1", role: .assistant, text: "I found two places with outdoor tables. Lupa has 7:30 on Saturday.",
                        date: date, reply: .complete, promptId: "u0"),
            ChatMessage(id: "u1", role: .user, text: "Great, book it", date: date.addingTimeInterval(20),
                        delivery: .delivered, userRowId: 1),
            ChatMessage(id: "a2", role: .assistant, text: "Booked for 2 at 7:30. Do you want a reminder?",
                        date: date.addingTimeInterval(30), reply: .complete, promptId: "u1"),
        ]
        if let memo {
            messages.append(ChatMessage(id: "v1", role: .user, text: memo.transcript.text ?? "",
                                        date: date.addingTimeInterval(60), delivery: .delivered, userRowId: 2,
                                        voice: memo))
        }
        return messages
    }

    private func makeScreen(_ messages: [ChatMessage], style: UIUserInterfaceStyle = .light,
                            size: UIContentSizeCategory = .large) -> Screen {
        let recorder = FakeVoiceRecorder()
        let model = ChatViewModel(transport: OfflineChatTransport(), messages: messages)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GlassCapsuleUITests")
        let controller = ChatViewController(model: model, recorder: recorder, joiner: FakeVoiceClipJoiner(),
                                            voiceFolder: folder)
        controller.overrideUserInterfaceStyle = style
        controller.traitOverrides.preferredContentSizeCategory = size
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        Self.keep.append(window)
        return Screen(controller: controller, model: model, recorder: recorder, window: window)
    }

    /// Feeds the waveform a varied voice, so the bars look like speech.
    private func speak(_ screen: Screen, seconds: TimeInterval, steps: Int = 40) {
        for step in 0..<steps {
            screen.recorder.decibels = -40 + 34 * Float(abs(sin(Double(step) * 0.7)))
            screen.recorder.currentTime = seconds * Double(step + 1) / Double(steps)
            screen.controller.voice.tick()
        }
    }

    private func settle(_ screen: Screen) {
        screen.controller.messageInputBar.layoutIfNeeded()
        screen.controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        screen.controller.view.layoutIfNeeded()
    }

    private func recordingBar(_ screen: Screen) throws -> VoiceRecordingBar {
        try #require(screen.controller.messageInputBar.middleContentView as? VoiceRecordingBar)
    }

    // MARK: States

    private enum State: String, CaseIterable {
        case composer, hold, locked, cancel, paused, nearLimit = "near-limit", transcribing, transcript
    }

    private func show(_ state: State, style: UIUserInterfaceStyle, size: UIContentSizeCategory) throws -> Screen {
        let url = URL(fileURLWithPath: "/tmp/glass-capsule.m4a")
        let waveform: [Float] = (0..<VoiceMemoLimits.waveformBars).map { 0.2 + 0.8 * Float(abs(sin(Double($0) * 0.6))) }
        switch state {
        case .transcribing:
            return makeScreen(thread(VoiceMemo(fileURL: url, duration: 14, waveform: waveform, transcript: .pending)),
                              style: style, size: size)
        case .transcript:
            let text = "Yes, remind me Saturday at 6. And tell them we may be one more person."
            return makeScreen(thread(VoiceMemo(fileURL: url, duration: 14, waveform: waveform, transcript: .done(text))),
                              style: style, size: size)
        default:
            break
        }
        let screen = makeScreen(thread(), style: style, size: size)
        let voice = screen.controller.voice
        switch state {
        case .hold:
            voice.press()
            speak(screen, seconds: 7)
            voice.drag(dx: -20, dy: -12)
        case .locked:
            voice.startTapMode()
            speak(screen, seconds: 19)
        case .cancel:
            voice.press()
            speak(screen, seconds: 5)
            voice.drag(dx: -120, dy: 0)
        case .paused:
            voice.startTapMode()
            speak(screen, seconds: 22)
            voice.pause()
        case .nearLimit:
            voice.startTapMode()
            speak(screen, seconds: 575)
        case .composer, .transcribing, .transcript:
            break
        }
        settle(screen)
        return screen
    }

    @Test func eachStateShowsTheRightBar() throws {
        for state in State.allCases {
            let screen = try show(state, style: .light, size: .large)
            let mode = screen.controller.recordingBarMode
            switch state {
            case .composer, .transcribing, .transcript: #expect(mode == nil, "\(state)")
            case .hold:
                guard case .hold(_, let lock) = mode else { Issue.record("hold: \(String(describing: mode))"); break }
                #expect(lock == 0.2)
            case .locked, .nearLimit: #expect(mode == .locked, "\(state)")
            case .cancel: #expect(mode == .cancelArmed)
            case .paused: #expect(mode == .paused)
            }
            screen.controller.voice.cancel()
        }
    }

    @Test func lockedKeysAre56PointsWithTheVoiceOverLabels() throws {
        let screen = try show(.locked, style: .light, size: .large)
        let bar = try recordingBar(screen)
        for key in [bar.deleteButton, bar.middleButton, bar.sendButton] {
            #expect(key.frame.size == CGSize(width: 56, height: 56))
            #expect(!key.isHidden)
        }
        #expect(bar.deleteButton.accessibilityLabel == "Delete Recording")
        #expect(bar.middleButton.accessibilityLabel == "Pause Recording")
        #expect(bar.sendButton.accessibilityLabel == "Send Voice Memo")
        #expect(bar.timeLabel.text == "0:19")
        #expect(bar.statusLabel.attributedText?.string.hasSuffix("Locked") == true)

        bar.middleButton.sendActions(for: .touchUpInside)
        #expect(screen.controller.recordingBarMode == .paused)
        #expect(bar.middleButton.accessibilityLabel == "Resume Recording")
        #expect(bar.playButton.accessibilityLabel == "Play Recording")
        #expect(bar.timeLabel.text == "0:00 / 0:19")
        #expect(bar.statusLabel.text == "Paused · play, add more, or send")

        bar.middleButton.sendActions(for: .touchUpInside)
        #expect(screen.controller.recordingBarMode == .locked)
        bar.sendButton.sendActions(for: .touchUpInside)
        #expect(screen.controller.recordingBarMode == nil)
    }

    @Test func deleteKeyDeletesTheMemo() throws {
        let screen = try show(.paused, style: .light, size: .large)
        try recordingBar(screen).deleteButton.sendActions(for: .touchUpInside)
        #expect(screen.controller.recordingBarMode == nil)
        #expect(screen.controller.voice.isActive == false)
    }

    @Test func nearTheLimitTheTimerIsOrangeAndCountsDown() throws {
        let screen = try show(.nearLimit, style: .light, size: .large)
        let bar = try recordingBar(screen)
        #expect(bar.timeLabel.text == "0:25")
        #expect(bar.timeLabel.textColor == .systemOrange)
        #expect(bar.timeLabel.accessibilityLabel == "Recording, 25 seconds left")
    }

    @Test func cancelShowsReleaseToDelete() throws {
        let screen = try show(.cancel, style: .light, size: .large)
        let bar = try recordingBar(screen)
        #expect(bar.statusLabel.text == "Slide back to keep recording")
        #expect(bar.timeLabel.isHidden)
        #expect(bar.deleteButton.isHidden)
    }

    /// AX5: the locked bar keeps two rows (timer and bars, then the keys), and the keys stay 56 pt.
    @Test func ax5KeepsTheKeysAt56PointsUnderTheCapsule() throws {
        let screen = try show(.locked, style: .light, size: .accessibilityExtraExtraExtraLarge)
        let bar = try recordingBar(screen)
        #expect(bar.capsuleHeight > 44)
        for key in [bar.deleteButton, bar.middleButton, bar.sendButton] {
            #expect(key.frame.size == CGSize(width: 56, height: 56))
            #expect(key.frame.minY >= bar.timeLabel.convert(bar.timeLabel.bounds, to: bar).maxY)
        }
        let time = bar.timeLabel.convert(bar.timeLabel.bounds, to: bar)
        #expect(time.maxX <= bar.bounds.width)
    }

    @Test func reduceMotionBarsUpdateInPlace() {
        #expect(VoiceRecordingBar.inPlace([0.1, 0.2], count: 4) == [0.1, 0.2, 0, 0])
        // The 5th level writes over the 1st bar. The others keep their place.
        #expect(VoiceRecordingBar.inPlace([0.1, 0.2, 0.3, 0.4, 0.5], count: 4) == [0.5, 0.2, 0.3, 0.4])
        #expect(VoiceRecordingBar.inPlace([], count: 3) == [0, 0, 0])
    }

    @Test func memoTranscriptShowsInACardWithTheFooter() throws {
        let screen = try show(.transcript, style: .light, size: .large)
        settle(screen)
        let collection = screen.controller.messagesCollectionView
        let cell = try #require(collection.visibleCells.compactMap { $0 as? ChatVoiceCell }.first)
        #expect(!cell.transcriptCard.isHidden)
        #expect(cell.transcriptCard.frame.contains(cell.transcriptLabel.frame))
        #expect(cell.transcriptLabel.font == UIFont.preferredFont(forTextStyle: .subheadline))
        #expect(cell.messageBottomLabel.text == "Transcript · Delivered")
        #expect(!cell.transcribingBars.isActive)
    }

    @Test func pendingMemoPulsesBesideTranscribing() throws {
        let screen = try show(.transcribing, style: .light, size: .large)
        settle(screen)
        let cell = try #require(screen.controller.messagesCollectionView.visibleCells
            .compactMap { $0 as? ChatVoiceCell }.first)
        #expect(cell.transcriptLabel.text == "Transcribing…")
        #expect(cell.transcribingBars.isActive)
        #expect(cell.transcribingBars.frame.maxX <= cell.transcriptLabel.frame.minX)
        #expect(cell.transcriptCard.isHidden)
    }

    // MARK: Real touch paths (QA #116 defect 2)

    /// The center of `view` in the view of the chat screen, where the mic recognizer reads its points.
    private func center(of view: UIView, in screen: Screen) -> CGPoint {
        view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: screen.controller.view)
    }

    /// Hit-tests the center of `key` in its window, then taps the control that the touch reaches.
    private func tap(_ key: UIControl) throws {
        let window = try #require(key.window)
        let point = key.convert(CGPoint(x: key.bounds.midX, y: key.bounds.midY), to: window)
        let hit = try #require(window.hitTest(point, with: nil))
        #expect(hit.isDescendant(of: key), "the touch reached \(type(of: hit)), not the key")
        var control: UIView? = hit
        while let view = control, !(view is UIControl) { control = view.superview }
        (control as? UIControl)?.sendActions(for: .touchUpInside)
    }

    @Test func micRecognizerIsOnTheComposerAndStartsAtOnce() throws {
        let screen = makeScreen(thread())
        let recognizer = screen.controller.micPressRecognizer
        #expect(recognizer.view === screen.controller.messageInputBar)
        #expect(recognizer.minimumPressDuration == 0)
        #expect(recognizer.delegate != nil)
    }

    /// The 64 pt hit area of the mic takes the touch. The text field and an active recording do not.
    @Test func micHitAreaTakesTouchesOnTheMicOnly() throws {
        let screen = makeScreen(thread())
        let bar = screen.controller.messageInputBar
        bar.layoutIfNeeded()
        let mic = try #require(bar.rightStackView.arrangedSubviews.first)
        let frame = mic.convert(mic.bounds, to: bar)
        #expect(screen.controller.micPressShouldReceive(at: CGPoint(x: frame.midX, y: frame.midY)))
        #expect(screen.controller.micPressShouldReceive(at: CGPoint(x: frame.minX - 9, y: frame.midY)))
        #expect(!screen.controller.micPressShouldReceive(at: CGPoint(x: frame.minX - 12, y: frame.midY)))
        let field = bar.inputTextView.convert(bar.inputTextView.bounds, to: bar)
        #expect(!screen.controller.micPressShouldReceive(at: CGPoint(x: field.midX, y: field.midY)))
        screen.controller.voice.startTapMode()
        #expect(!screen.controller.micPressShouldReceive(at: CGPoint(x: frame.midX, y: frame.midY)))
        screen.controller.voice.cancel()
    }

    /// Recognizer points map to the slide: up 60 pt locks, and the finger can lift.
    @Test func micPressSlideUpLocks() throws {
        let screen = makeScreen(thread())
        let mic = try #require(screen.controller.messageInputBar.rightStackView.arrangedSubviews.first)
        let start = center(of: mic, in: screen)
        let controller = screen.controller
        controller.handleMicPress(.began, at: start)
        guard case .hold = controller.recordingBarMode else { Issue.record("expected the hold bar"); return }
        controller.handleMicPress(.changed, at: CGPoint(x: start.x - 4, y: start.y - 30))
        guard case .hold(_, let lock) = controller.recordingBarMode else { Issue.record("expected hold"); return }
        #expect(lock == 0.5)
        controller.handleMicPress(.changed, at: CGPoint(x: start.x - 4, y: start.y - 61))
        #expect(controller.recordingBarMode == .locked)
        controller.handleMicPress(.ended, at: CGPoint(x: start.x, y: start.y - 61))
        #expect(controller.recordingBarMode == .locked)
        controller.voice.cancel()
    }

    /// Recognizer points map to the slide: left 100 pt arms the cancel, and the release deletes.
    @Test func micPressSlideLeftThenReleaseDeletes() throws {
        let screen = makeScreen(thread())
        let mic = try #require(screen.controller.messageInputBar.rightStackView.arrangedSubviews.first)
        let start = center(of: mic, in: screen)
        let controller = screen.controller
        controller.handleMicPress(.began, at: start)
        controller.handleMicPress(.changed, at: CGPoint(x: start.x - 99, y: start.y))
        #expect(controller.recordingBarMode != .cancelArmed)
        controller.handleMicPress(.changed, at: CGPoint(x: start.x - 101, y: start.y + 3))
        #expect(controller.recordingBarMode == .cancelArmed)
        controller.handleMicPress(.ended, at: CGPoint(x: start.x - 101, y: start.y))
        #expect(controller.recordingBarMode == nil)
        #expect(screen.recorder.discards == 1)
        #expect(screen.model.messages.count == 3)
    }

    /// A hold of 0.3 s or more, then the release, sends the memo. A system cancel pauses.
    @Test func micPressHoldThenReleaseSendsAndSystemCancelPauses() throws {
        let screen = makeScreen(thread())
        let mic = try #require(screen.controller.messageInputBar.rightStackView.arrangedSubviews.first)
        let start = center(of: mic, in: screen)
        let controller = screen.controller
        controller.handleMicPress(.began, at: start)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        screen.recorder.currentTime = 2
        controller.handleMicPress(.ended, at: start)
        #expect(controller.recordingBarMode == nil)
        #expect(screen.model.messages.last?.voice?.duration == 2)

        controller.handleMicPress(.began, at: start)
        controller.handleMicPress(.cancelled, at: start)
        #expect(controller.recordingBarMode == .paused)
        controller.voice.cancel()
    }

    /// A touch on each capsule key reaches that key in the laid-out bar.
    @Test func capsuleKeysTakeTouchesInTheLaidOutBar() throws {
        let screen = try show(.locked, style: .light, size: .large)
        let bar = try recordingBar(screen)
        try tap(bar.middleButton)
        #expect(screen.controller.recordingBarMode == .paused)
        settle(screen)
        try tap(bar.playButton)
        try tap(bar.middleButton)
        #expect(screen.controller.recordingBarMode == .locked)
        settle(screen)
        screen.recorder.currentTime = 3
        try tap(bar.sendButton)
        #expect(screen.controller.recordingBarMode == nil)
        #expect(screen.model.messages.last?.voice != nil)

        let other = try show(.locked, style: .light, size: .accessibilityExtraExtraExtraLarge)
        try tap(try recordingBar(other).deleteButton)
        #expect(other.controller.recordingBarMode == nil)
        #expect(other.model.messages.count == 3)
    }

    /// The screens of each state in light, dark and AX5 (`.team/screens/103/`).
    @Test func screens() throws {
        let folder = ProcessInfo.processInfo.environment["HERMES_SCREENS_DIR"].map { URL(fileURLWithPath: $0) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for state in State.allCases {
            for (style, size, suffix) in [(UIUserInterfaceStyle.light, UIContentSizeCategory.large, "light"),
                                          (.dark, .large, "dark"),
                                          (.light, .accessibilityExtraExtraExtraLarge, "ax5")] {
                let screen = try show(state, style: style, size: size)
                let image = UIGraphicsImageRenderer(bounds: screen.window.bounds).image { _ in
                    screen.window.drawHierarchy(in: screen.window.bounds, afterScreenUpdates: true)
                }
                #expect(image.size.width > 0)
                if let folder {
                    try image.pngData()?.write(to: folder.appending(path: "\(state.rawValue)-\(suffix).png"))
                }
                screen.controller.voice.cancel()
                screen.window.isHidden = true
            }
        }
    }
}
