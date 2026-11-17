#if DEBUG
import AVFoundation
import HermesKit

/// DEBUG only: the audio file transcripts of `HERMES_DEMO=audio-transcripts` (issue #50).
/// `HERMES_DEMO_TRANSCRIPTS` picks the files: `main` (default), `errors`, `permission`, or `sent` (issue #87).
/// No speech engine runs: the file name picks the result.
enum AudioTranscriptDemo {
    static let folder = "/home/hermes/.hermes/outputs/audio/"

    enum Variant: String {
        /// "Transcribe", a long file at 42 %, and a transcript.
        case main
        /// "No speech found.", a format that iOS cannot read, and a failed run.
        case errors
        /// Speech recognition is off: the line and the alert.
        case permission
        /// Issue #87: audio files that the owner sent: "Transcribe", 42 %, a transcript, and a format that iOS
        /// cannot read.
        case sent
    }

    static var variant: Variant {
        ProcessInfo.processInfo.environment["HERMES_DEMO_TRANSCRIPTS"].flatMap(Variant.init(rawValue:)) ?? .main
    }

    static var names: [String] {
        switch variant {
        case .main: ["voicemail.wav", "interview.wav", "standup.wav"]
        case .errors: ["wind.wav", "radio.ogg", "lecture.wav"]
        case .permission: ["voicemail.wav"]
        case .sent: []
        }
    }

    /// Issue #87: the sent files of the `sent` variant. `Voice memo.wav` keeps "Transcribe".
    static let sentNames = ["Voice memo.wav", "interview.wav", "standup.wav", "radio.ogg"]

    /// Issue #87: the private copies of the sent files, made again at each launch (no saved transcript).
    static let sentItems: [ChatAttachment] = {
        let root = FileManager.default.temporaryDirectory.appending(path: "AudioTranscriptDemo-sent",
                                                                     directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        return sentNames.enumerated().compactMap { index, name in
            let id = "demo-sent-\(index)"
            let folder = root.appending(path: id, directoryHint: .isDirectory)
            let url = folder.appending(path: name)
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                  let made = try? download(path: folder.path + "/" + name),
                  (try? FileManager.default.moveItem(at: made, to: url)) != nil else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return ChatAttachment(id: id, kind: .file, name: name, byteCount: size, fileURL: url,
                                  mimeType: name.hasSuffix(".ogg") ? "audio/ogg" : "audio/wav", upload: .attached)
        }
    }()

    /// The files that start a run at launch. `voicemail.wav` in `main` keeps "Transcribe".
    static var started: [ReceivedFile] {
        names.filter { variant != .main || $0 != "voicemail.wav" }.map { ReceivedFile(path: folder + $0) }
    }

    static func messages(now: Date) -> [ChatMessage] {
        let start = now.addingTimeInterval(-3 * 60)
        if variant == .sent {
            return [
                ChatMessage(id: "at1", role: .user, text: "Here are the recordings from today.", date: start,
                            delivery: .delivered, userRowId: 601, attachments: sentItems),
                // The demo composer covers the end of the last row: keep the states above it.
                ChatMessage(id: "at2", role: .assistant, text: "Got them. Tell me which one to summarize.",
                            date: start.addingTimeInterval(20), reply: .complete, promptId: "at1"),
            ]
        }
        return [
            ChatMessage(id: "at1", role: .user, text: "Send me the recordings from today.", date: start,
                        delivery: .delivered, userRowId: 601),
            ChatMessage(id: "at2", role: .assistant, text: (["Here they are."] + names.map { "MEDIA:" + folder + $0 })
                .joined(separator: "\n"), date: start.addingTimeInterval(20), reply: .complete, promptId: "at1"),
            // The demo composer covers the end of the last row (also on main): keep the states above it.
            ChatMessage(id: "at3", role: .user, text: "Thanks", date: start.addingTimeInterval(40),
                        delivery: .delivered, userRowId: 603),
        ]
    }

    static func owns(_ path: String) -> Bool { path.hasPrefix(folder) }

    /// A soft tone of the length of the name. `radio.ogg` is bytes that iOS cannot read.
    static func download(path: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "demo-\(UUID().uuidString)")
        let name = (path as NSString).lastPathComponent
        if name == "radio.ogg" {
            try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: url)
            return url
        }
        let seconds: Double = switch name {
        case "interview.wav": 12 * 60 + 40
        case "lecture.wav": 48 * 60
        case "standup.wav": 74
        default: 9
        }
        try tone(seconds: seconds, to: url)
        return url
    }

    private static func tone(seconds: Double, to url: URL) throws {
        let rate = 8_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16,
                                   interleaved: false)
        let chunk = AVAudioFrameCount(rate * 10)
        var written = 0.0
        while written < seconds {
            let frames = AVAudioFrameCount(min(Double(chunk), (seconds - written) * rate))
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let samples = buffer.int16ChannelData![0]
            for index in 0..<Int(frames) {
                let time = written + Double(index) / rate
                let level = 0.3 * (0.5 + 0.5 * sin(2 * .pi * 0.4 * time))
                samples[index] = Int16(sin(2 * .pi * 220 * time) * level * 32_000)
            }
            try file.write(from: buffer)
            written += Double(frames) / rate
        }
    }

    /// The fake engine: the name picks the result.
    static let transcribe: ReceivedAudioTranscripts.Transcribe = { url, progress in
        let name = url.lastPathComponent
        if name == "interview.wav" {
            progress(0.42)
            try await Task.sleep(for: .seconds(3600))
        }
        switch name {
        case "standup.wav":
            return "Morning standup. The release moves to Thursday. Maria owns the App Store notes, and Sam checks "
                + "the crash report before noon. Next sync is Monday at 9."
        case "wind.wav": return ""
        case "lecture.wav": throw AudioFileTranscriptionError.failed
        default: throw AudioFileTranscriptionError.noPermission
        }
    }

    /// Starts the runs when each audio bubble is ready. A start before that does nothing.
    @MainActor
    static func start(_ transcripts: ReceivedAudioTranscripts) {
        Task { @MainActor in
            for _ in 0..<30 {
                for file in started where transcripts.state(for: file) == .none { transcripts.start(file) }
                // Issue #87: the sent files, but not the first one.
                if variant == .sent {
                    for item in sentItems.dropFirst() where transcripts.state(for: item) == .none { transcripts.start(item) }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
#endif
