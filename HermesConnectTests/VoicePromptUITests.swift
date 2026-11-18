import Foundation
import HermesKit
import SwiftUI
import Testing
import UIKit
@testable import HermesConnect

// Issue #121: Hermes prompts on the Voice tab, in Hands-Free and Live. Fakes only: no microphone, no speech, no
// server and no live session. The tests find each control in the accessibility tree of the window, hit-test its
// center, and activate it. They type with `insertText`, the path of the keyboard.

/// A chat transport that records the answers. No network.
private final class FakeVoicePromptTransport: ChatTransport, ServerRequestTransport, @unchecked Sendable {
    let events: AsyncStream<GatewayClientEvent> = AsyncStream { _ in }
    private let lock = NSLock()
    private var _approvals: [(JSONRPCID, ApprovalChoice)] = []
    private var _values: [(JSONRPCID, String)] = []
    private var _clarifies: [(JSONRPCID, [String: String?]?)] = []

    var approvals: [(JSONRPCID, ApprovalChoice)] { lock.withLock { _approvals } }
    var values: [(JSONRPCID, String)] { lock.withLock { _values } }
    var clarifies: [(JSONRPCID, [String: String?]?)] { lock.withLock { _clarifies } }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: "st1")
    }

    func resumeSession(storedId _: String, source _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: "st1")
    }

    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? { 1 }
    func stopReply(sessionId _: String) async throws -> Bool { true }
    func history(sessionId _: String) async throws -> [TranscriptMessage] { [] }

    func answerApproval(requestId: JSONRPCID, choice: ApprovalChoice) async throws {
        lock.withLock { _approvals.append((requestId, choice)) }
    }

    func rejectServerRequest(_: JSONRPCID, code _: Int, message _: String) async throws {}
    func respondApproval(sessionId _: String, choice _: ApprovalChoice, requestId _: String?) async throws -> Int { 1 }
    func acknowledgeApproval(sessionId _: String, requestId _: String) async throws {}
    func pendingApprovals(sessionId _: String) async throws -> [ApprovalRequest] { [] }

    func answerValue(requestId: JSONRPCID, value: String) async throws {
        lock.withLock { _values.append((requestId, value)) }
    }

    func answerClarify(requestId: JSONRPCID, answers: [String: String?]?, outcome _: String) async throws {
        lock.withLock { _clarifies.append((requestId, answers)) }
    }
}

/// The on-device voice, scripted. It records each line.
@MainActor
private final class ScriptedVoice: VoicePromptVoice {
    private(set) var lines: [String] = []
    private(set) var listens = 0
    var answers: [VoicePromptHeard] = []
    /// `false`: a listen waits until `stop()`, so the test taps first.
    var answersAtOnce = true
    private var waiting: CheckedContinuation<VoicePromptHeard, Never>?

    func speak(_ line: String) async { lines.append(line) }

    func listen() async -> VoicePromptHeard {
        listens += 1
        if answersAtOnce, !answers.isEmpty { return answers.removeFirst() }
        return await withCheckedContinuation { waiting = $0 }
    }

    func stop() {
        waiting?.resume(returning: .nothing)
        waiting = nil
    }
}

@MainActor
private final class PromptMic: VoiceModeMicrophone {
    var access: VoiceModeMicrophoneAccess = .granted
    private(set) var isOpen = false
    func requestAccess() async -> Bool { true }
    func activate() throws {}
    func deactivate() {}
    func startClip(url _: URL) throws { isOpen = true }
    func stopClip() -> TimeInterval {
        isOpen = false
        return 1
    }
    func discardClip() { isOpen = false }
    func level() -> Float { -60 }
}

private final class MutePlayer: StreamedSpeechPlaying, @unchecked Sendable {
    func begin(sampleRate _: Double) throws {}
    func enqueue(_: Data) {}
    func drain() async {}
    func playClip(_: SpokenAudio) async throws {}
    func stop() {}
}

private struct NoReplySpeech: Error {}

private final class PromptLiveService: LiveModeService, @unchecked Sendable {
    func voiceLiveStatus() async throws -> VoiceLiveStatus? {
        VoiceLiveStatus(mode: .gptLive, available: true, model: "gpt-live-1", voice: "marin")
    }

    func createVoiceLiveSession(offerSDP _: String, history _: [VoiceLiveHistoryItem]) async throws
        -> VoiceLiveSessionAnswer {
        VoiceLiveSessionAnswer(sessionId: "s", sdp: "answer")
    }
}

@MainActor
private final class PromptConnection: LiveModeConnection {
    var onEvent: (@MainActor (LiveModeLinkEvent) -> Void)?
    var sent: [String] = []
    var muted = false
    var remoteHeld = false
    func makeOffer() async throws -> String { "v=0\r\n" }
    func applyAnswer(_: String) async throws {}
    func send(_ text: String) -> Bool { sent.append(text); return true }
    func setMuted(_ muted: Bool) { self.muted = muted }
    func setRemoteAudioHeld(_ held: Bool) { remoteHeld = held }
    func close() {}
}

/// SwiftUI builds its accessibility tree only for an assistive client. KIF turns on the same switch.
@MainActor private let promptAccessibilityOn: Void = {
    guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
          let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return }
    typealias SetEnabled = @convention(c) (Int32) -> Void
    unsafeBitCast(symbol, to: SetEnabled.self)(1)
}()

@MainActor
private struct PromptScreen {
    let window: UIWindow
    let host: UIViewController

    init(_ view: some View, style: UIUserInterfaceStyle = .light, size: UIContentSizeCategory = .large) {
        _ = promptAccessibilityOn
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

    func close() {
        window.endEditing(true)
        window.isHidden = true
    }

    func settle(_ seconds: TimeInterval = 0.15) async {
        window.layoutIfNeeded()
        try? await Task.sleep(for: .seconds(seconds))
        window.layoutIfNeeded()
    }

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
    func element(_ label: String) -> NSObject? { elements().first { $0.accessibilityLabel == label } }
    func shows(_ text: String) -> Bool { labels().contains { $0.contains(text) } }

    /// The control is on screen, a touch at its center lands in the tab, and the control is enabled.
    func checkHit(_ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> NSObject {
        let element = try #require(self.element(label), "no control \"\(label)\" in \(labels())",
                                   sourceLocation: sourceLocation)
        let frame = element.accessibilityFrame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        #expect(window.bounds.contains(center), "\"\(label)\" is off screen at \(frame)", sourceLocation: sourceLocation)
        #expect(frame.height >= 43.5, "\"\(label)\" is shorter than 44 pt: \(frame)", sourceLocation: sourceLocation)
        let hit = window.hitTest(center, with: nil)
        let inTab = hit.map { $0 === host.view || $0.isDescendant(of: host.view) } ?? false
        #expect(inTab, "a touch on \"\(label)\" at \(center) found \(String(describing: hit))",
                sourceLocation: sourceLocation)
        return element
    }

    func tap(_ label: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let element = try checkHit(label, sourceLocation: sourceLocation)
        #expect(!element.accessibilityTraits.contains(.notEnabled), "\"\(label)\" is disabled",
                sourceLocation: sourceLocation)
        #expect(element.accessibilityActivate(), "\"\(label)\" did not run its action", sourceLocation: sourceLocation)
        await settle()
    }

    func isEnabled(_ label: String) -> Bool? { element(label).map { !$0.accessibilityTraits.contains(.notEnabled) } }

    /// The text field under the center of `label`, after a hit test. The owner taps it, then types.
    func type(_ text: String, into label: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let element = try checkHit(label, sourceLocation: sourceLocation)
        let frame = element.accessibilityFrame
        let field = try #require(textField(at: CGPoint(x: frame.midX, y: frame.midY)),
                                 "no text field under \"\(label)\"", sourceLocation: sourceLocation)
        #expect(field.becomeFirstResponder(), sourceLocation: sourceLocation)
        await settle()
        field.insertText(text)
        await settle()
    }

    private func textField(at point: CGPoint) -> UITextField? {
        var found: UITextField?
        func visit(_ view: UIView) {
            if let field = view as? UITextField, !field.isHidden,
               field.convert(field.bounds, to: window).insetBy(dx: -4, dy: -4).contains(point) {
                found = field
            }
            view.subviews.forEach(visit)
        }
        visit(window)
        return found
    }

    func image() -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}

@MainActor
@Suite(.serialized) struct VoicePromptUITests {
    static let value = "VALUE-77d2 hunter2"

    private struct Rig {
        let model: VoiceTabModel
        let transport: FakeVoicePromptTransport
        let voice: ScriptedVoice
        let mic: PromptMic
        let connection: PromptConnection
        let app: AppModel
    }

    private func rig() -> Rig {
        let suite = "voice-prompt-\(UUID().uuidString)"
        let transport = FakeVoicePromptTransport()
        let sessions = SessionListModel(transport: OfflineChatTransport(), chatTransport: transport,
                                        cache: InMemorySessionCacheStore())
        let voice = ScriptedVoice()
        let mic = PromptMic()
        let connection = PromptConnection()
        let model = VoiceTabModel(
            sessions: sessions, store: VoiceTargetStore(suite: suite), modeStore: VoiceTabModeStore(suite: suite),
            liveService: PromptLiveService(),
            makeSession: {
                VoiceModeSessionModel(controller: VoiceModeController(
                    microphone: mic, player: MutePlayer(), makeSpeech: { _ in throw NoReplySpeech() },
                    makeClipURL: { FileManager.default.temporaryDirectory.appending(path: "vp-\(UUID()).m4a") },
                    removeFile: { _ in }, autoTick: false))
            },
            makeLive: { chat, service in
                LiveModeSessionModel(hermes: chat, service: service, makeConnection: { connection },
                                     requestsMicrophone: { true }, autoTick: false)
            },
            makePromptVoice: { voice })
        model.choose(.chosen(id: "st1", title: "Plans", server: nil))
        let profile = ServerProfile(host: "100.64.0.9", displayName: "Hostinger", hostKey: .sample)
        let app = AppModel.preview(servers: [profile], activeIndex: 0)
        app.previewConnection(.connected(gateVersion: "demo"))
        return Rig(model: model, transport: transport, voice: voice, mic: mic, connection: connection, app: app)
    }

    private func tab(_ rig: Rig) -> some View {
        VoiceTab(model: rig.model).environment(rig.app)
    }

    private func wait(_ screen: PromptScreen, _ until: () -> Bool) async {
        for _ in 0..<100 where !until() { await screen.settle(0.05) }
    }

    private func request(_ id: String, _ method: String, _ json: String) throws -> GatewayClientEvent {
        let params = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return .serverRequest(try GatewayServerRequest(id: .string(id), method: method, params: params))
    }

    private func approval() throws -> GatewayClientEvent {
        try request("srq-1", "approval", #"""
        {"session_id":"s1","request_id":"a1","command":"rm -rf /tmp/cache","description":"Clear the cache","choices":["once","session","deny"]}
        """#)
    }

    private func secret() throws -> GatewayClientEvent {
        try request("srq-2", "secret", #"{"session_id":"s1","env_var":"WEATHER_API_KEY","prompt":"Paste the API key"}"#)
    }

    private func clarify() throws -> GatewayClientEvent {
        try request("srq-3", "clarify", #"""
        {"session_id":"s1","questions":[{"qid":"q1","question":"Which calendar?","choices":["Work","Personal"]}]}
        """#)
    }

    /// Starts Hands-Free in the chat "Plans", and opens its session so server requests reach it.
    private func startHandsFree(_ rig: Rig) async throws -> ChatViewModel {
        await rig.model.start()
        let chat = try #require(rig.model.sessionChat)
        await chat.open()
        return chat
    }

    // MARK: Hands-Free

    @Test func anApprovalShowsOnTheTabAndATapAnswersIt() async throws {
        let rig = rig()
        rig.voice.answersAtOnce = false
        let screen = PromptScreen(tab(rig))
        defer { screen.close() }
        let chat = try await startHandsFree(rig)
        #expect(rig.mic.isOpen)
        chat.receive(try approval())
        await wait(screen) { screen.element("Allow Once") != nil }
        #expect(rig.model.display.title == "Hermes needs an answer")
        #expect(screen.shows("Hermes needs an answer"))
        #expect(screen.shows("Hermes asks for approval"))
        #expect(screen.shows("Clear the cache"))
        #expect(!rig.mic.isOpen, "the loop holds the mic while the card waits")
        #expect(rig.voice.lines == ["Hermes needs your approval. Say allow once, this chat, or deny."])
        #expect(rig.voice.listens == 1, "it listens for a spoken choice")
        #expect(screen.isEnabled("Mute") == false, "Mute is off while the card waits")
        _ = try screen.checkHit("Allow for This Chat")
        _ = try screen.checkHit("Deny")
        try await screen.tap("Allow Once")
        await wait(screen) { !rig.transport.approvals.isEmpty }
        #expect(rig.transport.approvals.map(\.0) == [.string("srq-1")])
        #expect(rig.transport.approvals.map(\.1) == [.once])
        #expect(chat.messages.compactMap(\.approval).first?.state == .answered(.once), "the chat card updates too")
        await wait(screen) { rig.model.promptItem == nil }
        #expect(rig.voice.lines.last == "Allowed once")
        #expect(rig.model.promptItem == nil, "the card hides after 2 s")
        #expect(rig.model.display.title != "Hermes needs an answer")
        rig.model.end()
    }

    @Test func aSpokenChoiceAnswersTheApproval() async throws {
        let rig = rig()
        rig.voice.answers = [.text("deny")]
        let screen = PromptScreen(tab(rig))
        defer { screen.close() }
        let chat = try await startHandsFree(rig)
        chat.receive(try approval())
        await wait(screen) { !rig.transport.approvals.isEmpty }
        #expect(rig.transport.approvals.map(\.1) == [.deny])
        await wait(screen) { rig.model.promptItem == nil }
        #expect(rig.voice.lines.last == "Denied")
        #expect(rig.mic.isOpen == false || rig.model.state == .listening)
        rig.model.end()
    }

    @Test func aClarifyChoiceTakesATapAndSend() async throws {
        let rig = rig()
        rig.voice.answersAtOnce = false
        let screen = PromptScreen(tab(rig))
        defer { screen.close() }
        let chat = try await startHandsFree(rig)
        chat.receive(try clarify())
        await wait(screen) { screen.element("Personal") != nil }
        #expect(rig.voice.lines == ["Hermes has a question. Which calendar? Say Work, or Personal."])
        #expect(screen.isEnabled("Send") == false)
        try await screen.tap("Personal")
        try await screen.tap("Send")
        await wait(screen) { !rig.transport.clarifies.isEmpty }
        #expect(rig.transport.clarifies.first?.1 == ["q1": "Personal"])
        rig.model.end()
    }

    @Test func aSecretIsTypedOnlyAndTheValueNeverReachesTheVoice() async throws {
        let rig = rig()
        let screen = PromptScreen(tab(rig))
        defer { screen.close() }
        let chat = try await startHandsFree(rig)
        chat.receive(try secret())
        await wait(screen) { screen.element("Secret") != nil }
        #expect(rig.voice.lines == ["Hermes needs a secret. Type it on the screen."])
        #expect(rig.voice.listens == 0, "the mic stays closed for a secret")
        #expect(!rig.mic.isOpen)
        #expect(screen.isEnabled("Send") == false, "Send is off while the field is empty")
        _ = try screen.checkHit("Cancel")
        try await screen.type(Self.value, into: "Secret")
        await wait(screen) { screen.isEnabled("Send") == true }
        #expect(screen.element("Mute") == nil && screen.element("End") == nil, "Mute and End hide with the keyboard")
        try await screen.tap("Send")
        await wait(screen) { !rig.transport.values.isEmpty }
        #expect(rig.transport.values.map(\.1) == [Self.value])
        #expect(rig.transport.values.map(\.0) == [.string("srq-2")])
        await wait(screen) { rig.model.promptItem == nil }
        #expect(!rig.voice.lines.contains { $0.contains("hunter2") || $0.contains("VALUE-77d2") })
        #expect(!screen.labels().contains { $0.contains("hunter2") })
        #expect(!String(describing: chat.messages).contains("hunter2"))
        rig.model.end()
    }

    @Test func endHidesTheCardAndKeepsItInTheChat() async throws {
        let rig = rig()
        rig.voice.answersAtOnce = false
        let screen = PromptScreen(tab(rig))
        defer { screen.close() }
        let chat = try await startHandsFree(rig)
        chat.receive(try approval())
        await wait(screen) { screen.element("Allow Once") != nil }
        try await screen.tap("End")
        #expect(!rig.model.isRunning)
        #expect(rig.model.promptItem == nil)
        #expect(chat.waitingPrompts.count == 1, "the chat keeps the card")
    }

    // MARK: Live

    @Test func liveHoldsTheMicAndTheRemoteAudioWhileTheCardWaits() async throws {
        let rig = rig()
        rig.voice.answersAtOnce = false
        let screen = PromptScreen(tab(rig))
        defer { screen.close() }
        await rig.model.refreshLiveStatus()
        rig.model.select(.live)
        await rig.model.start()
        #expect(rig.model.isLiveRunning)
        rig.connection.onEvent?(.connected)
        let chat = try #require(rig.model.sessionChat)
        await chat.open()
        chat.receive(try approval())
        await wait(screen) { screen.element("Allow Once") != nil }
        #expect(rig.connection.muted, "no speech goes to the live model while the card waits")
        #expect(rig.connection.remoteHeld)
        #expect(rig.model.liveController?.promptHold == true)
        #expect(rig.voice.lines == ["Hermes needs your approval. Say allow once, this chat, or deny."])
        #expect(rig.connection.sent.allSatisfy { !$0.contains("approval") }, "the line never goes to the live model")
        try await screen.tap("Deny")
        await wait(screen) { rig.model.promptItem == nil }
        #expect(rig.transport.approvals.map(\.1) == [.deny])
        #expect(!rig.connection.muted, "the mic comes back after the answer")
        #expect(!rig.connection.remoteHeld)
        rig.model.end()
    }

    // MARK: Screenshots (light, dark, AX5). Set TEST_RUNNER_HERMES_SCREENS_DIR to write them.

    @Test func screenshots() async throws {
        let folder = ProcessInfo.processInfo.environment["HERMES_SCREENS_DIR"].map { URL(fileURLWithPath: $0) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let cases: [(String, () throws -> GatewayClientEvent)] = [
            ("approval", approval), ("clarify", clarify), ("secret", secret),
        ]
        for (name, make) in cases {
            for (style, styleName) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
                for (size, sizeName) in [(UIContentSizeCategory.large, "default"), (.accessibilityExtraExtraExtraLarge, "ax5")] {
                    let rig = rig()
                    rig.voice.answersAtOnce = false
                    let screen = PromptScreen(tab(rig), style: style, size: size)
                    let chat = try await startHandsFree(rig)
                    chat.receive(try make())
                    await wait(screen) { rig.model.promptItem != nil }
                    await screen.settle(0.3)
                    #expect(rig.model.promptItem != nil)
                    if let folder {
                        let data = try #require(screen.image().pngData())
                        try data.write(to: folder.appending(path: "voice-prompt-\(name)-\(styleName)-\(sizeName).png"))
                    }
                    rig.model.end()
                    screen.close()
                }
            }
        }
    }
}
