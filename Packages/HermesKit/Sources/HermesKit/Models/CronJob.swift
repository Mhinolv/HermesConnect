import Foundation

/// One cron job of `GET /api/cron/jobs` (issue #73, `apps/desktop/src/types/hermes.ts` `CronJob`).
///
/// Decoding is tolerant: every field but `id` can be missing, so a newer server or an older cache still loads.
/// The cache uses the same keys as the server.
public struct CronJob: Identifiable, Sendable, Hashable, Codable {
    public struct Schedule: Sendable, Hashable, Codable {
        public var display: String?
        public var expr: String?
        public var kind: String?

        public init(display: String? = nil, expr: String? = nil, kind: String? = nil) {
            self.display = display
            self.expr = expr
            self.kind = kind
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            display = try? container.decodeIfPresent(String.self, forKey: .display)
            expr = try? container.decodeIfPresent(String.self, forKey: .expr)
            kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        }
    }

    /// One attempt of the execution ledger. `claimed` and `running` mean that a run is in flight.
    public struct Execution: Sendable, Hashable, Codable {
        public var id: String?
        public var status: String?

        public init(id: String? = nil, status: String? = nil) {
            self.id = id
            self.status = status
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
        }

        var isInFlight: Bool { ["claimed", "running"].contains(status ?? "") }
    }

    public let id: String
    public var name: String?
    public var enabled: Bool?
    /// `scheduled`, `paused`, `completed`, `disabled`, ...
    public var state: String?
    public var schedule: Schedule?
    public var scheduleDisplay: String?
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var lastStatus: String?
    public var lastError: String?
    public var latestExecution: Execution?
    public var liveExecution: Execution?

    public init(id: String, name: String? = nil, enabled: Bool? = true, state: String? = nil,
                schedule: Schedule? = nil, scheduleDisplay: String? = nil, lastRunAt: Date? = nil,
                nextRunAt: Date? = nil, lastStatus: String? = nil, lastError: String? = nil,
                latestExecution: Execution? = nil, liveExecution: Execution? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.state = state
        self.schedule = schedule
        self.scheduleDisplay = scheduleDisplay
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.latestExecution = latestExecution
        self.liveExecution = liveExecution
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, state, schedule, scheduleDisplay = "schedule_display", lastRunAt = "last_run_at"
        case nextRunAt = "next_run_at", lastStatus = "last_status", lastError = "last_error"
        case latestExecution = "latest_execution", liveExecution = "live_execution"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
        state = try? container.decodeIfPresent(String.self, forKey: .state)
        schedule = try? container.decodeIfPresent(Schedule.self, forKey: .schedule)
        scheduleDisplay = try? container.decodeIfPresent(String.self, forKey: .scheduleDisplay)
        lastRunAt = CronDate.decode(container, .lastRunAt)
        nextRunAt = CronDate.decode(container, .nextRunAt)
        lastStatus = try? container.decodeIfPresent(String.self, forKey: .lastStatus)
        lastError = try? container.decodeIfPresent(String.self, forKey: .lastError)
        latestExecution = try? container.decodeIfPresent(Execution.self, forKey: .latestExecution)
        liveExecution = try? container.decodeIfPresent(Execution.self, forKey: .liveExecution)
    }

    /// Dates go to the cache as seconds since 1970. `CronDate.decode` reads them back.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encodeIfPresent(schedule, forKey: .schedule)
        try container.encodeIfPresent(scheduleDisplay, forKey: .scheduleDisplay)
        try container.encodeIfPresent(lastRunAt?.timeIntervalSince1970, forKey: .lastRunAt)
        try container.encodeIfPresent(nextRunAt?.timeIntervalSince1970, forKey: .nextRunAt)
        try container.encodeIfPresent(lastStatus, forKey: .lastStatus)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encodeIfPresent(latestExecution, forKey: .latestExecution)
        try container.encodeIfPresent(liveExecution, forKey: .liveExecution)
    }

    /// The name, or "Untitled Job".
    public var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled Job" : trimmed
    }

    /// `schedule_display`, else `schedule.display`, else `schedule.expr`. Empty when the server gave none.
    public var scheduleText: String {
        for text in [scheduleDisplay, schedule?.display, schedule?.expr] {
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return ""
    }

    /// The status of the row (issue #73 design notes). A live run wins, then the saved state, then the last run.
    public var status: CronJobStatus {
        if latestExecution?.isInFlight == true || liveExecution != nil { return .running }
        let state = state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if state == "paused" { return .paused }
        if ["disabled", "completed"].contains(state) || enabled == false { return .off }
        if state == "running" { return .running }
        let error = lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let succeeded = ["ok", "success", "succeeded", "completed"].contains(lastStatus?.lowercased() ?? "")
        if !error.isEmpty, !succeeded { return .failed(error) }
        return .scheduled
    }

    /// `true` when the name or the schedule has `query`. An empty query matches every job.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return displayName.localizedStandardContains(query) || scheduleText.localizedStandardContains(query)
    }
}

/// The status symbol and text of a job row.
public enum CronJobStatus: Sendable, Equatable {
    case scheduled
    case running
    case paused
    /// The last run failed. The value is `last_error`.
    case failed(String)
    /// Disabled, or a one-shot job that completed.
    case off

    /// The word in the row and in VoiceOver. `scheduled` has no word: the row shows only the schedule.
    public var text: String? {
        switch self {
        case .scheduled: nil
        case .running: "Running"
        case .paused: "Paused"
        case .failed: "Failed"
        case .off: "Off"
        }
    }

    /// The text of the "Status" row of the job screen.
    public var detailText: String { text ?? "Scheduled" }
}

/// One run of `GET /api/cron/jobs/{id}/runs`, newest first (`web_routers/cron.py:520-560`).
///
/// An agent run is a stored session (`source: "cron"`). A script-only run has a `cron_output:` id
/// and no session: the server has no endpoint for its full text, so the app shows its `preview`.
public struct CronRun: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public var title: String?
    public var preview: String?
    public var source: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var isActive: Bool?
    public var messageCount: Int?

    public init(id: String, title: String? = nil, preview: String? = nil, source: String? = "cron",
                startedAt: Date? = nil, endedAt: Date? = nil, isActive: Bool? = nil, messageCount: Int? = nil) {
        self.id = id
        self.title = title
        self.preview = preview
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isActive = isActive
        self.messageCount = messageCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, preview, source, startedAt = "started_at", endedAt = "ended_at", isActive = "is_active"
        case messageCount = "message_count"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        preview = try? container.decodeIfPresent(String.self, forKey: .preview)
        source = try? container.decodeIfPresent(String.self, forKey: .source)
        startedAt = CronDate.decode(container, .startedAt)
        endedAt = CronDate.decode(container, .endedAt)
        isActive = try? container.decodeIfPresent(Bool.self, forKey: .isActive)
        messageCount = try? container.decodeIfPresent(Int.self, forKey: .messageCount)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(startedAt?.timeIntervalSince1970, forKey: .startedAt)
        try container.encodeIfPresent(endedAt?.timeIntervalSince1970, forKey: .endedAt)
        try container.encodeIfPresent(isActive, forKey: .isActive)
        try container.encodeIfPresent(messageCount, forKey: .messageCount)
    }

    /// Issue #73: a cron run from the session list, for a notification tap. The run screen needs only the id.
    public init(session: SessionListItem) {
        self.init(id: session.id, title: session.title, preview: session.preview, source: session.source,
                  startedAt: session.startedAt, messageCount: session.messageCount)
    }

    /// A script-only run: no session, only the `preview` of its output document.
    public var isOutputOnly: Bool { id.hasPrefix("cron_output:") || source == "cron_output" }

    /// The status from the title prefix ("FAILED · ...", `cron.py:368-374`). A run that is still open is running.
    public var status: CronRunStatus {
        let title = (title ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        if title.hasPrefix("FAILED") { return .failed }
        if title.hasPrefix("CANCELLED") { return .cancelled }
        if title.hasPrefix("MISSED") { return .missed }
        if isActive == true { return .running }
        return .done
    }

    /// Two lines of the row: the preview, else the title.
    public var previewText: String {
        for text in [preview, title] {
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return ""
    }
}

public enum CronRunStatus: Sendable, Equatable {
    case done
    case running
    case failed
    case cancelled
    case missed

    /// The word in the run row. A run that ended well has none.
    public var text: String? {
        switch self {
        case .done: nil
        case .running: "Running"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .missed: "Missed"
        }
    }
}

/// `GET /api/cron/jobs/{id}/runs` result.
public struct CronRunsPage: Decodable, Sendable, Equatable {
    public var runs: [CronRun]
    public var limit: Int?

    private enum CodingKeys: String, CodingKey { case runs, limit }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runs = try container.decode(LossyArray<CronRun>.self, forKey: .runs).items
        limit = try? container.decodeIfPresent(Int.self, forKey: .limit)
    }
}

/// An array that drops the items that do not decode, so one bad row does not hide the list.
struct LossyArray<Element: Decodable>: Decodable {
    var items: [Element]

    private struct Item: Decodable {
        var value: Element?
        init(from decoder: any Decoder) throws { value = try? Element(from: decoder) }
    }

    init(items: [Element]) {
        self.items = items
    }

    init(from decoder: any Decoder) throws {
        items = try [Item](from: decoder).compactMap(\.value)
    }
}

/// Cron times: seconds since 1970 (run rows, the cache) or ISO 8601 text (job fields, `datetime.isoformat()`).
enum CronDate {
    static func decode<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> Date? {
        if let seconds = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return parse(text)
    }

    /// Python `isoformat()`: an optional fraction of 1 to 6 digits, and an optional offset.
    /// Text with no offset is local time, as `datetime.fromisoformat(...).timestamp()` reads it.
    static func parse(_ text: String) -> Date? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
        text = text.replacingOccurrences(of: " ", with: "T")
        var fraction = 0.0
        if let dot = text.firstIndex(of: "."), let timeStart = text.firstIndex(of: "T"), dot > timeStart {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            text.removeSubrange(dot..<text.index(dot, offsetBy: digits.count + 1))
        }
        if text.hasSuffix("Z") { text = String(text.dropLast()) + "+00:00" }
        let hasOffset = text.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = hasOffset ? "yyyy-MM-dd'T'HH:mm:ssXXXXX" : "yyyy-MM-dd'T'HH:mm:ss"
        if let date = formatter.date(from: text) { return date.addingTimeInterval(fraction) }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
