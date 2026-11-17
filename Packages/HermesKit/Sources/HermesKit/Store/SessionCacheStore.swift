import Foundation

/// The local cache of the session list, the transcripts, the drafts and the active session (issue #7).
/// The cache only makes the screens fast: the server stays the source of truth. A file that does not
/// decode is read as empty, never as an error.
public protocol SessionCacheStore: Sendable {
    func loadSessions() -> [SessionListItem]
    func saveSessions(_ sessions: [SessionListItem])
    /// The cached messages of one session, oldest first.
    func loadTranscript(sessionId: String) -> [ChatMessage]
    /// Keeps the last `SessionCache.transcriptLimit` messages that have ended (no send or stream in progress).
    func saveTranscript(_ messages: [ChatMessage], sessionId: String)
    func loadDraft(sessionId: String) -> String
    /// An empty draft removes the draft.
    func saveDraft(_ text: String, sessionId: String)
    /// The stored id of the session that the owner opened last.
    func loadActiveSessionId() -> String?
    func saveActiveSessionId(_ id: String?)
}

public enum SessionCache {
    /// The most messages that the cache keeps per session.
    public static let transcriptLimit = 500
    /// The file format version. Readers accept every version: missing keys get defaults.
    /// Version 2 (issue #10): voice memos, memos that were not delivered, and the audio of voice replies.
    public static let formatVersion = 2

    /// The messages to keep: the last `limit` ones that have ended, plus every voice memo.
    /// The owner never loses a recording: a memo that was not delivered stays with "Try Again".
    public static func cacheable(_ messages: [ChatMessage], limit: Int = transcriptLimit) -> [ChatMessage] {
        Array(messages.filter { isEnded($0) || $0.voice != nil }.suffix(limit))
    }

    /// A delivered prompt, or a reply that ended. The server transcript has these messages.
    public static func isEnded(_ message: ChatMessage) -> Bool {
        switch message.role {
        case .user: message.delivery == .delivered
        case .assistant: message.reply == .complete || message.reply == .interrupted
        }
    }
}

/// A local file path in the cache. A path in the app folder is stored relative to it, because iOS can
/// move the app folder on an update.
enum CachedPath {
    static func encode(_ url: URL, home: String = NSHomeDirectory()) -> String {
        let path = url.standardizedFileURL.path
        let root = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(root) ? "~/" + path.dropFirst(root.count) : path
    }

    static func decode(_ path: String, home: String = NSHomeDirectory()) -> URL {
        guard path.hasPrefix("~/") else { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: home).appending(path: String(path.dropFirst(2)))
    }
}

/// A cached voice memo (format version 2).
struct CachedVoice: Codable, Equatable {
    var path: String
    var duration: TimeInterval
    var waveform: [Float]
    /// "done", "empty" or "failed". A memo that was still in "Transcribing…" reads as "failed".
    var transcript: String

    init(_ memo: VoiceMemo) {
        path = CachedPath.encode(memo.fileURL)
        duration = memo.duration
        waveform = memo.waveform
        transcript = switch memo.transcript {
        case .done: "done"
        case .empty: "empty"
        case .pending, .failed: "failed"
        }
    }

    func memo(text: String) -> VoiceMemo {
        let state: VoiceTranscript = switch transcript {
        case "done" where !text.isEmpty: .done(text)
        case "empty": .empty
        default: .failed
        }
        return VoiceMemo(fileURL: CachedPath.decode(path), duration: duration, waveform: waveform, transcript: state)
    }

    private enum CodingKeys: String, CodingKey { case path, duration, waveform, transcript }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        waveform = try container.decodeIfPresent([Float].self, forKey: .waveform) ?? []
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript) ?? "done"
    }
}

/// The cached audio of a voice reply (format version 2). A reply that was still in "Preparing audio…"
/// reads as failed, so the owner can tap to retry.
struct CachedSpeech: Codable, Equatable {
    var path: String?
    var duration: TimeInterval

    init(_ spoken: SpokenReply) {
        path = spoken.audio.map { CachedPath.encode($0.fileURL) }
        duration = spoken.audio?.duration ?? 0
    }

    var spoken: SpokenReply {
        guard let path else { return .failed }
        return .ready(VoiceReplyAudio(fileURL: CachedPath.decode(path), duration: duration))
    }

    private enum CodingKeys: String, CodingKey { case path, duration }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
    }
}

/// One cached message. The file format: change it only with tolerant decoding.
struct CachedMessage: Codable, Equatable {
    var id: String
    var role: String
    var text: String
    var date: Date
    var userRowId: Int?
    var promptId: String?
    var interrupted: Bool
    /// `true` for a voice memo that was not delivered. Version 1 files have no key: delivered.
    var notDelivered: Bool
    var voice: CachedVoice?
    var speech: CachedSpeech?

    init(_ message: ChatMessage) {
        id = message.id
        role = message.role == .user ? "user" : "assistant"
        text = message.text
        date = message.date
        userRowId = message.userRowId
        promptId = message.promptId
        interrupted = message.reply == .interrupted
        notDelivered = message.role == .user && message.delivery != .delivered
        voice = message.voice.map(CachedVoice.init)
        speech = message.spokenReply.map(CachedSpeech.init)
    }

    var message: ChatMessage {
        if role == "user" {
            let memo = voice?.memo(text: text)
            return ChatMessage(id: id, role: .user, text: memo.map { $0.transcript.text ?? "" } ?? text, date: date,
                               delivery: notDelivered ? .failed : .delivered, userRowId: userRowId, voice: memo)
        }
        return ChatMessage(id: id, role: .assistant, text: text, date: date,
                           reply: interrupted ? .interrupted : .complete, promptId: promptId,
                           spokenReply: speech?.spoken)
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, date, userRowId, promptId, interrupted, notDelivered, voice, speech
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date(timeIntervalSince1970: 0)
        userRowId = try container.decodeIfPresent(Int.self, forKey: .userRowId)
        promptId = try container.decodeIfPresent(String.self, forKey: .promptId)
        interrupted = try container.decodeIfPresent(Bool.self, forKey: .interrupted) ?? false
        notDelivered = try container.decodeIfPresent(Bool.self, forKey: .notDelivered) ?? false
        // A broken memo or speech entry drops only that part, never the message.
        voice = (try? container.decodeIfPresent(CachedVoice.self, forKey: .voice)) ?? nil
        speech = (try? container.decodeIfPresent(CachedSpeech.self, forKey: .speech)) ?? nil
    }
}

/// The JSON envelope of each cache file. `version` tells a later build which format wrote the file.
struct CacheFile<Body: Codable>: Codable {
    var version: Int
    var body: Body

    init(_ body: Body) {
        version = SessionCache.formatVersion
        self.body = body
    }
}

/// The small state file: the active session and the drafts.
struct CacheState: Codable, Equatable {
    var activeSessionId: String?
    var drafts: [String: String]

    init(activeSessionId: String? = nil, drafts: [String: String] = [:]) {
        self.activeSessionId = activeSessionId
        self.drafts = drafts
    }

    private enum CodingKeys: String, CodingKey { case activeSessionId, drafts }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeSessionId = try container.decodeIfPresent(String.self, forKey: .activeSessionId)
        drafts = try container.decodeIfPresent([String: String].self, forKey: .drafts) ?? [:]
    }
}

/// The cache as JSON files in Application Support (`HermesConnect/Cache/`).
///
/// - Files use `completeUntilFirstUserAuthentication`, so background catch-up can read them after the first unlock.
/// - The folder is excluded from backup: the server holds the real transcript.
/// - One lock orders the reads and writes. A transcript file is at most 500 messages.
public final class FileSessionCacheStore: SessionCacheStore, @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    /// The default location in Application Support.
    public static func applicationSupport() throws -> FileSessionCacheStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return FileSessionCacheStore(directory: base.appending(path: "HermesConnect/Cache", directoryHint: .isDirectory))
    }

    var sessionsURL: URL { directory.appending(path: "sessions.json") }
    var stateURL: URL { directory.appending(path: "state.json") }

    /// The transcript file of one session. The id is hex-encoded, so no id can name a path outside the folder.
    func transcriptURL(sessionId: String) -> URL {
        let name = sessionId.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "transcripts/\(name).json")
    }

    // MARK: SessionCacheStore

    public func loadSessions() -> [SessionListItem] {
        lock.withLock { read([SessionListItem].self, from: sessionsURL) ?? [] }
    }

    public func saveSessions(_ sessions: [SessionListItem]) {
        lock.withLock { write(sessions, to: sessionsURL) }
    }

    public func loadTranscript(sessionId: String) -> [ChatMessage] {
        lock.withLock { read([CachedMessage].self, from: transcriptURL(sessionId: sessionId)) ?? [] }.map(\.message)
    }

    public func saveTranscript(_ messages: [ChatMessage], sessionId: String) {
        let cached = SessionCache.cacheable(messages).map(CachedMessage.init)
        lock.withLock { write(cached, to: transcriptURL(sessionId: sessionId)) }
    }

    public func loadDraft(sessionId: String) -> String {
        lock.withLock { state().drafts[sessionId] ?? "" }
    }

    public func saveDraft(_ text: String, sessionId: String) {
        lock.withLock {
            var state = state()
            let value = text.isEmpty ? nil : text
            guard state.drafts[sessionId] != value else { return }
            state.drafts[sessionId] = value
            write(state, to: stateURL)
        }
    }

    public func loadActiveSessionId() -> String? {
        lock.withLock { state().activeSessionId }
    }

    public func saveActiveSessionId(_ id: String?) {
        lock.withLock {
            var state = state()
            guard state.activeSessionId != id else { return }
            state.activeSessionId = id
            write(state, to: stateURL)
        }
    }

    // MARK: Files

    private func state() -> CacheState {
        read(CacheState.self, from: stateURL) ?? CacheState()
    }

    private func read<Body: Codable>(_: Body.Type, from url: URL) -> Body? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(CacheFile<Body>.self, from: data).body
    }

    private func write<Body: Codable>(_ body: Body, to url: URL) {
        do {
            try prepareDirectory(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try encoder.encode(CacheFile(body)).write(to: url, options: options)
        } catch {
            // The cache is optional. The next save tries again.
        }
    }

    private func prepareDirectory(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }
}

/// A `SessionCacheStore` in memory, for tests, previews and the DEBUG demo.
public final class InMemorySessionCacheStore: SessionCacheStore, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [SessionListItem]
    private var transcripts: [String: [ChatMessage]] = [:]
    private var drafts: [String: String] = [:]
    private var activeId: String?

    public init(sessions: [SessionListItem] = [], transcripts: [String: [ChatMessage]] = [:],
                activeSessionId: String? = nil) {
        self.sessions = sessions
        self.transcripts = transcripts.mapValues { SessionCache.cacheable($0) }
        self.activeId = activeSessionId
    }

    public func loadSessions() -> [SessionListItem] { lock.withLock { sessions } }
    public func saveSessions(_ sessions: [SessionListItem]) { lock.withLock { self.sessions = sessions } }

    public func loadTranscript(sessionId: String) -> [ChatMessage] {
        lock.withLock { transcripts[sessionId] ?? [] }
    }

    public func saveTranscript(_ messages: [ChatMessage], sessionId: String) {
        let kept = SessionCache.cacheable(messages)
        lock.withLock { transcripts[sessionId] = kept }
    }

    public func loadDraft(sessionId: String) -> String { lock.withLock { drafts[sessionId] ?? "" } }

    public func saveDraft(_ text: String, sessionId: String) {
        lock.withLock { drafts[sessionId] = text.isEmpty ? nil : text }
    }

    public func loadActiveSessionId() -> String? { lock.withLock { activeId } }
    public func saveActiveSessionId(_ id: String?) { lock.withLock { activeId = id } }
}
