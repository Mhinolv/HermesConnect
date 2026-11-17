import HermesKit
import SwiftUI

/// The tabs of the root (issue #73).
enum RootTab: Hashable {
    case chats
    case jobs
}

/// A screen in the Jobs stack: a job with its runs, or the read-only output of one run.
enum JobsRoute: Hashable {
    case job(CronJob)
    case run(CronRun, jobName: String)
}

/// The Jobs tab: the job list, then the job screen, then the run screen (issue #73). Read-only.
struct JobsTab: View {
    let model: JobsModel
    /// The cron runs with the blue dot. Opening a run clears it.
    var sessions = ChatLaunch.makeOfflineSessions()
    var link: LiveChatTransport?
    @Binding var path: [JobsRoute]
    var onSettings: () -> Void = {}

    var body: some View {
        NavigationStack(path: $path) {
            JobsListScreen(model: model, link: link, query: JobsDemo.search,
                           unreadJobIds: model.unreadJobIds(sessions.unreadCronRuns), onSettings: onSettings)
                .navigationDestination(for: JobsRoute.self) { route in
                    switch route {
                    case .job(let job):
                        JobScreen(jobs: model, job: job, link: link,
                                  unreadRunIds: Set(sessions.unreadCronRuns.map(\.id)))
                    case .run(let run, let jobName):
                        CronRunScreen(model: CronRunTranscriptModel(run: run, transport: model.transport),
                                      jobName: jobName, link: link)
                            .onAppear { sessions.markRead(run.id) }
                    }
                }
        }
    }
}

/// The job list, like the chats list (issue #73 design notes).
struct JobsListScreen: View {
    let model: JobsModel
    var link: LiveChatTransport?
    /// Jobs with an unread run get the blue dot.
    var unreadJobIds: Set<String> = []
    var onSettings: () -> Void = {}
    @State private var query: String

    init(model: JobsModel, link: LiveChatTransport? = nil, query: String = "", unreadJobIds: Set<String> = [],
         onSettings: @escaping () -> Void = {}) {
        self.model = model
        self.link = link
        self.unreadJobIds = unreadJobIds
        self.onSettings = onSettings
        _query = State(initialValue: query)
    }

    var body: some View {
        let state = model.state(query: query)
        List {
            switch state {
            case .loading:
                ForEach(0..<5, id: \.self) { _ in
                    JobRow(job: JobsText.placeholder)
                        .redacted(reason: .placeholder)
                        .accessibilityHidden(true)
                }
            case .rows:
                ForEach(model.filtered(query)) { job in
                    NavigationLink(value: JobsRoute.job(job)) {
                        JobRow(job: job, isUnread: unreadJobIds.contains(job.id))
                    }
                }
            case .empty, .noResults, .error:
                EmptyView()
            }
        }
        .listStyle(.plain)
        .overlay {
            switch state {
            case .empty:
                ContentUnavailableView("No Jobs", systemImage: "clock.arrow.circlepath",
                                       description: Text("Cron jobs on your Hermes server show here."))
            case .noResults:
                ContentUnavailableView.search(text: query)
            case .error(let message):
                CronLoadErrorView(title: "Couldn't Load Jobs", message: message) { await model.refresh() }
            case .loading, .rows:
                EmptyView()
            }
        }
        .searchable(text: $query, prompt: "Search")
        .refreshable { await model.refresh() }
        .navigationTitle("Jobs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { ChatNavigationTitle(title: "Jobs", link: link) }
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape", action: onSettings)
            }
        }
        // The list refreshes when it shows, then on each connect, `cron.changed` and `sessions.changed`.
        .task {
            await model.refresh()
            await model.watch()
        }
    }
}

/// One job: the name and the last run time, then the status and the schedule (like `SessionRow`, no dot).
struct JobRow: View {
    let job: CronJob
    /// A run that the owner did not open yet: the blue dot, as in the chats list.
    var isUnread = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            UnreadDot(isUnread: isUnread)
            VStack(alignment: .leading, spacing: 2) {
                header
                statusLine
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if case .failed(let error) = job.status {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(JobsText.accessibilityLabel(job, isUnread: isUnread))
    }

    @ViewBuilder private var header: some View {
        let title = Text(job.displayName).font(.headline).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
        let time = job.lastRunAt.map { Text(SessionRowText.time($0)).font(.footnote).foregroundStyle(.secondary) }
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                title
                time
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                title
                Spacer(minLength: 8)
                time
            }
        }
    }

    private var statusLine: some View {
        HStack(alignment: .center, spacing: 4) {
            JobStatusSymbol(status: job.status)
            Text(JobsText.statusLine(job))
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
        }
    }
}

/// The symbol of a job status (issue #73 design notes, "Job row").
struct JobStatusSymbol: View {
    let status: CronJobStatus

    var body: some View {
        switch status {
        case .scheduled:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.mini)
        case .paused:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .off:
            Image(systemName: "moon.zzz").foregroundStyle(.secondary)
        }
    }
}

/// The job details, then the runs, newest first.
struct JobScreen: View {
    let jobs: JobsModel
    var link: LiveChatTransport?
    /// Runs that the owner did not open yet get the blue dot.
    var unreadRunIds: Set<String> = []
    @State private var runs: CronRunsModel
    private let initial: CronJob

    init(jobs: JobsModel, job: CronJob, link: LiveChatTransport? = nil, unreadRunIds: Set<String> = []) {
        self.jobs = jobs
        self.link = link
        self.unreadRunIds = unreadRunIds
        initial = job
        _runs = State(initialValue: jobs.runs(for: job))
    }

    /// The newest copy of the job. A job that left the server list keeps its last copy.
    private var job: CronJob { jobs.job(id: initial.id) ?? initial }

    var body: some View {
        let job = job
        List {
            Section {
                LabeledContent("Schedule", value: job.scheduleText.isEmpty ? "None" : job.scheduleText)
                LabeledContent("Next Run", value: JobsText.dateTime(job.nextRunAt))
                LabeledContent("Last Run", value: JobsText.dateTime(job.lastRunAt))
                LabeledContent("Status") {
                    HStack(spacing: 4) {
                        JobStatusSymbol(status: job.status)
                        Text(job.status.detailText)
                    }
                }
                if case .failed(let error) = job.status {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Runs") {
                switch runs.state {
                case .loading:
                    ForEach(0..<5, id: \.self) { _ in
                        RunRow(run: JobsText.placeholderRun)
                            .redacted(reason: .placeholder)
                            .accessibilityHidden(true)
                    }
                case .rows, .noResults:
                    ForEach(runs.runs) { run in
                        NavigationLink(value: JobsRoute.run(run, jobName: job.displayName)) {
                            RunRow(run: run, isUnread: unreadRunIds.contains(run.id))
                        }
                    }
                case .empty:
                    ContentUnavailableView("No Runs", systemImage: "clock.arrow.circlepath",
                                           description: Text("This job has not run yet."))
                case .error(let message):
                    CronLoadErrorView(title: "Couldn't Load Runs", message: message) { await runs.refresh() }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(job.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { ChatNavigationTitle(title: job.displayName, link: link) }
        }
        .refreshable {
            async let list: Void = jobs.refresh()
            async let history: Void = runs.refresh()
            _ = await (list, history)
        }
        .task {
            await runs.refresh()
            async let list: Void = jobs.watch()
            async let history: Void = runs.watch()
            _ = await (list, history)
        }
    }
}

/// One run: the date and time, the status from the title, and 2 lines of the preview.
struct RunRow: View {
    let run: CronRun
    var isUnread = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            UnreadDot(isUnread: isUnread)
            content
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(JobsText.accessibilityLabel(run, isUnread: isUnread))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(JobsText.dateTime(run.startedAt))
                .font(.headline)
            if let text = run.status.text {
                HStack(spacing: 4) {
                    switch run.status {
                    case .failed:
                        Image(systemName: "exclamationmark.circle.fill")
                    case .running:
                        ProgressView().controlSize(.mini)
                    default:
                        EmptyView()
                    }
                    Text(text)
                }
                .font(.subheadline)
                .foregroundStyle(run.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            Text(JobsText.runPreview(run))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// The blue dot of an unread row, as in `SessionRow`. The space stays when it is read, so rows line up.
struct UnreadDot: View {
    let isUnread: Bool

    var body: some View {
        Circle()
            .fill(isUnread ? Color.blue : Color.clear)
            .frame(width: 10, height: 10)
            .padding(.top, 6)
    }
}

/// Issue #73: where a notification tap on a cron run goes.
@MainActor
enum JobsRouting {
    /// The Jobs stack for a cron run session: its job screen, then the read-only run screen.
    /// `nil` when `id` is not a cron run, so the tap opens the chat.
    static func path(forSession id: String, sessions: SessionListModel, jobs: JobsModel) -> [JobsRoute]? {
        let row = sessions.session(id: id)
        guard row?.isCronRun == true || (row == nil && id.hasPrefix("cron_")) else { return nil }
        let session = row ?? SessionListItem(id: id, source: "cron")
        let run = CronRun(session: session)
        guard let job = jobs.job(forRun: session) else {
            return [.run(run, jobName: session.displayTitle)]
        }
        return [.job(job), .run(run, jobName: job.displayName)]
    }
}

/// The read-only output of one run: the chat thread with no composer and no tapbacks (issue #73).
struct CronRunScreen: View {
    @State var model: CronRunTranscriptModel
    let jobName: String
    var link: LiveChatTransport?
    @State private var chat: ChatViewModel?

    var body: some View {
        Group {
            if let chat {
                ChatThreadView(model: chat, readOnly: true)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else if let message = model.errorMessage {
                CronLoadErrorView(title: "Couldn't Load Run", message: message) { await load() }
            } else {
                ProgressView()
                    .accessibilityLabel("Loading run")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(jobName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(JobsText.dateTime(model.run.startedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .toolbarVisibility(.hidden, for: .tabBar)
        .task { await load() }
    }

    private func load() async {
        await model.load()
        guard chat == nil, let messages = model.messages else { return }
        // The thread only shows the messages. `link` is there for the files in a reply (issue #12).
        let transport: any ChatTransport = link ?? OfflineChatTransport()
        chat = ChatViewModel(transport: transport, title: jobName, messages: messages)
    }
}

/// "Couldn't Load Jobs", the server message and "Try Again".
struct CronLoadErrorView: View {
    let title: String
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await retry() } }
                .buttonStyle(.glassProminent)
        }
    }
}

/// Text of the Jobs tab, apart from the views so the tests can read it.
enum JobsText {
    /// The status word (if any), then the schedule: "Paused · Every day at 8:00 AM".
    static func statusLine(_ job: CronJob) -> String {
        let schedule = job.scheduleText.isEmpty ? "No schedule" : job.scheduleText
        guard let word = job.status.text else { return schedule }
        return "\(word) · \(schedule)"
    }

    /// "<name>, <status>, <schedule>, last run <time>" (issue #73 design notes, VoiceOver).
    static func accessibilityLabel(_ job: CronJob, isUnread: Bool = false, now: Date = Date()) -> String {
        var parts = isUnread ? ["Unread"] : []
        parts += [job.displayName, job.status.detailText]
        if case .failed(let error) = job.status { parts.append(error) }
        if !job.scheduleText.isEmpty { parts.append(job.scheduleText) }
        if let date = job.lastRunAt { parts.append("last run \(SessionRowText.time(date, now: now))") }
        return parts.joined(separator: ", ")
    }

    static func accessibilityLabel(_ run: CronRun, isUnread: Bool = false) -> String {
        var parts = isUnread ? ["Unread"] : []
        parts.append(dateTime(run.startedAt))
        if let text = run.status.text { parts.append(text) }
        let preview = runPreview(run)
        if !preview.isEmpty { parts.append(preview) }
        return parts.joined(separator: ", ")
    }

    /// The preview with the status prefix of the title taken away ("FAILED · boom" shows "boom").
    static func runPreview(_ run: CronRun) -> String {
        let text = run.previewText
        guard run.preview?.isEmpty != false, run.status != .done, run.status != .running,
              let range = text.range(of: " · ") else { return text }
        return String(text[range.upperBound...])
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static let placeholder = CronJob(id: "placeholder", name: "Placeholder job name",
                                     scheduleDisplay: "Every day at 8:00 AM", lastRunAt: Date())
    static let placeholderRun = CronRun(id: "placeholder", title: "Placeholder",
                                        preview: "Placeholder preview text for this run that fills two lines",
                                        startedAt: Date())
}

extension ChatLaunch {
    /// Issue #73: the Release job list and its cache in Application Support.
    static func makeJobs(link: LiveChatTransport) -> JobsModel {
        let cache: any CronJobCacheStore = (try? FileCronJobCacheStore.applicationSupport())
            ?? InMemoryCronJobCacheStore()
        return JobsModel(transport: link, cache: cache)
    }

    /// The job list of a window with no app model (previews, tests). Nothing connects.
    static func makeOfflineJobs() -> JobsModel {
        JobsModel(transport: OfflineCronTransport(), cache: InMemoryCronJobCacheStore())
    }
}

/// A cron transport with no server. Every call fails as "not connected".
struct OfflineCronTransport: CronTransport {
    let events: AsyncStream<GatewayClientEvent> = AsyncStream { _ in }

    func fetchCronJobs() async throws -> [CronJob] { throw GatewayError.notConnected }
    func fetchCronRuns(jobId _: String, limit _: Int) async throws -> [CronRun] { throw GatewayError.notConnected }
    func fetchRunTranscript(sessionId _: String) async throws -> [TranscriptMessage] {
        throw GatewayError.notConnected
    }
}

struct JobsListScreen_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            JobsListScreen(model: JobsModel(transport: OfflineCronTransport(),
                                            cache: InMemoryCronJobCacheStore(jobs: JobsDemo.jobs())))
        }
        .environment(AppModel.preview(setUp: true))
    }
}
