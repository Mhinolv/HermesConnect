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
    public static func spokenText(_ text: String) -> String {
        let plain = ChatMarkdown.runs(text).filter { !$0.isCodeBlock }.map(\.text).joined()
        let lines = plain.components(separatedBy: .newlines).filter { line in
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("MEDIA:")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
    public static func save(_ audio: SpokenAudio, in folder: URL = directory()) throws -> VoiceReplyAudio {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(UUID().uuidString).\(fileExtension(mimeType: audio.mimeType))")
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try audio.data.write(to: url, options: options)
        let duration = (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
        return VoiceReplyAudio(fileURL: url, duration: duration.isFinite ? duration : 0)
    }
}
