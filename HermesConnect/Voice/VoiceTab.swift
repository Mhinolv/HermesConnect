import AudioToolbox
import AVKit
import HermesKit
import SwiftUI

/// Issue #101: the Voice tab. It shows the #96 hands-free loop with the Quiet Ring.
struct VoiceTab: View {
    let model: VoiceTabModel
    var link: LiveChatTransport?
    /// Issue #83: the unread chats of the active server, for the server menu.
    var activeUnreadChats = 0
    var onSettings: () -> Void = {}
    @State private var choosing = false

    var body: some View {
        NavigationStack {
            VoiceScreen(state: VoiceScreenState(model: model), link: link, activeUnreadChats: activeUnreadChats,
                        actions: actions)
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
            settings: onSettings)
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
}

extension VoiceScreenState {
    @MainActor init(model: VoiceTabModel) {
        self.init(display: model.display, level: model.level, bargeIns: model.bargeInCount,
                  targetTitle: model.targetTitle, target: model.target, activeChatTitle: model.activeChatTitle)
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
}

/// The Quiet Ring layout: the ring at 40 % of the height, the title, then the controls above the tab bar.
struct VoiceScreen: View {
    var state: VoiceScreenState
    var link: LiveChatTransport?
    var activeUnreadChats = 0
    var actions = VoiceScreenActions()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var display: VoiceTabDisplay { state.display }
    /// AX5: the ring is 160 pt. The keys stay 64 pt.
    private var ringSize: CGFloat { typeSize.isAccessibilitySize ? 160 : 200 }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 8)
                    .frame(maxHeight: max(0, proxy.size.height * 0.4 - (typeSize.isAccessibilitySize ? 160 : 120)
                                           - ringSize / 2))
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
        .background(Color(uiColor: .systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .accessibilityAction(.magicTap, actions.magic)
        .accessibilityAction(.escape, actions.end)
    }

    private var ring: some View {
        Button(action: actions.ring) {
            ZStack {
                QuietRing(style: display.ring, level: state.level, diameter: ringSize)
                if !reduceMotion { BargeInHalo(trigger: state.bargeIns, diameter: ringSize) }
            }
            .frame(width: 240, height: 240)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(display.ringAccessibilityLabel)
        .accessibilityHint(ringHint)
    }

    private var ringHint: String {
        switch display.ring {
        case .idle: "Starts voice mode."
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
                    VoiceKey(title: "End", systemImage: "xmark", tint: .red, action: actions.end)
                }
            }
        } else {
            VStack(spacing: 20) {
                VoiceModePicker()
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

/// "Hands-Free | Live". Live is dim until #102.
struct VoiceModePicker: View {
    var body: some View {
        HStack(spacing: 0) {
            Label("Hands-Free", systemImage: "waveform")
                .fontWeight(.semibold)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .glassEffect(.regular, in: Capsule())
                .accessibilityAddTraits(.isSelected)
            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .foregroundStyle(.tertiary)
                .accessibilityHint("Not available yet.")
        }
        .font(.subheadline)
        .padding(3)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
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
    var onOpen: () -> Void = {}
    var onEnd: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    QuietRing(style: display.ring, level: level, diameter: 28, lineWidth: 2, showsSymbol: false)
                    Text(display.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(display.ringAccessibilityLabel)
            .accessibilityHint("Opens the Voice tab.")
            Button("End", systemImage: "xmark", action: onEnd)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .foregroundStyle(.red)
                .frame(width: 44, height: 44)
                .accessibilityLabel("End Voice Mode")
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
                VoiceMiniBar(display: model.display, level: model.level, onOpen: onOpen, onEnd: { model.end() })
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
