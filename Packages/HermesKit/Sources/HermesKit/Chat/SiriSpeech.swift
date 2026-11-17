import Foundation

/// Issue #45: the text that Siri speaks for one reply.
public struct SiriSpokenText: Sendable, Equatable {
    /// Plain text with no Markdown. It ends with "The rest is in the app." when the reply was cut.
    public var text: String
    /// `false` when the reply was cut at the length limit. A cut reply stays unread.
    public var isComplete: Bool

    public init(text: String, isComplete: Bool) {
        self.text = text
        self.isComplete = isComplete
    }
}

/// Issue #45: one function for "Ask Hermes" and "Read Hermes". The spoken text never goes to a log.
///
/// | Content | Siri says |
/// |---|---|
/// | Markdown | Plain text. A bare URL is "a link". |
/// | Table | "There is a table in the app." |
/// | Code block | "There is code in the app." |
/// | Photo, file | "Hermes sent a photo." or "Hermes sent a file." |
/// | Over 400 characters | Cut at a sentence end, then "The rest is in the app." |
public enum SiriSpeech {
    public static let limit = 400
    public static let restInApp = "The rest is in the app."
    public static let table = "There is a table in the app."
    public static let code = "There is code in the app."
    public static let link = "a link"
    public static let photo = "Hermes sent a photo."
    public static let file = "Hermes sent a file."
    public static let location = "Hermes sent a location."

    public static func spokenText(_ message: ChatMessage) -> SiriSpokenText {
        spokenText(message.text, attachments: message.attachments)
    }

    public static func spokenText(_ markdown: String, attachments: [ChatAttachment] = []) -> SiriSpokenText {
        var sentences = attachments.map { sentence(for: $0.kind) }
        var body: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("MEDIA:") {
                sentences.append(isImagePath(trimmed.dropFirst(6)) ? photo : file)
            } else {
                body.append(line)
            }
        }
        for block in ChatMarkdown.blocks(body.joined(separator: "\n")) {
            for sentence in self.sentences(for: block) where sentence != sentences.last || !isPlaceholder(sentence) {
                sentences.append(sentence)
            }
        }
        return cut(sentences.filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// Cuts `text` to `limit` characters or fewer at the last sentence end, then adds "The rest is in the app."
    /// A text with no sentence end in the limit is cut at the last space.
    public static func cut(_ text: String, limit: Int = limit) -> SiriSpokenText {
        guard text.count > limit else { return SiriSpokenText(text: text, isComplete: true) }
        let chars = Array(text)
        var end: Int?
        for index in stride(from: limit - 1, through: 0, by: -1) where ".!?".contains(chars[index]) {
            if index + 1 == chars.count || chars[index + 1].isWhitespace {
                end = index + 1
                break
            }
        }
        var head: String
        if let end {
            head = String(chars[..<end])
        } else {
            let prefix = chars[..<limit]
            let space = prefix.lastIndex(where: \.isWhitespace) ?? limit
            head = String(chars[..<space]).trimmingCharacters(in: .whitespaces)
            head = head.isEmpty ? String(prefix) + "…" : head + "…"
        }
        return SiriSpokenText(text: head + " " + restInApp, isComplete: false)
    }

    private static func sentence(for kind: ChatAttachment.Kind) -> String {
        switch kind {
        case .photo: photo
        case .file, .pdf: file
        case .location: location
        }
    }

    private static func isImagePath(_ path: Substring) -> Bool {
        let ext = (path.trimmingCharacters(in: .whitespaces) as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(ext)
    }

    private static func isPlaceholder(_ sentence: String) -> Bool { sentence == table || sentence == code }

    private static func sentences(for block: ChatBlock) -> [String] {
        switch block {
        case .paragraph(let runs), .heading(_, let runs), .listItem(_, _, let runs):
            return [ended(plain(runs))]
        case .quote(let blocks):
            return blocks.flatMap(sentences(for:))
        case .code:
            return [code]
        case .table:
            return [table]
        case .rule:
            return []
        }
    }

    /// The run text with no marks. A link whose label is its URL is "a link". A bare URL in the text too.
    private static func plain(_ runs: [ChatTextRun]) -> String {
        let text = runs.map { run -> String in
            if let url = run.link, run.text == url.absoluteString || isBareURL(run.text) { return link }
            return run.text
        }.joined()
        let words = text.split(whereSeparator: \.isWhitespace).map { word -> String in
            isBareURL(String(word)) ? trailingPunctuation(of: word, after: link) : String(word)
        }
        return words.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isBareURL(_ word: String) -> Bool {
        let lower = word.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.")
    }

    /// "https://x.com." is "a link.": the sentence end stays.
    private static func trailingPunctuation(of word: Substring, after replacement: String) -> String {
        let tail = word.reversed().prefix { ".,;:!?)".contains($0) }
        return replacement + String(tail.reversed())
    }

    /// A line with no end mark gets a period, so Siri pauses after a heading or a list item.
    private static func ended(_ text: String) -> String {
        guard let last = text.last else { return "" }
        return last.isLetter || last.isNumber ? text + "." : text
    }
}

/// Issue #45: what Siri says. The spoken reply text never goes to a log.
public enum SiriDialog {
    public static let notSetUp = "Set up Hermes in the app first."
    public static let unlock = "Unlock your iPhone to use Hermes."
    public static let unreachable = "I can't reach Hermes right now."
    public static let noReplies = "There are no replies from Hermes yet."
    public static let stillWorking = "Hermes is still working. I'll notify you when the reply comes."
    public static let replyFailed = "Hermes could not answer. Open the app to try again."

    /// "No new replies. The last one, from <session title>:"
    public static func lastReply(title: String) -> String { "No new replies. The last one, from \(title):" }

    /// The dialog that stops a run before any network call, or `nil` when the run can go on.
    /// App Lock does not count: an unlocked iPhone runs Siri with no Face ID (UX notes #45).
    public static func blocking(isSetUp: Bool, isDeviceLocked: Bool, usesSiriWhenLocked: Bool) -> String? {
        if !isSetUp { return notSetUp }
        if isDeviceLocked, !usesSiriWhenLocked { return unlock }
        return nil
    }
}

/// Settings > Notifications > "Use Siri When Locked" (owner decision 2026-11-17).
public enum SiriSettings {
    /// `UserDefaults` key. No value means off.
    public static let useWhenLockedKey = "siri.useWhenLocked"

    public static func usesSiriWhenLocked(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: useWhenLockedKey) as? Bool ?? false
    }
}

/// The timing of the Siri runs. App Intents have about 30 s (Apple: `IntentCancellationReason.timeout`).
public enum SiriTiming {
    /// The "Read Hermes" sync. After it, Siri reads the cache.
    public static let readSync: Duration = .seconds(5)
    /// "Ask Hermes": the connect, the send and the reply. Then Siri says "Hermes is still working."
    public static let askReply: Duration = .seconds(25)
    /// "Ask Hermes" after a complete reply: the list refresh that marks the session read.
    public static let markRead: Duration = .seconds(2)
    /// A slow reply: how long the app waits for it in the background before the notification.
    public static let followUp: Duration = .seconds(25)

    /// Runs `work` and returns `true` when it ends before `timeout`. At the timeout it returns `false`,
    /// and `work` goes on.
    @MainActor
    public static func finishes(within timeout: Duration, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        let gate = RaceGate()
        return await withCheckedContinuation { continuation in
            gate.continuation = continuation
            Task { @MainActor in
                await work()
                gate.resume(true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.resume(false)
            }
        }
    }

    /// The time left until `deadline`, never below zero.
    public static func remaining(until deadline: ContinuousClock.Instant) -> Duration {
        max(.zero, deadline - ContinuousClock.now)
    }
}

@MainActor private final class RaceGate {
    var continuation: CheckedContinuation<Bool, Never>?

    func resume(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// Issue #45: "Read Hermes". Reads 3 or fewer unread replies, newest first, each after its session title.
@MainActor
public enum SiriRead {
    public static let maxReplies = 3

    /// What Siri says, and the sessions that become read.
    public struct Result: Sendable, Equatable {
        public var dialog: String
        /// The sessions whose reply Siri read in full. A cut reply stays unread.
        public var readSessionIds: [String]
    }

    /// `rows` are in list order (most recent first). `lastReply` gives the newest reply of a session.
    /// `reachable` is `false` when the sync could not reach the server.
    public static func result(rows: [SessionListItem], reachable: Bool,
                              lastReply: (String) -> ChatMessage?) -> Result {
        let unread = rows.filter(\.isUnread).compactMap { row in lastReply(row.id).map { (row, $0) } }
            .prefix(maxReplies)
        if !unread.isEmpty {
            var parts: [String] = []
            var read: [String] = []
            for (row, reply) in unread {
                let spoken = SiriSpeech.spokenText(reply)
                parts.append("\(row.displayTitle): \(spoken.text)")
                if spoken.isComplete { read.append(row.id) }
            }
            return Result(dialog: parts.joined(separator: "\n"), readSessionIds: read)
        }
        for row in rows {
            guard let reply = lastReply(row.id) else { continue }
            let spoken = SiriSpeech.spokenText(reply)
            return Result(dialog: SiriDialog.lastReply(title: row.displayTitle) + " " + spoken.text, readSessionIds: [])
        }
        return Result(dialog: reachable || !rows.isEmpty ? SiriDialog.noReplies : SiriDialog.unreachable,
                      readSessionIds: [])
    }

    /// The newest reply of a chat that Siri can speak: a complete reply with text or attachments.
    public static func lastReply(of messages: [ChatMessage]) -> ChatMessage? {
        messages.last { message in
            message.role == .assistant && message.reply == .complete
                && (!message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.attachments.isEmpty)
        }
    }

    /// One run: sync for `syncTimeout` or less (the list and each unread chat), then read from the models.
    /// With no link, or after the timeout, Siri reads the cache.
    public static func run(sessions: SessionListModel, syncTimeout: Duration = SiriTiming.readSync,
                           linkReady: @escaping @MainActor (Duration) async -> Bool) async -> Result {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: syncTimeout)
        var reachable = false
        _ = await SiriTiming.finishes(within: syncTimeout) {
            guard await linkReady(SiriTiming.remaining(until: deadline)) else { return }
            reachable = true
            await sessions.refresh()
            for row in sessions.sessions.filter(\.isUnread).prefix(maxReplies) {
                await sessions.chat(for: row.id).open()
            }
        }
        let result = result(rows: sessions.sessions, reachable: reachable) { id in
            lastReply(of: sessions.chat(for: id).messages)
        }
        result.readSessionIds.forEach(sessions.markRead)
        return result
    }
}

/// Issue #45: "Ask Hermes" in the background. It sends the text, waits for the reply, and gives the dialog.
@MainActor
public enum SiriAsk {
    public enum Outcome: Equatable {
        case reply(SiriSpokenText, sessionId: String?)
        /// No reply in the time. The app posts a notification when the reply comes.
        case stillWorking(Pending)
        case unreachable
        case replyFailed

        public var dialog: String {
            switch self {
            case .reply(let spoken, _): spoken.text
            case .stillWorking: SiriDialog.stillWorking
            case .unreachable: SiriDialog.unreachable
            case .replyFailed: SiriDialog.replyFailed
            }
        }
    }

    /// A prompt whose reply did not come in the Siri time.
    public struct Pending: Equatable {
        public let chat: ChatViewModel
        public let promptId: String

        public static func == (lhs: Pending, rhs: Pending) -> Bool {
            lhs.chat === rhs.chat && lhs.promptId == rhs.promptId
        }
    }

    /// The reply state of the prompt `promptId`.
    enum ReplyState: Equatable {
        case waiting
        case done(ChatMessage)
        case failed
    }

    /// 1. Wait for the link until the deadline. No link: "I can't reach Hermes right now." Nothing is sent.
    /// 2. The session: the cached active session, else `session.most_recent`, else a new chat.
    /// 3. Send, then wait for the reply until the deadline.
    /// 4. A list refresh. A reply that Siri reads in full marks the session read. A cut reply stays unread.
    public static func run(text: String, sessions: SessionListModel, timeout: Duration = SiriTiming.askReply,
                           poll: Duration = .milliseconds(100),
                           linkReady: @escaping @MainActor (Duration) async -> Bool) async -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var ready = false
        _ = await SiriTiming.finishes(within: timeout) { ready = await linkReady(SiriTiming.remaining(until: deadline)) }
        guard ready, !trimmed.isEmpty else { return .unreachable }
        let chat: ChatViewModel
        if let id = sessions.cachedActiveSessionId {
            chat = sessions.chat(for: id)
        } else {
            var mostRecent: String?
            _ = await SiriTiming.finishes(within: SiriTiming.remaining(until: deadline)) {
                mostRecent = await sessions.mostRecentSessionId()
            }
            chat = mostRecent.map(sessions.chat(for:)) ?? sessions.newChat(key: UUID().uuidString)
        }
        let before = Set(chat.messages.map(\.id))
        let task = chat.send(trimmed)
        guard let promptId = chat.messages.last(where: { $0.role == .user && !before.contains($0.id) })?.id else {
            return .unreachable
        }
        _ = await SiriTiming.finishes(within: SiriTiming.remaining(until: deadline)) { await task?.value }
        if chat.messages.first(where: { $0.id == promptId })?.delivery == .failed { return .unreachable }
        while true {
            switch replyState(of: promptId, in: chat.messages) {
            case .done(let reply):
                let spoken = SiriSpeech.spokenText(reply)
                // The refresh gives the session its blue dot for the new reply. A full read removes it.
                _ = await SiriTiming.finishes(within: SiriTiming.markRead) { await sessions.refresh() }
                if spoken.isComplete, let id = chat.storedSessionId { sessions.markRead(id) }
                return .reply(spoken, sessionId: chat.storedSessionId)
            case .failed:
                return .replyFailed
            case .waiting:
                if clock.now >= deadline { return .stillWorking(Pending(chat: chat, promptId: promptId)) }
                try? await Task.sleep(for: poll)
            }
        }
    }

    /// The reply after the prompt `promptId`: the first assistant message after it.
    static func replyState(of promptId: String, in messages: [ChatMessage]) -> ReplyState {
        guard let index = messages.firstIndex(where: { $0.id == promptId }) else { return .failed }
        if messages[index].delivery == .failed { return .failed }
        guard let reply = messages[(index + 1)...].first(where: { $0.role == .assistant }) else { return .waiting }
        switch reply.reply {
        case .complete: return .done(reply)
        case .failed, .interrupted: return .failed
        case .streaming, nil: return .waiting
        }
    }

    /// A slow reply: wait for it in the background, then post one reply notification (#15 rules: the
    /// body has message text only with "Show Message Preview" on). Returns `true` when it posted.
    @discardableResult
    public static func notifyWhenDone(_ pending: Pending, title: @MainActor () -> String, showsPreview: Bool,
                                      notifier: any LocalNotifying, timeout: Duration = SiriTiming.followUp,
                                      poll: Duration = .milliseconds(200)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            switch replyState(of: pending.promptId, in: pending.chat.messages) {
            case .done(let reply):
                guard let id = pending.chat.storedSessionId else { return false }
                let row = SessionListItem(id: id, title: title())
                await notifier.post(CatchUpNotification(session: row, reply: reply.text, showsPreview: showsPreview))
                return true
            case .failed:
                return false
            case .waiting:
                if Task.isCancelled || clock.now >= deadline { return false }
                try? await Task.sleep(for: poll)
            }
        }
    }
}
