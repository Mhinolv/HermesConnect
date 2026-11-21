import AVFoundation
import Foundation
import HermesKit
import MediaPlayer
import SwiftUI
import Testing
import UIKit
@testable import HermesConnect

// Issue #101: the Voice tab. Fakes only: no test opens the microphone, plays audio or reaches a server.

@MainActor
private final class FakeMic: VoiceModeMicrophone {
    var access: VoiceModeMicrophoneAccess = .granted
    private(set) var activations = 0
    private(set) var deactivations = 0
    private(set) var isOpen = false

    func requestAccess() async -> Bool { true }
    func activate() throws { activations += 1 }
    func deactivate() { deactivations += 1 }
    func startClip(url _: URL) throws { isOpen = true }
    func stopClip() -> TimeInterval {
        isOpen = false
        return 1
    }
    func discardClip() { isOpen = false }
    func level() -> Float { -60 }
}

private final class SilentPlayer: StreamedSpeechPlaying, @unchecked Sendable {
    func begin(sampleRate _: Double) throws {}
    func enqueue(_: Data) {}
    func drain() async {}
    func playClip(_: SpokenAudio) async throws {}
    func stop() {}
}

private struct NoSpeech: Error {}

@MainActor
@Suite struct VoiceTabUITests {
    private func rig(suite: String = "voice-tab-\(UUID().uuidString)") -> (VoiceTabModel, FakeMic) {
        let mic = FakeMic()
        let model = VoiceTabModel(sessions: ChatLaunch.makeOfflineSessions(), store: VoiceTargetStore(suite: suite)) {
            VoiceModeSessionModel(controller: VoiceModeController(
                microphone: mic, player: SilentPlayer(), makeSpeech: { _ in throw NoSpeech() },
                makeClipURL: { FileManager.default.temporaryDirectory.appending(path: "voice-tab-\(UUID()).m4a") },
                removeFile: { _ in }, autoTick: false))
        }
        return (model, mic)
    }

    @Test func aTapOnTheRingStartsTheLoopAndEndReleasesTheMicrophone() async throws {
        let (model, mic) = rig()
        #expect(model.display.title == "Tap to Talk")
        #expect(!model.isRunning)
        await model.ringTap()
        #expect(model.state == .listening)
        #expect(model.isRunning)
        #expect(model.display.isSession)
        #expect(mic.activations == 1)
        #expect(mic.isOpen)
        // A new chat starts when the owner speaks: no chat exists yet.
        #expect(model.targetTitle == "New Chat")
        // A tap while listening does not end the clip. Magic Tap does.
        await model.ringTap()
        #expect(model.state == .listening)
        model.toggleMute()
        #expect(model.state == .muted)
        #expect(model.display.muteOn)
        #expect(!mic.isOpen)
        model.toggleMute()
        #expect(model.state == .listening)
        model.end()
        #expect(model.state == .ended(.end))
        #expect(!model.isRunning)
        #expect(!mic.isOpen)
        #expect(mic.deactivations == 1)
        #expect(model.display.title == "Tap to Talk")
    }

    /// Issue #151: the chat of a running Hands-Free session counts as open. After the end it does not.
    @Test func theRunningSessionChatIsTheVoiceChatOfTheList() async throws {
        let (model, _) = rig()
        #expect(model.sessions.voiceChat?() == nil)
        await model.ringTap()
        #expect(model.isRunning)
        #expect(model.sessions.voiceChat?() != nil)
        model.end()
        #expect(model.sessions.voiceChat?() == nil)
    }

    /// Issue #138: background and Lock no longer pause (owner decision). The mic stays open in the session.
    @Test func backgroundAndLockDoNotPauseTheSession() async throws {
        let (model, mic) = rig()
        await model.ringTap()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        #expect(model.state == .listening)
        #expect(mic.isOpen)
        #expect(mic.deactivations == 0)
        model.end()
        #expect(!mic.isOpen)
    }

    /// A call still pauses and closes the mic. Resume listens again.
    @Test func aCallPausesAndResumeListensAgain() async throws {
        let (model, mic) = rig()
        await model.ringTap()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        #expect(model.state == .paused(.call))
        #expect(model.display.action == .resume)
        #expect(!mic.isOpen)
        model.run(.resume)
        #expect(model.state == .listening)
        #expect(mic.isOpen)
        model.end()
    }

    @Test func aServerSwitchEndsTheSession() async throws {
        let (model, mic) = rig()
        model.serverChanged(UUID())
        await model.ringTap()
        #expect(model.isRunning)
        model.serverChanged(UUID())
        #expect(!model.isRunning)
        #expect(mic.deactivations == 1)
    }

    @Test func theTargetChoiceStaysAndFollowsTheServer() async throws {
        let suite = "voice-tab-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let home = UUID()
        let (model, _) = rig(suite: suite)
        model.serverChanged(home)
        #expect(model.target == .active)
        #expect(model.targetTitle == "New Chat")
        model.choose(row: SessionListItem(id: "s7", title: "Weekend trip plan"))
        #expect(model.targetTitle == "Weekend trip plan")
        let (again, _) = rig(suite: suite)
        again.serverChanged(home)
        #expect(again.target == .chosen(id: "s7", title: "Weekend trip plan", server: home))
        again.serverChanged(UUID())
        #expect(again.target == .active)
        again.choose(.new)
        #expect(again.targetTitle == "New Chat")
    }

    // MARK: Screenshots (light, dark, AX5). Set TEST_RUNNER_HERMES_SCREENS_DIR to write them.

    @Test func screenshots() throws {
        let folder = ProcessInfo.processInfo.environment["HERMES_SCREENS_DIR"].map { URL(fileURLWithPath: $0) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let app = AppModel.preview(setUp: true, hostKey: .sample)
        app.previewConnection(.connected(gateVersion: "demo"))
        func screen(_ state: VoiceModeState, muted: Bool = false, level: Float = 0, seconds: Int = 0,
                    barge: Bool = false, title: String = "Weekend trip plan") -> some View {
            NavigationStack {
                VoiceScreen(state: VoiceScreenState(
                    display: .make(state: state, muted: muted, thinkingSeconds: seconds, afterBargeIn: barge),
                    level: level, targetTitle: title, activeChatTitle: "Weekend trip plan"))
            }
            .environment(app)
        }
        let states: [(String, AnyView)] = [
            ("01-idle", AnyView(screen(.idle))),
            ("02-listening", AnyView(screen(.listening, level: 0.7))),
            ("03-transcribing", AnyView(screen(.transcribing))),
            ("03-thinking", AnyView(screen(.thinking, seconds: 6))),
            ("03-still-working", AnyView(screen(.thinking, seconds: 12))),
            ("04-speaking", AnyView(screen(.speaking, level: 0.6))),
            ("05-barge-in", AnyView(screen(.listening, level: 0.4, barge: true))),
            ("10-muted", AnyView(screen(.muted, muted: true))),
            ("11-paused", AnyView(screen(.paused(.call)))),
            ("12-error-microphone", AnyView(screen(.error(.microphoneOff)))),
            ("12-error-microphone-unavailable", AnyView(screen(.error(.microphoneUnavailable)))),
            ("12-error-offline", AnyView(screen(.error(.offline)))),
            ("13-ended-silence", AnyView(screen(.ended(.silence)))),
            ("08-choose-chat", AnyView(VoiceChatPicker(rows: [
                SessionListItem(id: "a", title: "Weekend trip plan", preview: "Book the cabin for Friday."),
                SessionListItem(id: "b", title: "Server upgrade", preview: "Disk is at 81 %."),
                SessionListItem(id: "c", title: "Grocery list"),
            ], onPick: { _ in }))),
            ("15-mini-bar", AnyView(miniBar)),
        ]
        for (name, view) in states { try shoot(view, name, folder) }
    }

    private var miniBar: some View {
        VStack(spacing: 12) {
            Spacer()
            ForEach([VoiceModeState.listening, .thinking, .speaking, .muted], id: \.self.debugTitle) { state in
                VoiceMiniBar(display: .make(state: state, muted: state == .muted, thinkingSeconds: 3), level: 0.5)
                    .frame(height: 48)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.horizontal, 20)
            }
            Spacer().frame(height: 100)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private func shoot(_ view: some View, _ name: String, _ folder: URL?) throws {
        for (style, size, suffix) in [(UIUserInterfaceStyle.light, UIContentSizeCategory.large, "light"),
                                      (.dark, .large, "dark"),
                                      (.light, .accessibilityExtraExtraExtraLarge, "ax5")] {
            let image = render(view, style: style, size: size)
            #expect(image.size.width > 0)
            if let folder { try image.pngData()?.write(to: folder.appending(path: "\(name)-\(suffix).png")) }
        }
    }

    private func render(_ view: some View, style: UIUserInterfaceStyle, size: UIContentSizeCategory) -> UIImage {
        let host = UIHostingController(rootView: view)
        host.overrideUserInterfaceStyle = style
        host.traitOverrides.preferredContentSizeCategory = size
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        return image
    }
}

private extension VoiceModeState {
    var debugTitle: String { String(describing: self) }
}
