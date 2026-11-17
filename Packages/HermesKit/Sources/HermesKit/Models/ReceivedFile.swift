import Foundation

/// One file that Hermes sent with a `MEDIA:` tag in its reply text (issue #12, docs/hermes-protocol.md 5.1).
/// The bytes stay on the server until the owner opens the file. Never log the path or the name.
public struct ReceivedFile: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// An inline image bubble. A tap opens Quick Look.
        case image
        /// The #10 audio bubble, with no auto-play. Issue #50 transcribes these files.
        case audio
        /// The file cell: icon, name, size.
        case file
    }

    /// The path on the server, as the tag gives it. It goes only to the download routes of protocol 5.2.
    public let path: String
    /// The last path component, for the cell and the saved copy.
    public let name: String
    public let kind: Kind

    public var id: String { path }

    public init(path: String) {
        self.path = path
        let last = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        name = last.isEmpty ? "File" : last
        kind = Self.kind(forExtension: (last as NSString).pathExtension)
    }

    /// The lowercased file extension, with no dot.
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    /// Issue #12 design notes: these types use the #10 audio bubble. Issue #50 finds them here.
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "ogg", "wav"]
    /// Types that `UIImage` decodes. Other images (SVG) show as a file cell.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic"]

    public static func kind(forExtension ext: String) -> Kind {
        let ext = ext.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if audioExtensions.contains(ext) { return .audio }
        return .file
    }
}

/// The `MEDIA:` tags of a reply (docs/hermes-protocol.md 5.1). A port of the Desktop parser
/// (`apps/desktop/src/lib/chat-messages/parts.ts:180-300`), so both clients find the same files.
public enum MediaTags {
    public struct Split: Sendable, Equatable {
        /// The reply text with no tags. Empty when the text was only tags.
        public var text: String
        /// The files, in tag order. A path shows once.
        public var files: [ReceivedFile]
    }

    /// Splits the text into the visible text and the files. Text with no tag comes back unchanged.
    public static func split(_ text: String) -> Split {
        guard text.contains("MEDIA:") else { return Split(text: text, files: []) }
        let source = text as NSString
        var result = ""
        var files: [ReceivedFile] = []
        var cursor = 0
        for match in tagExpression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let value = source.substring(with: match.range(at: 1))
            guard let found = path(fromCapture: value) else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += found.punctuation
            cursor = match.range.location + match.range.length
            if !files.contains(where: { $0.path == found.path }) { files.append(ReceivedFile(path: found.path)) }
        }
        guard !files.isEmpty else { return Split(text: text, files: []) }
        result += source.substring(from: cursor)
        return Split(text: tidy(result), files: files)
    }

    /// The text with no tags. VoiceOver and the speak call read it.
    public static func visibleText(_ text: String) -> String { split(text).text }

    // MARK: Parser

    /// `MEDIA_DELIVERY_EXTS`, longest first, so a short type never matches the start of a longer one.
    static let deliveryExtensions = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg", "mp4", "mov", "avi", "mkv", "webm", "3gp", "mp3",
        "m2a", "wav", "ogg", "opus", "m4a", "flac", "pdf", "docx", "doc", "odt", "rtf", "txt", "md", "epub", "xlsx",
        "xls", "ods", "csv", "tsv", "json", "xml", "yaml", "yml", "kmz", "kml", "geojson", "gpx", "pptx", "ppt", "odp",
        "key", "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "apk", "ipa", "html", "htm",
    ].sorted { $0.count > $1.count }

    private static let tagExpression: NSRegularExpression = {
        let exts = deliveryExtensions.joined(separator: "|")
        let anchored = #"(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:"# + exts
            + #")(?=[\s`"'*_,;:)\]}]|MEDIA:|$)"#
        let bare = #"[^\s`"]+"#
        let pattern = #"[`"']?MEDIA:\s*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|"# + anchored + "|" + bare + #")[`"']?"#
        // The pattern is a constant. A failure here is a programmer error that every test finds.
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]

    /// A path separator, or a dot with text after it (`report.md`, `.env`). Else the capture is prose.
    static func isPlausiblePath(_ value: String) -> Bool {
        if value.contains("/") || value.contains("\\") { return true }
        guard let dot = value.firstIndex(of: ".") else { return false }
        var index = dot
        while index < value.endIndex {
            let next = value.index(after: index)
            if value[index] == ".", next < value.endIndex, value[next] != "." { return true }
            index = next
        }
        return false
    }

    /// The path and the sentence punctuation that trailed a bare capture (`open MEDIA:/tmp/a.pdf.`).
    /// Quoted captures keep each character inside the quotes.
    static func path(fromCapture raw: String) -> (path: String, punctuation: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        if trimmed.count >= 2, "\"'`".contains(first), trimmed.last == first {
            let inner = String(trimmed.dropFirst().dropLast())
            return isPlausiblePath(inner) ? (inner, "") : nil
        }
        var value = trimmed
        if value.last == "`" || value.last == "\"" { value.removeLast() }
        var end = value.endIndex
        while end > value.startIndex {
            let before = value.index(before: end)
            guard trailingPunctuation.contains(value[before]), isPlausiblePath(String(value[..<before])) else { break }
            end = before
        }
        let path = String(value[..<end])
        return isPlausiblePath(path) ? (path, String(value[end...])) : nil
    }

    /// Drops the blank lines and spaces that the removed tags leave.
    private static func tidy(_ text: String) -> String {
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            var line = line
            while line.last == " " || line.last == "\t" { line.removeLast() }
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// The `@file:` refs at the start of a prompt that `file.attach` made (docs/hermes-protocol.md 3.8).
/// The server history has them in the user text. Issue #12: a row with no local attachments shows file cells.
public enum AttachmentRefs {
    public struct Split: Sendable, Equatable {
        public var text: String
        /// The ref paths, in order.
        public var paths: [String]
    }

    /// Reads the ref lines at the start of `text`, then the blank line, then the owner text.
    public static func split(_ text: String) -> Split {
        guard text.hasPrefix("@file:") else { return Split(text: text, paths: []) }
        var lines = text.components(separatedBy: "\n")[...]
        var paths: [String] = []
        while let line = lines.first, line.hasPrefix("@file:") {
            var value = String(line.dropFirst("@file:".count)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, "\"'`".contains(quote), value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { break }
            paths.append(value)
            lines = lines.dropFirst()
        }
        if lines.first?.isEmpty == true { lines = lines.dropFirst() }
        return Split(text: lines.joined(separator: "\n"), paths: paths)
    }

    /// File cells for the refs of a server row. The bytes are not on the phone, so the size is 0 (not shown).
    public static func attachments(for paths: [String], rowId: String) -> [ChatAttachment] {
        paths.enumerated().map { index, path in
            let file = ReceivedFile(path: path)
            let kind: ChatAttachment.Kind = file.fileExtension == "pdf" ? .pdf : .file
            return ChatAttachment(id: "\(rowId)-ref\(index)", kind: kind, name: file.name, byteCount: 0,
                                  fileURL: URL(fileURLWithPath: "/dev/null"), mimeType: "", upload: .attached,
                                  refText: "@file:\(path)")
        }
    }
}
