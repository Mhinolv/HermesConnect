import AudioToolbox
import AVKit
import HermesKit
import SwiftUI

/// Issue #101: the Voice tab. It shows the #96 hands-free loop with the Quiet Ring.
/// Issue #102: it also shows the #98 live mode (the Live segment of the picker).
struct VoiceTab: View {
    @Bindable var model: VoiceTabModel
    var link: LiveChatTransport?
    /// Issue #83: the unread chats of the active server, for the server menu.
    var activeUnreadChats = 0
    var onSettings: () -> Void = {}
    @State private var choosing = false
    @Environment(AppModel.self) private var app: AppModel?

    /// A new server or a new connection checks `voice-live/status` again.
    private var statusKey: String {
        "\(app?.profile?.id.uuidString ?? "none") \(app?.hermesEndpoint != nil)"
    }

    var body: some View {
        NavigationStack {
            VoiceScreen(state: VoiceScreenState(model: model, server: app?.profile?.name), link: link,
                        activeUnreadChats: activeUnreadChats, actions: actions)
        }
        .task(id: statusKey) { await model.refreshLiveStatus() }
        // Issue #102: the engine also ends by itself (idle, background, a phone call, the server).
        .onChange(of: model.isLiveRunning) { _, running in if !running { model.liveDidStop() } }
        // Issue #121: the loop ended by itself (silence, "stop"): the card hides from the tab.
        .onChange(of: model.isRunning) { _, running in if !running { model.stopPrompts() } }
        // Issue #121: haptic `.warning` when a card shows.
        .sensoryFeedback(.warning, trigger: model.prompts?.shownCount ?? 0)
        .onChange(of: model.liveController?.phase) { _, phase in
            if let phase, let text = VoiceTabDisplay.liveAnnouncement(phase) {
                AccessibilityNotification.Announcement(text).post()
            }
        }
        .onChange(of: model.liveToast) { _, toast in
            if let toast { AccessibilityNotification.Announcement(toast).post() }
        }
        .alert("Microphone Access Off", isPresented: $model.liveMicrophoneDenied) {
            Button("Cancel", role: .cancel) {}
            Button("Open Settings") { model.run(.openSettings) }
        } message: {
            Text("Turn on Microphone for Hermes in Settings to use Live mode.")
        }
        .sheet(isPresented: $choosing) {
            VoiceChatPicker(rows: model.sessions.chatRows) { row in
                model.choose(row: row)
                choosing = false
            } onCancel: {
                choosing = false
            }
        }
        // Barge-in: haptic `.rigid`, and "Reply stopped" until the next clip ends.
        .sensoryFeedback(.impact(flexibility: .rigid), trigger: model.bargeInCount)
        .onChange(of: model.bargeInCount) { model.noteBargeIn() }
        // Issue #96: a clip that ends on silence plays the soft tone.
        .onChange(of: model.clipEndCount) { _, count in if count > 0 { AudioServicesPlaySystemSound(1_113) } }
        // VoiceOver announces Thinking only, so the loop does not hear more speech.
        .onChange(of: model.state) { _, state in
            if let text = VoiceTabDisplay.announcement(state) {
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }

    private var actions: VoiceScreenActions {
        VoiceScreenActions(
            ring: { Task { await model.ringTap() } },
            magic: { Task { await model.magicTap() } },
            mute: { model.toggleMute() },
            end: { model.end() },
            action: { model.run($0) },
            pick: { model.choose($0) },
            choose: { choosing = true },
            settings: onSettings,
            select: { model.select($0) },
            dismissToast: { model.clearLiveToast() },
            prompt: VoicePromptActions(
                choose: { model.answerPrompt($0) },
                sendValue: { model.sendPrompt(value: $0) },
                sendAnswers: { model.sendPrompt(typed: $0) },
                cancel: { model.cancelPrompt() }))
    }
}

/// What the Voice screen draws. Tests build it with no engine.
struct VoiceScreenState {
    var display: VoiceTabDisplay
    var level: Float = 0
    var bargeIns = 0
    var targetTitle: String
    var target: VoiceTarget = .active
    /// The name under "Active Chat". `nil` when there is no chat yet.
    var activeChatTitle: String?
    /// Issue #102: the segment that is on.
    var mode: VoiceTabMode = .handsFree
    var liveAvailable = false
    /// The line under the picker: the cost, or why Live is not available.
    var liveLine: String?
    /// The elapsed time of the live session, in seconds.
    var liveElapsed = 0
    /// The red-dot capsule shows (a live session that has not failed).
    var showsLiveCapsule = false
    /// "Live Mode Ended, 4:12".
    var toast: String?
    /// Issue #121: the Hermes card that waits, and its step.
    var prompt: VoicePromptItem?
    var promptPhase: VoicePromptPhase = .waiting
}

extension VoiceScreenState {
    @MainActor init(model: VoiceTabModel, server: String? = nil) {
        let live = model.liveController
        self.init(display: model.display, level: Self.level(model), bargeIns: model.bargeInCount,
                  targetTitle: model.targetTitle, target: model.target, activeChatTitle: model.activeChatTitle,
                  mode: model.mode, liveAvailable: model.liveAvailability.isAvailable,
                  liveLine: model.liveAvailability.line(server: server, selected: model.mode == .live),
                  liveElapsed: model.liveElapsed,
                  showsLiveCapsule: model.isLiveRunning && live?.phase != .failed,
                  toast: model.liveToast, prompt: model.promptItem, promptPhase: model.promptPhase)
    }

    /// The #98 engine has no audio level. The live ring bends a little, more while Hermes talks.
    @MainActor private static func level(_ model: VoiceTabModel) -> Float {
        guard let live = model.liveController, model.isLiveRunning else { return model.level }
        return live.speaking ? 0.6 : 0.3
    }
}

struct VoiceScreenActions {
    var ring: () -> Void = {}
    var magic: () -> Void = {}
    var mute: () -> Void = {}
    var end: () -> Void = {}
    var action: (VoiceTabAction) -> Void = { _ in }
    var pick: (VoiceTarget) -> Void = { _ in }
    var choose: () -> Void = {}
    var settings: () -> Void = {}
    /// Issue #102: the mode picker.
    var select: (VoiceTabMode) -> Void = { _ in }
    var dismissToast: () -> Void = {}
    /// Issue #121: the buttons and fields of the card.
    var prompt = VoicePromptActions()
}

/// The Quiet Ring layout: the ring at 40 % of the height, the title, then the controls above the tab bar.
struct VoiceScreen: View {
    var state: VoiceScreenState
    var link: LiveChatTransport?
    var activeUnreadChats = 0
    var actions = VoiceScreenActions()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Issue #121: Mute and End hide while the keyboard shows.
    @State private var keyboardShown = false
    @State private var promptEditing = false

    private var display: VoiceTabDisplay { state.display }
    /// AX5: the ring is 160 pt. The keys stay 64 pt.
    /// Issue #121: 96 pt while a card waits.
    private var ringSize: CGFloat { state.prompt != nil ? 96 : (typeSize.isAccessibilitySize ? 160 : 200) }
    private var ringFrame: CGFloat { state.prompt != nil ? 120 : 240 }

    var body: some View {
        content
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
    }

    @ViewBuilder private var content: some View {
        if let prompt = state.prompt {
            promptLayout(prompt)
        } else {
            loopLayout
        }
    }

    /// Issue #121: the 96 pt ring, "Hermes needs an answer", then the card. The controls stay under it.
    private func promptLayout(_ prompt: VoicePromptItem) -> some View {
        VStack(spacing: 0) {
            if state.showsLiveCapsule {
                LiveCapsule(elapsed: state.liveElapsed)
                    .padding(.top, 8)
            }
            ScrollView {
                VStack(spacing: 12) {
                    ring
                    titles
                    VoicePromptCardView(item: prompt, phase: state.promptPhase, actions: promptActions)
                        .id(prompt.id)
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            if !keyboardShown, !promptEditing {
                controls
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 16)
        .background(Color(uiColor: .systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .accessibilityAction(.escape, actions.end)
    }

    private var promptActions: VoicePromptActions {
        var prompt = actions.prompt
        prompt.editing = { promptEditing = $0 }
        return prompt
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The server name with the #83 menu.
        ToolbarItem(placement: .topBarLeading) {
            ServerTitle(title: "Voice", link: link, activeUnreadChats: activeUnreadChats,
                        onManage: actions.settings)
                .fixedSize()
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        ToolbarItem(placement: .topBarTrailing) {
            AudioRoutePicker()
                .frame(width: 32, height: 32)
                .accessibilityLabel("Audio Output")
        }
    }

    private var loopLayout: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if state.showsLiveCapsule {
                    LiveCapsule(elapsed: state.liveElapsed)
                        .padding(.top, 8)
                        .transition(.opacity)
                }
                Spacer(minLength: 8)
                    .frame(maxHeight: max(0, proxy.size.height * 0.4 - (typeSize.isAccessibilitySize ? 160 : 120)
                                           - ringSize / 2 - (state.showsLiveCapsule ? 56 : 0)))
                ring
                titles
                    .padding(.top, typeSize.isAccessibilitySize ? 16 : 28)
                Spacer(minLength: 16)
                // AX5: the keys stay 64 pt, so their names and the picker stop at the first accessibility size.
                controls
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
        }
        .overlay(alignment: .top) {
            if let toast = state.toast {
                LiveEndToast(text: toast, onDismiss: actions.dismissToast)
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.toast)
        .background(Color(uiColor: .systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .accessibilityAction(.magicTap, actions.magic)
        .accessibilityAction(.escape, actions.end)
    }

    private var ring: some View {
        Button(action: actions.ring) {
            ZStack {
                QuietRing(style: display.ring, level: state.level, diameter: ringSize)
                if !reduceMotion { BargeInHalo(trigger: state.bargeIns, diameter: ringSize) }
            }
            .frame(width: ringFrame, height: ringFrame)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(display.isLive ? display.liveAccessibilityLabel(elapsedSeconds: state.liveElapsed)
                            : display.ringAccessibilityLabel)
        .accessibilityHint(ringHint)
    }

    private var ringHint: String {
        if display.isLive { return display.action == .tryAgain ? "Starts Live mode again." : "" }
        return switch display.ring {
        case .idle: state.mode == .live ? "Starts Live mode." : "Starts voice mode."
        case .speaking: "Stops the reply."
        case .paused: "Listens again."
        case .listening, .working, .muted: ""
        }
    }

    private var titles: some View {
        VStack(spacing: 6) {
            Text(display.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            if let subtitle = display.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .monospacedDigit()
            }
            if let action = display.action {
                Button(action.title) { actions.action(action) }
                    .buttonStyle(.glassProminent)
                    .padding(.top, 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: display)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var controls: some View {
        if display.isSession {
            VStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("In").foregroundStyle(.secondary)
                    Text(state.targetTitle).fontWeight(.semibold).lineLimit(1)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                HStack(spacing: 40) {
                    VoiceKey(title: "Mute", systemImage: "mic.slash.fill", isOn: display.muteOn, action: actions.mute)
                        .disabled(!display.muteEnabled)
                        .accessibilityValue(display.muteOn ? "On" : "Off")
                    VoiceKey(title: "End", systemImage: display.isLive ? "phone.down.fill" : "xmark", tint: .red,
                             action: actions.end)
                        .accessibilityLabel(display.isLive ? "End Live Mode" : "End")
                }
            }
        } else {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    VoiceModePicker(mode: state.mode, liveAvailable: state.liveAvailable, onSelect: actions.select)
                    if let line = state.liveLine {
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                targetMenu
            }
        }
    }

    private var targetMenu: some View {
        Menu {
            Button {
                actions.pick(.active)
            } label: {
                Label("Active Chat", systemImage: state.target == .active ? "checkmark" : "bubble.left")
                Text(state.activeChatTitle ?? "No chat yet")
            }
            Button {
                actions.pick(.new)
            } label: {
                Label("New Chat", systemImage: state.target == .new ? "checkmark" : "square.and.pencil")
                Text("Starts when you speak")
            }
            Divider()
            Button("Choose Chat…", systemImage: "list.bullet", action: actions.choose)
        } label: {
            HStack(spacing: 4) {
                Text("To").foregroundStyle(.secondary)
                Text(state.targetTitle).fontWeight(.semibold).foregroundStyle(.primary).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("To \(state.targetTitle)")
        .accessibilityHint("Chooses the chat for voice turns.")
    }
}

/// "Hands-Free | Live". Issue #102: Live is dim and not selectable while the server does not have it.
struct VoiceModePicker: View {
    var mode: VoiceTabMode = .handsFree
    var liveAvailable = false
    var onSelect: (VoiceTabMode) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            segment("Hands-Free", systemImage: "waveform", value: .handsFree)
            segment("Live", systemImage: "dot.radiowaves.left.and.right", value: .live)
                .disabled(!liveAvailable)
                .accessibilityHint(liveAvailable ? "Talks with Hermes in real time." : "Not available on this server.")
        }
        .font(.subheadline)
        .padding(3)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
    }

    private func segment(_ title: String, systemImage: String, value: VoiceTabMode) -> some View {
        let selected = mode == value
        return Button { onSelect(value) } label: {
            Label(title, systemImage: systemImage)
                .fontWeight(selected ? .semibold : .regular)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .contentShape(Capsule())
        }
        .buttonStyle(VoiceSegmentStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One segment of the mode picker: glass when it is on, tertiary when it is off and disabled.
private struct VoiceSegmentStyle: ButtonStyle {
    var selected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .glassEffect(selected ? .regular : .identity, in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Issue #102: the live capsule (top center, glass): red dot, "Live", elapsed `m:ss`. The cost line is under it.
/// The red dot does not blink. AX5: the cost line wraps and never truncates.
struct LiveCapsule: View {
    var elapsed: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(uiColor: .systemRed))
                    .frame(width: 8, height: 8)
                Text(VoiceTabDisplay.liveMiniTitle(elapsedSeconds: elapsed))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .glassEffect(.regular, in: Capsule())
            Text(LiveModeFormat.costCaption)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live, \(LiveModeFormat.elapsed(elapsed)), \(LiveModeFormat.costCaption)")
    }
}

/// Issue #102: "Live Mode Ended, 4:12" after the end. It hides after 3 s, or on a tap.
struct LiveEndToast: View {
    var text: String
    var onDismiss: () -> Void = {}

    var body: some View {
        Button(action: onDismiss) {
            Label(text, systemImage: "phone.down.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Hides the message.")
        .task(id: text) {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}

/// A 64 pt glass key with its name under it.
struct VoiceKey: View {
    var title: String
    var systemImage: String
    var tint: Color?
    var isOn = false
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tint != nil ? Color.white
                                     : isOn ? Color(uiColor: .systemBackground) : Color.primary)
                    .frame(width: 64, height: 64)
                    .glassEffect(glass, in: Circle())
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var glass: Glass {
        if let tint { return .regular.tint(tint).interactive() }
        return isOn ? .regular.tint(Color(uiColor: .label)).interactive() : .regular.interactive()
    }
}

/// A faint gray halo that shrinks out in 0.2 s on a barge-in.
struct BargeInHalo: View {
    var trigger: Int
    var diameter: CGFloat

    var body: some View {
        Circle()
            .stroke(Color(uiColor: .systemGray), lineWidth: 8)
            .frame(width: diameter, height: diameter)
            .keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, value in
                view.scaleEffect(1.2 - 0.2 * value).opacity(0.5 * (1 - value))
            } keyframes: { _ in
                LinearKeyframe(0.0, duration: 0)
                LinearKeyframe(1.0, duration: 0.2)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The audio route button (`AVRoutePickerView`).
struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context _: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_: AVRoutePickerView, context _: Context) {}
}

/// "Choose Chat…": the recent chats.
struct VoiceChatPicker: View {
    var rows: [SessionListItem]
    var onPick: (SessionListItem) -> Void
    var onCancel: () -> Void = {}

    var body: some View {
        NavigationStack {
            List(rows) { row in
                Button { onPick(row) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayTitle).foregroundStyle(.primary).lineLimit(2)
                        if let preview = row.preview, !preview.isEmpty {
                            Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No Chats", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Your recent chats show here."))
                }
            }
            .tint(.primary)
            .navigationTitle("Choose Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            }
        }
    }
}

// MARK: Mini bar

/// The mini bar on Chats and Jobs while voice mode runs: a 28 pt ring, the state and End. A tap opens Voice.
struct VoiceMiniBar: View {
    var display: VoiceTabDisplay
    var level: Float = 0
    /// Issue #102: the elapsed time of a live session. Live shows a red dot and "Live 2:14".
    var liveElapsed: Int?
    var onOpen: () -> Void = {}
    var onEnd: () -> Void = {}

    /// A live session that has not failed.
    private var showsLiveTime: Bool { display.isLive && display.action != .tryAgain }
    private var title: String {
        showsLiveTime ? VoiceTabDisplay.liveMiniTitle(elapsedSeconds: liveElapsed ?? 0) : display.title
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    if showsLiveTime {
                        Circle()
                            .fill(Color(uiColor: .systemRed))
                            .frame(width: 10, height: 10)
                            .frame(width: 28, height: 28)
                    } else {
                        QuietRing(style: display.ring, level: level, diameter: 28, lineWidth: 2, showsSymbol: false)
                    }
                    Text(title)
                        .monospacedDigit()
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(display.isLive ? display.liveAccessibilityLabel(elapsedSeconds: liveElapsed ?? 0)
                                : display.ringAccessibilityLabel)
            .accessibilityHint("Opens the Voice tab.")
            Button("End", systemImage: display.isLive ? "phone.down.fill" : "xmark", action: onEnd)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .foregroundStyle(.red)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(display.isLive ? "End Live Mode" : "End Voice Mode")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
    }
}

extension View {
    /// Issue #101: the mini bar in the tab bar accessory (iOS 26.1 and later).
    func voiceMiniBar(_ model: VoiceTabModel, isEnabled: Bool, onOpen: @escaping () -> Void) -> some View {
        modifier(VoiceMiniBarAccessory(model: model, isEnabled: isEnabled, onOpen: onOpen))
    }
}

private struct VoiceMiniBarAccessory: ViewModifier {
    let model: VoiceTabModel
    var isEnabled: Bool
    var onOpen: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled) {
                VoiceMiniBar(display: model.display, level: VoiceScreenState(model: model).level,
                             liveElapsed: model.isLiveRunning ? model.liveElapsed : nil,
                             onOpen: onOpen, onEnd: { model.end() })
            }
        } else {
            content
        }
    }
}

struct VoiceTab_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            VoiceScreen(state: VoiceScreenState(
                display: .make(state: .listening, muted: false, thinkingSeconds: 0), level: 0.5,
                targetTitle: "Weekend trip plan"))
        }
        .environment(AppModel.preview(setUp: true))
    }
}
