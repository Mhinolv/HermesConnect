import Foundation
import HermesKit
import InputBarAccessoryView
import MessageKit
import Testing
import UIKit
@testable import HermesConnect

/// Issue #49: bubble space, the composer line, the voice reply length and the tapback badge.
@MainActor
@Suite(.serialized) struct ChatLayoutTests {
    private let date = Date(timeIntervalSince1970: 1_763_290_000)
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatLayoutTests")

    private func makeController(_ messages: [ChatMessage]) -> ChatViewController {
        let model = ChatViewModel(transport: OfflineChatTransport(), messages: messages)
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(), voiceFolder: folder)
        controller.autoPlayEnabled = { false }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        controller.messagesCollectionView.layoutIfNeeded()
        return controller
    }

    /// The bubble frame of a section, in collection view points.
    private func bubbleFrame(_ controller: ChatViewController, section: Int) throws -> CGRect {
        let collection = controller.messagesCollectionView
        let cell = try #require(collection.cellForItem(at: IndexPath(item: 0, section: section)) as? MessageContentCell)
        return cell.contentView.convert(cell.messageContainerView.frame, to: collection)
    }

    /// The center line of a view, in input bar points.
    private func centerY(_ view: UIView, in bar: UIView) -> CGFloat {
        view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: bar).y
    }

    /// A view that the owner sees: in a window path with no hidden view and some size.
    private func isShown(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let next = current {
            if next.isHidden || next.alpha < 0.01 { return false }
            current = next.superview
        }
        return view.bounds.width > 0 && view.bounds.height > 0
    }

    // MARK: Bubble space

    @Test func bubblesOfOneSenderHave2PointsAndASenderChangeHas10() throws {
        // No time header, no "Delivered" line and no badge between these bubbles: only the bubble space.
        let messages = [
            ChatMessage(id: "u1", role: .user, text: "Book the train", date: date, delivery: .delivered, userRowId: 1),
            ChatMessage(id: "a1", role: .assistant, text: "Booked.", date: date.addingTimeInterval(5),
                        reply: .complete, promptId: "u1"),
            ChatMessage(id: "a2", role: .assistant, text: "Seats 4A and 4B.", date: date.addingTimeInterval(6),
                        reply: .complete, promptId: "u1"),
            ChatMessage(id: "u2", role: .user, text: "Thanks", date: date.addingTimeInterval(9), delivery: .delivered,
                        userRowId: 3),
        ]
        let controller = makeController(messages)
        let frames = try (0..<4).map { try bubbleFrame(controller, section: $0) }
        let gaps = (1..<4).map { frames[$0].minY - frames[$0 - 1].maxY }
        #expect(abs(gaps[0] - 10) < 0.5, "sender change: \(gaps[0])")
        #expect(abs(gaps[1] - 2) < 0.5, "same sender: \(gaps[1])")
        #expect(abs(gaps[2] - 10) < 0.5, "sender change: \(gaps[2])")
    }

    // MARK: Composer

    @Test func plusFieldAndMicShareOneCenterLine() throws {
        let controller = makeController([])
        let bar = controller.messageInputBar
        bar.layoutIfNeeded()
        let plus = try #require(bar.leftStackView.arrangedSubviews.first)
        let mic = try #require(bar.rightStackView.arrangedSubviews.last)
        let field = bar.inputTextView
        let line = centerY(field, in: bar)
        #expect(abs(centerY(plus, in: bar) - line) <= 1, "plus \(centerY(plus, in: bar)) field \(line)")
        #expect(abs(centerY(mic, in: bar) - line) <= 1, "mic \(centerY(mic, in: bar)) field \(line)")
    }

    @Test func plusIsHiddenWhileAMemoRecordsAndTheRowSharesOneCenterLine() throws {
        let controller = makeController([])
        let bar = controller.messageInputBar
        let plus = try #require(bar.leftStackView.arrangedSubviews.first)
        controller.voice.startTapMode()
        bar.layoutIfNeeded()
        #expect(controller.recordingBarMode == .locked)
        #expect(!isShown(plus), "the + button shows while a memo records")
        let row = try #require(bar.middleContentView as? VoiceRecordingBar)
        row.layoutIfNeeded()
        // Issue #103: the locked keys (Delete, Pause, Send) share one center line under the capsule.
        let line = centerY(row.sendButton, in: bar)
        for view in [row.deleteButton, row.middleButton] {
            #expect(abs(centerY(view, in: bar) - line) <= 1)
            #expect(view.frame.width == VoiceRecordingBar.keySize)
        }
        #expect(row.frame.height >= row.height(for: .locked) - 1)
        controller.voice.cancel()
        bar.layoutIfNeeded()
        #expect(isShown(plus), "the + button comes back after the recording")
    }

    // MARK: Voice reply length

    @Test func voiceReplyShowsItsLengthAfterAPausePartWay() async throws {
        let url = folder.appendingPathComponent("reply-2s.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DemoChatTransport.toneWAV(seconds: 2).write(to: url)
        let messages = [
            ChatMessage(id: "u", role: .user, text: "Lunch?", date: date, delivery: .delivered, userRowId: 1),
            ChatMessage(id: "r", role: .assistant, text: "Lunch at noon.", date: date.addingTimeInterval(3),
                        reply: .complete, promptId: "u", spokenReply: .ready(VoiceReplyAudio(fileURL: url, duration: 2))),
        ]
        let controller = makeController(messages)
        let collection = controller.messagesCollectionView
        let cell = try #require(collection.visibleCells.compactMap { $0 as? ChatVoiceCell }.first)
        // The owner drags to 1.5 s, then pauses.
        cell.onSeek?(1.5)
        #expect(controller.playerIsPlaying)
        controller.tapAudio(id: "r")
        #expect(!controller.playerIsPlaying)
        collection.layoutIfNeeded()
        let shown = try #require(collection.visibleCells.compactMap { $0 as? ChatVoiceCell }.first)
        let labels = shown.messageContainerView.subviews.compactMap { $0 as? UILabel }.compactMap(\.text)
        #expect(labels.contains("0:02"), "labels: \(labels)")
        #expect(!labels.contains("0:01"))
    }

    // MARK: Tapback badge

    @Test func tapbackBadgeIsOpaqueAndInsideTheCell() throws {
        let messages = [
            ChatMessage(id: "u1", role: .user, text: "Book the train", date: date, delivery: .delivered, userRowId: 1,
                        agentAck: .done, tapback: .heart),
            ChatMessage(id: "a1", role: .assistant, text: "Booked.", date: date.addingTimeInterval(5),
                        reply: .complete, promptId: "u1", tapback: .heart),
        ]
        let controller = makeController(messages)
        let collection = controller.messagesCollectionView
        for section in 0..<2 {
            let cell = try #require(collection.cellForItem(at: IndexPath(item: 0, section: section))
                as? MessageContentCell)
            let overlay = try #require(cell.contentView.subviews.compactMap { $0 as? ReactionBadgeOverlay }.first)
            overlay.layoutIfNeeded()
            let badges = overlay.subviews.compactMap { $0 as? ReactionBadgeView }
            #expect(!badges.isEmpty)
            for badge in badges {
                // Glass lets the bubble show through the badge. The badge is a solid circle.
                #expect(!badge.isKind(of: UIVisualEffectView.self), "the badge is see-through glass")
                var alpha: CGFloat = 0
                badge.backgroundColor?.resolvedColor(with: cell.traitCollection).getRed(nil, green: nil, blue: nil,
                                                                                         alpha: &alpha)
                #expect(alpha == 1, "badge fill alpha \(alpha)")
                #expect(badge.alpha == 1)
                // The badge is above the bubble, and the cell does not cut it.
                #expect(overlay.convert(badge.frame, to: cell.contentView).minY >= 0)
            }
            // The badges draw over the bubble, not under it.
            #expect(cell.contentView.subviews.last === overlay)
        }
    }

    // MARK: Voice reply bubble (owner decisions on #49)

    private func reply(_ spoken: SpokenReply?, text: String = "Noted. I saved that in the **Nourish** workflow: "
        + "allow time for a cold browser to warm up before treating timeouts as a failure.") throws -> [ChatMessage] {
        [
            ChatMessage(id: "u", role: .user, text: "Lunch?", date: date, delivery: .delivered, userRowId: 1),
            ChatMessage(id: "r", role: .assistant, text: text, date: date.addingTimeInterval(3), reply: .complete,
                        promptId: "u", spokenReply: spoken),
        ]
    }

    private func readyAudio(seconds: Double = 2) throws -> VoiceReplyAudio {
        let url = folder.appendingPathComponent("reply-\(Int(seconds))s.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DemoChatTransport.toneWAV(seconds: seconds).write(to: url)
        return VoiceReplyAudio(fileURL: url, duration: seconds, waveform: VoiceWaveform.bars(contentsOf: url) ?? [])
    }

    private func cells(_ controller: ChatViewController) -> [UICollectionViewCell] {
        let collection = controller.messagesCollectionView
        collection.layoutIfNeeded()
        return (0..<collection.numberOfSections).compactMap { collection.cellForItem(at: IndexPath(item: 0, section: $0)) }
    }

    @Test func replyWithNoAudioIsATextBubble() throws {
        let shown = cells(makeController(try reply(nil)))
        #expect(shown.count == 2)
        #expect(shown[1] is ChatTextCell)
    }

    /// All views under a view, the view too.
    private func allViews(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(allViews)
    }

    /// QA #54 defect 1: no empty grey bubble. A spinner and "Preparing audio…" show under the text bubble.
    @Test func preparingReplyIsTheTextBubbleWithASpinnerCaption() throws {
        let shown = cells(makeController(try reply(.preparing)))
        #expect(shown.count == 2, "bubbles: \(shown.count)")
        let text = try #require(shown.last as? ChatTextCell)
        #expect(text.messageBottomLabel.text?.contains("Preparing audio…") == true)
        let spinner = allViews(text).compactMap { $0 as? UIActivityIndicatorView }.first { !$0.isHidden }
        #expect(spinner?.isAnimating == true, "no spinner in the caption row")
        // The spinner sits in the caption row, at its leading end.
        if let spinner {
            let frame = spinner.convert(spinner.bounds, to: text.contentView)
            #expect(text.messageBottomLabel.frame.insetBy(dx: 0, dy: -4).contains(CGPoint(x: frame.midX, y: frame.midY)))
        }
    }

    /// QA #54 defect 1: the failed state is the text bubble with a red retry caption that is a 44 pt target.
    @Test func failedReplyIsTheTextBubbleWithARetryCaption() async throws {
        let folder = self.folder
        let model = ChatViewModel(transport: ToneSpeakingTransport(), messages: try reply(.failed),
                                  saveSpeech: { try VoiceReplyFiles.save($0, in: folder) })
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(), voiceFolder: folder)
        controller.autoPlayEnabled = { false }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        let shown = cells(controller)
        #expect(shown.count == 2, "bubbles: \(shown.count)")
        let text = try #require(shown.last as? ChatTextCell)
        let caption = try #require(text.messageBottomLabel.attributedText)
        #expect(caption.string.contains("Audio unavailable. Tap to retry."))
        var hasIcon = false
        caption.enumerateAttribute(.attachment, in: NSRange(location: 0, length: caption.length)) { value, _, _ in
            if let image = (value as? NSTextAttachment)?.image, image.size.height > 1 { hasIcon = true }
        }
        #expect(hasIcon, "no arrow.clockwise in the caption row")
        let color = caption.attribute(.foregroundColor, at: caption.length - 1, effectiveRange: nil) as? UIColor
        #expect(color == .systemRed)
        #expect(text.messageBottomLabel.frame.height >= 44)
        #expect(text.accessibilityLabel?.contains("Audio unavailable. Tap to retry.") == true)
        #expect(text.accessibilityHint == "Double-tap to retry.")
        // A tap on the row speaks again. Then the voice bubble shows in the same row.
        controller.didTapMessageBottomLabel(in: text)
        try await waitUntilReady(model)
        controller.messagesCollectionView.layoutIfNeeded()
        #expect(cells(controller).last is ChatVoiceCell)
    }

    /// QA #54 defect 1 at AX5: the caption row wraps and has room for every line. The spinner grows with the text.
    @Test(arguments: [SpokenReply.failed, .preparing])
    func captionRowFitsItsTextAtAX5(state: SpokenReply) throws {
        let model = ChatViewModel(transport: OfflineChatTransport(), messages: try reply(state))
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(), voiceFolder: folder)
        controller.autoPlayEnabled = { false }
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let text = try #require(cells(controller).last as? ChatTextCell)
        text.layoutIfNeeded()
        let label = text.messageBottomLabel
        let caption = try #require(label.attributedText)
        let width = label.bounds.width - label.textInsets.left - label.textInsets.right
        let needed = caption.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        #expect(label.bounds.height >= needed.rounded(.up), "row \(label.bounds.height), text \(needed)")
        if state == .preparing {
            let font = try #require(caption.attribute(.font, at: caption.length - 1, effectiveRange: nil) as? UIFont)
            #expect(text.captionSpinner.frame.height >= font.capHeight, "spinner \(text.captionSpinner.frame.height)")
        }
    }

    private func waitUntilReady(_ model: ChatViewModel) async throws {
        for _ in 0..<400 {
            if model.messages.last?.spokenReply?.audio != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the audio did not come")
    }

    @Test func readyReplyShowsTwoLinesOfTextUnderTheWaveform() throws {
        let audio = try readyAudio()
        let shown = cells(makeController(try reply(.ready(audio))))
        #expect(shown.count == 2)
        let voice = try #require(shown[1] as? ChatVoiceCell)
        #expect(voice.waveform.levels == audio.waveform)
        #expect(voice.waveform.levels.count == VoiceMemoLimits.waveformBars)
        #expect(voice.durationLabel.text == "0:02")
        #expect(voice.transcriptLabel.numberOfLines == 2)
        #expect(voice.transcriptLabel.lineBreakMode == .byTruncatingTail)
        // Plain text: no Markdown marks.
        #expect(voice.transcriptLabel.text?.hasPrefix("Noted. I saved that in the Nourish workflow") == true)
        // The label frame has room for both lines, so it shows 2 lines and then "…", not 1.
        let label = voice.transcriptLabel
        let font = try #require(label.font)
        let drawn = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: 0).height
        #expect(drawn > font.lineHeight * 1.5, "drawn \(drawn), line \(font.lineHeight)")
        #expect(label.bounds.height < font.lineHeight * 3)
    }

    @Test func tapOnTheTextOpensTheFullReplyThatSelects() throws {
        let audio = try readyAudio()
        let controller = makeController(try reply(.ready(audio)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let voice = try #require(cells(controller).last as? ChatVoiceCell)
        voice.onTranscriptTap?()
        let navigation = try #require(controller.presentedViewController as? UINavigationController)
        let sheet = try #require(navigation.topViewController as? ReplyTextViewController)
        sheet.loadViewIfNeeded()
        #expect(sheet.textView.isSelectable)
        #expect(!sheet.textView.isEditable)
        // The full text with Markdown: bold "Nourish", no `**` marks.
        let text = try #require(sheet.textView.attributedText)
        #expect(text.string.hasSuffix("as a failure."))
        #expect(!text.string.contains("**"))
        let range = (text.string as NSString).range(of: "Nourish")
        let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(navigation.sheetPresentationController?.detents.count == 2)
        controller.dismiss(animated: false)
    }

    @Test func linkInTheFullReplyOpens() {
        let source = NSMutableAttributedString(string: "See docs")
        let url = URL(string: "https://example.com")!
        source.addAttribute(ChatBubbleText.linkKey, value: url, range: NSRange(location: 4, length: 4))
        let text = ReplyTextViewController.withLinks(source)
        #expect(text.attribute(.link, at: 5, effectiveRange: nil) as? URL == url)
        #expect(text.attribute(.link, at: 1, effectiveRange: nil) == nil)
    }

    @Test func waveformFillsAsTheReplyPlaysAndATapSeeks() throws {
        let audio = try readyAudio(seconds: 4)
        let controller = makeController(try reply(.ready(audio)))
        let voice = try #require(cells(controller).last as? ChatVoiceCell)
        voice.layoutIfNeeded()
        #expect(voice.waveform.progress == 0)
        voice.setProgress(time: 1)
        #expect(voice.waveform.progress == 0.25)
        // The label keeps the full length while it plays.
        #expect(voice.durationLabel.text == "0:04")
        let wave = voice.waveform.frame
        #expect(abs(voice.seekTime(at: CGPoint(x: wave.midX, y: wave.midY)) - 2) < 0.01)
        #expect(voice.seekTime(at: CGPoint(x: wave.minX - 50, y: wave.midY)) == 0)
        #expect(voice.seekTime(at: CGPoint(x: wave.maxX + 50, y: wave.midY)) == 4)
        // A seek plays from that point.
        voice.onSeek?(3)
        #expect(controller.playerIsPlaying)
        #expect(controller.playerURL == audio.fileURL)
        controller.tapAudio(id: "r")
    }

    @Test func oldCachedReplyWithNoLevelsShowsFlatBars() throws {
        var audio = try readyAudio()
        audio.waveform = []
        let voice = try #require(cells(makeController(try reply(.ready(audio)))).last as? ChatVoiceCell)
        #expect(voice.waveform.levels == Array(repeating: 0, count: VoiceMemoLimits.waveformBars))
        #expect(!voice.waveform.isHidden)
    }

    /// The thread stays at the bottom when the audio comes and the text bubble becomes the voice bubble.
    @Test func audioArrivalKeepsTheThreadAtTheBottom() async throws {
        var messages = try reply(.failed)
        for index in 0..<30 {
            let role: ChatMessage.Role = index % 2 == 0 ? .user : .assistant
            messages.insert(ChatMessage(id: "o\(index)", role: role, text: "Older message \(index)",
                                        date: date.addingTimeInterval(-1000), delivery: role == .user ? .delivered : nil,
                                        reply: role == .user ? nil : .complete, userRowId: 100 + index), at: 0)
        }
        let folder = self.folder
        let model = ChatViewModel(transport: ToneSpeakingTransport(), messages: messages,
                                  saveSpeech: { try VoiceReplyFiles.save($0, in: folder) })
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(), voiceFolder: folder)
        controller.autoPlayEnabled = { false }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let collection = controller.messagesCollectionView
        collection.layoutIfNeeded()
        #expect(controller.isPinnedToBottom)
        #expect(collection.numberOfSections == 32)

        await model.retrySpeech(id: "r")?.value
        #expect(model.messages.last?.spokenReply?.audio != nil)
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutIfNeeded()
        collection.layoutIfNeeded()
        #expect(collection.numberOfSections == 32)
        #expect(collection.cellForItem(at: IndexPath(item: 0, section: 31)) is ChatVoiceCell)
        #expect(controller.isPinnedToBottom)
        let bottom = ChatScroll.bottomOffset(contentHeight: collection.contentSize.height,
                                             viewHeight: collection.bounds.height, insets: collection.adjustedContentInset)
        #expect(abs(collection.contentOffset.y - bottom) < 1)
    }
}

/// Speaks a 2 s tone at once. No server.
private final class ToneSpeakingTransport: ChatTransport, @unchecked Sendable {
    let events: AsyncStream<GatewayClientEvent> = AsyncStream { _ in }
    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: "st1")
    }
    func resumeSession(storedId: String, source _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: storedId)
    }
    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? { 1 }
    func submitVoicePrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? { 2 }
    func transcribe(audio _: Data, mimeType _: String) async throws -> String { "" }
    func speak(text _: String) async throws -> SpokenAudio {
        SpokenAudio(data: DemoChatTransport.toneWAV(seconds: 2), mimeType: "audio/wav")
    }
    func stopReply(sessionId _: String) async throws -> Bool { false }
    func history(sessionId _: String) async throws -> [TranscriptMessage] { [] }
}
