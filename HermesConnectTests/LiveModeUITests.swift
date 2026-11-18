import AVFoundation
import Foundation
import HermesKit
import SwiftUI
import Testing
import UIKit
@testable import HermesConnect

// Issue #98: the status gate and the end rules of `LiveModeSessionModel`. Fakes only: no test opens a live session.
// Issue #102: the Voice tab tests (`VoiceLiveTabUITests`) cover the live views.

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
}
