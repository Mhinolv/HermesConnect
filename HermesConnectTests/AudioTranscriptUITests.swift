import Foundation
import HermesKit
import MessageKit
import Testing
import UIKit
@testable import HermesConnect

/// Issue #50: the transcript line under a received audio bubble. A fake engine, no server, no speech framework.
@MainActor
@Suite(.serialized) struct AudioTranscriptUITests {
    private let date = Date(timeIntervalSince1970: 1_763_290_000)
    private let file = ReceivedFile(path: "/out/call.wav")
    private let transcriptText = "Morning standup. The release moves to Thursday. Maria owns the App Store notes, "
        + "and Sam checks the crash report before noon. Next sync is Monday at 9."

    /// The windows of the screens, so the composer and its insets are real.
    private static var keep: [UIWindow] = []
    private var windows: [UIWindow] {
        get { Self.keep }
        nonmutating set { Self.keep = newValue }
    }

    private struct Screen {
        let controller: ChatViewController
        let loader: ReceivedFileLoader
    }

    /// A chat with one received audio file. `folder` is the received files folder (the same after a relaunch).
    private func makeScreen(folder: URL, transcribe: @escaping ReceivedAudioTranscripts.Transcribe) -> Screen {
        let loader = ReceivedFileLoader(download: { _, _, _, _ in
            let url = FileManager.default.temporaryDirectory.appending(path: "fake-\(UUID().uuidString)")
            try Data(repeating: 1, count: 4_000).write(to: url)
            return url
        }, folder: folder, storedSessionId: { "st1" }, prepareAudio: { url in
            VoiceReplyAudio(fileURL: url, duration: 74, waveform: [0.2, 0.8])
        })
        let messages = [
            ChatMessage(id: "u1", role: .user, text: "Send the recording", date: date, delivery: .delivered, userRowId: 1),
            ChatMessage(id: "a1", role: .assistant, text: "Here it is.\nMEDIA:/out/call.wav", date: date.addingTimeInterval(5),
                        reply: .complete, promptId: "u1"),
        ]
        let model = ChatViewModel(transport: DemoChatTransport(scenario: .thread), storedSessionId: "st1",
                                  messages: messages, receivedFiles: loader)
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(),
                                            voiceFolder: FileManager.default.temporaryDirectory)
        controller.audioTranscripts = ReceivedAudioTranscripts(files: loader, transcribe: transcribe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        windows.append(window)
        return Screen(controller: controller, loader: loader)
    }

    private func settle(_ screen: Screen) async throws {
        for _ in 0..<300 {
            let ready = screen.loader.state(for: file).fileURL != nil && screen.loader.audio(for: file) != .preparing
            let running = screen.controller.audioTranscripts.state(for: file).isTranscribing
            if ready, !running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        screen.controller.view.layoutIfNeeded()
        screen.controller.messagesCollectionView.layoutIfNeeded()
    }

    /// The one audio bubble of the chat.
    private func audioCell(_ screen: Screen) throws -> ChatVoiceCell {
        let collection = screen.controller.messagesCollectionView
        let cell = (0..<collection.numberOfSections).lazy
            .compactMap { collection.cellForItem(at: IndexPath(item: 0, section: $0)) as? ChatVoiceCell }.first
        return try #require(cell)
    }

    @Test func transcribeShowsTheTranscriptAndARelaunchKeepsIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "at-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = transcriptText
        let screen = makeScreen(folder: folder) { _, _ in text }
        try await settle(screen)
        var cell = try audioCell(screen)
        #expect(cell.transcriptLabel.attributedText?.string.hasSuffix("Transcribe") == true)
        #expect(cell.accessibilityCustomActions?.map(\.name).contains("Transcribe") == true)

        screen.controller.audioTranscripts.start(file)
        try await settle(screen)
        cell = try audioCell(screen)
        #expect(cell.transcriptLabel.attributedText?.string == text)
        #expect(cell.accessibilityLabel?.contains("Transcript: Morning standup.") == true)
        // The cell has room for the 3 transcript lines: the line is not cut by the cell or the next row.
        #expect(cell.transcriptLabel.frame.maxY <= cell.bounds.height + 0.5)
        #expect(cell.transcriptLabel.frame.height > UIFont.preferredFont(forTextStyle: .footnote).lineHeight * 2.5)
        // The thread follows the longer line: the end of the transcript is in view.
        let collection = screen.controller.messagesCollectionView
        let bottom = ChatScroll.bottomOffset(contentHeight: collection.contentSize.height,
                                             viewHeight: collection.bounds.height, insets: collection.adjustedContentInset)
        #expect(abs(collection.contentOffset.y - bottom) < 1, "offset \(collection.contentOffset.y), bottom \(bottom)")
        let lineEnd = cell.convert(cell.transcriptLabel.frame, to: collection).maxY
        #expect(lineEnd <= collection.contentSize.height + 0.5, "line end \(lineEnd), content \(collection.contentSize.height)")
        let visibleEnd = collection.contentOffset.y + collection.bounds.height - collection.adjustedContentInset.bottom
        #expect(lineEnd <= visibleEnd + 0.5, "line end \(lineEnd), visible end \(visibleEnd)")

        // Relaunch: a new screen and a new store read the saved transcript. The engine does not run again.
        let again = makeScreen(folder: folder) { _, _ in
            Issue.record("The engine ran again after the relaunch")
            return "other"
        }
        try await settle(again)
        #expect(try audioCell(again).transcriptLabel.attributedText?.string == text)
    }

    @Test func longFileShowsProgressAndCancels() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "at-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let screen = makeScreen(folder: folder) { _, progress in
            progress(0.42)
            try await Task.sleep(for: .seconds(30))
            return "late"
        }
        try await settle(screen)
        screen.controller.audioTranscripts.start(file)
        for _ in 0..<100 where screen.controller.audioTranscripts.state(for: file) != .transcribing(0.42) {
            try await Task.sleep(for: .milliseconds(10))
        }
        screen.controller.messagesCollectionView.layoutIfNeeded()
        var cell = try audioCell(screen)
        #expect(cell.transcriptLabel.attributedText?.string == "Transcribing… 42%. Tap to cancel.")
        #expect(cell.accessibilityCustomActions?.map(\.name).contains("Cancel Transcription") == true)
        screen.controller.audioTranscripts.cancel(file)
        screen.controller.messagesCollectionView.layoutIfNeeded()
        cell = try audioCell(screen)
        #expect(cell.transcriptLabel.attributedText?.string.hasSuffix("Transcribe") == true)
    }

    /// The DEBUG demo thread: 3 audio files, the last one with a transcript. Its end is in view.
    @Test func lastTranscriptIsInView() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "at-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let loader = ReceivedFileLoader(download: { path, _, _, _ in try AudioTranscriptDemo.download(path: path) },
                                        folder: folder, storedSessionId: { "st1" })
        let transport = DemoChatTransport(scenario: .thread)
        let messages = transport.seedMessages(now: date) + AudioTranscriptDemo.messages(now: date)
        let model = ChatViewModel(transport: transport, storedSessionId: "st1", messages: messages, receivedFiles: loader)
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(),
                                            voiceFolder: FileManager.default.temporaryDirectory)
        controller.audioTranscripts = ReceivedAudioTranscripts(files: loader, transcribe: AudioTranscriptDemo.transcribe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        windows.append(window)
        AudioTranscriptDemo.start(controller.audioTranscripts)
        let last = ReceivedFile(path: AudioTranscriptDemo.folder + "standup.wav")
        for _ in 0..<400 where !(controller.audioTranscripts.state(for: last).caption.hasPrefix("Morning")) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
        let collection = controller.messagesCollectionView
        let cells = (0..<collection.numberOfSections).compactMap {
            collection.cellForItem(at: IndexPath(item: 0, section: $0)) as? ChatVoiceCell
        }
        let cell = try #require(cells.last)
        #expect(cell.transcriptLabel.attributedText?.string.hasPrefix("Morning") == true)
        let lineEnd = cell.convert(cell.transcriptLabel.frame, to: collection).maxY
        let visibleEnd = collection.contentOffset.y + collection.bounds.height - collection.adjustedContentInset.bottom
        #expect(lineEnd <= visibleEnd + 0.5, "line end \(lineEnd), visible end \(visibleEnd), content \(collection.contentSize.height), cell \(cell.frame), label \(cell.transcriptLabel.frame), bottom \(cell.messageBottomLabel.frame)")
    }
}
