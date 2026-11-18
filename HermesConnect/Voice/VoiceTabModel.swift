import HermesKit
import Observation
import UIKit

/// Issue #101: the state of the Voice tab and the mini bar. It owns one #96 voice session at a time and the
/// target chat choice. The loop logic stays in `VoiceModeController`.
@MainActor @Observable
final class VoiceTabModel {
    private(set) var session: VoiceModeSessionModel?
    /// The choice of "To <chat>". It stays until the owner changes it.
    private(set) var target: VoiceTarget = .active
    /// The chat of the running session.
    private(set) var sessionChat: ChatViewModel?
    /// The `clipEndCount` at the last barge-in. Listening shows "Reply stopped" until the next clip ends.
    private var clipEndsAtBargeIn: Int?
    private var seenBargeIns = 0

    @ObservationIgnored let sessions: SessionListModel
    @ObservationIgnored private let makeSession: @MainActor () -> VoiceModeSessionModel?
    @ObservationIgnored private let store: VoiceTargetStore
    @ObservationIgnored private var server: UUID?

    /// - Parameter makeSession: a new voice session for the active server. `nil` when there is no link (DEBUG demo).
    init(sessions: SessionListModel, store: VoiceTargetStore = VoiceTargetStore(),
         makeSession: @escaping @MainActor () -> VoiceModeSessionModel? = { nil }) {
        self.sessions = sessions
        self.store = store
        self.makeSession = makeSession
        target = store.load(server: nil)
    }

    /// The live app: a session on the chat link. While VoiceOver runs, only Magic Tap interrupts a reply.
    static func live(sessions: SessionListModel, link: LiveChatTransport?) -> VoiceTabModel {
        VoiceTabModel(sessions: sessions) {
            guard let link else { return nil }
            var tuning = VoiceModeTuning()
            tuning.autoBargeIn = !UIAccessibility.isVoiceOverRunning
            return VoiceModeSessionModel(speech: link, tuning: tuning)
        }
    }

    var controller: VoiceModeController? { session?.controller }
    var state: VoiceModeState { controller?.state ?? .idle }
    /// `true` from start to end. The mini bar shows on the other tabs.
    var isRunning: Bool { state.isActive }
    var level: Float { controller?.level ?? 0 }
    var bargeInCount: Int { controller?.bargeInCount ?? 0 }
    var clipEndCount: Int { controller?.clipEndCount ?? 0 }

    var display: VoiceTabDisplay {
        let afterBargeIn = clipEndsAtBargeIn != nil && clipEndsAtBargeIn == controller?.clipEndCount
        return VoiceTabDisplay.make(state: state, muted: controller?.muted ?? false,
                                    thinkingSeconds: controller?.thinkingSeconds ?? 0, afterBargeIn: afterBargeIn)
    }

    // MARK: Target chat

    /// The chat name of "To <chat>" and "In <chat>".
    var targetTitle: String {
        if isRunning, let chat = sessionChat {
            if let title = chat.title, !title.isEmpty { return title }
            if let id = chat.storedSessionId, let row = sessions.session(id: id) { return row.displayTitle }
            return "New Chat"
        }
        switch target {
        case .active: return activeChatTitle ?? "New Chat"
        case .new: return "New Chat"
        case .chosen(_, let title, _): return title
        }
    }

    /// The name of the chat that "Active Chat" sends to. `nil` when there is no chat yet.
    var activeChatTitle: String? {
        activeSessionId.map { sessions.session(id: $0)?.displayTitle ?? "Active Chat" }
    }

    private var activeSessionId: String? {
        VoiceTargetResolver.activeSessionId(open: sessions.openSessionId, lastActive: sessions.cachedActiveChatId,
                                            rows: sessions.chatRows)
    }

    func choose(_ target: VoiceTarget) {
        self.target = target
        store.save(target)
    }

    func choose(row: SessionListItem) {
        choose(.chosen(id: row.id, title: row.displayTitle, server: server))
    }

    /// Issue #83: a switch ends the session. A chosen chat of another server reads as "Active Chat".
    func serverChanged(_ id: UUID?) {
        guard id != server else { return }
        end()
        server = id
        target = store.load(server: id)
    }

    // MARK: Commands

    func start() async {
        guard !isRunning else { return }
        let chat: ChatViewModel
        switch target {
        case .active:
            chat = activeSessionId.map(sessions.chat(for:)) ?? sessions.newChat(key: Self.newChatKey())
        case .new:
            chat = sessions.newChat(key: Self.newChatKey())
        case .chosen(let id, _, _):
            chat = sessions.chat(for: id)
        }
        guard let session = makeSession() else { return }
        self.session = session
        sessionChat = chat
        clipEndsAtBargeIn = nil
        seenBargeIns = 0
        await session.start(in: chat)
    }

    /// End: the microphone closes and the audio session is released.
    func end() {
        controller?.end()
    }

    func toggleMute() {
        controller?.toggleMute()
    }

    func perform(_ command: VoiceRingCommand) async {
        switch command {
        case .start: await start()
        case .interrupt: controller?.bargeIn()
        case .resume: controller?.resume()
        case .send: controller?.sendClip()
        case .none: break
        }
    }

    func ringTap() async { await perform(VoiceTabDisplay.ringTap(state)) }
    func magicTap() async { await perform(VoiceTabDisplay.magicTap(state)) }

    func run(_ action: VoiceTabAction) {
        switch action {
        case .resume, .tryAgain:
            controller?.resume()
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }

    /// The view calls it when `bargeInCount` changes.
    func noteBargeIn() {
        guard bargeInCount != seenBargeIns else { return }
        seenBargeIns = bargeInCount
        clipEndsAtBargeIn = clipEndCount
    }

    private static func newChatKey() -> String { "voice-\(UUID().uuidString)" }
}
