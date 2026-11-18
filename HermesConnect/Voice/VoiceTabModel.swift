import HermesKit
import Observation
import UIKit

/// Issue #101: the state of the Voice tab and the mini bar. It owns one #96 voice session at a time and the
/// target chat choice. The loop logic stays in `VoiceModeController`.
/// Issue #102: it also owns one #98 live session (`LiveModeSessionModel`) in the Live mode. The live logic stays
/// in `LiveModeController`.
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
    /// Issue #102: the picker choice of this server. It stays Hands-Free while Live is not available.
    private(set) var chosenMode: VoiceTabMode = .handsFree
    /// Issue #102: the last `voice-live/status` answer of the active server.
    private(set) var liveAvailability: LiveAvailability = .checking
    /// Issue #102: the live session that runs, or that failed ("Try Again"). `nil` in Hands-Free.
    private(set) var live: LiveModeSessionModel?
    /// Issue #102: the toast after a live session ends ("Live Mode Ended, 4:12").
    private(set) var liveToast: String?
    /// Issue #102: the owner refused the microphone. The tab shows "Microphone Access Off".
    var liveMicrophoneDenied = false
    @ObservationIgnored private var seenLiveEnd = 0
    /// Issue #121: the Hermes prompts of the session chat, shown and spoken on the tab. `nil` while no session runs.
    private(set) var prompts: VoicePromptCoordinator?
    @ObservationIgnored private let makePromptVoice: @MainActor () -> any VoicePromptVoice

    @ObservationIgnored let sessions: SessionListModel
    @ObservationIgnored private let makeSession: @MainActor () -> VoiceModeSessionModel?
    @ObservationIgnored private let store: VoiceTargetStore
    @ObservationIgnored private let modeStore: VoiceTabModeStore
    @ObservationIgnored private let liveService: (any LiveModeService)?
    @ObservationIgnored private let makeLive: @MainActor (ChatViewModel, any LiveModeService) -> LiveModeSessionModel
    @ObservationIgnored private var server: UUID?

    /// - Parameters:
    ///   - makeSession: a new voice session for the active server. `nil` when there is no link (DEBUG demo).
    ///   - liveService: the `voice-live` calls (#97). `nil`: Live is not available.
    ///   - makeLive: a new live session in a chat. Tests give a fake connection. No test opens a real session.
    ///   - makePromptVoice: issue #121, on-device speech and STT for prompt lines. Tests give a fake.
    init(sessions: SessionListModel, store: VoiceTargetStore = VoiceTargetStore(),
         modeStore: VoiceTabModeStore = VoiceTabModeStore(), liveService: (any LiveModeService)? = nil,
         makeSession: @escaping @MainActor () -> VoiceModeSessionModel? = { nil },
         makeLive: @escaping @MainActor (ChatViewModel, any LiveModeService) -> LiveModeSessionModel = {
             LiveModeSessionModel(hermes: $0, service: $1)
         },
         makePromptVoice: @escaping @MainActor () -> any VoicePromptVoice = { OnDevicePromptVoice() }) {
        self.makePromptVoice = makePromptVoice
        self.sessions = sessions
        self.store = store
        self.modeStore = modeStore
        self.liveService = liveService
        self.makeLive = makeLive
        self.makeSession = makeSession
        target = store.load(server: nil)
        chosenMode = modeStore.load(server: nil)
        if liveService == nil { liveAvailability = .failed }
    }

    /// The live app: a session on the chat link. While VoiceOver runs, only Magic Tap interrupts a reply.
    static func live(sessions: SessionListModel, link: LiveChatTransport?) -> VoiceTabModel {
        VoiceTabModel(sessions: sessions, liveService: link.map { $0 as any LiveModeService }) {
            guard let link else { return nil }
            var tuning = VoiceModeTuning()
            tuning.autoBargeIn = !UIAccessibility.isVoiceOverRunning
            return VoiceModeSessionModel(speech: link, tuning: tuning)
        }
    }

    var controller: VoiceModeController? { session?.controller }
    var state: VoiceModeState { controller?.state ?? .idle }
    /// Issue #102: the live engine of the live session.
    var liveController: LiveModeController? { live?.controller }
    /// `true` from start to end. The mini bar shows on the other tabs.
    var isRunning: Bool { state.isActive || isLiveRunning }
    /// Issue #102: a live session runs (also "Live mode stopped", until End or Try Again).
    var isLiveRunning: Bool { liveController?.isActive ?? false }
    var liveElapsed: Int { liveController?.elapsedSeconds ?? 0 }

    /// The segment that shows as on. Live only when the server has it.
    var mode: VoiceTabMode { chosenMode == .live && liveAvailability.isAvailable ? .live : .handsFree }
    var level: Float { controller?.level ?? 0 }
    var bargeInCount: Int { controller?.bargeInCount ?? 0 }
    var clipEndCount: Int { controller?.clipEndCount ?? 0 }

    /// Issues #120 and #129: the line under the ring shows the last tool of the turn in the session chat.
    var display: VoiceTabDisplay { withPrompt(loopDisplay(tool: sessionChat?.toolActivity)) }
    /// Issue #120: the mini bar does not show the tool.
    var miniBarDisplay: VoiceTabDisplay { withPrompt(loopDisplay(tool: nil)) }

    /// Issue #121: a card waits. The title says so, the ring follows the prompt step, and Mute is off.
    private func withPrompt(_ display: VoiceTabDisplay) -> VoiceTabDisplay {
        guard let prompts, prompts.item != nil else { return display }
        return .prompt(prompts.phase, over: display)
    }

    /// Issue #121: the card that waits on the tab, and its step.
    var promptItem: VoicePromptItem? { prompts?.item }
    var promptPhase: VoicePromptPhase { prompts?.phase ?? .waiting }

    private func loopDisplay(tool: ChatToolActivity?) -> VoiceTabDisplay {
        if let live = liveController, let display = VoiceTabDisplay.live(
            phase: live.phase, muted: live.muted, speaking: live.speaking, idleWarning: live.idleWarning,
            stillWorking: live.stillWorking, failure: live.failure, tool: tool) {
            return display
        }
        let afterBargeIn = clipEndsAtBargeIn != nil && clipEndsAtBargeIn == controller?.clipEndCount
        return VoiceTabDisplay.make(state: state, muted: controller?.muted ?? false,
                                    thinkingSeconds: controller?.thinkingSeconds ?? 0, afterBargeIn: afterBargeIn,
                                    tool: tool)
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
        chosenMode = modeStore.load(server: id)
        liveAvailability = liveService == nil ? .failed : .checking
    }

    // MARK: Live mode (issue #102)

    /// "Hands-Free | Live". A change ends the current session. Live is not selectable while it is not available.
    func select(_ mode: VoiceTabMode) {
        guard mode != self.mode else {
            // Live shows as Hands-Free while it is not available. A tap on Hands-Free keeps Hands-Free.
            chosenMode = mode
            modeStore.save(mode, server: server)
            return
        }
        guard mode == .handsFree || liveAvailability.isAvailable else { return }
        if isLiveRunning { endLive(.modeChange) } else { end() }
        chosenMode = mode
        modeStore.save(mode, server: server)
    }

    /// `GET /api/audio/voice-live/status`. A failure or no link makes the segment dim.
    func refreshLiveStatus() async {
        guard let liveService else {
            liveAvailability = .failed
            return
        }
        let server = server
        let result: LiveAvailability
        do {
            result = LiveAvailability(status: try await liveService.voiceLiveStatus())
        } catch {
            result = .failed
        }
        // A switch while the call ran: the answer belongs to the old server.
        guard server == self.server else { return }
        liveAvailability = result
    }

    private func startLive(in chat: ChatViewModel) async {
        guard let liveService else { return }
        let live = makeLive(chat, liveService)
        self.live = live
        sessionChat = chat
        liveToast = nil
        seenLiveEnd = live.controller.lastEnd?.serial ?? 0
        await live.start()
        if live.controller.isActive { startPrompts(chat, hold: live.controller) }
        // The gate refreshed the status. A server that turned Live off shows it in the picker.
        if let status = live.status { liveAvailability = .init(status: status) }
        if live.isOlderServer { liveAvailability = .olderServer }
        if live.microphoneDenied { liveMicrophoneDenied = true }
        // The gate or the microphone refused: no session runs.
        if !live.controller.isActive { self.live = nil }
    }

    /// Ends the live session at once. The toast shows "Live Mode Ended, m:ss".
    func endLive(_ reason: LiveModeEndReason = .hangUp) {
        guard let live else { return }
        stopPrompts()
        live.end(reason)
        noteLiveEnd()
        if !live.controller.isActive { self.live = nil }
    }

    /// The view calls it when the live phase changes: the engine also ends by itself (idle, background, server).
    func noteLiveEnd() {
        guard let end = liveController?.lastEnd, end.serial != seenLiveEnd else { return }
        seenLiveEnd = end.serial
        liveToast = end.toast
    }

    func clearLiveToast() { liveToast = nil }

    /// The view calls it when the live session is no longer active: the model drops it.
    func liveDidStop() {
        stopPrompts()
        noteLiveEnd()
        if let live, !live.controller.isActive { self.live = nil }
    }

    // MARK: Commands

    func start() async {
        guard !isRunning else { return }
        if mode == .live {
            await startLive(in: targetChat())
            return
        }
        let chat = targetChat()
        guard let session = makeSession() else { return }
        self.session = session
        sessionChat = chat
        clipEndsAtBargeIn = nil
        seenBargeIns = 0
        await session.start(in: chat)
        if session.controller.state.isActive { startPrompts(chat, hold: session.controller) }
    }

    // MARK: Prompts (issue #121)

    private func startPrompts(_ chat: ChatViewModel, hold: any VoicePromptHolding) {
        let prompts = self.prompts ?? VoicePromptCoordinator(voice: makePromptVoice())
        prompts.onStop = { [weak self] in self?.end() }
        self.prompts = prompts
        prompts.start(chat: chat, hold: hold)
    }

    /// The session ended: the card hides from the tab. The chat keeps it.
    func stopPrompts() {
        prompts?.stop()
    }

    /// A tap on a choice of the approval card on the tab.
    func answerPrompt(_ choice: ApprovalChoice) {
        guard let id = promptItem?.id else { return }
        sessionChat?.answerApproval(id: id, choice: choice)
        prompts?.refresh()
    }

    /// Send on a secret or a password card. The value goes from the field to the chat, and nowhere else.
    func sendPrompt(value: String) {
        guard let id = promptItem?.id else { return }
        sessionChat?.answerPrompt(id: id, value: value)
        prompts?.refresh()
    }

    func sendPrompt(typed: [String: String]) {
        guard let id = promptItem?.id else { return }
        sessionChat?.answerClarify(id: id, typed: typed)
        prompts?.refresh()
    }

    func cancelPrompt() {
        guard let id = promptItem?.id else { return }
        sessionChat?.cancelPrompt(id: id)
        prompts?.refresh()
    }

    private func targetChat() -> ChatViewModel {
        let chat: ChatViewModel
        switch target {
        case .active:
            chat = activeSessionId.map(sessions.chat(for:)) ?? sessions.newChat(key: Self.newChatKey())
        case .new:
            chat = sessions.newChat(key: Self.newChatKey())
        case .chosen(let id, _, _):
            chat = sessions.chat(for: id)
        }
        return chat
    }

    /// End: the microphone closes and the audio session is released. In Live, the live session ends.
    func end() {
        stopPrompts()
        if live != nil {
            endLive(.hangUp)
            return
        }
        controller?.end()
    }

    func toggleMute() {
        if let liveController, isLiveRunning {
            liveController.toggleMute()
            return
        }
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

    func ringTap() async {
        // Issue #121: the card takes the answer. A tap on the ring does nothing while it shows.
        if promptItem != nil { return }
        if let liveController, isLiveRunning {
            if VoiceTabDisplay.liveRingTap(liveController.phase) == .resume { await tryAgainLive() }
            return
        }
        await perform(VoiceTabDisplay.ringTap(state))
    }

    /// Live: Magic Tap mutes. Idle in Live mode: it starts a session.
    func magicTap() async {
        if promptItem != nil { return }
        if isLiveRunning {
            toggleMute()
            return
        }
        await perform(VoiceTabDisplay.magicTap(state))
    }

    private func tryAgainLive() async {
        guard let live else { return }
        await live.start()
    }

    func run(_ action: VoiceTabAction) {
        if isLiveRunning, action == .tryAgain {
            Task { await tryAgainLive() }
            return
        }
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
