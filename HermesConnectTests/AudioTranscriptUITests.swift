import Foundation
import Synchronization
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

/// Issue #87: the transcript line under a sent audio file cell, and the runs stop when the owner leaves the chat.
/// A fake engine and files in a temporary folder. No server, no speech framework.
@MainActor
@Suite(.serialized) struct SentAudioTranscriptUITests {
    private let date = Date(timeIntervalSince1970: 1_763_290_000)
    private let transcriptText = "Pick up the keys at the front desk. The meeting moved to 3. Bring the signed lease "
        + "and the parking card for level 2."

    private static var keep: [UIWindow] = []

    /// A sent audio file and a sent PDF, in their private folders under `folder` (the same after a relaunch).
    private func items(in folder: URL, audio bytes: Data? = nil) throws -> [ChatAttachment] {
        func item(_ id: String, _ name: String, _ mime: String, _ data: Data) throws -> ChatAttachment {
            let url = folder.appending(path: id, directoryHint: .isDirectory).appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url) }
            return ChatAttachment(id: id, kind: mime == "application/pdf" ? .pdf : .file, name: name,
                                  byteCount: data.count, fileURL: url, mimeType: mime, upload: .attached)
        }
        return [try item("s1", "Front desk.m4a", "audio/mp4", bytes ?? Data(repeating: 1, count: 4_000)),
                try item("s2", "Lease.pdf", "application/pdf", Data("%PDF".utf8))]
    }

    private func makeScreen(items: [ChatAttachment], transcribe: @escaping ReceivedAudioTranscripts.Transcribe,
                            prepareSent: ReceivedAudioTranscripts.PrepareSent? = nil) -> ChatViewController {
        let loader = ReceivedFileLoader(download: nil, folder: FileManager.default.temporaryDirectory
            .appending(path: "received-\(UUID().uuidString)"), storedSessionId: { "st1" })
        let messages = [
            ChatMessage(id: "u1", role: .user, text: "The notes from the call", date: date, delivery: .delivered,
                        userRowId: 1, attachments: items),
            ChatMessage(id: "a1", role: .assistant, text: "Thanks, I have them.", date: date.addingTimeInterval(5),
                        reply: .complete, promptId: "u1"),
        ]
        let model = ChatViewModel(transport: DemoChatTransport(scenario: .thread), storedSessionId: "st1",
                                  messages: messages, receivedFiles: loader)
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(),
                                            voiceFolder: FileManager.default.temporaryDirectory)
        controller.audioTranscripts = prepareSent.map {
            ReceivedAudioTranscripts(files: loader, transcribe: transcribe, prepareSent: $0)
        } ?? ReceivedAudioTranscripts(files: loader, transcribe: transcribe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        Self.keep.append(window)
        return controller
    }

    private func settle(_ controller: ChatViewController, _ item: ChatAttachment) async throws {
        for _ in 0..<300 where controller.audioTranscripts.state(for: item).isTranscribing {
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.view.layoutIfNeeded()
        controller.messagesCollectionView.layoutIfNeeded()
    }

    /// The file cell of a sent item.
    private func fileCell(_ controller: ChatViewController, name: String) throws -> ChatTextCell {
        let collection = controller.messagesCollectionView
        let section = (0..<collection.numberOfSections).first { section in
            let bubble = controller.messageForItem(at: IndexPath(item: 0, section: section), in: collection) as? ChatBubble
            return bubble?.part.attachment?.name == name
        }
        let index = try #require(section)
        collection.scrollToItem(at: IndexPath(item: 0, section: index), at: .centeredVertically, animated: false)
        collection.layoutIfNeeded()
        return try #require(collection.cellForItem(at: IndexPath(item: 0, section: index)) as? ChatTextCell)
    }

    /// Acceptance criterion: a sent audio file shows the transcribe action, as a received one does.
    @Test func sentAudioFileShowsTranscribeAndTheTranscript() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let sent = try items(in: folder)
        let text = transcriptText
        let controller = makeScreen(items: sent, transcribe: { _, _ in text }, prepareSent: { $0 })
        try await settle(controller, sent[0])
        var cell = try fileCell(controller, name: "Front desk.m4a")
        #expect(cell.transcriptLabel.attributedText?.string.hasSuffix("Transcribe") == true)
        #expect(cell.accessibilityCustomActions?.map(\.name).contains("Transcribe") == true)
        // The cell is as wide as the received audio bubble, so the line has the same width.
        let voiceWidth = ChatVoiceLayout.bubbleSize(traits: controller.traitCollection, maxWidth: .greatestFiniteMagnitude).width
        #expect(cell.messageContainerView.frame.width >= voiceWidth - 0.5)
        // A sent PDF has no line and no action.
        let pdf = try fileCell(controller, name: "Lease.pdf")
        #expect(pdf.transcriptLabel.attributedText == nil)
        #expect(pdf.accessibilityCustomActions?.map(\.name).contains("Transcribe") != true)

        controller.audioTranscripts.start(sent[0])
        try await settle(controller, sent[0])
        cell = try fileCell(controller, name: "Front desk.m4a")
        #expect(cell.transcriptLabel.attributedText?.string == text)
        #expect(cell.accessibilityLabel?.contains("Transcript: Pick up the keys") == true)
        // The cell has room for the 3 transcript lines, above the footnote of the row.
        #expect(cell.transcriptLabel.frame.minY >= cell.messageContainerView.frame.maxY)
        #expect(cell.transcriptLabel.frame.maxY <= cell.bounds.height + 0.5)
        #expect(cell.transcriptLabel.frame.height > UIFont.preferredFont(forTextStyle: .footnote).lineHeight * 2.5)
        #expect(FileManager.default.fileExists(atPath: sent[0].fileURL.deletingLastPathComponent()
            .appending(path: "transcript.json").path))

        // Relaunch: a new screen and a new store read the saved transcript. The engine does not run again.
        let again = makeScreen(items: try items(in: folder), transcribe: { _, _ in
            Issue.record("The engine ran again after the relaunch")
            return "other"
        })
        try await settle(again, sent[0])
        #expect(try fileCell(again, name: "Front desk.m4a").transcriptLabel.attributedText?.string == text)
    }

    /// Acceptance criterion: the unreadable state is saved and shows after a relaunch, with no "Transcribe".
    @Test func unreadableSentFileShowsAfterARelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        // Bytes that iOS cannot read, and the real prepare step of the app.
        let sent = try items(in: folder, audio: Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        let controller = makeScreen(items: sent, transcribe: { _, _ in
            Issue.record("The engine ran for a file that iOS cannot read")
            return "x"
        })
        controller.audioTranscripts.start(sent[0])
        await controller.audioTranscripts.task(for: sent[0])?.value
        try await settle(controller, sent[0])
        #expect(try fileCell(controller, name: "Front desk.m4a").transcriptLabel.attributedText?.string
            == "Can't read this audio format.")

        let again = makeScreen(items: try items(in: folder), transcribe: { _, _ in "x" })
        try await settle(again, sent[0])
        let cell = try fileCell(again, name: "Front desk.m4a")
        #expect(cell.transcriptLabel.attributedText?.string == "Can't read this audio format.")
        #expect(cell.accessibilityCustomActions?.map(\.name).contains("Transcribe") != true)
    }

    /// Acceptance criterion: a running transcription stops when the owner leaves the chat.
    /// SwiftUI dismantles the chat view when the owner goes back to the session list.
    @Test func leavingTheChatStopsTheTranscription() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let sent = try items(in: folder)
        let stopped = Mutex(false)
        let controller = makeScreen(items: sent, transcribe: { _, progress in
            progress(0.42)
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                stopped.withLock { $0 = true }
                throw error
            }
            return "late"
        }, prepareSent: { $0 })
        controller.audioTranscripts.start(sent[0])
        for _ in 0..<100 where controller.audioTranscripts.state(for: sent[0]) != .transcribing(0.42) {
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.messagesCollectionView.layoutIfNeeded()
        #expect(try fileCell(controller, name: "Front desk.m4a").transcriptLabel.attributedText?.string
            == "Transcribing… 42%. Tap to cancel.")
        let task = try #require(controller.audioTranscripts.task(for: sent[0]))

        ChatThreadView.dismantleUIViewController(controller, coordinator: ())
        await task.value
        #expect(stopped.withLock { $0 })
        #expect(!controller.audioTranscripts.isRunning)
        #expect(controller.audioTranscripts.state(for: sent[0]) == .none)
        #expect(!FileManager.default.fileExists(atPath: sent[0].fileURL.deletingLastPathComponent()
            .appending(path: "transcript.json").path))
    }
}
