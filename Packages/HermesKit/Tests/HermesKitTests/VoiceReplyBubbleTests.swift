import Foundation
import Testing
@testable import HermesKit

/// A 16-bit PCM WAV: `silence` seconds of silence, then `tone` seconds of a sine at `amplitude` (0 to 1).
private func wav(silence: Double, tone: Double, amplitude: Double, rate: Int = 8000, channels: Int = 1) -> Data {
    var samples: [Float] = []
    let quiet = Int(Double(rate) * silence)
    let loud = Int(Double(rate) * tone)
    for index in 0..<(quiet + loud) {
        let value = index < quiet ? 0 : Float(sin(Double(index) * 2 * .pi * 440 / Double(rate)) * amplitude)
        samples += Array(repeating: value, count: channels)
    }
    return WAVFile.data(samples: samples, channels: channels, rate: rate)
}

private func tempFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "VoiceReplyBubbleTests-\(UUID().uuidString)",
                                                     directoryHint: .isDirectory)
}

/// Issue #49: the waveform of a voice reply (owner decision 1).
@Suite struct VoiceReplyWaveformTests {
    /// A sine at amplitude A has an RMS of A / sqrt(2). At A = 0.5 that is -9.03 dBFS: level 0.819.
    private let loudLevel = VoiceWaveform.level(decibels: Float(20 * log10(0.5 / 2.0.squareRoot())))

    @Test func knownWAVGivesTheExpectedLevels() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "half.wav")
        try wav(silence: 1, tone: 1, amplitude: 0.5).write(to: url)

        let bars = try #require(VoiceWaveform.bars(contentsOf: url))
        #expect(bars.count == VoiceMemoLimits.waveformBars)
        #expect(abs(loudLevel - 0.819) < 0.001)
        // The first half is silent: the smallest bar. The second half is the tone.
        #expect(bars.prefix(16).allSatisfy { $0 == 0 })
        #expect(bars.suffix(16).allSatisfy { abs($0 - loudLevel) < 0.01 }, "\(bars)")
    }

    @Test func stereoAndOddSizesGiveTheSameLevels() {
        let rate = 8000
        let mono = (0..<rate).map { Float(sin(Double($0) * 2 * .pi * 440 / Double(rate)) * 0.5) }
        let stereo = mono.flatMap { [$0, $0] }
        let a = VoiceWaveform.bars(samples: mono, channels: 1, sampleRate: Double(rate))
        let b = VoiceWaveform.bars(samples: stereo, channels: 2, sampleRate: Double(rate))
        #expect(zip(a, b).allSatisfy { abs($0 - $1) < 0.0001 })
        #expect(VoiceWaveform.bars(samples: [], channels: 1, sampleRate: 8000) == Array(repeating: 0, count: 32))
        // A clip shorter than one bar per window still gives 32 bars.
        #expect(VoiceWaveform.bars(samples: [0.5, -0.5], channels: 1, sampleRate: 8000).count == 32)
        #expect(VoiceWaveform.bars(samples: mono, channels: 1, sampleRate: 8000, count: 5).count == 5)
    }

    @Test func fileThatDoesNotDecodeGivesNil() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "bad.wav")
        try Data("not audio".utf8).write(to: url)
        #expect(VoiceWaveform.bars(contentsOf: url) == nil)
        #expect(VoiceWaveform.bars(contentsOf: folder.appending(path: "missing.wav")) == nil)
    }

    @Test func savedReplyHasItsWaveform() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = try VoiceReplyFiles.save(SpokenAudio(data: wav(silence: 1, tone: 1, amplitude: 0.5),
                                                         mimeType: "audio/wav"), in: folder)
        #expect(abs(audio.duration - 2) < 0.01)
        #expect(audio.waveform.count == VoiceMemoLimits.waveformBars)
        #expect(audio.waveform.prefix(16).allSatisfy { $0 == 0 })
        #expect(audio.waveform.suffix(16).allSatisfy { abs($0 - loudLevel) < 0.01 })
    }

    /// Issue #42 fixture: the decoded Ogg Opus reply also gets levels.
    @Test func oggReplyHasItsWaveform() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = try VoiceReplyFiles.save(SpokenAudio(data: try fixture("voice-reply.ogg"), mimeType: "audio/ogg"),
                                             in: folder)
        #expect(audio.waveform.count == VoiceMemoLimits.waveformBars)
        #expect(audio.waveform.contains { $0 > 0.3 })
    }
}

/// Issue #49: the cache keeps the levels (format version 4) and reads older files.
@Suite struct VoiceReplyWaveformCacheTests {
    private func store() -> FileSessionCacheStore {
        FileSessionCacheStore(directory: tempFolder())
    }

    @Test func waveformRoundTripsThroughTheCache() throws {
        let cache = store()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let levels: [Float] = (0..<32).map { Float($0) / 31 }
        let audio = VoiceReplyAudio(fileURL: URL(fileURLWithPath: "/tmp/r.wav"), duration: 7, waveform: levels)
        let reply = ChatMessage(id: "a1", role: .assistant, text: "Noted.", date: Date(timeIntervalSince1970: 1),
                                reply: .complete, spokenReply: .ready(audio))
        cache.saveTranscript([reply], sessionId: "k")
        let loaded = FileSessionCacheStore(directory: cache.directory).loadTranscript(sessionId: "k")
        #expect(loaded == [reply])
        #expect(loaded.first?.spokenReply?.audio?.waveform == levels)
        let raw = try String(contentsOf: cache.transcriptURL(sessionId: "k"), encoding: .utf8)
        #expect(raw.contains("\"version\":\(SessionCache.formatVersion)"))
        #expect(raw.contains(#""waveform""#))
    }

    /// A reply that a version 3 build cached has no waveform key. It still shows, as one voice bubble.
    @Test func versionThreeReplyStillLoadsAndShowsOneVoiceBubble() throws {
        let cache = store()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let url = cache.transcriptURL(sessionId: "k")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"version":3,"body":[{"id":"a1","role":"assistant","text":"Noted.","date":1,"#
            + #""speech":{"path":"/tmp/r.wav","duration":7}}]}"#
        try Data(json.utf8).write(to: url)
        let loaded = cache.loadTranscript(sessionId: "k")
        let audio = try #require(loaded.first?.spokenReply?.audio)
        #expect(audio.duration == 7)
        #expect(audio.waveform.isEmpty)
        let parts = ChatBubbleParts.parts(for: ChatTimeline.rows(for: loaded))
        #expect(parts.map(\.content) == [.spokenReply])
    }

    @Test func brokenWaveformDropsOnlyTheWaveform() throws {
        let cache = store()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let url = cache.transcriptURL(sessionId: "k")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"version":4,"body":[{"id":"a1","role":"assistant","text":"Noted.","date":1,"#
            + #""speech":{"path":"/tmp/r.wav","duration":7,"waveform":"loud"}}]}"#
        try Data(json.utf8).write(to: url)
        let audio = try #require(cache.loadTranscript(sessionId: "k").first?.spokenReply?.audio)
        #expect(audio.duration == 7)
        #expect(audio.waveform.isEmpty)
    }
}

/// Issue #49 (owner decision 2): the bubbles of a reply in each audio state.
@Suite struct VoiceReplyPartsTests {
    private let date = Date(timeIntervalSince1970: 1_763_290_000)
    private let audio = VoiceReplyAudio(fileURL: URL(fileURLWithPath: "/tmp/r.wav"), duration: 7, waveform: [0.5])

    private func reply(_ spoken: SpokenReply?, text: String = "Noted. **Saved** it.") -> ChatMessage {
        ChatMessage(id: "r", role: .assistant, text: text, date: date, reply: .complete, promptId: "u",
                    spokenReply: spoken)
    }

    private func parts(_ message: ChatMessage) -> [ChatBubblePart] {
        ChatBubbleParts.parts(for: ChatTimeline.rows(for: [message]))
    }

    @Test func noAudioIsOneTextBubble() {
        let shown = parts(reply(nil))
        #expect(shown.map(\.content) == [.text])
        #expect(shown.map(\.id) == ["r"])
    }

    /// QA #54 defect 1: no empty audio bubble. The text bubble has a caption row under it.
    @Test func preparingIsTheTextBubbleWithAPreparingCaption() {
        let shown = parts(reply(.preparing))
        #expect(shown.map(\.content) == [.text])
        #expect(shown.map(\.id) == ["r"])
        #expect(shown[0].row.hasTail)
        #expect(shown[0].row.footnote?.text == "Preparing audio…")
        #expect(shown[0].row.footnote?.isError == false)
        #expect(ChatBubbleParts.accessibilityLabel(for: shown[0]).contains("Preparing audio…"))
    }

    @Test func readyIsOneVoiceBubbleWithTheRowId() {
        let shown = parts(reply(.ready(audio)))
        #expect(shown.map(\.content) == [.spokenReply])
        // The text bubble had the same id, so the row reloads in place.
        #expect(shown.map(\.id) == parts(reply(.preparing)).prefix(1).map(\.id))
        #expect(shown[0].row.hasTail)
        #expect(shown[0].row.showsReactions)
        #expect(ChatBubbleParts.accessibilityLabel(for: shown[0]) == "Hermes voice reply, 0:07, Noted. Saved it.")
    }

    /// QA #54 defect 1: the failed state is the text bubble with a red retry caption, no empty bubble.
    @Test func failedIsTheTextBubbleWithARetryCaption() {
        let shown = parts(reply(.failed))
        #expect(shown.map(\.content) == [.text])
        #expect(shown.map(\.id) == ["r"])
        #expect(shown[0].row.footnote == .audioUnavailable)
        #expect(ChatBubbleParts.accessibilityLabel(for: shown[0]).contains("Audio unavailable. Tap to retry."))
    }

    @Test func tapbackOnTheVoiceBubbleIsRead() {
        var message = reply(.ready(audio))
        message.tapback = .heart
        let label = ChatBubbleParts.accessibilityLabel(for: parts(message)[0])
        #expect(label.hasPrefix("Hermes voice reply, 0:07, Noted. Saved it., "))
        #expect(label.hasSuffix("You reacted \(Tapback.heart.title.lowercased())"))
    }

    @Test func previewTextIsPlainOnOneRunOfLines() {
        #expect(VoiceReplyText.previewText("See [the docs](https://example.com) now.") == "See the docs now.")
        #expect(VoiceReplyText.previewText("**one**\n\ntwo") == "one two")
        #expect(VoiceReplyText.previewText("") == "")
    }
}

/// Issue #49: the space between bubbles, like iMessage.
@Suite struct BubbleSpacingTests {
    private let date = Date(timeIntervalSince1970: 1_763_290_000)

    @Test func twoPointsInAGroupAndTenBetweenGroups() {
        let messages = [
            ChatMessage(id: "u1", role: .user, text: "A", date: date, delivery: .delivered, userRowId: 1),
            ChatMessage(id: "u2", role: .user, text: "B", date: date.addingTimeInterval(1), delivery: .delivered,
                        userRowId: 2),
            ChatMessage(id: "a1", role: .assistant, text: "C", date: date.addingTimeInterval(2), reply: .complete,
                        promptId: "u2", spokenReply: .preparing),
            // A time header starts a new group, also for the same sender.
            ChatMessage(id: "a2", role: .assistant, text: "D", date: date.addingTimeInterval(3 * 3600),
                        reply: .complete, promptId: "u2"),
        ]
        let parts = ChatBubbleParts.parts(for: ChatTimeline.rows(for: messages))
        #expect(parts.map(\.id) == ["u1", "u2", "a1", "a2"])
        #expect(parts[3].row.timeHeader != nil)
        let space = parts.indices.map { ChatBubbleParts.spaceAbove(parts[$0], after: $0 > 0 ? parts[$0 - 1] : nil) }
        #expect(space == [10, 2, 10, 10])
    }
}
