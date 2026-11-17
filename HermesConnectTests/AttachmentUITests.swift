import Foundation
import HermesKit
import ImageIO
import InputBarAccessoryView
import MessageKit
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import HermesConnect

/// Issue #8: the composer `plus` menu, the strip, the import checks and the photo bubbles. No server.
@MainActor
@Suite(.serialized) struct AttachmentUITests {
    private func tempURL(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ui-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    private func pdf(pages: Int) throws -> URL {
        let url = tempURL("Doc.pdf")
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            for _ in 0..<pages { context.beginPage() }
        }
        try data.write(to: url)
        return url
    }

    /// A file of `bytes` logical size with no disk use.
    private func sparseFile(_ name: String, bytes: UInt64) throws -> URL {
        let url = tempURL(name)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: bytes)
        try handle.close()
        return url
    }

    private func gpsPhoto() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
        let cg = try #require(image.cgImage)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil)
            ?? CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 30.2, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 97.7, kCGImagePropertyGPSLongitudeRef: "W"]
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // MARK: Import

    @Test func pickedPhotoIsDownscaledJPEGWithoutLocation() throws {
        UserDefaults.standard.removeObject(forKey: AttachmentSettings.includeLocationKey)
        let item = try AttachmentImport.photo(from: try gpsPhoto(), name: "IMG_0001.HEIC")
        #expect(item.kind == .photo)
        #expect(item.name == "IMG_0001.jpg")
        #expect(item.mimeType == "image/jpeg")
        #expect(max(item.pixelWidth ?? 0, item.pixelHeight ?? 0) == 2048)
        let data = try Data(contentsOf: item.fileURL)
        #expect(!PhotoEncoder.hasLocation(data))
        AttachmentImport.discard(item)
    }

    @Test func pdfCarriesItsPageCountAndLongPDFsAsk() throws {
        let short = try AttachmentImport.file(at: try pdf(pages: 3))
        #expect(short.kind == .pdf)
        #expect(short.pageCount == 3)
        #expect(short.mimeType == "application/pdf")
        let long = try AttachmentImport.file(at: try pdf(pages: 26))
        #expect(AttachmentLimits.check(kind: long.kind, byteCount: long.byteCount, pageCount: long.pageCount)
            == .pdfPagesOver(26))
    }

    @Test func tooLargeFilesAreRefusedBeforeTheCopy() throws {
        let bigPDF = try sparseFile("Big.pdf", bytes: UInt64(AttachmentLimits.pdfBytes) + 1)
        #expect(throws: AttachmentImport.Failure.tooLarge) { try AttachmentImport.file(at: bigPDF) }
        let bigFile = try sparseFile("Big.zip", bytes: UInt64(AttachmentLimits.fileBytes))
        #expect(throws: AttachmentImport.Failure.tooLarge) { try AttachmentImport.file(at: bigFile) }
        let okFile = try sparseFile("Notes.txt", bytes: 2048)
        let item = try AttachmentImport.file(at: okFile)
        #expect(item.kind == .file)
        #expect(item.byteCount == 2048)
        #expect(item.mimeType == "text/plain")
    }

    @Test func alertTextMatchesTheDesignNotes() {
        #expect(AttachmentLimits.tooLargeTitle == "File Too Large")
        #expect(AttachmentLimits.tooLargeMessage
            == "Files must be smaller than 256 MB. PDFs must be 50 MB or smaller.")
        #expect(AttachmentLimits.pdfPagesTitle == "Hermes reads the first 25 pages.")
    }

    // MARK: Composer

    private func controller(_ model: ChatViewModel) -> ChatViewController {
        let controller = ChatViewController(model: model)
        controller.loadViewIfNeeded()
        return controller
    }

    @Test func plusButtonIsOnTheLeftWithTheMenu() throws {
        let vc = controller(ChatViewModel(transport: OfflineChatTransport()))
        let plus = try #require(vc.messageInputBar.leftStackView.arrangedSubviews.first as? InputBarButtonItem)
        #expect(plus.accessibilityLabel == "Attach")
        let titles = plus.menu?.children.map(\.title) ?? []
        let expected = AttachmentComposer.hasCamera ? ["Photos", "Camera", "Files", "Send Location"]
            : ["Photos", "Files", "Send Location"]
        #expect(titles == expected)
    }

    @Test func pendingItemsEnableSendAndGoWithTheMessage() async throws {
        let model = ChatViewModel(transport: OfflineChatTransport())
        let vc = controller(model)
        let send = vc.messageInputBar.sendButton
        // Issue #9: an empty composer shows the mic. Pending items bring Send back.
        #expect(vc.showsMic)
        let composer = try #require(vc.attachmentComposer)
        let photo = try AttachmentImport.photo(from: try gpsPhoto())
        let doc = try AttachmentImport.file(at: try pdf(pages: 2))
        composer.add([photo, doc])
        #expect(!vc.showsMic)
        #expect(vc.messageInputBar.rightStackViewItems.first as? UIView === send)
        #expect(send.isEnabled)
        #expect(!composer.strip.isHidden)
        #expect(send.accessibilityLabel == "Send")

        vc.inputBar(vc.messageInputBar, didPressSendButtonWith: "")
        #expect(model.messages.count == 1)
        #expect(model.messages[0].attachments.map(\.id) == [photo.id, doc.id])
        #expect(model.messages[0].text == "")
        #expect(!composer.hasPending)
        #expect(composer.strip.isHidden)
        #expect(vc.showsMic)
        // One photo bubble and one file cell, no text bubble.
        for _ in 0..<100 where vc.messagesCollectionView.numberOfSections != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(vc.messagesCollectionView.numberOfSections == 2)
    }

    @Test func removeTakesTheItemOutOfTheStrip() throws {
        let vc = controller(ChatViewModel(transport: OfflineChatTransport()))
        let composer = try #require(vc.attachmentComposer)
        let doc = try AttachmentImport.file(at: try pdf(pages: 1))
        composer.add([doc])
        composer.remove(id: doc.id)
        #expect(!composer.hasPending)
        #expect(vc.showsMic)
        #expect(!FileManager.default.fileExists(atPath: doc.fileURL.path))
    }

    @Test func pastedImageJoinsThePendingItems() async throws {
        let vc = controller(ChatViewModel(transport: OfflineChatTransport()))
        let composer = try #require(vc.attachmentComposer)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        #expect(composer.handleInput(of: image))
        #expect(!composer.handleInput(of: "text" as NSString))
        for _ in 0..<200 where !composer.hasPending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(composer.pending.map(\.kind) == [.photo])
    }

    @Test func stripReadsPhotoAttachedWithARemoveAction() throws {
        let photo = try AttachmentImport.photo(from: try gpsPhoto())
        #expect(AttachmentStripView.accessibilityLabel(for: photo) == "Photo, attached")
        let strip = AttachmentStripView()
        strip.show([photo])
        let tile = try #require(strip.allSubviews.first { $0.accessibilityLabel == "Photo, attached" })
        #expect(tile.accessibilityCustomActions?.map(\.name) == ["Remove"])
    }

    // MARK: Bubbles

    @Test func photoPartIsAPhotoMessageAt240Points() throws {
        let photo = ChatAttachment(id: "p", kind: .photo, name: "a.jpg", byteCount: 10,
                                   fileURL: URL(fileURLWithPath: "/dev/null"), mimeType: "image/jpeg",
                                   pixelWidth: 2048, pixelHeight: 1536)
        let message = ChatMessage(id: "m", role: .user, text: "Hi", date: .now, delivery: .sending,
                                  attachments: [photo])
        let parts = ChatBubbleParts.parts(for: ChatTimeline.rows(for: [message]))
        let bubble = ChatBubble(part: parts[0], text: NSAttributedString())
        guard case .photo(let item) = bubble.kind else {
            Issue.record("expected a photo")
            return
        }
        #expect(item.size == CGSize(width: 240, height: 180))
        #expect(ChatViewController.isUploading(photo, in: parts[0].row))
        #expect(ChatBubbleParts.accessibilityLabel(for: parts[0]).hasPrefix("You sent a photo"))
        let text = ChatBubble(part: parts[1], text: NSAttributedString(string: "Hi"))
        guard case .attributedText = text.kind else {
            Issue.record("expected text")
            return
        }
    }

    @Test func fileCellShowsIconNameAndSize() {
        let doc = ChatAttachment(id: "d", kind: .pdf, name: "Lease.pdf", byteCount: 2_400_000,
                                 fileURL: URL(fileURLWithPath: "/dev/null"), mimeType: "application/pdf")
        let text = AttachmentFileText.make(doc, outgoing: true, traits: UITraitCollection(preferredContentSizeCategory: .large))
        #expect(text.string.contains("Lease.pdf"))
        #expect(text.string.contains(AttachmentPayload.sizeText(2_400_000)))
        #expect(text.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        #expect(AttachmentFileText.symbol(for: doc) == "doc.richtext.fill")
    }
}

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap(\.allSubviews) }
}
