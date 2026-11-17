import Foundation

/// One photo, file, PDF or location card on an outgoing message (issue #8).
///
/// The bytes stay in a local file (`fileURL`), so a message compare does not compare megabytes.
/// Never log the name or the bytes.
public struct ChatAttachment: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `image.attach_bytes`. The file is the downscaled JPEG.
        case photo
        /// `file.attach` with a `data_url`. The reply text gets its `ref_text`.
        case file
        /// `pdf.attach`. A server with no `pdftoppm` (5028) gets `file.attach`.
        case pdf
        /// The one-time "Send Location" card. The file is the map snapshot. Nothing uploads: the text line goes.
        case location
    }

    /// The state of the attach call.
    public enum Upload: Sendable, Equatable {
        case pending
        case uploading
        case attached
        case failed
    }

    public let id: String
    public var kind: Kind
    /// The display name ("IMG_0001.jpg", "Lease.pdf").
    public var name: String
    public var byteCount: Int
    public var fileURL: URL
    /// The MIME type for the `data_url` of `file.attach`.
    public var mimeType: String
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var pageCount: Int?
    public var upload: Upload
    /// The `@file:` ref that `file.attach` returned. It goes first in the prompt text.
    public var refText: String?
    /// The live session that holds the attached item. A retry on the same session does not upload it again.
    public var attachedSessionId: String?

    public init(id: String, kind: Kind, name: String, byteCount: Int, fileURL: URL, mimeType: String,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil, pageCount: Int? = nil,
                upload: Upload = .pending, refText: String? = nil, attachedSessionId: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.byteCount = byteCount
        self.fileURL = fileURL
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pageCount = pageCount
        self.upload = kind == .location ? .attached : upload
        self.refText = refText
        self.attachedSessionId = attachedSessionId
    }

    /// Photos and location cards show as image bubbles. Files and PDFs show as file cells.
    public var showsAsImage: Bool { kind == .photo || kind == .location }

    /// `true` when the item must go to `session` before `prompt.submit`.
    public func needsUpload(to session: String) -> Bool {
        guard kind != .location else { return false }
        return !(upload == .attached && attachedSessionId == session)
    }
}

/// The size caps of docs/hermes-protocol.md 3.8 (`prompt_attachments.py:20-23`). The app checks them on pick.
public enum AttachmentLimits {
    public static let mebibyte = 1024 * 1024
    /// `image.attach_bytes`: 25 MiB decoded.
    public static let imageBytes = 25 * mebibyte
    /// `file.attach` with a `data_url`: 256 MiB.
    public static let fileBytes = 256 * mebibyte
    /// `pdf.attach`: 50 MiB.
    public static let pdfBytes = 50 * mebibyte
    /// `pdf.attach` reads 25 pages per call.
    public static let pdfPages = 25
    /// The photo picker takes 10 items.
    public static let maxPhotos = 10
    /// The long edge of a photo after the downscale.
    public static let photoLongEdge = 2048

    public enum Check: Sendable, Equatable {
        case ok
        /// The "File Too Large" alert.
        case tooLarge
        /// The PDF has more pages than Hermes reads. The owner picks "Send" or "Cancel".
        case pdfPagesOver(Int)
    }

    public static func check(kind: ChatAttachment.Kind, byteCount: Int, pageCount: Int? = nil) -> Check {
        switch kind {
        case .photo:
            return byteCount <= imageBytes ? .ok : .tooLarge
        case .file:
            return byteCount < fileBytes ? .ok : .tooLarge
        case .pdf:
            guard byteCount <= pdfBytes else { return .tooLarge }
            if let pageCount, pageCount > pdfPages { return .pdfPagesOver(pageCount) }
            return .ok
        case .location:
            return .ok
        }
    }

    public static let tooLargeTitle = "File Too Large"
    public static let tooLargeMessage = "Files must be smaller than 256 MB. PDFs must be 50 MB or smaller."
    public static let pdfPagesTitle = "Hermes reads the first 25 pages."
}

/// The wire forms of an attachment (docs/hermes-protocol.md 3.8).
public enum AttachmentPayload {
    /// Desktop sends this text when the owner sends only images (`submit.ts:302`).
    public static let imageOnlyPrompt = "What do you see in this image?"

    /// `data:<mime>;base64,<bytes>` for `file.attach`.
    public static func dataURL(_ data: Data, mimeType: String) -> String {
        "data:\(mimeType.isEmpty ? "application/octet-stream" : mimeType);base64,\(data.base64EncodedString())"
    }

    /// The `prompt.submit` text: the `@file:` refs (one per line), a blank line, then the owner text.
    /// Only images and no text: the Desktop image prompt (`submit.ts:288-303`).
    public static func promptText(_ text: String, attachments: [ChatAttachment]) -> String {
        let refs = attachments.compactMap(\.refText).filter { !$0.isEmpty }.joined(separator: "\n")
        let visible = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
        let joined = [refs, visible].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if joined.isEmpty, attachments.contains(where: { $0.kind == .photo || $0.kind == .pdf }) {
            return imageOnlyPrompt
        }
        return joined
    }

    /// "2.4 MB" for the file cell and the pending chip.
    public static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
