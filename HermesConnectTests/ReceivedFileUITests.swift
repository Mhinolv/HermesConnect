import Foundation
import HermesKit
import MessageKit
import Testing
import UIKit
@testable import HermesConnect

/// Issue #12: received files in the thread: image, file and audio bubbles, states, VoiceOver, and the
/// 44 pt "Remove" hit area of the strip. No server: the download is a fake that writes fixture files.
@MainActor
@Suite(.serialized) struct ReceivedFileUITests {
    private let date = Date(timeIntervalSince1970: 1_763_290_000)

    /// Fake downloads: `status` per path (404 and so on), else a fixture file for the extension.
    private final class FakeFiles: @unchecked Sendable {
        let lock = NSLock()
        var notFound: Set<String> = []
        var paths: [String] = []

        func download(path: String, maxBytes _: Int?) throws -> URL {
            let missing = lock.withLock { () -> Bool in
                paths.append(path)
                return notFound.contains(path)
            }
            if missing { throw ReceivedFileError.notAvailable }
            let url = FileManager.default.temporaryDirectory.appending(path: "fake-\(UUID().uuidString)")
            if path.hasSuffix(".png") {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200)).image { context in
                    UIColor.systemOrange.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
                }
                try image.pngData()!.write(to: url)
            } else {
                try Data(repeating: 1, count: 2_000_000).write(to: url)
            }
            return url
        }
    }

    private func makeController(_ text: String, fake: FakeFiles = FakeFiles())
        -> (ChatViewController, ChatViewModel, ReceivedFileLoader) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rf-\(UUID().uuidString)")
        let loader = ReceivedFileLoader(download: { path, _, maxBytes, _ in
            try fake.download(path: path, maxBytes: maxBytes)
        }, folder: folder, storedSessionId: { "st1" }, prepareAudio: { url in
            VoiceReplyAudio(fileURL: url, duration: 4, waveform: [0.2, 0.8])
        })
        let messages = [
            ChatMessage(id: "u1", role: .user, text: "Send the files", date: date, delivery: .delivered, userRowId: 1),
            ChatMessage(id: "a1", role: .assistant, text: text, date: date.addingTimeInterval(5), reply: .complete,
                        promptId: "u1"),
        ]
        let model = ChatViewModel(transport: DemoChatTransport(scenario: .thread), messages: messages,
                                  receivedFiles: loader)
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(),
                                            voiceFolder: FileManager.default.temporaryDirectory)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        return (controller, model, loader)
    }

    private func settle(_ loader: ReceivedFileLoader, _ files: [ReceivedFile]) async throws {
        for _ in 0..<200 {
            let busy = files.contains { file in
                switch loader.state(for: file) {
                case .downloading: true
                case .ready where file.kind == .audio: loader.audio(for: file) == .preparing
                default: false
                }
            }
            if !busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func tagsBecomeFileBubblesAfterTheText() async throws {
        let (controller, _, loader) = makeController("Here they are.\nMEDIA:/out/chart.png\nMEDIA:/out/report.pdf")
        let bubbles = controller.receivedFileBubbles
        #expect(bubbles.compactMap(\.part.receivedFile).map(\.name) == ["chart.png", "report.pdf"])
        // The image loads at once into the 240 x 180 gray box. The PDF waits for a tap.
        guard case .photo(let placeholder) = bubbles[0].kind else {
            Issue.record("expected a photo bubble")
            return
        }
        #expect(placeholder.size == CGSize(width: 240, height: 180))
        let pdf = ReceivedFile(path: "/out/report.pdf")
        #expect(loader.state(for: pdf) == .idle)
        #expect(bubbles[1].text.string.contains("report.pdf"))
        #expect(bubbles[1].text.string.contains("Tap to download"))

        try await settle(loader, [ReceivedFile(path: "/out/chart.png")])
        guard case .photo(let loaded) = controller.receivedFileBubbles[0].kind else {
            Issue.record("expected a photo bubble")
            return
        }
        // Max width 240 pt, aspect kept (400 x 200).
        #expect(loaded.size == CGSize(width: 240, height: 120))
    }

    @Test func tapDownloadsTheFileAndTheCellShowsItsSize() async throws {
        let fake = FakeFiles()
        let (controller, _, loader) = makeController("MEDIA:/out/report.pdf", fake: fake)
        let pdf = ReceivedFile(path: "/out/report.pdf")
        controller.perform(.share, on: pdf, from: controller.view)
        #expect(loader.state(for: pdf) == .downloading(nil))
        try await settle(loader, [pdf])
        #expect(loader.state(for: pdf).fileURL?.lastPathComponent == "report.pdf")
        let cell = try #require(controller.receivedFileBubbles.first)
        #expect(cell.text.string.contains(AttachmentPayload.sizeText(2_000_000)))
        #expect(fake.paths == ["/out/report.pdf"])
    }

    @Test func missingFileShowsFileNotAvailable() async throws {
        let fake = FakeFiles()
        fake.notFound = ["/out/gone.png", "/out/gone.pdf"]
        let (controller, _, loader) = makeController("MEDIA:/out/gone.png MEDIA:/out/gone.pdf", fake: fake)
        controller.perform(.open, on: ReceivedFile(path: "/out/gone.pdf"), from: controller.view)
        try await settle(loader, [ReceivedFile(path: "/out/gone.png"), ReceivedFile(path: "/out/gone.pdf")])
        let bubbles = controller.receivedFileBubbles
        #expect(bubbles.map(\.received) == [.notAvailable, .notAvailable])
        #expect(bubbles[1].text.string.contains("File not available"))
        #expect(ReceivedFileText.symbol(for: ReceivedFile(path: "/out/gone.pdf"), state: .notAvailable)
            == "exclamationmark.triangle")
    }

    @Test func audioUsesTheVoiceBubbleWithNoAutoPlay() async throws {
        let (controller, _, loader) = makeController("Your clip: MEDIA:/out/memo.m4a")
        let audio = ReceivedFile(path: "/out/memo.m4a")
        try await settle(loader, [audio])
        let bubble = try #require(controller.receivedFileBubbles.first)
        guard case .custom = bubble.kind else {
            Issue.record("expected the audio bubble")
            return
        }
        #expect(loader.audio(for: audio).audio?.duration == 4)
        #expect(!controller.playerIsPlaying)
    }

    @Test func voiceOverReadsTheFileAndOffersTheActions() async throws {
        let (controller, _, loader) = makeController("MEDIA:/out/report.pdf")
        let pdf = ReceivedFile(path: "/out/report.pdf")
        controller.perform(.saveToFiles, on: pdf, from: controller.view)
        try await settle(loader, [pdf])
        let collection = controller.messagesCollectionView
        collection.layoutIfNeeded()
        let cell = try #require(collection.cellForItem(at: IndexPath(item: 0, section: 1)))
        #expect(cell.accessibilityLabel == "Hermes sent a file, report.pdf, \(AttachmentPayload.sizeText(2_000_000))")
        #expect(cell.accessibilityCustomActions?.prefix(3).map(\.name) == ["Open", "Save to Files", "Share"])
    }

    @Test func removeButtonHasA44PointHitArea() throws {
        let photo = ChatAttachment(id: "p", kind: .photo, name: "a.jpg", byteCount: 10,
                                   fileURL: URL(fileURLWithPath: "/dev/null"), mimeType: "image/jpeg")
        let strip = AttachmentStripView(frame: CGRect(x: 0, y: 0, width: 402, height: 100))
        strip.show([photo])
        strip.layoutIfNeeded()
        let remove = try #require(strip.allSubviews.compactMap { $0 as? UIButton }.first)
        #expect(remove.bounds.width >= 44 && remove.bounds.height >= 44)
        #expect(AttachmentStripView.removeHitSize == 44)
    }

    @Test func refOnlyFileCellHasNoSize() {
        let item = AttachmentRefs.attachments(for: ["/w/Lease.pdf"], rowId: "row-1")[0]
        let text = AttachmentFileText.make(item, outgoing: true, traits: UITraitCollection(preferredContentSizeCategory: .large))
        #expect(text.string.hasSuffix("Lease.pdf"))
        #expect(!text.string.contains("Zero"))
    }
}

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap(\.allSubviews) }
}
