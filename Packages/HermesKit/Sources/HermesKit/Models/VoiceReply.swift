import AVFoundation
import Foundation

/// The spoken audio of an incoming reply to a voice memo (issue #10, docs/hermes-protocol.md 3.9).
/// The reply text bubble shows first. The audio bubble shows under it.
public enum SpokenReply: Sendable, Equatable {
    /// `POST /api/audio/speak` runs. The bubble shows "Preparing audio…".
    case preparing
    /// The audio is in a local file. A replay reads the file, with no network call.
    case ready(VoiceReplyAudio)
    /// The speak call failed. The bubble shows "Audio unavailable. Tap to retry."
    case failed

    public var audio: VoiceReplyAudio? {
        if case .ready(let audio) = self { return audio }
        return nil
    }
}

/// One saved voice reply file.
public struct VoiceReplyAudio: Sendable, Equatable {
    public var fileURL: URL
    /// The length in seconds.
    public var duration: TimeInterval

    public init(fileURL: URL, duration: TimeInterval) {
        self.fileURL = fileURL
        self.duration = duration
    }
}

/// The decoded `data_url` of `POST /api/audio/speak`.
public struct SpokenAudio: Sendable, Equatable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    /// Splits `data:<mime>;base64,<body>`. Returns `nil` for any other form.
    public static func decode(dataURL: String) -> SpokenAudio? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let mime = String(header.dropLast(";base64".count))
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])), !data.isEmpty else {
            return nil
        }
        return SpokenAudio(data: data, mimeType: mime.isEmpty ? "audio/mpeg" : mime)
    }
}

/// The text that goes to the speak call (docs/hermes-protocol.md 3.9 step 5).
public enum VoiceReplyText {
    /// The plain reply text with no code blocks, no `MEDIA:` tags and no Markdown marks.
    /// Link runs keep their label. An empty result means: do not call speak.
    /// Issue #36: headings, bullets, quotes, rules and left-over emphasis marks go too. The bubble keeps them.
    public static func spokenText(_ text: String) -> String {
        let plain = ChatMarkdown.runs(text).filter { !$0.isCodeBlock }.map(\.text).joined()
        let lines = plain.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("MEDIA:") || isRule(trimmed) { return nil }
            return withoutEmphasisMarks(withoutBlockMarks(trimmed))
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `---`, `***` or `___` (spaces allowed): a thematic break.
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// Drops the marks at the start of a line: quotes (`>`), headings (`#` to `######`, also closing `#`s)
    /// and bullets (`-`, `*`, `+`). A numbered item keeps its number.
    private static func withoutBlockMarks(_ line: String) -> String {
        var rest = Substring(line)
        while rest.hasPrefix(">") { rest = rest.dropFirst().drop { $0 == " " } }
        let hashes = rest.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), rest.count == hashes || rest.dropFirst(hashes).first == " " {
            rest = rest.dropFirst(hashes).drop { $0 == " " }
            let body = rest.trimmingCharacters(in: .whitespaces)
            let closing = body.reversed().prefix { $0 == "#" }.count
            if closing > 0, closing == body.count || body.dropLast(closing).last == " " {
                rest = Substring(body.dropLast(closing))
            }
        } else if let mark = rest.first, "-*+".contains(mark), rest.count == 1 || rest.dropFirst().first == " " {
            rest = rest.dropFirst().drop { $0 == " " }
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// Marks that the inline parser left, for example an open `**` in a reply that ended early.
    /// A single `_` or `~` stays, because names and paths use it (`file_name`, `~home`).
    private static func withoutEmphasisMarks(_ line: String) -> String {
        line.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")
    }
}

/// Settings > Voice (issue #10 design notes).
public enum VoiceReplySettings {
    /// The `UserDefaults` key of "Auto-Play Voice Replies".
    public static let autoPlayKey = "voice.autoPlayReplies"

    /// On by default (owner decision 2026-11-16).
    public static func autoPlay(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoPlayKey) as? Bool ?? true
    }
}

/// Issue #36: why a voice reply has no audio.
public enum VoiceReplyError: Error, Equatable {
    /// The bytes are not audio that iOS plays, or a broken Ogg Opus stream (issue #42).
    case cannotDecode
}

/// The files of the voice replies: Application Support/HermesConnect/VoiceReplies.
public enum VoiceReplyFiles {
    public static func directory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "HermesConnect/VoiceReplies", directoryHint: .isDirectory)
    }

    /// The file extension for a speak MIME type (`web_routers/audio.py:54-57`).
    public static func fileExtension(mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/ogg": "ogg"
        case "audio/opus": "opus"
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/flac": "flac"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": "m4a"
        default: "mp3"
        }
    }

    /// Writes the audio to a new file in `folder` and reads its length.
    /// Issue #36: audio that does not decode, or has no length, throws `VoiceReplyError.cannotDecode`
    /// and leaves no file. The bubble then shows the error state with retry, not a ready 0 s bubble.
    /// Issue #42: Ogg Opus (found by its "OggS" bytes, for any MIME type) is decoded to a WAV file first.
    /// AVAudioPlayer opens an Ogg file and reads its length, but it cannot play it.
    public static func save(_ audio: SpokenAudio, in folder: URL = directory()) throws -> VoiceReplyAudio {
        let isOgg = OggOpus.isOgg(audio.data)
        let data = isOgg ? try OggOpus.wav(from: audio.data) : audio.data
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = isOgg ? "wav" : fileExtension(mimeType: audio.mimeType)
        let url = folder.appending(path: "\(UUID().uuidString).\(ext)")
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
        guard let duration = playableDuration(url) else {
            try? FileManager.default.removeItem(at: url)
            throw VoiceReplyError.cannotDecode
        }
        return VoiceReplyAudio(fileURL: url, duration: duration)
    }

    /// The length of a file that the player opens and that decodes to audio frames, else `nil`.
    /// Issue #42: the length alone is not enough, because AVAudioPlayer reads it from an Ogg file too.
    /// The check reads a few frames and does not touch the audio session, so other audio keeps playing.
    static func playableDuration(_ url: URL) -> TimeInterval? {
        guard let duration = try? AVAudioPlayer(contentsOf: url).duration, duration.isFinite, duration > 0,
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096),
              (try? file.read(into: buffer, frameCount: 4_096)) != nil, buffer.frameLength > 0 else { return nil }
        return duration
    }
}
