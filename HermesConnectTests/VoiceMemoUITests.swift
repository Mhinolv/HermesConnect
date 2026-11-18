import Foundation
import HermesKit
import Testing
import UIKit
@testable import HermesConnect

/// A recorder with no microphone. Tests set the clip time and the permission.
@MainActor
final class FakeVoiceRecorder: VoiceRecording {
    var access: MicrophoneAccess = .granted
    var grants = true
    var failStart = false
    var currentTime: TimeInterval = 0
    var decibels: Float = -25
    private(set) var started: [URL] = []
    private(set) var accessRequests = 0
    private(set) var pauses = 0
    private(set) var stops = 0
    private(set) var discards = 0
    var onInterruption: (() -> Void)?

    struct StartFailed: Error {}

    func requestAccess() async -> Bool {
        accessRequests += 1
        return grants
    }

    func start(url: URL) throws {
        if failStart { throw StartFailed() }
        started.append(url)
    }

    func pause() { pauses += 1 }

    func stop() -> TimeInterval {
        stops += 1
        return currentTime
    }

    func discard() { discards += 1 }

    func level() -> Float { decibels }
}

/// Issue #103: joins the parts of a memo with no audio work. It answers at once.
@MainActor
final class FakeVoiceClipJoiner: VoiceClipJoining {
    var succeeds = true
    private(set) var joins: [(parts: [URL], target: URL)] = []

    func join(_ parts: [URL], into url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        joins.append((parts, url))
        completion(succeeds)
    }
}

@MainActor
private final class VoiceHarness {
    let recorder = FakeVoiceRecorder()
    let joiner = FakeVoiceClipJoiner()
    var now: TimeInterval = 100
    var sent: [VoiceMemo] = []
    var haptics: [VoiceHaptic] = []
    var announcements: [String] = []
    var denied = 0
    var failed = 0
    var voiceOver = false
    let controller: VoiceMemoController

    init() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceMemoUITests")
        var clock: () -> TimeInterval = { 0 }
        controller = VoiceMemoController(recorder: recorder, joiner: joiner, folder: folder, clock: { clock() })
        clock = { [unowned self] in self.now }
        controller.onSend = { [unowned self] in self.sent.append($0) }
        controller.onHaptic = { [unowned self] in self.haptics.append($0) }
        controller.onAnnounce = { [unowned self] in self.announcements.append($0) }
        controller.onAccessDenied = { [unowned self] in self.denied += 1 }
        controller.onRecordFailed = { [unowned self] in self.failed += 1 }
        controller.isVoiceOverRunning = { [unowned self] in self.voiceOver }
    }
}

@MainActor
@Suite struct VoiceMemoControllerTests {
    @Test func tapRecordsHandsFreeThenSendSendsTheMemo() throws {
        let h = VoiceHarness()
        #expect(h.controller.press())
        #expect(h.recorder.started.count == 1)
        #expect(h.recorder.started.first?.pathExtension == "m4a")
        #expect(h.haptics == [.start])
        h.now += 0.1
        h.controller.release()
        #expect(h.controller.capture.phase == .recording)

        h.recorder.currentTime = 12.5
        h.controller.tick()
        #expect(h.controller.elapsed == 12.5)
        h.controller.send()
        let memo = try #require(h.sent.first)
        #expect(memo.duration == 12.5)
        #expect(memo.fileURL == h.recorder.started.first)
        #expect(memo.waveform.count == VoiceMemoLimits.waveformBars)
        #expect(memo.waveform.allSatisfy { $0 == 0.5 })
        #expect(h.recorder.stops == 1)
        #expect(h.haptics == [.start, .sent])
        #expect(!h.controller.isActive)
    }

    @Test func holdThenReleaseSends() {
        let h = VoiceHarness()
        h.controller.press()
        h.now += 0.4
        h.controller.tick()
        #expect(h.controller.capture.phase == .holding)
        h.recorder.currentTime = 3
        h.controller.release()
        #expect(h.sent.map(\.duration) == [3])
    }

    /// Issue #103: past 100 pt the cancel arms with a warning haptic. The release deletes the clip.
    @Test func slideLeftPastTheThresholdThenReleaseDeletesTheClip() {
        let h = VoiceHarness()
        h.controller.press()
        h.now += 0.5
        h.controller.tick()
        h.controller.drag(dx: -40)
        h.controller.drag(dx: -101)
        #expect(h.controller.isActive)
        #expect(h.controller.capture.cancelArmed)
        #expect(h.haptics == [.start, .warning])
        h.controller.release()
        #expect(!h.controller.isActive)
        #expect(h.recorder.discards == 1)
        #expect(h.sent.isEmpty)
        #expect(h.haptics.last == .cancelled)
        // A late release does nothing.
        h.controller.release()
        #expect(h.sent.isEmpty)
    }

    /// Issue #103: a slide up of 60 pt locks with the `.rigid` haptic. The finger lifts and it records on.
    @Test func slideUpLocksThenTheKeysSend() throws {
        let h = VoiceHarness()
        h.controller.press()
        h.now += 0.5
        h.controller.tick()
        h.controller.drag(dx: -5, dy: -61)
        #expect(h.controller.capture.phase == .recording)
        #expect(h.haptics == [.start, .lock])
        h.controller.release()
        #expect(h.controller.isActive)
        h.recorder.currentTime = 7
        h.controller.tick()
        h.controller.send()
        #expect(try #require(h.sent.first).duration == 7)
        #expect(h.haptics.last == .sent)
    }

    /// Issue #103: Pause keeps the clip as a playable file. Add More records a new part. Send joins the parts.
    @Test func pausePlaysThenAddMoreThenSendJoinsTheParts() throws {
        let h = VoiceHarness()
        h.controller.startTapMode()
        h.recorder.currentTime = 5
        h.controller.tick()
        h.controller.pause()
        #expect(h.controller.capture.phase == .paused)
        #expect(h.recorder.stops == 1)
        #expect(h.controller.elapsed == 5)
        let first = try #require(h.recorder.started.first)
        #expect(h.controller.reviewURL == first)

        h.controller.resume()
        #expect(h.controller.capture.phase == .recording)
        #expect(h.recorder.started.count == 2)
        #expect(h.controller.reviewURL == nil)
        h.recorder.currentTime = 3
        h.controller.tick()
        #expect(h.controller.elapsed == 8)
        h.controller.pause()
        // Two parts join into one file, so the paused clip plays as one.
        #expect(h.joiner.joins.count == 1)
        #expect(h.joiner.joins.first?.parts == h.recorder.started)
        let review = try #require(h.controller.reviewURL)
        #expect(review == h.joiner.joins.first?.target)

        h.controller.send()
        let memo = try #require(h.sent.first)
        #expect(memo.duration == 8)
        #expect(memo.fileURL == review)
        #expect(!h.controller.isActive)
    }

    @Test func sendWhileRecordingTheSecondPartJoinsThePartsFirst() throws {
        let h = VoiceHarness()
        h.controller.startTapMode()
        h.recorder.currentTime = 4
        h.controller.tick()
        h.controller.pause()
        h.controller.resume()
        h.recorder.currentTime = 2
        h.controller.tick()
        h.controller.send()
        let memo = try #require(h.sent.first)
        #expect(memo.duration == 6)
        #expect(h.joiner.joins.count == 1)
        #expect(memo.fileURL == h.joiner.joins.first?.target)
    }

    @Test func failedJoinShowsTheAlertAndSendsNothing() {
        let h = VoiceHarness()
        h.joiner.succeeds = false
        h.controller.startTapMode()
        h.controller.pause()
        h.controller.resume()
        h.controller.send()
        #expect(h.sent.isEmpty)
        #expect(h.failed == 1)
        #expect(!h.controller.isActive)
    }

    @Test func deleteWhilePausedDeletesTheClip() throws {
        let h = VoiceHarness()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceMemoUITests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        h.controller.startTapMode()
        h.controller.pause()
        let part = try #require(h.controller.reviewURL)
        try Data([1, 2, 3]).write(to: part)
        h.controller.cancel()
        #expect(!FileManager.default.fileExists(atPath: part.path))
        #expect(h.recorder.discards == 0)
        #expect(h.sent.isEmpty)
        #expect(h.haptics.last == .cancelled)
    }

    @Test func addMoreThatFailsToStartStaysPaused() {
        let h = VoiceHarness()
        h.controller.startTapMode()
        h.controller.pause()
        h.recorder.failStart = true
        h.controller.resume()
        #expect(h.controller.capture.phase == .paused)
        #expect(h.failed == 1)
    }

    /// Main decision 2026-11-17: at 10:00 the recording stops and the memo sends, also after Add More.
    @Test func tenMinutesAcrossPartsSends() throws {
        let h = VoiceHarness()
        h.controller.startTapMode()
        h.recorder.currentTime = 400
        h.controller.tick()
        h.controller.pause()
        h.controller.resume()
        h.recorder.currentTime = 200
        h.controller.tick()
        #expect(try #require(h.sent.first).duration == 600)
        #expect(!h.controller.isActive)
    }

    @Test func microphoneOffShowsTheAlertAndDoesNotRecord() {
        let h = VoiceHarness()
        h.recorder.access = .denied
        #expect(!h.controller.press())
        #expect(!h.controller.startTapMode())
        #expect(h.denied == 2)
        #expect(h.recorder.started.isEmpty)
    }

    @Test func firstUseAsksForPermissionAndDoesNotRecordYet() async throws {
        let h = VoiceHarness()
        h.recorder.access = .undetermined
        #expect(!h.controller.press())
        for _ in 0..<100 where h.recorder.accessRequests == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(h.recorder.accessRequests == 1)
        #expect(h.recorder.started.isEmpty)
        #expect(h.denied == 0)
    }

    @Test func recorderFailureShowsAnAlert() {
        let h = VoiceHarness()
        h.recorder.failStart = true
        #expect(!h.controller.press())
        #expect(h.failed == 1)
        #expect(!h.controller.isActive)
    }

    @Test func interruptionPausesAndKeepsTheClip() throws {
        let h = VoiceHarness()
        h.controller.startTapMode()
        h.recorder.currentTime = 30
        h.recorder.onInterruption?()
        #expect(h.controller.capture.phase == .paused)
        // Issue #103: the part is finished, so the owner can play it.
        #expect(h.recorder.stops == 1)
        #expect(h.controller.elapsed == 30)
        h.controller.send()
        #expect(try #require(h.sent.first).duration == 30)
    }

    @Test func warningAtNineThirtyAndSendAtTen() {
        let h = VoiceHarness()
        h.controller.startTapMode()
        h.recorder.currentTime = 570
        h.controller.tick()
        #expect(h.haptics == [.start, .warning])
        h.recorder.currentTime = 600
        h.controller.tick()
        #expect(h.sent.map(\.duration) == [600])
        #expect(!h.controller.isActive)
    }

    @Test func voiceOverHearsTheMinutes() {
        let h = VoiceHarness()
        h.voiceOver = true
        h.controller.startTapMode()
        h.recorder.currentTime = 61
        h.controller.tick()
        h.recorder.currentTime = 125
        h.controller.tick()
        #expect(h.announcements == ["1 minute", "2 minutes"])
    }
}

@MainActor
@Suite struct VoiceComposerTests {
    private func makeController(_ messages: [ChatMessage] = []) -> (ChatViewController, ChatViewModel, FakeVoiceRecorder) {
        let recorder = FakeVoiceRecorder()
        let model = ChatViewModel(transport: OfflineChatTransport(), messages: messages)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceComposerTests")
        let controller = ChatViewController(model: model, recorder: recorder, voiceFolder: folder)
        controller.loadViewIfNeeded()
        return (controller, model, recorder)
    }

    @Test func micShowsOnlyWhileTheTextIsEmpty() {
        let (controller, _, _) = makeController()
        #expect(controller.showsMic)
        let bar = controller.messageInputBar
        controller.inputBar(bar, textViewTextDidChangeTo: "hi")
        #expect(!controller.showsMic)
        #expect((bar.rightStackViewItems.first as? UIView) === bar.sendButton)
        controller.inputBar(bar, textViewTextDidChangeTo: "  ")
        #expect(controller.showsMic)
        let mic = bar.rightStackViewItems.first as? UIView
        #expect(mic?.accessibilityLabel == "Record Voice Memo")
    }

    @Test func recordingBarReplacesTheComposerThenTheMemoBubbleShows() async throws {
        let (controller, model, recorder) = makeController()
        #expect(controller.recordingBarMode == nil)
        controller.voice.startTapMode()
        #expect(controller.recordingBarMode == .locked)
        recorder.currentTime = 4
        controller.voice.interrupt()
        #expect(controller.recordingBarMode == .paused)
        controller.voice.send()
        #expect(controller.recordingBarMode == nil)
        #expect(controller.showsMic)
        let memo = try #require(model.messages.first?.voice)
        #expect(memo.duration == 4)
        // The controller draws on the next main-actor turn.
        for _ in 0..<100 where controller.messagesCollectionView.numberOfSections == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.messagesCollectionView.numberOfSections == 1)
    }

    @Test func holdModeShowsSlideToCancel() {
        let (controller, model, _) = makeController()
        controller.voice.press()
        guard case .hold = controller.recordingBarMode else {
            Issue.record("expected the hold bar")
            return
        }
        controller.voice.cancel()
        #expect(controller.recordingBarMode == nil)
        #expect(model.messages.isEmpty)
    }

    @Test func voiceBubbleDrawsInTheVoiceCellWithTheTranscriptHeight() throws {
        let url = URL(fileURLWithPath: "/tmp/none.m4a")
        let long = String(repeating: "Remind me to call Sam about the lease. ", count: 6)
        let messages = [ChatMessage(id: "v", role: .user, text: long, date: .now, delivery: .delivered,
                                    voice: VoiceMemo(fileURL: url, duration: 14, waveform: [0.5, 1],
                                                     transcript: .done(long)))]
        let (controller, _, _) = makeController(messages)
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        let collection = controller.messagesCollectionView
        collection.layoutIfNeeded()
        let cell = try #require(collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? ChatVoiceCell)
        #expect(cell.transcriptLabel.numberOfLines == ChatVoiceLayout.collapsedLines)
        #expect(cell.transcriptLabel.frame.minY >= cell.messageContainerView.frame.maxY)
        #expect(cell.messageBottomLabel.frame.minY >= cell.transcriptLabel.frame.maxY)
    }

    @Test func transcriptLayoutCollapsesToThreeLines() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let memo = VoiceMemo(fileURL: URL(fileURLWithPath: "/tmp/x.m4a"), duration: 3, waveform: [],
                             transcript: .done(String(repeating: "word ", count: 80)))
        let text = ChatVoiceLayout.transcriptText(for: memo, traits: traits)
        let font = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        let collapsed = ChatVoiceLayout.transcriptHeight(text, width: 240, expanded: false)
        let expanded = ChatVoiceLayout.transcriptHeight(text, width: 240, expanded: true)
        // Issue #49: a label measures the 3 lines, so they need a little more than 3 * lineHeight. Not 4 lines.
        #expect(collapsed > font.lineHeight * 3)
        #expect(collapsed < font.lineHeight * 4 + 6)
        #expect(expanded > collapsed)
        #expect(ChatVoiceLayout.isTruncated(text, width: 240))

        var empty = memo
        empty.transcript = .empty
        #expect(ChatVoiceLayout.transcriptText(for: empty, traits: traits) == nil)
        var pending = memo
        pending.transcript = .pending
        #expect(ChatVoiceLayout.transcriptText(for: pending, traits: traits)?.string == "Transcribing…")
        var failed = memo
        failed.transcript = .failed
        #expect(ChatVoiceLayout.transcriptText(for: failed, traits: traits)?.string == "Couldn't transcribe")
    }

    @Test func bubbleGrowsWithTextSizeButFitsTheColumn() {
        let large = ChatVoiceLayout.bubbleSize(traits: UITraitCollection(preferredContentSizeCategory: .large),
                                               maxWidth: 300)
        let ax5 = ChatVoiceLayout.bubbleSize(
            traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge), maxWidth: 300)
        #expect(large.height >= 48)
        #expect(ax5.height > large.height)
        #expect(ax5.width <= 300)
    }
}
