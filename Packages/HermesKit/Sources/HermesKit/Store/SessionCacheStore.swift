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
    /// Issue #64: drops the transcript, the draft and the active id of a deleted session.
    /// The list row goes with the next `saveSessions`. The file format does not change.
    func removeSession(sessionId: String)
    /// Issue #39: the transcript keys with messages in the outbox, oldest first. After a relaunch the app
    /// sends them on connect, also for a chat that the owner does not open.
    func outboxSessionIds() -> [String]
    /// Issue #39: marks or clears the outbox of one transcript key.
    func saveOutbox(_ hasQueued: Bool, sessionId: String)
    /// Issue #84: the store of the server that is active now. A chat model keeps it, so a late save of a chat
    /// of the old server never goes to the folder of the new server. A plain store gives itself.
    func pinned() -> any SessionCacheStore
}

extension SessionCacheStore {
    public func removeSession(sessionId: String) {
        saveTranscript([], sessionId: sessionId)
        saveDraft("", sessionId: sessionId)
        if loadActiveSessionId() == sessionId { saveActiveSessionId(nil) }
        saveOutbox(false, sessionId: sessionId)
    }

    /// Stores with no outbox index (older fakes) keep the queued messages in the transcript only.
    public func outboxSessionIds() -> [String] { [] }
    public func saveOutbox(_: Bool, sessionId _: String) {}
    public func pinned() -> any SessionCacheStore { self }
}

public enum SessionCache {
    /// The most messages that the cache keeps per session.
    public static let transcriptLimit = 500
    /// The file format version. Readers accept every version: missing keys get defaults.
    /// Version 2 (issue #10): voice memos, memos that were not delivered, and the audio of voice replies.
    /// Version 3 (issue #11): agent acks and owner tapbacks.
    /// Version 4 (issue #49): the waveform of a voice reply.
    /// Version 5 (issue #12): the photos, files and location cards of sent messages (metadata and local path).
    /// Version 6 (issues #39 and #17): messages in the outbox (`queued`), the outbox index in the state file,
    /// and the quote of a reply. Both are optional keys, so one version covers both.
    /// Version 7 (issue #120): the tool calls of a reply (name, summary, duration). Older files: no tools.
    public static let formatVersion = 7
    /// Issue #36: the transcript key of the new chat that has no server row yet. Its memos stay here,
    /// so a failed memo survives a quit. No stored id starts with `#`.
    public static let newChatId = "#new-chat"

    /// Issue #83: the key that kept the new chat of a server that was not active. It is never in the outbox,
    /// so nothing sends from it. Issue #84: each server has its own folder with its own `newChatId`, so builds
    /// from #84 do not park. The migration moves a parked new chat to the folder of its server.
    public static func parkedNewChatId(server: UUID) -> String {
        "\(newChatId)@\(server.uuidString)"
    }

    /// The messages to keep: the last `limit` ones that have ended, plus every voice memo.
    /// The owner never loses a recording: a memo that was not delivered stays with "Try Again".
    /// Issue #39: the outbox stays too. A message that the outbox sends right now does not: a quit then
    /// must not send it twice.
    public static func cacheable(_ messages: [ChatMessage], limit: Int = transcriptLimit) -> [ChatMessage] {
        Array(messages.filter { isEnded($0) || $0.voice != nil || $0.delivery == .queued }.suffix(limit))
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
    /// "done", "empty", "failed" or "pending" (version 6, a queued memo with no transcript yet).
    /// A memo that was still in "Transcribing…" and is not queued reads as "failed".
    var transcript: String

    init(_ memo: VoiceMemo, queued: Bool = false) {
        path = CachedPath.encode(memo.fileURL)
        duration = memo.duration
        waveform = memo.waveform
        transcript = switch memo.transcript {
        case .done: "done"
        case .empty: "empty"
        case .pending where queued: "pending"
        case .pending, .failed: "failed"
        }
    }

    func memo(text: String, queued: Bool = false) -> VoiceMemo {
        let state: VoiceTranscript = switch transcript {
        case "done" where !text.isEmpty: .done(text)
        case "empty": .empty
        case "pending" where queued: .pending
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
    /// Version 4 (issue #49): the bubble levels, so a relaunch does not decode the file again. Older files: empty.
    var waveform: [Float]

    init(_ spoken: SpokenReply) {
        path = spoken.audio.map { CachedPath.encode($0.fileURL) }
        duration = spoken.audio?.duration ?? 0
        waveform = spoken.audio?.waveform ?? []
    }

    /// A file with no length did not decode (builds before issue #36). It reads as failed, with retry.
    /// Issue #42: an `.ogg` or `.opus` file of an older build does not play on iOS. It reads as failed too.
    var spoken: SpokenReply {
        let ext = path.map { ($0 as NSString).pathExtension.lowercased() }
        guard let path, duration > 0, ext != "ogg", ext != "opus" else { return .failed }
        return .ready(VoiceReplyAudio(fileURL: CachedPath.decode(path), duration: duration, waveform: waveform))
    }

    private enum CodingKeys: String, CodingKey { case path, duration, waveform }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        // A broken waveform drops only the waveform.
        waveform = ((try? container.decodeIfPresent([Float].self, forKey: .waveform)) ?? nil) ?? []
    }
}

/// The quote of a reply (format version 6, issue #17).
struct CachedQuote: Codable, Equatable {
    var messageId: String?
    var author: String
    var time: String
    var excerpt: String

    init(_ quote: ChatQuote) {
        messageId = quote.messageId
        author = quote.author == .user ? "user" : "assistant"
        time = quote.time
        excerpt = quote.excerpt
    }

    /// `nil` for an entry with no excerpt.
    var quote: ChatQuote? {
        guard !excerpt.isEmpty else { return nil }
        return ChatQuote(messageId: messageId, author: author == "user" ? .user : .assistant, time: time,
                         excerpt: excerpt)
    }

    private enum CodingKeys: String, CodingKey { case messageId, author, time, excerpt }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? "assistant"
        time = try container.decodeIfPresent(String.self, forKey: .time) ?? ""
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
    }
}

/// One tool call of a reply (format version 7, issue #120). Only the name, the summary and the duration:
/// never the args or the result.
struct CachedTool: Codable, Equatable {
    var id: String
    var name: String
    var summary: String?
    var duration: TimeInterval?

    init(_ tool: ChatToolCall) {
        id = tool.id
        name = tool.name
        summary = tool.summary
        duration = tool.duration
    }

    var tool: ChatToolCall { ChatToolCall(id: id, name: name, summary: summary, duration: duration) }

    private enum CodingKeys: String, CodingKey { case id, name, summary, duration }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decode(String.self, forKey: .name)
        summary = (try? container.decodeIfPresent(String.self, forKey: .summary)) ?? nil
        duration = (try? container.decodeIfPresent(TimeInterval.self, forKey: .duration)) ?? nil
    }
}

/// One attachment of a sent message (format version 5, issue #12). The bytes stay in their local file.
/// A file that the system cleared shows the gray placeholder (photo) or the cell with no preview (file).
struct CachedAttachment: Codable, Equatable {
    var id: String
    /// "photo", "file", "pdf" or "location".
    var kind: String
    var name: String
    var byteCount: Int
    var path: String
    var mimeType: String
    var pixelWidth: Int?
    var pixelHeight: Int?
    var pageCount: Int?
    var refText: String?

    init(_ item: ChatAttachment) {
        id = item.id
        kind = switch item.kind {
        case .photo: "photo"
        case .file: "file"
        case .pdf: "pdf"
        case .location: "location"
        }
        name = item.name
        byteCount = item.byteCount
        path = CachedPath.encode(item.fileURL)
        mimeType = item.mimeType
        pixelWidth = item.pixelWidth
        pixelHeight = item.pixelHeight
        pageCount = item.pageCount
        refText = item.refText
    }

    /// A cached item was sent: it shows with no upload state.
    var attachment: ChatAttachment {
        let kind: ChatAttachment.Kind = switch self.kind {
        case "photo": .photo
        case "pdf": .pdf
        case "location": .location
        default: .file
        }
        return ChatAttachment(id: id, kind: kind, name: name, byteCount: byteCount, fileURL: CachedPath.decode(path),
                              mimeType: mimeType, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                              pageCount: pageCount, upload: .attached, refText: refText)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, byteCount, path, mimeType, pixelWidth, pixelHeight, pageCount, refText
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "file"
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "File"
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? "/dev/null"
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
        pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount)
        refText = try container.decodeIfPresent(String.self, forKey: .refText)
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
    /// Version 3: the raw value of `AgentAck`. Older files have no key.
    var ack: String?
    /// Version 3: the raw value of `Tapback`. Older files have no key.
    var tapback: String?
    /// Version 5 (issue #12): the attachments of a sent message. Older files have no key: none.
    var attachments: [CachedAttachment]
    /// Version 6 (issue #17): the quote of a reply. Older files have no key: no quote.
    var quote: CachedQuote?
    /// Version 6 (issue #39): the message waits in the outbox. `notDelivered` is also `true`, so an older
    /// build shows "Not Delivered" and never sends it twice. Older files have no key: not queued.
    var queued: Bool
    /// Version 7 (issue #120): the tool calls of a reply, in call order. Older files have no key: none.
    var tools: [CachedTool]

    init(_ message: ChatMessage) {
        id = message.id
        role = message.role == .user ? "user" : "assistant"
        text = message.text
        date = message.date
        userRowId = message.userRowId
        promptId = message.promptId
        interrupted = message.reply == .interrupted
        notDelivered = message.role == .user && message.delivery != .delivered
        let isQueued = message.role == .user && message.delivery == .queued
        queued = isQueued
        voice = message.voice.map { CachedVoice($0, queued: isQueued) }
        speech = message.spokenReply.map(CachedSpeech.init)
        ack = message.agentAck?.rawValue
        tapback = message.tapback?.rawValue
        attachments = message.attachments.map(CachedAttachment.init)
        quote = message.quote.map(CachedQuote.init)
        tools = message.role == .assistant ? message.tools.map(CachedTool.init) : []
    }

    var message: ChatMessage {
        let tapback = tapback.flatMap(Tapback.init(rawValue:))
        if role == "user" {
            let memo = voice?.memo(text: text, queued: queued)
            // The eyes of a turn that ran at the last save: the turn state is not known now.
            let ack = ack.flatMap(AgentAck.init(rawValue:)).flatMap { $0 == .seen ? nil : $0 }
            let delivery: ChatMessage.Delivery = queued ? .queued : notDelivered ? .failed : .delivered
            // A queued message uploads its attachments again with the send.
            let items = attachments.map(\.attachment).map { item in
                var item = item
                if queued, item.kind != .location { item.upload = .pending }
                return item
            }
            return ChatMessage(id: id, role: .user, text: memo.map { $0.transcript.text ?? "" } ?? text, date: date,
                               delivery: delivery, userRowId: userRowId, voice: memo,
                               attachments: items, agentAck: ack, tapback: tapback,
                               quote: quote?.quote)
        }
        return ChatMessage(id: id, role: .assistant, text: text, date: date,
                           reply: interrupted ? .interrupted : .complete, promptId: promptId,
                           spokenReply: speech?.spoken, tapback: tapback, tools: tools.map(\.tool))
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, date, userRowId, promptId, interrupted, notDelivered, voice, speech, ack, tapback
        case attachments, quote, queued, tools
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(userRowId, forKey: .userRowId)
        try container.encodeIfPresent(promptId, forKey: .promptId)
        try container.encode(interrupted, forKey: .interrupted)
        try container.encode(notDelivered, forKey: .notDelivered)
        try container.encodeIfPresent(voice, forKey: .voice)
        try container.encodeIfPresent(speech, forKey: .speech)
        try container.encodeIfPresent(ack, forKey: .ack)
        try container.encodeIfPresent(tapback, forKey: .tapback)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(quote, forKey: .quote)
        try container.encode(queued, forKey: .queued)
        // Version 7: a message with no tools writes no key, so the file stays small.
        if !tools.isEmpty { try container.encode(tools, forKey: .tools) }
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
        // A broken or unknown reaction drops only the reaction.
        ack = (try? container.decodeIfPresent(String.self, forKey: .ack)) ?? nil
        tapback = (try? container.decodeIfPresent(String.self, forKey: .tapback)) ?? nil
        // Version 5. A broken list drops only the attachments: the message shows its text.
        attachments = ((try? container.decodeIfPresent([CachedAttachment].self, forKey: .attachments)) ?? nil) ?? []
        // Version 6. A broken quote drops only the quote: the message shows its reply text.
        quote = (try? container.decodeIfPresent(CachedQuote.self, forKey: .quote)) ?? nil
        // Version 6. A broken value reads as not queued: "Not Delivered" with "Try Again", never a second send.
        queued = ((try? container.decodeIfPresent(Bool.self, forKey: .queued)) ?? nil) ?? false
        // Version 7. A broken list drops only the tools: the reply shows with no tool row.
        tools = ((try? container.decodeIfPresent([CachedTool].self, forKey: .tools)) ?? nil) ?? []
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

/// The small state file: the active session, the drafts and the outbox index.
struct CacheState: Codable, Equatable {
    var activeSessionId: String?
    var drafts: [String: String]
    /// Version 6 (issue #39): the transcript keys with queued messages, oldest first. Older files: none.
    var outbox: [String]

    init(activeSessionId: String? = nil, drafts: [String: String] = [:], outbox: [String] = []) {
        self.activeSessionId = activeSessionId
        self.drafts = drafts
        self.outbox = outbox
    }

    private enum CodingKeys: String, CodingKey { case activeSessionId, drafts, outbox }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeSessionId = try container.decodeIfPresent(String.self, forKey: .activeSessionId)
        drafts = try container.decodeIfPresent([String: String].self, forKey: .drafts) ?? [:]
        outbox = ((try? container.decodeIfPresent([String].self, forKey: .outbox)) ?? nil) ?? []
    }
}

/// The cache as JSON files in Application Support (`HermesConnect/Cache/`).
///
/// - `ProtectedStorage` rules (issue #18): files use `completeUntilFirstUserAuthentication`, so background
///   catch-up can read them after the first unlock, and the folder is excluded from backup.
/// - The first write of each store instance applies the rules again, also to files of older builds.
/// - One lock orders the reads and writes. A transcript file is at most 500 messages.
public final class FileSessionCacheStore: SessionCacheStore, @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    /// True after `ProtectedStorage.prepare` ran for this instance.
    private var prepared = false

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

    public func removeSession(sessionId: String) {
        lock.withLock {
            try? FileManager.default.removeItem(at: transcriptURL(sessionId: sessionId))
            var state = state()
            let active = state.activeSessionId == sessionId ? nil : state.activeSessionId
            guard state.drafts[sessionId] != nil || active != state.activeSessionId || state.outbox.contains(sessionId)
            else { return }
            state.drafts[sessionId] = nil
            state.activeSessionId = active
            state.outbox.removeAll { $0 == sessionId }
            write(state, to: stateURL)
        }
    }

    public func outboxSessionIds() -> [String] {
        lock.withLock { state().outbox }
    }

    public func saveOutbox(_ hasQueued: Bool, sessionId: String) {
        lock.withLock {
            var state = state()
            guard state.outbox.contains(sessionId) != hasQueued else { return }
            if hasQueued { state.outbox.append(sessionId) } else { state.outbox.removeAll { $0 == sessionId } }
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
            try encoder.encode(CacheFile(body)).write(to: url, options: ProtectedStorage.writeOptions)
        } catch {
            // The cache is optional. The next save tries again.
        }
    }

    /// Called with the lock held.
    private func prepareDirectory(_ url: URL) throws {
        if !prepared {
            try ProtectedStorage.prepare(directory: directory)
            prepared = true
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// A `SessionCacheStore` in memory, for tests, previews and the DEBUG demo.
public final class InMemorySessionCacheStore: SessionCacheStore, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [SessionListItem]
    private var transcripts: [String: [ChatMessage]] = [:]
    private var drafts: [String: String] = [:]
    private var activeId: String?
    private var outbox: [String] = []

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

    public func removeSession(sessionId: String) {
        lock.withLock {
            transcripts[sessionId] = nil
            drafts[sessionId] = nil
            if activeId == sessionId { activeId = nil }
            outbox.removeAll { $0 == sessionId }
        }
    }

    public func outboxSessionIds() -> [String] { lock.withLock { outbox } }

    public func saveOutbox(_ hasQueued: Bool, sessionId: String) {
        lock.withLock {
            guard outbox.contains(sessionId) != hasQueued else { return }
            if hasQueued { outbox.append(sessionId) } else { outbox.removeAll { $0 == sessionId } }
        }
    }

    /// The ids that have a transcript (tests).
    public var transcriptIds: Set<String> { lock.withLock { Set(transcripts.keys) } }
}
