#if DEBUG
import HermesKit
import UIKit

/// DEBUG only: fixture photos, files and a location card for `HERMES_DEMO=attachments` (issue #8).
/// The thread shows sent photo and file bubbles, a failed upload and a send with progress rings.
/// The composer starts with 2 photos and 1 PDF in the strip.
enum AttachmentDemo {
    static var isActive: Bool { DemoChatTransport.Scenario.current == .attachments }
    /// `HERMES_DEMO_ATTACH=sent`: no send in progress and an empty strip, so the sent bubbles show.
    static var sentOnly: Bool { ProcessInfo.processInfo.environment["HERMES_DEMO_ATTACH"] == "sent" }

    /// Its own folder: the composer clears the attachment folder at launch.
    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentDemo", isDirectory: true)
    }

    static func messages(now: Date) -> [ChatMessage] {
        let start = now.addingTimeInterval(-3 * 60)
        let beach = photo("beach", size: CGSize(width: 1600, height: 1200), hue: 0.55)
        let shot = photo("screenshot", size: CGSize(width: 1179, height: 2556), hue: 0.75)
        var lease = file("Lease agreement 2026.pdf", pages: 3)
        lease.upload = .attached
        let card = location()
        var failed = photo("sunset", size: CGSize(width: 1200, height: 1500), hue: 0.05)
        failed.upload = .failed
        var sending = [photo("garden", size: CGSize(width: 1600, height: 1200), hue: 0.3),
                       photo("street", size: CGSize(width: 1200, height: 1600), hue: 0.12),
                       file("Server logs.txt", pages: nil)]
        sending[0].upload = .attached
        sending[1].upload = .uploading
        let all = [
            ChatMessage(id: "a1", role: .user, text: "What is in these?", date: start, delivery: .delivered,
                        userRowId: 121, attachments: [attached(beach), attached(shot)]),
            ChatMessage(id: "a2", role: .assistant, text: "A beach at noon and a settings screen with **Wi-Fi** off.",
                        date: start.addingTimeInterval(20), reply: .complete, promptId: "a1"),
            ChatMessage(id: "a3", role: .user, text: "", date: start.addingTimeInterval(40), delivery: .delivered,
                        userRowId: 123, attachments: [lease]),
            ChatMessage(id: "a4", role: .assistant, text: "The lease runs to **June 30, 2027**. Rent is due on the 1st.",
                        date: start.addingTimeInterval(55), reply: .complete, promptId: "a3"),
            ChatMessage(id: "a5", role: .user, text: "My location: 30.26715, -97.74306 (accuracy 12 m).",
                        date: start.addingTimeInterval(70), delivery: .delivered, userRowId: 125, attachments: [card]),
            ChatMessage(id: "a6", role: .user, text: "", date: start.addingTimeInterval(90), delivery: .failed,
                        attachments: [failed]),
            ChatMessage(id: "a7", role: .user, text: "Which plants are these?", date: start.addingTimeInterval(110),
                        delivery: .sending, attachments: sending),
        ]
        return sentOnly ? Array(all.dropLast()) : all
    }

    /// The strip at launch: 2 photos and 1 PDF.
    static func pendingItems() -> [ChatAttachment] {
        guard !sentOnly else { return [] }
        return [photo("dog", size: CGSize(width: 1200, height: 1200), hue: 0.08),
         photo("receipt", size: CGSize(width: 900, height: 1600), hue: 0.6),
         file("Invoice 1142.pdf", pages: 2)]
    }

    private static func attached(_ item: ChatAttachment) -> ChatAttachment {
        var item = item
        item.upload = .attached
        return item
    }

    private static func photo(_ name: String, size: CGSize, hue: CGFloat) -> ChatAttachment {
        let url = target(name + ".jpg")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
                          UIColor(hue: hue + 0.08, saturation: 0.75, brightness: 0.55, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1])
            if let gradient {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                                     options: [])
            }
            UIColor.white.withAlphaComponent(0.8).setFill()
            let radius = min(size.width, size.height) / 6
            UIBezierPath(ovalIn: CGRect(x: size.width * 0.62, y: size.height * 0.18, width: radius * 2,
                                        height: radius * 2)).fill()
            UIColor.black.withAlphaComponent(0.18).setFill()
            UIBezierPath(rect: CGRect(x: 0, y: size.height * 0.7, width: size.width, height: size.height * 0.3)).fill()
        }
        let data = image.jpegData(compressionQuality: 0.8) ?? Data()
        try? data.write(to: url)
        return ChatAttachment(id: "demo-\(name)", kind: .photo, name: name + ".jpg", byteCount: data.count, fileURL: url,
                              mimeType: "image/jpeg", pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                              upload: .pending)
    }

    private static func file(_ name: String, pages: Int?) -> ChatAttachment {
        let url = target(name)
        let data: Data
        if let pages {
            data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
                for _ in 0..<pages { context.beginPage() }
            }
        } else {
            data = Data(String(repeating: "2026-11-16 09:41:00 gateway ready\n", count: 4000).utf8)
        }
        try? data.write(to: url)
        return ChatAttachment(id: "demo-\(name)", kind: pages == nil ? .file : .pdf, name: name, byteCount: data.count,
                              fileURL: url, mimeType: pages == nil ? "text/plain" : "application/pdf", pageCount: pages)
    }

    private static func location() -> ChatAttachment {
        let image = MainActor.assumeIsolated { LocationCardSnapshot.pinOnly(traits: nil) }
        let url = target("Location.jpg")
        let data = image.jpegData(compressionQuality: 0.85) ?? Data()
        try? data.write(to: url)
        return ChatAttachment(id: "demo-location", kind: .location, name: "Location.jpg", byteCount: data.count,
                              fileURL: url, mimeType: "image/jpeg", pixelWidth: Int(image.size.width * image.scale),
                              pixelHeight: Int(image.size.height * image.scale))
    }

    private static func target(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }
}

/// The demo attach calls wait a moment, so the rings show.
extension DemoChatTransport: AttachmentTransport {
    func attachImage(sessionId _: String, data _: Data, filename _: String) async throws {
        try await Task.sleep(for: .milliseconds(1200))
    }

    func attachFile(sessionId _: String, data _: Data, name: String, mimeType _: String) async throws -> String? {
        try await Task.sleep(for: .milliseconds(1200))
        return "@file:attachments/\(name)"
    }

    func attachPDF(sessionId _: String, data _: Data, filename _: String, lastPage _: Int?) async throws {
        try await Task.sleep(for: .milliseconds(1200))
    }
}
#endif
