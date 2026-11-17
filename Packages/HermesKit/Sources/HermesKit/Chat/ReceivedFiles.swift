import CryptoKit
import Foundation

/// The download state of one received file (issue #12 design notes, "States").
public enum ReceivedFileState: Sendable, Equatable {
    /// Not on the phone. Images and audio load when their bubble shows. Other files load on tap.
    case idle
    /// The progress ring. The fraction is `nil` until the size is known.
    case downloading(Double?)
    /// The file is on the phone. Quick Look, "Save to Files" and "Share" use it.
    case ready(URL)
    /// Larger than `ReceivedFileLoader.confirmBytes`: alert "Download 120 MB?".
    case needsConfirmation(byteCount: Int)
    /// 403 or 404: `exclamationmark.triangle`, "File not available".
    case notAvailable
    /// No Hermes link: "Connect to download". A tap tries again.
    case offline
    /// Another error. A tap tries again.
    case failed

    public var fileURL: URL? {
        if case .ready(let url) = self { return url }
        return nil
    }
}

/// Downloads the files of `MEDIA:` tags on demand and keeps them in the caches folder (issue #12).
///
/// - One download per path at a time. A file on disk is ready with no network call, also after a relaunch.
/// - A file over 50 MB downloads only after the owner confirms.
/// - Audio gets its length and levels once, for the #10 audio bubble. Ogg Opus is decoded to WAV (issue #42).
/// - Never logs a path, a name or the bytes.
@MainActor
public final class ReceivedFileLoader {
    /// The design notes limit for a download with no confirm.
    public static let confirmBytes = 50 * 1024 * 1024

    public typealias Download = @Sendable (_ path: String, _ storedSessionId: String?, _ maxBytes: Int?,
                                           _ progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    public typealias PrepareAudio = @Sendable (URL) -> VoiceReplyAudio?

    /// The folder of the downloaded files: Caches/HermesConnect/ReceivedFiles. The system can clear it.
    public nonisolated static func defaultFolder() -> URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "HermesConnect/ReceivedFiles", directoryHint: .isDirectory)
    }

    public let folder: URL
    /// The screen redraws the bubbles of a file when its state changes.
    public var onChange: ((ReceivedFile) -> Void)?
    private let download: Download?
    private let prepareAudio: PrepareAudio
    /// The stored id of the chat. `ChatViewModel` sets it, because a new chat gets its id later.
    public var storedSessionId: () -> String?
    private var states: [String: ReceivedFileState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var audio: [String: VoiceReplyAudio] = [:]
    private var preparing: Set<String> = []
    /// Audio files that iOS does not play. They stay ready for "Save to Files" and "Share".
    private var unplayable: Set<String> = []
    private let log = HermesLog(category: "files")

    /// `download` is `nil` for a transport with no REST (offline demo): every file is "Connect to download".
    public init(download: Download?, folder: URL = ReceivedFileLoader.defaultFolder(),
                storedSessionId: @escaping () -> String?,
                prepareAudio: @escaping PrepareAudio = { ReceivedFileLoader.playableAudio(at: $0) }) {
        self.download = download
        self.folder = folder
        self.storedSessionId = storedSessionId
        self.prepareAudio = prepareAudio
    }

    /// A loader on a transport. `LiveChatTransport` downloads. Other transports cannot.
    public convenience init(transport: any ChatTransport, folder: URL = ReceivedFileLoader.defaultFolder(),
                            storedSessionId: @escaping () -> String?) {
        var download: Download?
        if let downloader = transport as? any ReceivedFileDownloading {
            download = { path, session, maxBytes, progress in
                try await downloader.downloadReceivedFile(path: path, storedSessionId: session, maxBytes: maxBytes,
                                                          progress: progress)
            }
        }
        self.init(download: download, folder: folder, storedSessionId: storedSessionId)
    }

    /// The state now. A file that an earlier launch saved is `.ready`.
    public func state(for file: ReceivedFile) -> ReceivedFileState {
        let key = key(for: file)
        if let state = states[key] { return state }
        let url = localURL(for: file)
        guard FileManager.default.fileExists(atPath: url.path) else { return .idle }
        states[key] = .ready(url)
        return .ready(url)
    }

    /// The size of a ready file, for the cell and VoiceOver.
    public func byteCount(for file: ReceivedFile) -> Int? {
        guard let url = state(for: file).fileURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return size
    }

    /// The #10 bubble audio of a ready audio file. `nil` until it is prepared, or when it does not play.
    public func audio(for file: ReceivedFile) -> SpokenReply {
        let key = key(for: file)
        switch state(for: file) {
        case .idle, .downloading: return .preparing
        case .needsConfirmation, .notAvailable, .offline, .failed: return .failed
        case .ready(let url):
            if let ready = audio[key] { return .ready(ready) }
            guard !unplayable.contains(key) else { return .failed }
            guard !preparing.contains(key) else { return .preparing }
            preparing.insert(key)
            let prepare = prepareAudio
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = prepare(url)
                await self?.audioPrepared(result, key: key, file: file)
            }
            return .preparing
        }
    }

    private func audioPrepared(_ result: VoiceReplyAudio?, key: String, file: ReceivedFile) {
        preparing.remove(key)
        if let result { audio[key] = result } else { unplayable.insert(key) }
        onChange?(file)
    }

    /// Starts the download. `confirmed`: the owner accepted a file over 50 MB.
    /// A ready file or a running download does nothing.
    @discardableResult
    public func load(_ file: ReceivedFile, confirmed: Bool = false) -> Task<Void, Never>? {
        let key = key(for: file)
        switch state(for: file) {
        case .ready, .downloading: return nil
        case .needsConfirmation where !confirmed: return nil
        default: break
        }
        guard let download else {
            set(.offline, for: file)
            return nil
        }
        set(.downloading(nil), for: file)
        let session = storedSessionId()
        let target = localURL(for: file)
        let maxBytes = confirmed ? nil : Self.confirmBytes
        let task = Task { [weak self] in
            let state: ReceivedFileState
            do {
                let temporary = try await download(file.path, session, maxBytes) { [weak self] fraction in
                    Task { @MainActor in self?.progress(fraction, for: file) }
                }
                try Self.move(temporary, to: target)
                state = .ready(target)
            } catch {
                state = Self.state(for: error)
            }
            self?.finish(file, key: key, state: state)
        }
        tasks[key] = task
        return task
    }

    private func progress(_ fraction: Double, for file: ReceivedFile) {
        guard case .downloading = states[key(for: file)] else { return }
        set(.downloading(fraction), for: file)
    }

    private func finish(_ file: ReceivedFile, key: String, state: ReceivedFileState) {
        tasks[key] = nil
        if case .failed = state { log.info("Received file download failed") }
        set(state, for: file)
    }

    private func set(_ state: ReceivedFileState, for file: ReceivedFile) {
        let key = key(for: file)
        guard states[key] != state else { return }
        states[key] = state
        onChange?(file)
    }

    static func state(for error: any Error) -> ReceivedFileState {
        switch error {
        case ReceivedFileError.tooLarge(let bytes): .needsConfirmation(byteCount: bytes)
        case ReceivedFileError.notAvailable, HermesAPIError.notFound: .notAvailable
        case ReceivedFileError.offline, GatewayError.notConnected: .offline
        case let error as URLError where Self.offlineCodes.contains(error.code): .offline
        default: .failed
        }
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost,
    ]

    // MARK: Files

    /// `<folder>/<hash of session and path>/<name>`. The name is the last path component with no separator,
    /// so no server path can name a place outside the folder.
    public func localURL(for file: ReceivedFile) -> URL {
        folder.appending(path: key(for: file), directoryHint: .isDirectory)
            .appending(path: Self.safeName(file.name), directoryHint: .notDirectory)
    }

    private func key(for file: ReceivedFile) -> String {
        let digest = SHA256.hash(data: Data("\(storedSessionId() ?? "")\n\(file.path)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "File" : cleaned
    }

    nonisolated static func move(_ temporary: URL, to target: URL) throws {
        let manager = FileManager.default
        let directory = target.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        try manager.moveItem(at: temporary, to: target)
        #if os(iOS)
        try? (target as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication,
                                                forKey: .fileProtectionKey)
        #endif
    }

    /// The #10 bubble audio of a file: its length and levels. Ogg Opus is decoded to a WAV file next to it.
    public nonisolated static func playableAudio(at url: URL) -> VoiceReplyAudio? {
        var playable = url
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe), OggOpus.isOgg(data) {
            let wav = url.deletingLastPathComponent().appending(path: "playable.wav")
            if !FileManager.default.fileExists(atPath: wav.path) {
                guard let decoded = try? OggOpus.wav(from: data), (try? decoded.write(to: wav)) != nil else { return nil }
            }
            playable = wav
        }
        guard let duration = VoiceReplyFiles.playableDuration(playable) else { return nil }
        return VoiceReplyAudio(fileURL: playable, duration: duration, waveform: VoiceWaveform.bars(contentsOf: playable) ?? [])
    }
}
