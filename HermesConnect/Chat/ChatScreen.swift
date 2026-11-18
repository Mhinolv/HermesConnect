import HermesKit
import SwiftUI

/// The chat screen: the MessageKit thread with the session title and the connection status (issue #6).
/// Issue #7: the session list pushes it. Settings is on the list, not here. Cached messages show at once,
/// and `open()` merges the server history. With no cache, a `ProgressView` shows until the history comes.
struct ChatScreen: View {
    let model: ChatViewModel
    var link: LiveChatTransport?
    /// Issue #64: the title menu renames the session through the list. `nil` (previews) shows no menu.
    var sessions: SessionListModel?
    /// The server has no row for this session (`session.resume` 4007). The root drops it and shows the list.
    var onSessionGone: () -> Void = {}
    @Environment(NotificationController.self) private var notifications: NotificationController?
    @State private var actions = SessionActionState()

    init(model: ChatViewModel, link: LiveChatTransport? = nil, sessions: SessionListModel? = nil,
         onSessionGone: @escaping () -> Void = {}) {
        self.model = model
        self.link = link
        self.sessions = sessions
        self.onSessionGone = onSessionGone
    }

    /// Issue #64: "Rename" in the title menu. A new chat with no stored id has no menu.
    private var renameAction: (() -> Void)? {
        guard sessions != nil, let id = model.storedSessionId else { return nil }
        let title = model.title ?? ""
        return { actions.startRename(SessionActionTarget(id: id, title: title)) }
    }

    var body: some View {
        ChatThreadView(model: model)
            // Issue #60: one modifier for both regions. With two modifiers, SwiftUI made the view end at the home
            // indicator line while the keyboard was up, and the composer sat 34 pt above the keyboard.
            .ignoresSafeArea([.container, .keyboard], edges: .bottom)
            .overlay {
                if model.isLoadingHistory {
                    ProgressView()
                        .accessibilityLabel("Loading messages")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ChatNavigationTitle(title: model.title, link: link, updating: model.isUpdating, onRename: renameAction)
                }
            }
            .modifier(OptionalSessionActionDialogs(state: actions, model: sessions))
            .onAppear { model.startEvents() }
            // Issue #15: ask for notification permission after the first reply, not at first launch.
            .onChange(of: model.completedReplyId) { _, id in
                if id != nil { notifications?.requestAfterFirstReply() }
            }
            .task { await model.open() }
            .onChange(of: model.isSessionGone, initial: true) { _, gone in
                if gone { onSessionGone() }
            }
    }
}

/// The session title ("New Chat" for a new session) with the connection status under it.
/// A stale Hermes token shows "Reconnecting…" while #4 starts a new session, then "Not connected" if it fails.
struct ChatNavigationTitle: View {
    @Environment(AppModel.self) private var app
    let title: String?
    var link: LiveChatTransport?
    /// Issue #15: `open()` merges the server history into the cached messages.
    var updating = false
    /// Issue #64: with an action, the title is a menu with "Rename", like a `.toolbarTitleMenu`.
    var onRename: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if let onRename {
                Menu {
                    Button("Rename", systemImage: "pencil", action: onRename)
                } label: {
                    HStack(spacing: 3) {
                        titleText
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.primary)
                }
                .accessibilityHint("Shows the chat actions.")
            } else {
                titleText
            }
            ChatTitleStatus(link: link, updating: updating)
        }
        .accessibilityElement(children: .contain)
    }

    private var titleText: some View {
        Text(title ?? "New Chat")
            .font(.headline)
            .lineLimit(1)
    }
}

/// The status line under a title: the chat link state, else the #3 connection status.
/// Issue #83: the server menu title of the Chats and Jobs lists uses it too.
struct ChatTitleStatus: View {
    @Environment(AppModel.self) private var app
    var link: LiveChatTransport?
    var updating = false

    var body: some View {
        switch ChatLaunch.subtitle(link: link?.status, connection: app.connection, updating: updating) {
        case .updating:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Updating…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Connection status, Updating")
        case .reconnecting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Reconnecting…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Connection status, Reconnecting")
        case .chatFailed:
            Button {
                link?.retry()
            } label: {
                Label("Not connected", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityLabel("Connection status, Not connected. Hermes refused the session.")
            .accessibilityHint("Double-tap to retry.")
        case .connection:
            ConnectionStatusView()
        }
    }
}

/// Issue #64: the session action dialogs when the screen has a session list.
private struct OptionalSessionActionDialogs: ViewModifier {
    let state: SessionActionState
    let model: SessionListModel?

    func body(content: Content) -> some View {
        if let model {
            content.sessionActionDialogs(state, model: model)
        } else {
            content
        }
    }
}

/// `ChatViewController` in SwiftUI.
struct ChatThreadView: UIViewControllerRepresentable {
    let model: ChatViewModel
    /// Issue #73: the cron run screen. No composer and no tapbacks.
    var readOnly = false

    func makeUIViewController(context _: Context) -> ChatViewController {
        if readOnly { return ChatViewController(model: model, readOnly: true) }
        #if DEBUG
        if let scenario = DemoChatTransport.Scenario.current, scenario.recordsAtLaunch {
            let controller = ChatViewController(model: model, recorder: DemoVoiceRecorder(),
                                                voiceFolder: FileManager.default.temporaryDirectory)
            controller.onFirstAppear = { DemoVoiceRecorder.start(scenario, on: $0.voice) }
            return controller
        }
        if DemoChatTransport.Scenario.current == .catchUpPill {
            // Issue #15: the owner reads older messages, so the catch-up shows the pill.
            let controller = ChatViewController(model: model)
            controller.onFirstAppear = { $0.unpinForDemo() }
            return controller
        }
        if let scenario = DemoChatTransport.Scenario.current, scenario.showsVoiceReplies {
            let controller = ChatViewController(model: model)
            controller.onFirstAppear = { controller in
                if scenario == .voiceReplyText {
                    controller.showReplyText(id: "r2")
                    return
                }
                controller.tapAudio(id: "r2")
                guard scenario == .voiceRepliesPaused else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(9))
                    controller.tapAudio(id: "r2")
                }
            }
            return controller
        }
        if let scenario = DemoChatTransport.Scenario.current,
           [.markdownTableTop, .markdownBlocksTop, .markdownSheet].contains(scenario) {
            // Issue #56: the top of the Markdown reply, or its full text in the sheet.
            let controller = ChatViewController(model: model)
            controller.onFirstAppear = { controller in
                if scenario == .markdownSheet {
                    controller.showReplyText(id: "m2")
                } else {
                    controller.scrollToMessageForDemo(id: "m2")
                }
            }
            return controller
        }
        if DemoChatTransport.Scenario.current == .keyboard {
            // Issue #60: the keyboard is up over the thread.
            let controller = ChatViewController(model: model)
            controller.onFirstAppear = { _ = $0.messageInputBar.inputTextView.becomeFirstResponder() }
            return controller
        }
        if DemoChatTransport.Scenario.current == .audioTranscripts {
            // Issue #50: a fake engine. The runs start when the audio bubbles are ready.
            let controller = ChatViewController(model: model)
            controller.audioTranscripts = ReceivedAudioTranscripts(files: model.receivedFiles,
                                                                   transcribe: AudioTranscriptDemo.transcribe)
            controller.onFirstAppear = { AudioTranscriptDemo.start($0.audioTranscripts) }
            return controller
        }
        if DemoChatTransport.Scenario.current == .receivedFiles {
            // The ring and the error show with no tap: start those 2 downloads.
            for file in ReceivedFileDemo.startedFiles { model.receivedFiles.load(file) }
        }
        if DemoChatTransport.Scenario.current == .receivedFilesPreview {
            let controller = ChatViewController(model: model)
            controller.onFirstAppear = { controller in
                controller.perform(.open, on: ReceivedFileDemo.previewFile, from: controller.view)
            }
            return controller
        }
        if DemoChatTransport.Scenario.current == .tapbacksPicker {
            let controller = ChatViewController(model: model)
            controller.onFirstAppear = { controller in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    controller.showTapbackPicker(messageId: DemoChatTransport.tapbackPickerId)
                }
            }
            return controller
        }
        if let demo = QuoteDemo.current {
            // Issue #17: the quote screenshots.
            let controller = ChatViewController(model: model)
            controller.onFirstAppear = { demo.run(on: $0) }
            return controller
        }
        #endif
        return ChatViewController(model: model)
    }

    func updateUIViewController(_: ChatViewController, context _: Context) {}

    /// Issue #87: the owner left the chat. A transcription that nobody sees stops.
    static func dismantleUIViewController(_ controller: ChatViewController, coordinator _: ()) {
        controller.chatClosed()
    }
}

/// A transport with no server: every send fails with "Not Delivered". Previews, tests and the DEBUG
/// fallback use it. Release builds use `LiveChatTransport`, which also fails sends while not connected.
struct OfflineChatTransport: ChatTransport, SessionsTransport {
    struct NotConnected: Error {}

    let events: AsyncStream<GatewayClientEvent> = AsyncStream { _ in }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        throw NotConnected()
    }

    func resumeSession(storedId _: String, source _: String) async throws -> ChatSessionRef {
        throw NotConnected()
    }

    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? {
        throw NotConnected()
    }

    func stopReply(sessionId _: String) async throws -> Bool { false }

    func history(sessionId _: String) async throws -> [TranscriptMessage] {
        throw NotConnected()
    }

    func fetchSessions() async throws -> [SessionListItem] {
        throw NotConnected()
    }

    func fetchMostRecentSessionId() async throws -> String? { nil }
}

struct ChatScreen_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ChatScreen(model: ChatViewModel(transport: OfflineChatTransport()))
        }
        .environment(AppModel.preview(setUp: true))
    }
}

/// Makes the chat model at launch. DEBUG builds with `HERMES_DEMO` set use the demo conversation.
@MainActor
enum ChatLaunch {
    enum Subtitle: Equatable {
        /// The #3 and #4 connection status.
        case connection
        case reconnecting
        case chatFailed
        /// Issue #15: connected, and the chat merges the missed messages.
        case updating
    }

    /// The SSH and serve stages win when they fail (Offline, Not connected). Else the chat link state shows.
    static func subtitle(link: ChatLinkStatus?, connection: AppModel.ConnectionState,
                         updating: Bool = false) -> Subtitle {
        switch connection {
        case .offline, .notStarted, .hostKeyChanged: return .connection
        case .idle, .connecting, .startingHermes, .connected: break
        }
        switch link {
        case .reconnecting: return .reconnecting
        case .failed: return .chatFailed
        default: break
        }
        if updating, case .connected = connection { return .updating }
        return .connection
    }

    /// The Release chat link. `renew` asks #4 for a new Hermes session after a stale token.
    static func makeLink(renew: @escaping @MainActor () async -> Void) -> LiveChatTransport {
        let link = LiveChatTransport()
        link.onStaleToken = renew
        return link
    }

    #if DEBUG
    static var demoScenario: DemoChatTransport.Scenario? { DemoChatTransport.Scenario.current }
    #endif

    static var isDemo: Bool {
        #if DEBUG
        DemoChatTransport.Scenario.current != nil
        #else
        false
        #endif
    }

    /// The Release session list and its cache in Application Support (issue #7).
    /// Issue #84: `cache` is the folder of the active server (`ServerCaches.sessions`).
    static func makeSessions(link: LiveChatTransport, cache: any SessionCacheStore) -> SessionListModel {
        SessionListModel(transport: link, chatTransport: link, cache: cache,
                         transcription: OnDeviceTranscription.shared.transcription)
    }

    /// The session list of a window with no app model (previews, tests). Nothing connects.
    static func makeOfflineSessions() -> SessionListModel {
        SessionListModel(transport: OfflineChatTransport(), chatTransport: OfflineChatTransport(),
                         cache: InMemorySessionCacheStore())
    }

    /// The route to push at once on launch: the demo chat, or the cached active session.
    /// Issue #36: a new chat that kept a memo comes first, so the owner sees the memo and "Try Again".
    static func cachedLaunchRoute(_ sessions: SessionListModel) -> ChatRoute? {
        #if DEBUG
        if isDemo { return demoLaunchRoute }
        #endif
        if sessions.hasCachedNewChat { return .new(SessionCache.newChatId) }
        // Issue #73, #78: a cron run is not a chat. An older build could save it as the active session.
        guard let id = sessions.cachedActiveChatId else { return nil }
        return .session(id)
    }

    /// The search text of the DEBUG list demo (`HERMES_DEMO_SEARCH`). Empty in Release.
    static var demoSearch: String {
        #if DEBUG
        DemoChatTransport.Scenario.search ?? ""
        #else
        ""
        #endif
    }

    #if DEBUG
    /// The DEBUG demo: a session list with fixture rows. Chat scenarios also seed the demo chat and
    /// push it at launch (`launchRoute`).
    static func makeDemoSessions() -> SessionListModel {
        guard let scenario = DemoChatTransport.Scenario.current else { return makeOfflineSessions() }
        let transport = DemoChatTransport(scenario: scenario)
        // Issue #94: `HERMES_DEMO_MORE` gives two chats the blue dot.
        let rows = scenario.hasListRows ? ChatsMoreDemo.rows(DemoChatTransport.sessionRows()) : []
        let active = scenario.showsList || scenario == .empty ? nil : DemoChatTransport.storedId
        let cache = InMemorySessionCacheStore(sessions: rows, activeSessionId: active)
        let sessions = SessionListModel(transport: transport, chatTransport: transport, cache: cache)
        if scenario == .approvalsList, let first = rows.first {
            // Issue #104: the first chat waits for an approval, so its row shows "Approval needed".
            let waiting = ChatViewModel(transport: transport, storedSessionId: first.id, title: first.title,
                                        messages: DemoChatTransport.approvalMessages(now: Date(), done: false))
            sessions.register(waiting, for: first.id)
        }
        guard !scenario.showsList, scenario != .empty else { return sessions }
        let seeds = QuoteDemo.messages(transport.seedMessages(now: scenario.catchesUp ? DemoChatTransport.seedDate : Date()))
        let model = ChatViewModel(transport: transport, storedSessionId: DemoChatTransport.storedId,
                                  title: "Calendar and logs", messages: seeds, cache: cache)
        sessions.register(model, for: DemoChatTransport.storedId)
        if scenario == .outboxSent {
            // Issue #39: the link comes back. The outbox sends the queued messages in order.
            Task {
                try? await Task.sleep(for: .seconds(1))
                model.sendQueued()
            }
        }
        if let prompt = scenario.autoPrompt {
            Task {
                try? await Task.sleep(for: .seconds(1))
                model.send(prompt)
            }
        }
        return sessions
    }

    /// The route that a demo pushes at launch: the seeded chat, or a new chat for `empty`.
    static var demoLaunchRoute: ChatRoute? {
        guard let scenario = DemoChatTransport.Scenario.current else { return nil }
        if scenario == .archived { return .archived }
        guard !scenario.showsList else { return nil }
        return scenario == .empty ? .new("demo") : .session(DemoChatTransport.storedId)
    }
    #endif
}

/// Issue #15: the text of the "New Messages" pill.
enum ChatNewMessages {
    static func title(_ count: Int) -> String {
        count == 1 ? "1 New Message" : "\(count) New Messages"
    }

    /// VoiceOver reads it once after the update.
    static func spoken(_ count: Int) -> String {
        count == 1 ? "1 new message" : "\(count) new messages"
    }
}
