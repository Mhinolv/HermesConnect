import AVFoundation
import Foundation
import Testing
@testable import HermesKit

/// Issue #139: the bundled clips in the repo (`HermesConnect/Resources/AckClips`).
enum AckClipFiles {
    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "HermesConnect/Resources/AckClips")

    static func url(_ line: String) -> URL {
        directory.appending(path: VoiceModeAckClips.fileName(for: line) + "." + VoiceModeAckClips.fileExtension)
    }

    static func listLines() throws -> [String] {
        try String(contentsOf: directory.appending(path: "ack_lines.txt"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

@Suite struct VoiceModeAckClipNameTests {
    @Test func theClipNameIsTheSlugOfTheLine() {
        #expect(VoiceModeAckClips.fileName(for: "On it.") == "ack-on-it")
        #expect(VoiceModeAckClips.fileName(for: "Just a moment.") == "ack-just-a-moment")
        #expect(VoiceModeAckClips.fileName(for: "  Let ME check!! 2 times ") == "ack-let-me-check-2-times")
        #expect(VoiceModeAckClips.fileName(for: "...") == "ack-")
        #expect(VoiceModeAckClips.fileName(for: "Café") == "ack-caf")
    }

    @Test func theTextListHasTheAckLinesInTheirOrder() throws {
        #expect(try AckClipFiles.listLines() == VoiceModeText.ackLines)
        // The design notes: five lines, and the rotation never says one line twice in a row.
        #expect(VoiceModeText.ackLines.count == 5)
        #expect(Set(VoiceModeText.ackLines).count == VoiceModeText.ackLines.count)
    }

    @Test func eachLineHasAShortMonoClipAndAllClipsStayUnder200KB() throws {
        var bytes = 0
        for line in VoiceModeText.ackLines {
            let url = AckClipFiles.url(line)
            let buffer = try VoiceModeAckClips.decode(url)
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            #expect(seconds > 0.3 && seconds < 2.5, "\(url.lastPathComponent): \(seconds) s")
            #expect(buffer.format.channelCount == 1)
            bytes += try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        }
        #expect(bytes < 200_000, "\(bytes) bytes")
    }

    @Test func aMissingOrBadFileDoesNotDecode() throws {
        #expect(throws: (any Error).self) { try VoiceModeAckClips.decode(AckClipFiles.url("No such line.")) }
        let bad = FileManager.default.temporaryDirectory.appending(path: "ack-bad-\(UUID().uuidString).m4a")
        try Data("not audio".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        #expect(throws: (any Error).self) { try VoiceModeAckClips.decode(bad) }
    }
}

/// Issue #139: a clip player with no audio. `play` returns at `finish()` or `stop()`.
final class FakeAckClipPlayer: VoiceModeAckClipPlaying, @unchecked Sendable {
    struct Failed: Error {}
    private let lock = NSLock()
    private var _urls: [URL] = []
    private var _stops = 0
    private var waiter: CheckedContinuation<Void, Never>?
    var fails = false

    var urls: [URL] { lock.withLock { _urls } }
    var stops: Int { lock.withLock { _stops } }
    var isPlaying: Bool { lock.withLock { waiter != nil } }

    func play(_ url: URL) async throws {
        lock.withLock { _urls.append(url) }
        if fails { throw Failed() }
        await withCheckedContinuation { continuation in lock.withLock { waiter = continuation } }
    }

    func stop() {
        lock.withLock { _stops += 1 }
        finish()
    }

    func finish() {
        let woken = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { waiter = nil }
            return waiter
        }
        woken?.resume()
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BundledAckVoiceTests {
    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(2)) }
        #expect(condition(), "\(what)")
    }

    @Test func aBundledClipPlaysAndTheOnDeviceVoiceStaysSilent() async throws {
        let player = FakeAckClipPlayer()
        let fallback = FakeAckVoice()
        let voice = BundledAckVoice(clipURL: { AckClipFiles.url($0) }, player: player, fallback: fallback)
        let speech = Task { await voice.speak("On it.") }
        try await until("playing") { player.isPlaying }
        #expect(player.urls == [AckClipFiles.url("On it.")])
        player.finish()
        await speech.value
        #expect(fallback.lines.isEmpty)
    }

    @Test func aMissingClipSaysTheLineWithTheOnDeviceVoice() async throws {
        let player = FakeAckClipPlayer()
        let fallback = FakeAckVoice()
        let voice = BundledAckVoice(clipURL: { _ in nil }, player: player, fallback: fallback)
        let speech = Task { await voice.speak("One moment.") }
        try await until("fallback") { fallback.isSpeaking }
        #expect(fallback.lines == ["One moment."])
        #expect(player.urls.isEmpty)
        fallback.finishLine()
        await speech.value
    }

    @Test func aBadClipSaysTheLineWithTheOnDeviceVoice() async throws {
        let player = FakeAckClipPlayer()
        player.fails = true
        let fallback = FakeAckVoice()
        let voice = BundledAckVoice(clipURL: { AckClipFiles.url($0) }, player: player, fallback: fallback)
        let speech = Task { await voice.speak("Let me check.") }
        try await until("fallback") { fallback.isSpeaking }
        #expect(fallback.lines == ["Let me check."])
        fallback.finishLine()
        await speech.value
    }

    @Test func aStopEndsTheClipAtOnceAndNoFallbackFollows() async throws {
        let player = FakeAckClipPlayer()
        let fallback = FakeAckVoice()
        let voice = BundledAckVoice(clipURL: { AckClipFiles.url($0) }, player: player, fallback: fallback)
        let speech = Task { await voice.speak("Checking now.") }
        try await until("playing") { player.isPlaying }
        voice.stop()
        await speech.value
        #expect(!player.isPlaying)
        #expect(fallback.lines.isEmpty)
        #expect(fallback.stops >= 1, "a stop also stops the on-device voice")
    }

    @Test func noVoiceAtAllWhenTheClipIsMissingAndThereIsNoFallback() async {
        let player = FakeAckClipPlayer()
        let voice = BundledAckVoice(clipURL: { _ in nil }, player: player, fallback: nil)
        await voice.speak("On it.")
        #expect(player.urls.isEmpty)
    }
}

/// Issue #139: the real `AVAudioEngineAckPlayer`, on an engine in offline manual rendering mode. No audio hardware.
/// The render runs on a background queue, so the completion handlers come from a queue that is not the main one.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AVAudioEngineAckPlayerTests {
    private static let rate = 48_000.0
    private let queue = DispatchQueue(label: "ack-render")

    private func offlineEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        return engine
    }

    /// Renders `blocks` blocks of 1024 frames on `queue`. Returns the peak of all of them.
    private func render(_ engine: AVAudioEngine, blocks: Int) async throws -> Float {
        let box = UncheckedEngine(engine: engine)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let engine = box.engine
                    guard let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096)
                    else { throw VoiceReplyError.cannotDecode }
                    var loudest: Float = 0
                    for _ in 0..<blocks {
                        _ = try engine.renderOffline(1_024, to: output)
                        if let channel = output.floatChannelData?[0] {
                            for index in 0..<Int(output.frameLength) { loudest = max(loudest, abs(channel[index])) }
                        }
                    }
                    continuation.resume(returning: loudest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private struct UncheckedEngine: @unchecked Sendable { let engine: AVAudioEngine }

    @Test func theClipPlaysToItsEndWithTheHandlerOnABackgroundQueue() async throws {
        let engine = try offlineEngine()
        let player = AVAudioEngineAckPlayer(engine: engine, limitMarginSeconds: 30)
        let clip = AckClipFiles.url("On it.")
        let playing = Task { try await player.play(clip) }
        try await Task.sleep(for: .milliseconds(20))
        // The clip is about 0.5 s: 24 blocks at 48 kHz. 60 blocks render all of it.
        #expect(try await render(engine, blocks: 60) > 0.05, "the clip plays")
        // The handler ends the play. The limit is 30 s, so only the handler can end it in time.
        let start = ContinuousClock.now
        try await playing.value
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func aStopSilencesTheAckAtOnceAndKeepsTheReply() async throws {
        let engine = try offlineEngine()
        let reply = AVAudioEnginePCMPlayer(engine: engine)
        let player = AVAudioEngineAckPlayer(engine: engine, limitMarginSeconds: 30)
        let playing = Task { try await player.play(AckClipFiles.url("Just a moment.")) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(try await render(engine, blocks: 4) > 0.01, "the ack plays")
        player.stop()
        try await playing.value // returns at once after stop
        #expect(try await render(engine, blocks: 3) < 0.001, "silence after the stop")

        // The reply has its own node: a stop of the ack after the reply starts does not drop the reply.
        try reply.begin(sampleRate: Self.rate)
        reply.enqueue(Data(repeating: 0x20, count: 48_000 * 2)) // 1 s of 0x2020 samples
        let before = try await render(engine, blocks: 3)
        player.stop()
        let after = try await render(engine, blocks: 3)
        // 0x2020 is 0.25 of full scale. The mixer gives about 0.18 for one mono input of two.
        #expect(before > 0.1, "the reply plays")
        #expect(abs(after - before) < 0.01, "the ack stop does not change the reply")
        reply.shutdown()
    }

    @Test func aBadClipThrows() async throws {
        let engine = try offlineEngine()
        let player = AVAudioEngineAckPlayer(engine: engine)
        await #expect(throws: (any Error).self) { try await player.play(AckClipFiles.url("No such line.")) }
    }

    @Test func withNoHandlerTheAckEndsAtTheLimit() async throws {
        let engine = try offlineEngine()
        let player = AVAudioEngineAckPlayer(engine: engine, limitMarginSeconds: 0.05)
        // No render: the buffer never plays and no handler comes, as with an engine that a route change stopped.
        let start = ContinuousClock.now
        try await player.play(AckClipFiles.url("On it."))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(3), "\(elapsed)")
        // The buffer was dropped: it does not play late.
        #expect(try await render(engine, blocks: 30) < 0.001)
    }
}
