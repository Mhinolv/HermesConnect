import Foundation
import HermesKit
import SwiftUI
import Testing
import UIKit
@testable import HermesConnect

// Issue #102: live mode in the Voice tab. Fakes only: no test opens a live session or reaches a server.
// Each live session costs money. The fake connection makes no peer and the fake service makes no request.
// The tests drive the rendered views: they find each control in the accessibility tree of the window, hit-test
// its center, and activate it. Only the engine events (connected, speech, failure) come from the fake.

private final class FakeLiveService: LiveModeService, @unchecked Sendable {
    private let lock = NSLock()
    private var status: VoiceLiveStatus?
    private var failsStatus = false
    private(set) var statusCalls = 0
    private(set) var offers: [String] = []

    init(_ status: VoiceLiveStatus?, failsStatus: Bool = false) {
        self.status = status
        self.failsStatus = failsStatus
    }

    var offerCount: Int { lock.withLock { offers.count } }
    var statusCount: Int { lock.withLock { statusCalls } }

    func voiceLiveStatus() async throws -> VoiceLiveStatus? {
        try lock.withLock {
            statusCalls += 1
            if failsStatus { throw URLError(.notConnectedToInternet) }
            return status
        }
    }

    func createVoiceLiveSession(offerSDP: String, history _: [VoiceLiveHistoryItem]) async throws
        -> VoiceLiveSessionAnswer {
        lock.withLock { offers.append(offerSDP) }
        return VoiceLiveSessionAnswer(sessionId: "s", sdp: "answer")
    }
}

@MainActor
private final class FakeConnection: LiveModeConnection {
    var onEvent: (@MainActor (LiveModeLinkEvent) -> Void)?
    var sent: [String] = []
    var muted = false
    var closed = false
    func makeOffer() async throws -> String { "v=0\r\n" }
    func applyAnswer(_: String) async throws {}
    func send(_ text: String) -> Bool { sent.append(text); return true }
    func setMuted(_ muted: Bool) { self.muted = muted }
    func close() { closed = true }
}

/// SwiftUI builds its accessibility tree only for an assistive client. KIF turns on the same switch.
@MainActor private let accessibilityOn: Void = {
    guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
          let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return }
    typealias SetEnabled = @convention(c) (Int32) -> Void
    unsafeBitCast(symbol, to: SetEnabled.self)(1)
}()

/// The rendered tab in a window, and its controls as VoiceOver and touch see them.
@MainActor
private struct Screen {
    let window: UIWindow
    let host: UIViewController

    init(_ view: some View, style: UIUserInterfaceStyle = .light, size: UIContentSizeCategory = .large) {
        _ = accessibilityOn
        let host = UIHostingController(rootView: view)
        host.overrideUserInterfaceStyle = style
        host.traitOverrides.preferredContentSizeCategory = size
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        self.host = host
    }

    /// Opens the view and waits until it has drawn.
    static func open(_ view: some View, style: UIUserInterfaceStyle = .light,
                     size: UIContentSizeCategory = .large) async -> Screen {
        let screen = Screen(view, style: style, size: size)
        await screen.settle(0.4)
        return screen
    }

    func close() { window.isHidden = true }

    /// The test gives the main actor back, so view tasks and engine tasks run.
    func settle(_ seconds: TimeInterval = 0.15) async {
        window.layoutIfNeeded()
        try? await Task.sleep(for: .seconds(seconds))
        window.layoutIfNeeded()
    }

    /// Every accessibility element on screen. A container gives its children. A view with no container
    /// gives its subviews. The walk stops at 4,000 objects.
    func elements() -> [NSObject] {
        var found: [NSObject] = []
        var visited = 0
        func visit(_ object: NSObject, depth: Int) {
            visited += 1
            guard depth < 40, visited < 4_000 else { return }
            if object.isAccessibilityElement {
                found.append(object)
                return
            }
            if let children = object.accessibilityElements as? [NSObject], !children.isEmpty {
                children.forEach { visit($0, depth: depth + 1) }
                return
            }
            if let view = object as? UIView {
                view.subviews.filter { !$0.isHidden && $0.alpha > 0.01 }.forEach { visit($0, depth: depth + 1) }
            }
        }
        visit(window, depth: 0)
        return found
    }

    func labels() -> [String] { elements().compactMap(\.accessibilityLabel) }

    func element(_ label: String, prefix: Bool = false) -> NSObject? {
        elements().first { element in
            guard let text = element.accessibilityLabel else { return false }
            return prefix ? text.hasPrefix(label) : text == label
        }
    }

    func shows(_ text: String) -> Bool { labels().contains { $0.contains(text) } }

    /// A tap as the owner makes it: the control is on screen, a touch at its center lands in the tab,
    /// and the control is enabled. Then the control runs its own action.
    func tap(_ label: String, prefix: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let element = try #require(self.element(label, prefix: prefix), "no control \"\(label)\" in \(labels())",
                                   sourceLocation: sourceLocation)
        let frame = element.accessibilityFrame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        #expect(window.bounds.contains(center), "\"\(label)\" is off screen at \(frame)", sourceLocation: sourceLocation)
        #expect(frame.width >= 32 && frame.height >= 32, "\"\(label)\" is too small: \(frame)",
                sourceLocation: sourceLocation)
        let hit = window.hitTest(center, with: nil)
        let inTab = hit.map { $0 === host.view || $0.isDescendant(of: host.view) } ?? false
        #expect(inTab, "a touch on \"\(label)\" at \(center) found \(String(describing: hit))",
                sourceLocation: sourceLocation)
        #expect(!element.accessibilityTraits.contains(.notEnabled), "\"\(label)\" is disabled",
                sourceLocation: sourceLocation)
        #expect(element.accessibilityActivate(), "\"\(label)\" did not run its action", sourceLocation: sourceLocation)
        await settle()
    }

    func isEnabled(_ label: String) -> Bool? {
        element(label).map { !$0.accessibilityTraits.contains(.notEnabled) }
    }

    func image() -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}

@MainActor
@Suite(.serialized) struct VoiceLiveTabUITests {
    private static let on = VoiceLiveStatus(mode: .gptLive, available: true, model: "gpt-live-1", voice: "marin")
    private static let off = VoiceLiveStatus(mode: .chained, available: false)

    private struct Rig {
        let model: VoiceTabModel
        let service: FakeLiveService
        let connection: FakeConnection
        let app: AppModel
    }

    private func rig(_ service: FakeLiveService, server: String = "Hostinger", microphone: Bool = true) -> Rig {
        let suite = "voice-live-\(UUID().uuidString)"
        let connection = FakeConnection()
        let model = VoiceTabModel(
            sessions: ChatLaunch.makeOfflineSessions(), store: VoiceTargetStore(suite: suite),
            modeStore: VoiceTabModeStore(suite: suite), liveService: service,
            makeLive: { chat, service in
                LiveModeSessionModel(hermes: chat, service: service, makeConnection: { connection },
                                     requestsMicrophone: { microphone }, autoTick: false)
            })
        let profile = ServerProfile(host: "100.64.0.9", displayName: server, hostKey: .sample)
        let app = AppModel.preview(servers: [profile], activeIndex: 0)
        app.previewConnection(.connected(gateVersion: "demo"))
        model.serverChanged(profile.id)
        return Rig(model: model, service: service, connection: connection, app: app)
    }

    private func tab(_ rig: Rig) -> some View {
        VoiceTab(model: rig.model).environment(rig.app)
    }

    private func wait(_ screen: Screen, _ until: () -> Bool) async {
        for _ in 0..<100 where !until() { await screen.settle(0.05) }
    }

    // MARK: Picker

    @Test func liveOffOnOuroDimsTheSegmentAndShowsTheReason() async throws {
        let rig = rig(FakeLiveService(Self.off), server: "Ouro")
        let screen = await Screen.open(tab(rig))
        defer { screen.close() }
        await wait(screen) { rig.model.liveAvailability != .checking }
        #expect(rig.service.statusCount >= 1, "the tab asks voice-live/status, state \(rig.model.liveAvailability)")
        #expect(rig.model.liveAvailability == .unavailable(reason: nil))
        #expect(screen.isEnabled("Live") == false, "the Live segment is dim and not selectable")
        #expect(screen.isEnabled("Hands-Free") == true)
        #expect(screen.shows("Live is not available on Ouro."))
        // A tap on the dim segment changes nothing. Hands-Free stays selected.
        _ = screen.element("Live")?.accessibilityActivate()
        await screen.settle()
        #expect(rig.model.mode == .handsFree)
        #expect(screen.element("Hands-Free")?.accessibilityTraits.contains(.selected) == true)
    }

    @Test func aFailedStatusDimsTheSegment() async throws {
        let rig = rig(FakeLiveService(nil, failsStatus: true), server: "Ouro")
        let screen = await Screen.open(tab(rig))
        defer { screen.close() }
        await wait(screen) { rig.model.liveAvailability != .checking }
        #expect(rig.model.liveAvailability == .failed)
        #expect(screen.isEnabled("Live") == false)
        #expect(screen.shows("Live is not available on Ouro."))
    }

    // MARK: A live session, by taps

    @Test func tapsRunALiveSessionFromThePickerToTheEndToast() async throws {
        let rig = rig(FakeLiveService(Self.on))
        let screen = await Screen.open(tab(rig))
        defer { screen.close() }
        await wait(screen) { rig.model.liveAvailability == .available }
        #expect(screen.isEnabled("Live") == true, "the Live segment is on when available: true")
        #expect(!screen.shows("About $0.05 a minute"), "frame 01: no cost line while Hands-Free is on")

        try await screen.tap("Live")
        #expect(rig.model.mode == .live)
        #expect(screen.element("Live")?.accessibilityTraits.contains(.selected) == true)
        #expect(screen.shows("About $0.05 a minute"))

        // A tap on the ring starts the live session in the target chat.
        try await screen.tap("Voice Mode, Tap to Talk")
        await wait(screen) { rig.service.offerCount == 1 }
        #expect(rig.service.offerCount == 1)
        #expect(rig.model.isLiveRunning)
        #expect(rig.model.display.title == "Connecting…")
        #expect(screen.element("Live Mode, Connecting…", prefix: true) != nil)

        rig.connection.onEvent?(.connected)
        await screen.settle()
        #expect(rig.model.display.ring == .listening, "blue while the owner talks")
        #expect(screen.element("Live, 0:00, About $0.05 a minute") != nil, "the live capsule with the cost line")
        #expect(screen.element("Live Mode, Live. Speak any time, 0:00") != nil)
        rig.connection.onEvent?(.speaking(true))
        await screen.settle()
        #expect(rig.model.display.ring == .speaking, "the label color while Hermes talks")
        rig.connection.onEvent?(.speaking(false))

        try await screen.tap("Mute")
        #expect(rig.connection.muted)
        #expect(rig.model.display.title == "Muted")
        try await screen.tap("Mute")
        #expect(!rig.connection.muted)

        // End is `phone.down.fill` in live mode, with its own label.
        #expect(screen.element("End") == nil)
        try await screen.tap("End Live Mode")
        #expect(rig.connection.sent.last == #"{"type":"session.close"}"#)
        #expect(!rig.model.isRunning)
        #expect(rig.model.liveController == nil)
        #expect(rig.model.display.title == "Tap to Talk", "the tab goes back to Idle")
        #expect(screen.shows("Live Mode Ended, 0:00"), "the end toast")
        #expect(rig.model.liveToast == "Live Mode Ended, 0:00")
        #expect(screen.element("Live, 0:00, About $0.05 a minute") == nil, "no capsule after the end")
    }

    @Test func theEngineEndsBySelfAndTheTabShowsTheToast() async throws {
        let rig = rig(FakeLiveService(Self.on))
        let screen = await Screen.open(tab(rig))
        defer { screen.close() }
        await wait(screen) { rig.model.liveAvailability == .available }
        try await screen.tap("Live")
        try await screen.tap("Voice Mode, Tap to Talk")
        await wait(screen) { rig.service.offerCount == 1 }
        rig.connection.onEvent?(.connected)
        await screen.settle()
        // The server closes the session (for example the idle limit).
        rig.connection.onEvent?(.message(#"{"type":"session.closed","reason":"idle_timeout"}"#))
        await screen.settle()
        #expect(!rig.model.isRunning)
        #expect(rig.model.liveController == nil, "the tab drops the ended session")
        #expect(screen.shows("Live Mode Ended, 0:00"))
    }

    @Test func aFailureShowsTryAgainAndTheTapStartsAgain() async throws {
        let rig = rig(FakeLiveService(Self.on))
        let screen = await Screen.open(tab(rig))
        defer { screen.close() }
        await wait(screen) { rig.model.liveAvailability == .available }
        try await screen.tap("Live")
        try await screen.tap("Voice Mode, Tap to Talk")
        await wait(screen) { rig.service.offerCount == 1 }
        rig.connection.onEvent?(.connected)
        rig.connection.onEvent?(.failed)
        await screen.settle()
        #expect(rig.model.display.title == "Live mode stopped")
        #expect(screen.shows("The connection to Live mode was lost."))
        #expect(screen.isEnabled("Mute") == false)
        try await screen.tap("Try Again")
        await wait(screen) { rig.service.offerCount == 2 }
        #expect(rig.service.offerCount == 2)
        #expect(rig.model.display.title == "Connecting…")
        rig.model.end()
    }

    @Test func modeChangeEndsTheSessionAndTheModeStaysForTheServer() async throws {
        let rig = rig(FakeLiveService(Self.on))
        await rig.model.refreshLiveStatus()
        rig.model.select(.live)
        await rig.model.start()
        #expect(rig.model.isLiveRunning)
        let controller = try #require(rig.model.liveController)
        rig.model.select(.handsFree)
        #expect(!controller.isActive)
        #expect(controller.lastEnd?.reason == .modeChange)
        #expect(rig.model.mode == .handsFree)
        rig.model.select(.live)
        // A switch to another server and back: each server keeps its last mode.
        let home = try #require(rig.app.profile?.id)
        rig.model.serverChanged(UUID())
        #expect(rig.model.chosenMode == .handsFree)
        rig.model.serverChanged(home)
        #expect(rig.model.chosenMode == .live)
        #expect(rig.model.mode == .handsFree, "Live waits for the status of this server")
        await rig.model.refreshLiveStatus()
        #expect(rig.model.mode == .live)
        // While the status is not known, Live shows as Hands-Free. A tap on Hands-Free keeps Hands-Free.
        rig.model.serverChanged(UUID())
        rig.model.serverChanged(home)
        rig.model.select(.handsFree)
        await rig.model.refreshLiveStatus()
        #expect(rig.model.mode == .handsFree)
    }

    @Test func microphoneOffStartsNoLiveSession() async throws {
        let rig = rig(FakeLiveService(Self.on), microphone: false)
        await rig.model.refreshLiveStatus()
        rig.model.select(.live)
        await rig.model.start()
        #expect(rig.model.liveMicrophoneDenied)
        #expect(!rig.model.isRunning)
        #expect(rig.model.liveController == nil)
        #expect(rig.service.offerCount == 0)
    }

    @Test func magicTapMutesAndEscapeEnds() async throws {
        let rig = rig(FakeLiveService(Self.on))
        await rig.model.refreshLiveStatus()
        rig.model.select(.live)
        await rig.model.magicTap()
        #expect(rig.model.isLiveRunning, "Magic Tap in Idle starts")
        let screen = await Screen.open(tab(rig))
        defer { screen.close() }
        await wait(screen) { rig.service.offerCount == 1 }
        rig.connection.onEvent?(.connected)
        await screen.settle()
        // VoiceOver sends Magic Tap and Escape to the focused element. The Voice screen takes them.
        let ring = try #require(screen.element("Live Mode, Live", prefix: true))
        #expect(ring.accessibilityPerformMagicTap(), "the screen takes Magic Tap")
        await screen.settle()
        #expect(rig.connection.muted, "Magic Tap mutes in live mode")
        let muted = try #require(screen.element("Live Mode, Muted", prefix: true))
        #expect(muted.accessibilityPerformEscape(), "the screen takes Escape")
        await screen.settle()
        #expect(!rig.model.isRunning, "Escape ends")
        #expect(rig.connection.sent.last == #"{"type":"session.close"}"#)
    }

    // MARK: Mini bar

    @Test func theMiniBarShowsTheLiveTimeAndEnds() async throws {
        let rig = rig(FakeLiveService(Self.on))
        let tab = await Screen.open(tab(rig))
        await wait(tab) { rig.model.liveAvailability == .available }
        try await tab.tap("Live")
        try await tab.tap("Voice Mode, Tap to Talk")
        await wait(tab) { rig.service.offerCount == 1 }
        rig.connection.onEvent?(.connected)
        tab.close()
        let bar = await Screen.open(VoiceMiniBar(display: rig.model.display, liveElapsed: 134, onEnd: { rig.model.end() })
            .frame(height: 48))
        defer { bar.close() }
        #expect(bar.shows("Live 2:14") || bar.element("Live Mode, Live. Speak any time, 2:14") != nil)
        #expect(bar.element("End Voice Mode") == nil)
        try await bar.tap("End Live Mode")
        #expect(!rig.model.isRunning)
        #expect(rig.connection.sent.last == #"{"type":"session.close"}"#)
    }

    // MARK: Screenshots (light, dark, AX5). Set TEST_RUNNER_HERMES_SCREENS_DIR to write them.

    @Test func screenshots() async throws {
        let folder = ProcessInfo.processInfo.environment["HERMES_SCREENS_DIR"].map { URL(fileURLWithPath: $0) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        let ouro = rig(FakeLiveService(Self.off), server: "Ouro")
        await ouro.model.refreshLiveStatus()
        try await shoot(ouro, "01-live-off-ouro", folder)

        let rig = rig(FakeLiveService(Self.on))
        await rig.model.refreshLiveStatus()
        try await shoot(rig, "02-live-selected", folder, select: true)
        rig.model.select(.live)
        rig.model.choose(row: SessionListItem(id: "s7", title: "Weekend trip plan"))
        await rig.model.start()
        try await shoot(rig, "03-connecting", folder)
        for _ in 0..<100 where rig.service.offerCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        rig.connection.onEvent?(.connected)
        try await shoot(rig, "04-live-owner", folder, elapsed: 134)
        rig.connection.onEvent?(.speaking(true))
        try await shoot(rig, "05-live-hermes", folder, elapsed: 134)
        rig.connection.onEvent?(.speaking(false))
        rig.model.toggleMute()
        try await shoot(rig, "06-muted", folder, elapsed: 151)
        rig.model.toggleMute()
        rig.connection.onEvent?(.message(#"{"type":"session.input_transcript.delta","delta":"Check my mail."}"#))
        rig.connection.onEvent?(.message(#"{"type":"session.delegation.created","delegation":{"id":"d1"}}"#))
        try await shoot(rig, "07-hermes-working", folder, elapsed: 160)
        try await shootMiniBar(rig, "11-mini-bar", folder, elapsed: 160)
        rig.connection.onEvent?(.disconnected)
        try await shoot(rig, "08-reconnecting", folder, elapsed: 172)
        rig.connection.onEvent?(.failed)
        try await shoot(rig, "09-error", folder, elapsed: 172)
        rig.model.end()

        let ended = self.rig(FakeLiveService(Self.on))
        await ended.model.refreshLiveStatus()
        ended.model.select(.live)
        await ended.model.start()
        for _ in 0..<100 where ended.service.offerCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        ended.connection.onEvent?(.connected)
        ended.model.end()
        try await shoot(ended, "10-ended-toast", folder, toast: "Live Mode Ended, 4:12")
    }

    private func shoot(_ rig: Rig, _ name: String, _ folder: URL?, select: Bool = false, elapsed: Int? = nil,
                       toast: String? = nil) async throws {
        var state = VoiceScreenState(model: rig.model, server: rig.app.profile?.name)
        if select {
            state.mode = .live
            state.liveLine = rig.model.liveAvailability.line(server: rig.app.profile?.name, selected: true)
        }
        if let elapsed { state.liveElapsed = elapsed }
        // The offline chat has no title yet. The design frames name the chat.
        if state.display.isSession { state.targetTitle = "Weekend trip plan" }
        if let toast { state.toast = toast }
        let view = NavigationStack { VoiceScreen(state: state) }.environment(rig.app)
        for (style, size, suffix) in [(UIUserInterfaceStyle.light, UIContentSizeCategory.large, "light"),
                                      (.dark, .large, "dark"),
                                      (.light, .accessibilityExtraExtraExtraLarge, "ax5")] {
            let screen = await Screen.open(view, style: style, size: size)
            let image = screen.image()
            screen.close()
            #expect(image.size.width > 0)
            if let folder { try image.pngData()?.write(to: folder.appending(path: "\(name)-\(suffix).png")) }
        }
    }

    private func shootMiniBar(_ rig: Rig, _ name: String, _ folder: URL?, elapsed: Int) async throws {
        let live = rig.model.display
        let view = VStack(spacing: 12) {
            Spacer()
            ForEach([134, elapsed], id: \.self) { seconds in
                VoiceMiniBar(display: seconds == elapsed ? live : VoiceTabDisplay.live(
                    phase: .live, muted: false, speaking: false, idleWarning: false, stillWorking: false) ?? live,
                             liveElapsed: seconds)
                    .frame(height: 48)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.horizontal, 20)
            }
            Spacer().frame(height: 100)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        for (style, size, suffix) in [(UIUserInterfaceStyle.light, UIContentSizeCategory.large, "light"),
                                      (.dark, .large, "dark"),
                                      (.light, .accessibilityExtraExtraExtraLarge, "ax5")] {
            let screen = await Screen.open(view, style: style, size: size)
            let image = screen.image()
            screen.close()
            if let folder { try image.pngData()?.write(to: folder.appending(path: "\(name)-\(suffix).png")) }
        }
    }
}
