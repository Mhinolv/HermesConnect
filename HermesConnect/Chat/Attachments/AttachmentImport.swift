import HermesKit
import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Turns picked photos, camera shots and files into `ChatAttachment`s (issue #8).
/// Each item gets a private copy in Application Support. Never log a name or the bytes.
enum AttachmentImport {
    enum Failure: Error, Equatable {
        case tooLarge
        case unreadable
    }

    /// The folder of the private copies: Application Support/HermesConnect/Attachments.
    /// Issue #12: the cache keeps the sent bubbles, so the copies stay until `keepDays` pass.
    static var folder: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HermesConnect/Attachments", isDirectory: true)
    }

    /// A sent photo shows in the cached thread for this many days. After that its bubble shows the gray box.
    static let keepDays = 30

    /// Settings > Photos > "Include Photo Location". Off by default.
    static var includesPhotoLocation: Bool {
        UserDefaults.standard.bool(forKey: AttachmentSettings.includeLocationKey)
    }

    /// A photo from the picker, the camera or the clipboard: downscaled JPEG, no GPS unless the owner allows it.
    static func photo(from data: Data, name: String? = nil) throws -> ChatAttachment {
        let encoded = try PhotoEncoder.encode(data, includeLocation: includesPhotoLocation)
        guard AttachmentLimits.check(kind: .photo, byteCount: encoded.data.count) == .ok else { throw Failure.tooLarge }
        let id = UUID().uuidString
        let base = name.map { ($0 as NSString).deletingPathExtension } ?? "Photo"
        let fileName = "\(base.isEmpty ? "Photo" : base).jpg"
        let url = try write(encoded.data, id: id, name: fileName)
        return ChatAttachment(id: id, kind: .photo, name: fileName, byteCount: encoded.data.count, fileURL: url,
                              mimeType: "image/jpeg", pixelWidth: encoded.width, pixelHeight: encoded.height)
    }

    static func photo(from image: UIImage) throws -> ChatAttachment {
        guard let data = image.jpegData(compressionQuality: 0.95) else { throw Failure.unreadable }
        return try photo(from: data)
    }

    /// A file from the document picker. Images go as photos. PDFs carry their page count.
    /// Throws `.tooLarge` before any copy when the size is over the cap.
    static func file(at source: URL) throws -> ChatAttachment {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let type = values.contentType ?? UTType(filenameExtension: source.pathExtension) ?? .data
        let size = values.fileSize ?? 0
        let name = source.lastPathComponent
        if type.conforms(to: .image), size <= AttachmentLimits.imageBytes * 4 {
            let data = try Data(contentsOf: source)
            if let photo = try? photo(from: data, name: name) { return photo }
        }
        let kind: ChatAttachment.Kind = type.conforms(to: .pdf) ? .pdf : .file
        guard AttachmentLimits.check(kind: kind, byteCount: size) == .ok else { throw Failure.tooLarge }
        let id = UUID().uuidString
        let target = try folder(for: id).appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: target)
        let pages = kind == .pdf ? PDFDocument(url: target)?.pageCount : nil
        return ChatAttachment(id: id, kind: kind, name: name, byteCount: size, fileURL: target,
                              mimeType: type.preferredMIMEType ?? "application/octet-stream", pageCount: pages)
    }

    /// The map snapshot of the "Send Location" card.
    static func locationCard(_ image: UIImage) throws -> ChatAttachment {
        guard let data = image.jpegData(compressionQuality: 0.85) else { throw Failure.unreadable }
        let id = UUID().uuidString
        let url = try write(data, id: id, name: "Location.jpg")
        let scale = image.scale
        return ChatAttachment(id: id, kind: .location, name: "Location.jpg", byteCount: data.count, fileURL: url,
                              mimeType: "image/jpeg", pixelWidth: Int(image.size.width * scale),
                              pixelHeight: Int(image.size.height * scale))
    }

    /// Removes the private copies of items that the owner removed from the strip.
    static func discard(_ item: ChatAttachment) {
        try? FileManager.default.removeItem(at: item.fileURL.deletingLastPathComponent())
    }

    /// Once per launch, before the first composer shows: removes the copies older than `keepDays`, and the
    /// temporary folder of builds before issue #12.
    @MainActor static func clearEarlierLaunches(now: Date = Date()) {
        guard !cleared else { return }
        cleared = true
        let manager = FileManager.default
        try? manager.removeItem(at: manager.temporaryDirectory.appendingPathComponent("Attachments", isDirectory: true))
        let limit = now.addingTimeInterval(-Double(keepDays) * 24 * 3600)
        let items = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < limit { try? manager.removeItem(at: item) }
        }
    }

    @MainActor private static var cleared = false

    /// `ProtectedStorage` rules (issue #18): the folder is excluded from backup, the files use
    /// `completeUntilFirstUserAuthentication`.
    private static func folder(for id: String) throws -> URL {
        try ProtectedStorage.prepare(directory: folder)
        let url = folder.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ data: Data, id: String, name: String) throws -> URL {
        let url = try folder(for: id).appendingPathComponent(name)
        try data.write(to: url, options: ProtectedStorage.writeOptions)
        return url
    }
}

enum AttachmentSettings {
    static let includeLocationKey = "attachments.includePhotoLocation"
}

/// Settings > Photos (issue #8 orchestrator note): photo GPS data stays on the phone unless the owner turns it on.
struct PhotoSettingsSection: View {
    @AppStorage(AttachmentSettings.includeLocationKey) private var includeLocation = false

    var body: some View {
        Section {
            Toggle("Include Photo Location", isOn: $includeLocation)
        } header: {
            Text("Photos")
        } footer: {
            Text("When this is off, Hermes removes the location from photos before it sends them.")
        }
    }
}
