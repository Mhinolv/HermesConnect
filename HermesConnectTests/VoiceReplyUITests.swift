import Foundation
import HermesKit
import Testing
import UIKit
@testable import HermesConnect

/// A voice turn with no server: transcribe, a voice prompt and speak answer at once (issue #10).
private final class SpeakingTransport: ChatTransport, @unchecked Sendable {
    let events: AsyncStream<GatewayClientEvent> = AsyncStream { _ in }
    private let lock = NSLock()
    private var _speaks = 0
    var speaks: Int { lock.withLock { _speaks } }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: "st1")
    }
    func resumeSession(storedId: String, source _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: storedId)
    }
    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? { 1 }
    func submitVoicePrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? { 2 }
    func transcribe(audio _: Data, mimeType _: String) async throws -> String { "What's next?" }
    func speak(text _: String) async throws -> SpokenAudio {
        lock.withLock { _speaks += 1 }
        return SpokenAudio(data: DemoChatTransport.toneWAV(seconds: 2), mimeType: "audio/wav")
    }
    func stopReply(sessionId _: String) async throws -> Bool { false }
    func history(sessionId _: String) async throws -> [TranscriptMessage] { [] }
}

/// The test bundle, which holds the Ogg Opus fixture (issue #42).
private final class FixtureBundle {}

private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out")
}

@MainActor
@Suite(.serialized) struct VoiceReplyUITests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceReplyUITests")

    /// Issue #36: a reply keeps playing on a locked phone. Background location still uses no mode.
    @Test func infoPlistHasTheAudioBackgroundMode() {
        let modes = Bundle(for: ChatViewController.self).infoDictionary?["UIBackgroundModes"] as? [String] ?? []
        #expect(modes.contains("audio"))
        #expect(!modes.contains("location"))
    }

    private func makeController(_ model: ChatViewModel, autoPlay: Bool = true)
        -> (ChatViewController, FakeVoiceRecorder) {
        let recorder = FakeVoiceRecorder()
        let controller = ChatViewController(model: model, recorder: recorder, voiceFolder: folder)
        controller.autoPlayEnabled = { autoPlay }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        return (controller, recorder)
    }

    private func speakingModel(messages: [ChatMessage] = []) -> (ChatViewModel, SpeakingTransport) {
        let transport = SpeakingTransport()
        let folder = self.folder
        let model = ChatViewModel(transport: transport, messages: messages, loadAudio: { _ in Data("m4a".utf8) },
                                  saveSpeech: { try VoiceReplyFiles.save($0, in: folder) })
        return (model, transport)
    }

    private func voiceTurn(_ model: ChatViewModel) async throws {
        await model.sendVoiceMemo(VoiceMemo(fileURL: folder.appendingPathComponent("m.m4a"), duration: 2,
                                            waveform: [0.5])).value
        let json = #"{"type":"message.complete","session_id":"s1","payload":{"text":"Lunch at noon.","status":"complete"}}"#
        model.receive(.event(try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))))
    }

    private func readyReply() -> [ChatMessage] {
        let audio = VoiceReplyAudio(fileURL: folder.appendingPathComponent("tone.wav"), duration: 2)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? DemoChatTransport.toneWAV(seconds: 2).write(to: audio.fileURL)
        return [
            ChatMessage(id: "u", role: .user, text: "Hi", date: .now, delivery: .delivered,
                        voice: VoiceMemo(fileURL: folder.appendingPathComponent("m.m4a"), duration: 2, waveform: [0.5],
                                         transcript: .done("Hi"))),
            ChatMessage(id: "r", role: .assistant, text: "Lunch at noon.", date: .now, reply: .complete, promptId: "u",
                        spokenReply: .ready(audio)),
        ]
    }

    /// Issue #49 (owner decision): a reply with ready audio is one voice bubble with its text under it.
    @Test func readyReplyIsOneVoiceBubbleWithItsText() throws {
        let (controller, _) = makeController(ChatViewModel(transport: OfflineChatTransport(), messages: readyReply()))
        let collection = controller.messagesCollectionView
        collection.layoutIfNeeded()
        #expect(collection.numberOfSections == 2)
        let cell = try #require(collection.cellForItem(at: IndexPath(item: 0, section: 1)) as? ChatVoiceCell)
        #expect(!cell.waveform.isHidden)
        #expect(cell.seeks)
        #expect(cell.transcriptLabel.text == "Lunch at noon.")
        #expect(cell.transcriptLabel.numberOfLines == 2)
        #expect(cell.accessibilityLabel == "Hermes voice reply, 0:02, Lunch at noon.")
        #expect(cell.accessibilityCustomActions?.map(\.name).prefix(3) == ["Play", "Show Full Text", "Copy"])
    }

    @Test func tapPlaysPausesAndReplaysTheCachedFile() throws {
        let messages = readyReply()
        let url = try #require(messages[1].spokenReply?.audio?.fileURL)
        let (controller, _) = makeController(ChatViewModel(transport: OfflineChatTransport(), messages: messages))
        controller.tapAudio(id: "r")
        #expect(controller.playerURL == url)
        #expect(controller.playerIsPlaying)
        controller.tapAudio(id: "r")
        #expect(controller.playerURL == url)
        #expect(!controller.playerIsPlaying)
        controller.tapAudio(id: "r")
        #expect(controller.playerIsPlaying)
        // A new recording stops the playback.
        controller.voice.startTapMode()
        #expect(controller.playerURL == nil)
        controller.voice.cancel()
    }

    @Test func voiceTurnReplyAutoPlaysOnce() async throws {
        let (model, transport) = speakingModel()
        let (controller, _) = makeController(model)
        try await voiceTurn(model)
        try await waitUntil { controller.playerURL != nil }
        #expect(controller.playerURL == model.messages.last?.spokenReply?.audio?.fileURL)
        #expect(transport.speaks == 1)
    }

    @Test func autoPlayOffDoesNotPlay() async throws {
        let (model, _) = speakingModel()
        let (controller, _) = makeController(model, autoPlay: false)
        try await voiceTurn(model)
        try await waitUntil { model.messages.last?.spokenReply?.audio != nil }
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.playerURL == nil)
    }

    @Test func noAutoPlayWhileRecording() async throws {
        let (model, _) = speakingModel()
        let (controller, _) = makeController(model)
        controller.voice.startTapMode()
        try await voiceTurn(model)
        try await waitUntil { model.messages.last?.spokenReply?.audio != nil }
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.playerURL == nil)
        controller.voice.cancel()
    }

    /// Issue #42: the server gives Ogg Opus. On iOS the reply decodes to a file that plays.
    @Test func oggOpusReplyPlaysOnTheIPhone() throws {
        let ogg = try Data(contentsOf: try #require(Bundle(for: FixtureBundle.self)
            .url(forResource: "voice-reply", withExtension: "ogg")))
        let audio = try VoiceReplyFiles.save(SpokenAudio(data: ogg, mimeType: "audio/ogg"), in: folder)
        #expect(abs(audio.duration - 1.5) < 0.1)
        let reply = ChatMessage(id: "r", role: .assistant, text: "Lunch at noon.", date: .now, reply: .complete,
                                spokenReply: .ready(audio))
        let (controller, _) = makeController(ChatViewModel(transport: OfflineChatTransport(), messages: [reply]))
        controller.tapAudio(id: "r")
        #expect(controller.playerURL == audio.fileURL)
        #expect(controller.playerIsPlaying)
        controller.tapAudio(id: "r")
    }

    /// Issue #42: a ready reply with an `.ogg` file of an older build does not play silently.
    /// The bubble shows "Audio unavailable. Tap to retry.", and the next tap speaks again.
    @Test func replyThatDoesNotPlayShowsTheErrorState() async throws {
        let url = folder.appendingPathComponent("old.ogg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contentsOf: try #require(Bundle(for: FixtureBundle.self)
            .url(forResource: "voice-reply", withExtension: "ogg"))).write(to: url)
        var messages = readyReply()
        messages[1].spokenReply = .ready(VoiceReplyAudio(fileURL: url, duration: 1.5))
        let (model, transport) = speakingModel(messages: messages)
        let (controller, _) = makeController(model, autoPlay: false)
        controller.tapAudio(id: "r")
        #expect(controller.playerURL == nil)
        #expect(model.messages.last?.spokenReply == .failed)
        #expect(ChatTimeline.rows(for: model.messages).last?.footnote == .audioUnavailable)

        controller.tapAudio(id: "r")
        try await waitUntil { model.messages.last?.spokenReply?.audio != nil }
        #expect(transport.speaks == 1)
        controller.tapAudio(id: "r")
        #expect(controller.playerIsPlaying)
        controller.tapAudio(id: "r")
    }

    @Test func settingsTextMatchesTheDesign() {
        #expect(VoiceSettingsSection.toggleTitle == "Auto-Play Voice Replies")
        // Issue #149: the thinking sound switch, on by default.
        #expect(VoiceSettingsSection.thinkingSoundTitle == "Thinking Sound")
        #expect(VoiceSettingsSection.footer
                == "Hermes speaks replies to your voice memos. In Hands-Free, a soft heartbeat plays while Hermes thinks.")
    }

    /// Issue #130: the bubble player sets `.playback` on each play and each resume, with no ducking when
    /// no other audio plays, and writes one diagnostic line for each. A fake session: no real audio session.
    @Test func bubblePlayerSetsTheMediaCategoryOnPlayAndResume() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("tone-130.wav")
        try DemoChatTransport.toneWAV(seconds: 2).write(to: url)
        let session = FakeBubbleSession()
        let file = AudioDiagnosticsFile(url: folder.appendingPathComponent("diag-130.log"))
        try? FileManager.default.removeItem(at: file.url)
        let player = VoiceMemoPlayer(audio: VoicePlaybackAudio(session: session, diagnostics: file))
        player.play(url)
        #expect(player.isPlaying(url))
        player.toggle(url)
        #expect(!player.isPlaying(url))
        player.toggle(url)
        #expect(player.isPlaying(url))
        player.stop()
        #expect(session.calls == ["playback", "active", "playback", "active"])
        let all = file.read()
        let lines = all.filter { $0.contains(" playback ") }
        #expect(lines.count == 2)
        #expect(lines.first?.contains(" playback event=play out=BluetoothA2DPOutput ") == true)
        // Round 2: the Now Playing state goes to the same file.
        #expect(all.contains { $0.contains(" nowplaying event=show title=Hermes ") })
        #expect(all.last?.hasSuffix(" nowplaying event=clear") == true)
        #expect(lines.last?.contains(" playback event=resume ") == true)
    }
}

/// Issue #130: an audio session that only records its calls.
private final class FakeBubbleSession: VoicePlaybackSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    var routeState: VoiceAudioRouteState { VoiceAudioRouteState(outputs: ["BluetoothA2DPOutput"]) }
    var isOtherAudioPlaying: Bool { false }
    func setPlaybackCategory(duckOthers: Bool, mode _: VoicePlaybackMode) throws { lock.withLock { _calls.append(duckOthers ? "duck" : "playback") } }
    func setActive(_ active: Bool) throws { lock.withLock { _calls.append(active ? "active" : "inactive") } }
}
