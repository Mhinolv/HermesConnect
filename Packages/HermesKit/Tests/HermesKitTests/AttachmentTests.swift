import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HermesKit

/// A chat transport with attach calls (issue #8). Scripted answers, no network.
private final class FakeAttachTransport: ChatTransport, AttachmentTransport, @unchecked Sendable {
    enum Call: Equatable {
        case image(session: String, name: String, bytes: Int)
        case file(session: String, name: String, mime: String)
        case pdf(session: String, name: String, lastPage: Int?)
    }

    let events: AsyncStream<GatewayClientEvent> = AsyncStream { _ in }
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _submits: [String] = []
    /// Attach calls with these names fail.
    var failNames: Set<String> = []
    var pdfError: (any Error)?
    var calls: [Call] { lock.withLock { _calls } }
    var submits: [String] { lock.withLock { _submits } }

    struct Failure: Error {}

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: "20261116_101500_ab12cd")
    }

    func resumeSession(storedId: String, source _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s2", storedId: storedId)
    }

    func submitPrompt(sessionId _: String, text: String, retryBeforeRowId _: Int?) async throws -> Int? {
        lock.withLock { _submits.append(text) }
        return 7
    }

    func stopReply(sessionId _: String) async throws -> Bool { true }
    func history(sessionId _: String) async throws -> [TranscriptMessage] { [] }

    func attachImage(sessionId: String, data: Data, filename: String) async throws {
        lock.withLock { _calls.append(.image(session: sessionId, name: filename, bytes: data.count)) }
        if lock.withLock({ failNames.contains(filename) }) { throw Failure() }
    }

    func attachFile(sessionId: String, data _: Data, name: String, mimeType: String) async throws -> String? {
        lock.withLock { _calls.append(.file(session: sessionId, name: name, mime: mimeType)) }
        if lock.withLock({ failNames.contains(name) }) { throw Failure() }
        return "@file:attachments/\(name)"
    }

    func attachPDF(sessionId: String, data _: Data, filename: String, lastPage: Int?) async throws {
        lock.withLock { _calls.append(.pdf(session: sessionId, name: filename, lastPage: lastPage)) }
        if let error = lock.withLock({ pdfError }) { throw error }
    }
}

private func ids() -> @Sendable () -> String {
    let counter = IdCounter()
    return { counter.next() }
}

private final class IdCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> String { lock.withLock { value += 1; return "m\(value)" } }
}

private func tempFile(_ name: String, bytes: Int = 16) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("attach-test-\(UUID().uuidString)-\(name)")
    try Data(repeating: 7, count: bytes).write(to: url)
    return url
}

private func item(_ id: String, _ kind: ChatAttachment.Kind, _ name: String, pages: Int? = nil) throws -> ChatAttachment {
    let mime = switch kind {
    case .photo, .location: "image/jpeg"
    case .pdf: "application/pdf"
    case .file: "text/plain"
    }
    return ChatAttachment(id: id, kind: kind, name: name, byteCount: 16, fileURL: try tempFile(name), mimeType: mime,
                          pageCount: pages)
}

/// A JPEG of `width` x `height` with a GPS dictionary.
private func photoWithGPS(width: Int, height: Int) throws -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    let properties: [CFString: Any] = [kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 30.2672, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 97.7431, kCGImagePropertyGPSLongitudeRef: "W",
    ]]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite(.timeLimit(.minutes(1))) struct AttachmentLimitTests {
    @Test func capsMatchProtocolSection38() {
        let mib = AttachmentLimits.mebibyte
        #expect(AttachmentLimits.check(kind: .photo, byteCount: 25 * mib) == .ok)
        #expect(AttachmentLimits.check(kind: .photo, byteCount: 25 * mib + 1) == .tooLarge)
        #expect(AttachmentLimits.check(kind: .file, byteCount: 0) == .ok)
        #expect(AttachmentLimits.check(kind: .file, byteCount: 256 * mib - 1) == .ok)
        #expect(AttachmentLimits.check(kind: .file, byteCount: 256 * mib) == .tooLarge)
        #expect(AttachmentLimits.check(kind: .pdf, byteCount: 50 * mib, pageCount: 25) == .ok)
        #expect(AttachmentLimits.check(kind: .pdf, byteCount: 50 * mib + 1, pageCount: 1) == .tooLarge)
        #expect(AttachmentLimits.check(kind: .pdf, byteCount: 10, pageCount: 26) == .pdfPagesOver(26))
        // Size wins over pages: the owner cannot send a PDF over 50 MB.
        #expect(AttachmentLimits.check(kind: .pdf, byteCount: 51 * mib, pageCount: 90) == .tooLarge)
        #expect(AttachmentLimits.check(kind: .location, byteCount: .max) == .ok)
    }

    @Test func promptTextPutsRefsFirstThenABlankLine() throws {
        var file = try item("a", .file, "notes.txt")
        file.refText = "@file:attachments/notes.txt"
        var other = try item("b", .file, "log.txt")
        other.refText = "@file:attachments/log.txt"
        let photo = try item("c", .photo, "IMG_1.jpg")
        #expect(AttachmentPayload.promptText("Read these", attachments: [file, photo, other])
            == "@file:attachments/notes.txt\n@file:attachments/log.txt\n\nRead these")
        #expect(AttachmentPayload.promptText("", attachments: [file]) == "@file:attachments/notes.txt")
        #expect(AttachmentPayload.promptText("  ", attachments: [photo]) == AttachmentPayload.imageOnlyPrompt)
        #expect(AttachmentPayload.promptText("Hi", attachments: []) == "Hi")
        #expect(AttachmentPayload.promptText("", attachments: []) == "")
    }

    @Test func dataURLHasMimeAndBase64() {
        #expect(AttachmentPayload.dataURL(Data("hi".utf8), mimeType: "text/plain") == "data:text/plain;base64,aGk=")
        #expect(AttachmentPayload.dataURL(Data(), mimeType: "") == "data:application/octet-stream;base64,")
    }

    @Test func locationItemsNeverUpload() throws {
        let card = try item("l", .location, "Map.jpg")
        #expect(card.upload == .attached)
        #expect(!card.needsUpload(to: "s1"))
        var photo = try item("p", .photo, "IMG.jpg")
        #expect(photo.needsUpload(to: "s1"))
        photo.upload = .attached
        photo.attachedSessionId = "s1"
        #expect(!photo.needsUpload(to: "s1"))
        #expect(photo.needsUpload(to: "s2"))
    }

    @Test func locationLineHasCoordinatesAccuracyTimeAndMapsLink() throws {
        let fix = try #require(LocationFix(latitude: 30.267153, longitude: -97.743061, horizontalAccuracy: 12.4,
                                           timestamp: Date(timeIntervalSince1970: 1_794_830_400)))
        let text = LocationShareText.make(fix)
        #expect(text == "My location: 30.26715, -97.74306 (accuracy 12 m, 2026-11-16T12:00:00.000Z). "
            + "https://maps.apple.com/?ll=30.26715,-97.74306&q=My%20Location")
    }
}

@Suite(.timeLimit(.minutes(1))) struct PhotoEncoderTests {
    @Test func downscalesToLongEdgeAndDropsLocation() throws {
        let source = try photoWithGPS(width: 4032, height: 3024)
        #expect(PhotoEncoder.hasLocation(source))
        let encoded = try PhotoEncoder.encode(source)
        #expect(encoded.width == 2048)
        #expect(encoded.height == 1536)
        #expect(!PhotoEncoder.hasLocation(encoded.data))
        #expect(encoded.data.count < source.count)
    }

    @Test func keepsLocationWhenTheOwnerTurnsItOn() throws {
        let encoded = try PhotoEncoder.encode(try photoWithGPS(width: 300, height: 600), includeLocation: true)
        #expect(PhotoEncoder.hasLocation(encoded.data))
        // A small photo is not scaled up.
        #expect(encoded.width == 300)
        #expect(encoded.height == 600)
    }

    @Test func badDataThrows() {
        #expect(throws: PhotoEncoder.Failure.unreadable) { try PhotoEncoder.encode(Data("not an image".utf8)) }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct AttachmentSendTests {
    private func model(_ transport: any ChatTransport) -> ChatViewModel {
        ChatViewModel(transport: transport, redrawInterval: .seconds(60), makeId: ids())
    }

    @Test func attachmentsUploadInOrderThenPromptHasRefs() async throws {
        let transport = FakeAttachTransport()
        let vm = model(transport)
        let photo = try item("p1", .photo, "IMG_0001.jpg")
        let file = try item("f1", .file, "notes.txt")
        let task = vm.send("Look at these", attachments: [photo, file])
        #expect(vm.messages.count == 1)
        #expect(vm.messages[0].attachments.map(\.upload) == [.pending, .pending])
        await task?.value
        #expect(transport.calls == [.image(session: "s1", name: "IMG_0001.jpg", bytes: 16),
                                    .file(session: "s1", name: "notes.txt", mime: "text/plain")])
        #expect(transport.submits == ["@file:attachments/notes.txt\n\nLook at these"])
        #expect(vm.messages[0].delivery == .delivered)
        #expect(vm.messages[0].text == "Look at these")
        #expect(vm.messages[0].attachments.map(\.upload) == [.attached, .attached])
    }

    @Test func photosWithNoTextSendTheImagePrompt() async throws {
        let transport = FakeAttachTransport()
        let vm = model(transport)
        #expect(vm.send("") == nil)
        await vm.send(" ", attachments: [try item("p1", .photo, "a.jpg"), try item("p2", .photo, "b.jpg")])?.value
        #expect(transport.calls.count == 2)
        #expect(transport.submits == [AttachmentPayload.imageOnlyPrompt])
        #expect(vm.messages[0].text == "")
    }

    @Test func failedUploadShowsNotDeliveredThenRetryUploadsOnlyTheRest() async throws {
        let transport = FakeAttachTransport()
        transport.failNames = ["b.jpg"]
        let vm = model(transport)
        let items = [try item("p1", .photo, "a.jpg"), try item("p2", .photo, "b.jpg"), try item("p3", .photo, "c.jpg")]
        await vm.send("Hi", attachments: items)?.value
        #expect(vm.messages[0].delivery == .failed)
        #expect(vm.messages[0].attachments.map(\.upload) == [.attached, .failed, .pending])
        #expect(transport.submits.isEmpty)
        #expect(!vm.isReplyActive)
        #expect(ChatTimeline.rows(for: vm.messages).first?.footnote == .notDelivered)

        transport.failNames = []
        await vm.retrySend(id: vm.messages[0].id)?.value
        #expect(transport.calls.map { if case .image(_, let name, _) = $0 { name } else { "" } }
            == ["a.jpg", "b.jpg", "b.jpg", "c.jpg"])
        #expect(transport.submits == ["Hi"])
        #expect(vm.messages[0].delivery == .delivered)
        #expect(vm.messages[0].attachments.allSatisfy { $0.upload == .attached })
    }

    @Test func pdfUsesPdfAttachAndCapsLongPDFsAt25Pages() async throws {
        let transport = FakeAttachTransport()
        let vm = model(transport)
        await vm.send("", attachments: [try item("d1", .pdf, "short.pdf", pages: 3),
                                        try item("d2", .pdf, "long.pdf", pages: 40)])?.value
        #expect(transport.calls == [.pdf(session: "s1", name: "short.pdf", lastPage: nil),
                                    .pdf(session: "s1", name: "long.pdf", lastPage: 25)])
        #expect(transport.submits == [AttachmentPayload.imageOnlyPrompt])
    }

    @Test func pdfFallsBackToFileAttachWithoutPdftoppm() async throws {
        let transport = FakeAttachTransport()
        transport.pdfError = GatewayError.rpc(code: 5028, message: "pdftoppm not installed")
        let vm = model(transport)
        await vm.send("Summarize", attachments: [try item("d1", .pdf, "lease.pdf", pages: 3)])?.value
        #expect(transport.calls == [.pdf(session: "s1", name: "lease.pdf", lastPage: nil),
                                    .file(session: "s1", name: "lease.pdf", mime: "application/pdf")])
        #expect(transport.submits == ["@file:attachments/lease.pdf\n\nSummarize"])
    }

    @Test func locationCardSendsOnlyItsTextLine() async throws {
        let transport = FakeAttachTransport()
        let vm = model(transport)
        await vm.send("My location: 1.00000, 2.00000", attachments: [try item("l1", .location, "Map.jpg")])?.value
        #expect(transport.calls.isEmpty)
        #expect(transport.submits == ["My location: 1.00000, 2.00000"])
    }

    @Test func transportWithoutAttachCallsFailsTheMessage() async throws {
        let transport = FakeChatTransport()
        let vm = model(transport)
        await vm.send("Hi", attachments: [try item("p1", .photo, "a.jpg")])?.value
        #expect(vm.messages[0].delivery == .failed)
        #expect(vm.messages[0].attachments.first?.upload == .failed)
        #expect(transport.submits.isEmpty)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ChatBubblePartsTests {
    private func row(attachments: [ChatAttachment], text: String) -> ChatRow {
        let message = ChatMessage(id: "m1", role: .user, text: text, date: Date(), delivery: .failed,
                                  attachments: attachments)
        return ChatTimeline.rows(for: [message], statusLine: "Using web_search…")[0]
    }

    @Test func photosThenTextWithLabelsOnTheEnds() throws {
        let parts = ChatBubbleParts.parts(for: row(attachments: [try item("a", .photo, "1.jpg"),
                                                                 try item("b", .pdf, "2.pdf")], text: "Hi"))
        #expect(parts.map(\.id) == ["m1#a", "m1#b", "m1#text"])
        #expect(parts.map { $0.row.timeHeader != nil } == [true, false, false])
        #expect(parts.map(\.row.hasTail) == [false, false, true])
        #expect(parts.map(\.row.footnote) == [nil, nil, .notDelivered])
        #expect(parts.map(\.row.statusLine) == [nil, nil, "Using web_search…"])
        #expect(ChatBubbleParts.accessibilityLabel(for: parts[0]) == "You sent a photo")
        #expect(ChatBubbleParts.accessibilityLabel(for: parts[1]) == "You sent a file, 2.pdf, 16 bytes")
    }

    @Test func attachmentsOnlyHaveNoTextBubble() throws {
        let parts = ChatBubbleParts.parts(for: row(attachments: [try item("a", .photo, "1.jpg")], text: ""))
        #expect(parts.map(\.id) == ["m1#a"])
        #expect(parts[0].row.footnote == .notDelivered)
        #expect(ChatBubbleParts.accessibilityLabel(for: parts[0]) == "You sent a photo, Not Delivered")
    }

    @Test func plainMessageKeepsItsId() {
        let parts = ChatBubbleParts.parts(for: row(attachments: [], text: "Hi"))
        #expect(parts.map(\.id) == ["m1"])
    }

    @Test func historyMergeKeepsTheLocalTextAndItems() throws {
        let photo = try item("a", .photo, "1.jpg")
        let shown = ChatMessage(id: "m1", role: .user, text: "Hi", date: Date(), delivery: .delivered, userRowId: 5,
                                attachments: [photo])
        let row = TranscriptMessage(role: "user", text: "@file:attachments/x.txt\n\nHi", rowId: 5)
        let merged = ChatHistory.messages(from: [row], reusing: [shown])
        #expect(merged.first?.id == "m1")
        #expect(merged.first?.text == "Hi")
        #expect(merged.first?.attachments == [photo])
    }
}

@Suite(.timeLimit(.minutes(1))) struct AttachmentRPCTests {
    private func connected() async throws -> (GatewayClient, FakeGatewaySocket) {
        let socket = FakeGatewaySocket()
        let client = GatewayClient(endpoint: try GatewayEndpoint(port: 8123, token: String(repeating: "0f", count: 32)),
                                   connector: FakeGatewayConnector(socket), configuration: .init(heartbeatInterval: nil))
        async let ready = client.connect()
        socket.pushReady()
        socket.reply(to: try await socket.waitForRequest("client.capabilities"), result: "{}")
        _ = try await ready
        return (client, socket)
    }

    @Test func imageAttachBytesFrame() async throws {
        let (client, socket) = try await connected()
        let call = Task { try await client.attachImage(sessionId: "S", data: Data("hi".utf8), filename: "IMG_1.jpg") }
        let request = try await socket.waitForRequest("image.attach_bytes")
        #expect(request["params"] == ["session_id": "S", "content_base64": "aGk=", "filename": "IMG_1.jpg"])
        socket.reply(to: request, result: #"{"attached":true,"path":"/x/upload.jpg","count":1}"#)
        try await call.value
    }

    @Test func fileAttachFrameReturnsRefText() async throws {
        let (client, socket) = try await connected()
        let call = Task {
            try await client.attachFile(sessionId: "S", data: Data("hi".utf8), name: "notes.txt", mimeType: "text/plain")
        }
        let request = try await socket.waitForRequest("file.attach")
        #expect(request["params"] == ["session_id": "S", "data_url": "data:text/plain;base64,aGk=", "name": "notes.txt"])
        socket.reply(to: request, result: #"{"attached":true,"name":"notes.txt","ref_text":"@file:attachments/notes.txt"}"#)
        #expect(try await call.value == "@file:attachments/notes.txt")
    }

    @Test func pdfAttachFrameWithPageCap() async throws {
        let (client, socket) = try await connected()
        let call = Task { try await client.attachPDF(sessionId: "S", data: Data("hi".utf8), filename: "a.pdf", lastPage: 25) }
        let request = try await socket.waitForRequest("pdf.attach")
        #expect(request["params"] == ["session_id": "S", "content_base64": "aGk=", "filename": "a.pdf",
                                      "first_page": 1, "last_page": 25])
        socket.replyError(to: request, code: 4018, message: "too large")
        await #expect(throws: GatewayError.rpc(code: 4018, message: "too large")) { try await call.value }
    }
}
