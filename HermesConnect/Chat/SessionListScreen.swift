import HermesKit
import SwiftUI

/// A screen in the navigation stack: a stored session, or a new chat with a route key (issue #7).
enum ChatRoute: Hashable {
    case session(String)
    case new(String)
    /// Issue #64: the Archived list.
    case archived

    /// Issue #16: the chat that "Ask Hermes" opens.
    init(_ route: AskHermesRoute) {
        switch route {
        case .session(let id): self = .session(id)
        case .newChat(let key): self = .new(key)
        }
    }
}

/// The session list: the root screen, like the Messages list (issue #7).
struct SessionListScreen: View {
    let model: SessionListModel
    var link: LiveChatTransport?
    var onSettings: () -> Void = {}
    var onNewChat: () -> Void = {}
    /// Issue #94: after "Mark All as Read". The app writes the server book entry of the active server.
    var onMarkedAllRead: () -> Void = {}
    @State private var query: String
    /// Issue #64: rename, archive and delete.
    @State private var actions = SessionActionState()
    /// Issue #94: counts "Mark All as Read", for the success haptic.
    @State private var markedAllRead = 0
    /// Issue #95: the select mode, its selection and the alert of a partial failure.
    @State private var selecting = false
    @State private var selection = ChatSelection()
    @State private var archivedBatches = 0
    @State private var batchFailure: BatchArchiveFailure?
    @FocusState private var searchFocused: Bool
    @Environment(AppModel.self) private var appModel

    init(model: SessionListModel, link: LiveChatTransport? = nil, query: String = "",
         onSettings: @escaping () -> Void = {}, onNewChat: @escaping () -> Void = {},
         onMarkedAllRead: @escaping () -> Void = {}) {
        self.model = model
        self.link = link
        self.onSettings = onSettings
        self.onNewChat = onNewChat
        self.onMarkedAllRead = onMarkedAllRead
        _query = State(initialValue: query)
    }

    var body: some View {
        let rows = model.filtered(query)
        // Issue #95: `List(selection:)` in select mode only, so a tap outside it opens the chat.
        List(selection: selecting ? $selection.ids : nil) {
            if model.hasLoaded {
                ForEach(rows) { item in
                    if selecting {
                        // No swipe actions and no context menu. The row keeps its unread dot.
                        SessionRow(item: item)
                            .tag(item.id)
                    } else {
                        sessionLink(item)
                    }
                }
                if !selecting, SessionRowText.showsArchivedRow(count: model.archivedCount, query: query) {
                    NavigationLink(value: ChatRoute.archived) {
                        ArchivedRow(count: model.archivedCount)
                    }
                }
            } else {
                ForEach(0..<5, id: \.self) { index in
                    SessionRow(item: SessionRowText.placeholder(index))
                        .redacted(reason: .placeholder)
                        .accessibilityHidden(true)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .animation(.default, value: rows.map(\.id))
        .overlay {
            switch SessionRowText.overlay(hasLoaded: model.hasLoaded, total: model.chatRows.count,
                                          matches: rows.count, query: query, archived: model.archivedCount) {
            case .noChats:
                ContentUnavailableView {
                    Label("No Chats", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    Button("New Chat", action: onNewChat)
                        .buttonStyle(.glassProminent)
                }
            case .noResults:
                ContentUnavailableView.search(text: query)
            case nil:
                EmptyView()
            }
        }
        .searchable(text: $query, prompt: "Search")
        .searchFocused($searchFocused)
        // Issue #95: no refresh in select mode, so the rows do not move under the selection.
        .refreshable { await refreshUnlessSelecting() }
        .navigationTitle("Hermes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if selecting {
                selectToolbar(rows)
            } else {
                // Issue #83: with two or more servers, the title is the server menu.
                ToolbarItem(placement: .principal) {
                    ServerTitle(title: "Hermes", link: link, activeUnreadChats: model.chatsUnreadCount,
                                onManage: onSettings)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape", action: onSettings)
                }
                // Issue #94: one glass group, the "More" menu before "New Chat".
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ChatsMoreMenu(canMarkAllRead: model.canMarkAllRead, onMarkAllRead: markAllRead,
                                  onSelectChats: startSelect, canSelectChats: model.hasLoaded && !model.chatRows.isEmpty)
                    Button("New Chat", systemImage: "square.and.pencil", action: onNewChat)
                }
            }
        }
        // Issue #95: the bottom bar takes the place of the tab bar.
        .toolbarVisibility(selecting ? .hidden : .automatic, for: .tabBar)
        .sensoryFeedback(.success, trigger: markedAllRead)
        .sensoryFeedback(.success, trigger: archivedBatches)
        .sessionActionDialogs(actions, model: model)
        .alert(batchFailure?.title ?? "", isPresented: present($batchFailure), presenting: batchFailure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
        // Issue #95: a chat that leaves the list leaves the selection. A switch or a push ends select mode.
        .onChange(of: model.chatRows.map(\.id)) { selection.keep(only: model.chatRows) }
        .onChange(of: appModel.profile?.id) { endSelect() }
        .onDisappear { endSelect() }
        .task { await model.refresh() }
        #if DEBUG
        .onAppear {
            SessionActionDemo.present(on: actions, model: model)
            ChatsMoreDemo.present(markAllRead: markAllRead)
            ChatSelectDemo.present { runSelectDemo($0) }
        }
        #endif
    }

    /// A row outside select mode: it opens the chat, with the #64 swipe actions and context menu.
    private func sessionLink(_ item: SessionListItem) -> some View {
        NavigationLink(value: ChatRoute.session(item.id)) {
            SessionRow(item: item)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Archive", systemImage: "archivebox") { actions.archive(item.id, model) }
                .tint(.indigo)
            // No destructive role: that role removes the row before the dialog answers.
            Button("Delete", systemImage: "trash") { actions.deleteTarget = SessionActionTarget(item) }
                .tint(.red)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { actions.startRename(SessionActionTarget(item)) }
            Button("Archive", systemImage: "archivebox") { actions.archive(item.id, model) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                actions.deleteTarget = SessionActionTarget(item)
            }
        }
    }

    /// Issue #95: the bars of select mode. No server menu, no Settings, no More menu, no New Chat.
    @ToolbarContentBuilder private func selectToolbar(_ rows: [SessionListItem]) -> some ToolbarContent {
        let count = selection.selected(in: rows).count
        ToolbarItem(placement: .principal) {
            Text(ChatSelectText.title(count))
                .font(.headline)
                .lineLimit(1)
        }
        ToolbarItem(placement: .topBarLeading) {
            Button(selection.allSelected(rows) ? ChatSelectText.deselectAll : ChatSelectText.selectAll) {
                selection.toggleAll(rows)
            }
            .disabled(rows.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(ChatSelectText.done) { endSelect() }
                .buttonStyle(.glassProminent)
        }
        ToolbarItem(placement: .bottomBar) {
            // The toolbar shows only the icon of a `Label`. The design shows the word too.
            Button { archiveSelected(rows) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "archivebox")
                    Text(ChatSelectText.archive)
                }
            }
            .disabled(count == 0)
            .accessibilityLabel(ChatSelectText.archiveLabel(count))
        }
    }

    /// Issue #94: no confirmation and no undo, as in Messages. The dots fade out together.
    private func markAllRead() {
        guard withAnimation(.easeOut(duration: 0.3), { model.markAllRead() }) > 0 else { return }
        markedAllRead += 1
        onMarkedAllRead()
        // The menu closes first. VoiceOver drops an announcement that comes while it closes.
        announce(ChatsMoreText.announcement, after: .milliseconds(500))
    }

    // MARK: Select mode (issue #95)

    /// "Select Chats": the keyboard closes and the search query stays.
    private func startSelect() {
        searchFocused = false
        selection = ChatSelection()
        withAnimation { selecting = true }
    }

    /// "Done", "Archive", a server switch, a tab change or a push. No change to the chats.
    private func endSelect() {
        guard selecting else { return }
        withAnimation { selecting = false }
        selection = ChatSelection()
    }

    private func refreshUnlessSelecting() async {
        guard !selecting else { return }
        await model.refresh()
    }

    /// "Archive": the rows animate out at once and select mode ends. The calls go one at a time.
    /// A partial failure puts the failed rows back and shows one alert (owner decision).
    private func archiveSelected(_ rows: [SessionListItem]) {
        let ids = selection.selected(in: rows)
        guard !ids.isEmpty else { return }
        archivedBatches += 1
        endSelect()
        Task {
            let result = await model.archive(ids)
            guard !result.interrupted else { return }
            if result.failed.isEmpty {
                announce(ChatSelectText.announcement(result.archived.count))
            } else {
                batchFailure = BatchArchiveFailure(archived: result.archived.count, failed: result.failed.count)
            }
        }
    }

    private func announce(_ text: String, after delay: Duration = .zero) {
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            AccessibilityNotification.Announcement(text).post()
        }
    }

    /// `true` while the value is set. A dismiss clears it.
    private func present<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    #if DEBUG
    private func runSelectDemo(_ demo: ChatSelectDemo) {
        startSelect()
        let rows = model.filtered(query)
        switch demo {
        case .none: break
        case .three: selection = ChatSelection(ids: Set(rows.prefix(3).map(\.id)))
        case .all: selection.toggleAll(rows)
        case .failure:
            selection.toggleAll(rows)
            archiveSelected(rows)
        }
    }
    #endif
}

/// Issue #95: a batch archive with one or more failed chats. One alert shows the counts.
struct BatchArchiveFailure: Identifiable, Equatable {
    var archived: Int
    var failed: Int
    var id: String { "\(archived)-\(failed)" }
    var title: String { ChatSelectText.failureTitle(failed: failed) }
    var message: String { ChatSelectText.failureMessage(archived: archived, failed: failed) }
}

/// Issue #95: the text of select mode, apart from the views so the tests can read it.
enum ChatSelectText {
    static let selectAll = "Select All"
    static let deselectAll = "Deselect All"
    static let done = "Done"
    static let archive = "Archive"

    /// "Select Chats" with 0 selected, else "3 Selected".
    static func title(_ count: Int) -> String {
        count == 0 ? ChatsMoreText.selectChats : "\(count) Selected"
    }

    static func archiveLabel(_ count: Int) -> String {
        count == 1 ? "Archive 1 chat" : "Archive \(count) chats"
    }

    static func announcement(_ count: Int) -> String {
        count == 1 ? "1 chat archived" : "\(count) chats archived"
    }

    static func failureTitle(failed: Int) -> String {
        failed == 1 ? "Couldn't Archive Chat" : "Couldn't Archive \(failed) Chats"
    }

    static func failureMessage(archived: Int, failed: Int) -> String {
        guard archived > 0 else { return "No chats were archived. Try again later." }
        let done = archived == 1 ? "1 chat was archived." : "\(archived) chats were archived."
        let back = failed == 1 ? "The other chat is back in the list." : "The other \(failed) are back in the list."
        return "\(done) \(back)"
    }
}

/// Issue #94: the trailing "More" menu of the Chats list (`ellipsis`). Select mode (#95) hides it.
/// Issue #95: with `onSelectChats`, "Select Chats" shows above "Mark All as Read".
struct ChatsMoreMenu: View {
    /// "Mark All as Read" is disabled, not hidden, with no unread chat and on the first load.
    var canMarkAllRead: Bool
    var onMarkAllRead: () -> Void
    var onSelectChats: (() -> Void)?
    /// Issue #95: "Select Chats" is disabled with no chat row and on the first load.
    var canSelectChats = true

    var body: some View {
        Menu {
            if let onSelectChats {
                Button(ChatsMoreText.selectChats, systemImage: "checkmark.circle", action: onSelectChats)
                    .disabled(!canSelectChats)
            }
            Button(ChatsMoreText.markAllRead, systemImage: "checkmark.message", action: onMarkAllRead)
                .disabled(!canMarkAllRead)
        } label: {
            Label(ChatsMoreText.more, systemImage: "ellipsis")
        }
        .accessibilityHint(ChatsMoreText.hint)
    }
}

/// Issue #94: the text of the "More" menu, apart from the view so the tests can read it.
enum ChatsMoreText {
    static let more = "More"
    static let hint = "Shows chat actions."
    static let selectChats = "Select Chats"
    static let markAllRead = "Mark All as Read"
    static let announcement = "All chats marked as read"
}

/// Issue #64: the last row of the list. It opens the Archived list.
struct ArchivedRow: View {
    let count: Int

    var body: some View {
        HStack {
            Label(SessionActionText.archivedTitle, systemImage: "archivebox")
            Spacer()
            Text(count, format: .number)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SessionRowText.archivedLabel(count))
    }
}

/// One row: title and time, then two lines of preview with the source label (issue #7 design notes).
struct SessionRow: View {
    let item: SessionListItem
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(item.isUnread ? Color.blue : Color.clear)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                header
                preview
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SessionRowText.accessibilityLabel(item))
    }

    /// The time goes under the title at the accessibility sizes, so the title keeps its room.
    @ViewBuilder private var header: some View {
        let title = Text(item.displayTitle).font(.headline).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
        let time = item.startedAt.map { Text(SessionRowText.time($0)).font(.footnote).foregroundStyle(.secondary) }
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

    private var preview: Text {
        let text = item.preview ?? ""
        guard let badge = item.sourceBadge else { return Text(text) }
        let label = Text("\(Image(systemName: badge.symbol)) \(badge.text)").fontWeight(.semibold)
        return Text("\(label)  \(text)")
    }
}

/// Text and states of the list, apart from the views so the tests can read them.
enum SessionRowText {
    enum Overlay: Equatable {
        case noChats
        case noResults
    }

    /// `archived`: issue #64. With no chats but archived chats, the list shows the "Archived" row, not "No Chats".
    static func overlay(hasLoaded: Bool, total: Int, matches: Int, query: String, archived: Int = 0) -> Overlay? {
        guard hasLoaded else { return nil }
        if total == 0 { return archived > 0 && isEmptyQuery(query) ? nil : .noChats }
        if matches == 0, !isEmptyQuery(query) { return .noResults }
        return nil
    }

    private static func isEmptyQuery(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Issue #64: the "Archived" row shows when there are archived chats, and not in search results.
    static func showsArchivedRow(count: Int, query: String) -> Bool {
        count > 0 && isEmptyQuery(query)
    }

    static func archivedLabel(_ count: Int) -> String {
        count == 1 ? "Archived, 1 chat" : "Archived, \(count) chats"
    }

    /// Like Messages: the time today, "Yesterday", the weekday in the last week, else the date.
    static func time(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if isYesterday(date, now: now, calendar: calendar) {
            return "Yesterday"
        }
        let start = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: start), date >= weekAgo, date < start {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    private static func isYesterday(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }

    /// "<title>, <time>, <preview>". "Unread" and the source come in when they apply.
    static func accessibilityLabel(_ item: SessionListItem, now: Date = Date()) -> String {
        var parts: [String] = []
        if item.isUnread { parts.append("Unread") }
        parts.append(item.displayTitle)
        if let date = item.startedAt { parts.append(time(date, now: now)) }
        if let badge = item.sourceBadge { parts.append(badge.text) }
        if let preview = item.preview, !preview.isEmpty { parts.append(preview) }
        return parts.joined(separator: ", ")
    }

    /// A row for the first load. It shows redacted.
    static func placeholder(_ index: Int) -> SessionListItem {
        SessionListItem(id: "placeholder-\(index)", title: "Placeholder title",
                        preview: "Placeholder preview text for this session row that fills two lines",
                        startedAt: Date())
    }
}

#if DEBUG
/// Issue #94: the DEBUG screenshots of the "More" menu (`HERMES_DEMO=list HERMES_DEMO_MORE=<state>`).
enum ChatsMoreDemo: String {
    /// Two unread chats. The menu is open.
    case open
    /// No unread chat (only the cron run on Jobs). The menu is open with "Mark All as Read" disabled.
    case disabled
    /// Two unread chats, then "Mark All as Read" runs: the list after the action.
    case after

    static var current: ChatsMoreDemo? {
        ProcessInfo.processInfo.environment["HERMES_DEMO_MORE"].flatMap(ChatsMoreDemo.init(rawValue:))
    }

    /// The chat rows that get the blue dot in `open` and `after`.
    static let unreadIds: Set<String> = ["20261115_181200_photon", "20261112_090000_trip01"]

    static func rows(_ rows: [SessionListItem]) -> [SessionListItem] {
        guard let current, current != .disabled else { return rows }
        return rows.map { row in
            var row = row
            if unreadIds.contains(row.id) { row.isUnread = true }
            return row
        }
    }

    @MainActor static func present(markAllRead: @escaping @MainActor () -> Void) {
        guard let current else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            switch current {
            case .open, .disabled: openMenu()
            case .after: markAllRead()
            }
        }
    }

    /// The menu opens with no tap: the UIKit button of the "More" item performs its action.
    @MainActor private static func openMenu() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            // The bar buttons in order: Settings, More, New Chat. The views carry no label.
            let buttons = barButtons(in: window)
            guard buttons.count == 3 else { continue }
            buttons[1].performPrimaryAction()
            return
        }
    }

    /// The `_UIButtonBarButton` controls of the navigation bar, in view order.
    @MainActor private static func barButtons(in view: UIView, inBar: Bool = false) -> [UIControl] {
        let inBar = inBar || view is UINavigationBar
        if inBar, let control = view as? UIControl, String(describing: type(of: control)) == "_UIButtonBarButton" {
            return [control]
        }
        return view.subviews.flatMap { barButtons(in: $0, inBar: inBar) }
    }
}
#endif

#if DEBUG
/// Issue #95: the DEBUG screenshots of select mode (`HERMES_DEMO=list HERMES_DEMO_SELECT=<state>`).
/// `all` with `HERMES_DEMO_SEARCH=an` selects the search matches.
enum ChatSelectDemo: String {
    /// Select mode with no chat selected.
    case none
    /// Three chats selected.
    case three
    /// "Select All": every row that shows.
    case all
    /// Every chat archived. Two calls fail: the rows come back and the alert shows.
    case failure

    static var current: ChatSelectDemo? {
        ProcessInfo.processInfo.environment["HERMES_DEMO_SELECT"].flatMap(ChatSelectDemo.init(rawValue:))
    }

    /// The chats that the demo server does not archive in `failure`.
    static let failingIds: Set<String> = ["20261115_181200_photon", "20261023_140000_old001"]

    @MainActor static func present(_ run: @escaping @MainActor (ChatSelectDemo) -> Void) {
        guard let current else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            run(current)
        }
    }
}
#endif

struct SessionListScreen_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SessionListScreen(model: SessionListModel(
                transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                cache: InMemorySessionCacheStore(sessions: [
                    SessionListItem(id: "1", title: "Trip to Denver", preview: "The flight lands at 11:05 AM.",
                                    startedAt: .now, source: "ios"),
                    SessionListItem(id: "2", title: "Morning digest", preview: "3 new issues.", startedAt: .now,
                                    source: "cron", isUnread: true),
                ])))
        }
        .environment(AppModel.preview(setUp: true))
    }
}
