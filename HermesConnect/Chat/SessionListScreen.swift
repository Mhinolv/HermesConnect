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
        List {
            if model.hasLoaded {
                ForEach(rows) { item in
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
                if SessionRowText.showsArchivedRow(count: model.archivedCount, query: query) {
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
        .refreshable { await model.refresh() }
        .navigationTitle("Hermes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Issue #83: with two or more servers, the title is the server menu.
            ToolbarItem(placement: .principal) {
                ServerTitle(title: "Hermes", link: link, activeUnreadChats: model.chatsUnreadCount, onManage: onSettings)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape", action: onSettings)
            }
            // Issue #94: one glass group, the "More" menu before "New Chat". #95 adds "Select Chats" to the menu.
            ToolbarItemGroup(placement: .topBarTrailing) {
                ChatsMoreMenu(canMarkAllRead: model.canMarkAllRead, onMarkAllRead: markAllRead)
                Button("New Chat", systemImage: "square.and.pencil", action: onNewChat)
            }
        }
        .sensoryFeedback(.success, trigger: markedAllRead)
        .sessionActionDialogs(actions, model: model)
        .task { await model.refresh() }
        #if DEBUG
        .onAppear {
            SessionActionDemo.present(on: actions, model: model)
            ChatsMoreDemo.present(markAllRead: markAllRead)
        }
        #endif
    }

    /// Issue #94: no confirmation and no undo, as in Messages. The dots fade out together.
    private func markAllRead() {
        guard withAnimation(.easeOut(duration: 0.3), { model.markAllRead() }) > 0 else { return }
        markedAllRead += 1
        onMarkedAllRead()
        // The menu closes first. VoiceOver drops an announcement that comes while it closes.
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            AccessibilityNotification.Announcement(ChatsMoreText.announcement).post()
        }
    }
}

/// Issue #94: the trailing "More" menu of the Chats list (`ellipsis`). Select mode (#95) hides it.
/// #95 gives `onSelectChats`, so "Select Chats" shows above "Mark All as Read".
struct ChatsMoreMenu: View {
    /// "Mark All as Read" is disabled, not hidden, with no unread chat and on the first load.
    var canMarkAllRead: Bool
    var onMarkAllRead: () -> Void
    var onSelectChats: (() -> Void)?

    var body: some View {
        Menu {
            if let onSelectChats {
                Button(ChatsMoreText.selectChats, systemImage: "checkmark.circle", action: onSelectChats)
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
