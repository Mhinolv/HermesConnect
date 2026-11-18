import AVFoundation
import Foundation
import HermesKit
import SwiftUI
import Testing
import UIKit
@testable import HermesConnect

// Issue #98: the Live entry, the mode picker and the panel. Fakes only: no test opens a live session.

private final class StatusService: LiveModeService, @unchecked Sendable {
    let lock = NSLock()
    var status: VoiceLiveStatus?
    var offers: [String] = []

    init(_ status: VoiceLiveStatus?) { self.status = status }

    func voiceLiveStatus() async throws -> VoiceLiveStatus? { lock.withLock { status } }

    func createVoiceLiveSession(offerSDP: String, history _: [VoiceLiveHistoryItem]) async throws
        -> VoiceLiveSessionAnswer {
        lock.withLock { offers.append(offerSDP) }
        return VoiceLiveSessionAnswer(sessionId: "s", sdp: "answer")
    }
}

@MainActor
private final class StubConnection: LiveModeConnection {
    var onEvent: (@MainActor (LiveModeLinkEvent) -> Void)?
    var sent: [String] = []
    var closed = false
    func makeOffer() async throws -> String { "v=0\r\n" }
    func applyAnswer(_: String) async throws {}
    func send(_ text: String) -> Bool { sent.append(text); return true }
    func setMuted(_: Bool) {}
    func close() { closed = true }
}

@MainActor
@Suite struct LiveModeUITests {
    private func session(_ service: StatusService, connection: StubConnection, microphone: Bool = true)
        -> (LiveModeSessionModel, ChatViewModel) {
        let chat = ChatViewModel(transport: OfflineChatTransport())
        let model = LiveModeSessionModel(hermes: chat, service: service, makeConnection: { connection },
                                         requestsMicrophone: { microphone })
        return (model, chat)
    }

    private func settle(_ until: () -> Bool) async throws {
        for _ in 0..<300 where !until() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func unavailableStatusStartsNothingAndShowsTheReason() async throws {
        let off = StatusService(VoiceLiveStatus(mode: .chained, available: false, reason: "GPT-Live is off on this server."))
        let (model, chat) = session(off, connection: StubConnection())
        _ = chat
        #expect(model.availabilityText == "Not connected")
        await model.start()
        #expect(!model.controller.isActive)
        #expect(off.offers.isEmpty)
        #expect(model.availabilityText == "GPT-Live is off on this server.")
    }

    @Test func olderServerStartsNothing() async throws {
        let older = StatusService(nil)
        let (model, chat) = session(older, connection: StubConnection())
        _ = chat
        await model.start()
        #expect(!model.controller.isActive)
        #expect(older.offers.isEmpty)
        #expect(model.availabilityText == "This Hermes version has no Live mode.")
    }

    @Test func availableStatusStartsWithTheCostAndEndCloses() async throws {
        let service = StatusService(VoiceLiveStatus(mode: .gptLive, available: true))
        let connection = StubConnection()
        let (model, chat) = session(service, connection: connection)
        _ = chat
        await model.start()
        #expect(model.availabilityText == "About $0.05 a minute")
        try await settle { !service.offers.isEmpty }
        #expect(service.offers == ["v=0\r\n"])
        connection.onEvent?(.connected)
        #expect(model.controller.display == .live)
        model.end(.hangUp)
        // `session.close` goes out first. The peer closes 500 ms later.
        #expect(connection.sent.last == #"{"type":"session.close"}"#)
        try await settle { connection.closed }
        #expect(connection.closed)
        #expect(model.controller.lastEnd?.toast == "Live Mode Ended, 0:00")
    }

    @Test func backgroundAndPhoneCallEndTheSession() async throws {
        for note in [UIApplication.didEnterBackgroundNotification, AVAudioSession.interruptionNotification] {
            let service = StatusService(VoiceLiveStatus(mode: .gptLive, available: true))
            let connection = StubConnection()
            let (model, chat) = session(service, connection: connection)
            _ = chat
            await model.start()
            try await settle { !service.offers.isEmpty }
            connection.onEvent?(.connected)
            NotificationCenter.default.post(name: note, object: nil, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            try await settle { !model.controller.isActive }
            #expect(model.controller.lastEnd?.reason == (note == AVAudioSession.interruptionNotification
                                                          ? .phoneCall : .background))
            try await settle { connection.closed }
            #expect(connection.closed)
        }
    }

    @Test func microphoneOffStartsNoSession() async throws {
        let service = StatusService(VoiceLiveStatus(mode: .gptLive, available: true))
        let (model, chat) = session(service, connection: StubConnection(), microphone: false)
        _ = chat
        await model.start()
        #expect(model.microphoneDenied)
        #expect(!model.controller.isActive)
        #expect(service.offers.isEmpty)
    }

    // MARK: Screenshots of the plain view (light, dark, AX5). Set TEST_RUNNER_HERMES_SCREENS_DIR to write them.

    @Test func viewScreenshots() async throws {
        let folder = ProcessInfo.processInfo.environment["HERMES_SCREENS_DIR"].map { URL(fileURLWithPath: $0) }
        let off = StatusService(VoiceLiveStatus(mode: .chained, available: false, reason: "GPT-Live is off on this server."))
        let (offModel, offChat) = session(off, connection: StubConnection())
        _ = offChat
        await offModel.refreshStatus()
        try shoot(offModel, "unavailable", folder)

        let service = StatusService(VoiceLiveStatus(mode: .gptLive, available: true))
        let connection = StubConnection()
        let (model, chat) = session(service, connection: connection)
        _ = chat
        await model.refreshStatus()
        try shoot(model, "ready", folder)
        await model.start()
        try shoot(model, "connecting", folder)
        try await settle { !service.offers.isEmpty }
        connection.onEvent?(.connected)
        try shoot(model, "live", folder)
        model.controller.toggleMute()
        try shoot(model, "muted", folder)
        model.controller.toggleMute()
        connection.onEvent?(.message(#"{"type":"session.input_transcript.delta","delta":"Check my mail."}"#))
        connection.onEvent?(.message(#"{"type":"session.delegation.created","delegation":{"id":"d1"}}"#))
        try shoot(model, "working", folder)
        connection.onEvent?(.disconnected)
        try shoot(model, "reconnecting", folder)
        connection.onEvent?(.failed)
        try shoot(model, "error", folder)
        model.end(.hangUp)
        try shoot(model, "ended", folder)
    }

    private func shoot(_ model: LiveModeSessionModel, _ name: String, _ folder: URL?) throws {
        for (style, size, suffix) in [(UIUserInterfaceStyle.light, UIContentSizeCategory.large, "light"),
                                      (.dark, .large, "dark"),
                                      (.light, .accessibilityExtraExtraExtraLarge, "ax5")] {
            let image = render(LiveModeView(model: model), style: style, size: size)
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        return image
    }
}
