import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import HermesKit

private let token = String(repeating: "5e", count: 32)

/// A scripted player. `holdPlayback` keeps `drain` and `playClip` open until `stop` or `release`. No audio.
final class FakeSpeechPlayer: StreamedSpeechPlaying, @unchecked Sendable {
    struct State {
        var rates: [Double] = []
        var chunks: [Data] = []
        var clips: [SpokenAudio] = []
        var stops = 0
        var hold = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    let state = Mutex(State())

    init(holdPlayback: Bool = false) {
        state.withLock { $0.hold = holdPlayback }
    }

    var rates: [Double] { state.withLock { $0.rates } }
    var chunks: [Data] { state.withLock { $0.chunks } }
    var clips: [SpokenAudio] { state.withLock { $0.clips } }
    var stops: Int { state.withLock { $0.stops } }

    func begin(sampleRate: Double) throws { state.withLock { $0.rates.append(sampleRate) } }
    func enqueue(_ pcm: Data) { state.withLock { $0.chunks.append(pcm) } }

    func drain() async { await hold() }

    func playClip(_ audio: SpokenAudio) async throws {
        state.withLock { $0.clips.append(audio) }
        await hold()
    }

    func stop() {
        let waiters = state.withLock { state in
            state.stops += 1
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func release() {
        let waiters = state.withLock { state in
            state.hold = false
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    private func hold() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = state.withLock { state in
                if state.hold { state.waiters.append(continuation) }
                return state.hold
            }
            if !wait { continuation.resume() }
        }
    }
}

/// Records the fallback POST calls.
final class FakeFallback: @unchecked Sendable {
    private let state = Mutex<(texts: [String], error: (any Error)?)>(([], nil))

    init(error: (any Error)? = nil) {
        state.withLock { $0.error = error }
    }

    var texts: [String] { state.withLock { $0.texts } }

    func speak(_ text: String) async throws -> SpokenAudio {
        let error = state.withLock { state in
            state.texts.append(text)
            return state.error
        }
        if let error { throw error }
        return SpokenAudio(data: Data([1, 2, 3]), mimeType: "audio/wav")
    }
}

final class Flag: @unchecked Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func raise() { value.withLock { $0 += 1 } }
}

/// Collects the states of a speaker in the background.
final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StreamedSpeechState] = []

    init(_ speech: StreamedSpeech) {
        Task { [self] in
            for await state in speech.states { lock.withLock { items.append(state) } }
        }
    }

    var states: [StreamedSpeechState] { lock.withLock { items } }

    func waitFor(_ state: StreamedSpeechState) async throws {
        for _ in 0..<1000 {
            if states.contains(state) { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw FakeTimeout(what: "state \(state)")
    }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw FakeTimeout(what: "condition")
}

/// One speaker on one scripted socket.
private struct Rig {
    let socket = FakeGatewaySocket()
    let connector: FakeGatewayConnector
    let player: FakeSpeechPlayer
    let fallback: FakeFallback
    let refused = Flag()
    let speech: StreamedSpeech
    let log: StateLog

    init(holdPlayback: Bool = false, connectError: GatewayWebSocketClosed? = nil, fallbackError: (any Error)? = nil) throws {
        connector = connectError.map { FakeGatewayConnector(error: $0) } ?? FakeGatewayConnector(socket)
        player = FakeSpeechPlayer(holdPlayback: holdPlayback)
        fallback = FakeFallback(error: fallbackError)
        let endpoint = try GatewayEndpoint(port: 9119, token: token)
        let connector = self.connector
        let fallback = self.fallback
        let refused = self.refused
        speech = StreamedSpeech(
            open: { try await SpeakStreamConnection.open(endpoint: endpoint, connector: connector) },
            fallback: { try await fallback.speak($0) },
            player: player,
            onUnauthorized: { refused.raise() })
        log = StateLog(speech)
    }

    func sentFrames() -> [JSONValue] { socket.sent }
}

private func pcm(_ samples: [Int16]) -> Data {
    var data = Data()
    for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
    return data
}

@Suite(.timeLimit(.minutes(1))) struct SpeakStreamTests {
    @Test func urlUsesTheForwardAndTheToken() throws {
        let endpoint = try GatewayEndpoint(port: 41234, token: token)
        #expect(endpoint.speakStreamURL.absoluteString == "ws://127.0.0.1:41234/api/audio/speak-stream?token=\(token)")
        #expect(endpoint.webSocketURL.absoluteString == "ws://127.0.0.1:41234/api/ws?token=\(token)")
    }

    @Test func playsPCMUntilEnd() async throws {
        let rig = try Rig()
        await rig.speech.append("Hello. ")
        await rig.speech.append("**World**.")
        await rig.speech.finish()
        let frames = try await rig.socket.waitForSent(count: 3) { _ in true }
        // Deltas go as they are, in order. The server strips Markdown per sentence.
        #expect(frames[0]["text"]?.stringValue == "Hello. ")
        #expect(frames[1]["text"]?.stringValue == "**World**.")
        #expect(frames[2]["done"]?.boolValue == true)
        #expect(rig.connector.urls.map(\.path) == ["/api/audio/speak-stream"])

        rig.socket.push(#"{"type":"start","sample_rate":22050,"channels":1}"#)
        rig.socket.pushBinary(pcm([1, 2, 3]))
        rig.socket.pushBinary(pcm([4]))
        rig.socket.push(#"{"type":"end"}"#)
        #expect(await rig.speech.waitUntilDone() == .ended)
        #expect(rig.player.rates == [22050])
        #expect(rig.player.chunks == [pcm([1, 2, 3]), pcm([4])])
        #expect(rig.fallback.texts.isEmpty)
        #expect(rig.socket.closedCode == 1000)
        try await waitUntil { rig.log.states.last == .ended }
        #expect(rig.log.states == [.preparing, .speaking(viaFallback: false), .ended])
    }

    @Test func stopEndsTheAudioAtOnce() async throws {
        let rig = try Rig(holdPlayback: true)
        await rig.speech.append("A long reply. ")
        rig.socket.push(#"{"type":"start","sample_rate":24000,"channels":1}"#)
        rig.socket.pushBinary(pcm([7, 7]))
        try await rig.log.waitFor(.speaking(viaFallback: false))

        let clock = ContinuousClock()
        let elapsed = await clock.measure { await rig.speech.stop() }
        #expect(elapsed < .milliseconds(100), "barge-in took \(elapsed)")
        #expect(rig.player.stops == 1)
        #expect(await rig.speech.state == .stopped)
        let stop = try await rig.socket.waitForSent { $0["stop"]?.boolValue == true }
        #expect(stop.count == 1)
        #expect(rig.socket.closedCode == 1000)

        // Nothing after the stop changes the state or plays.
        await rig.speech.append("More text.")
        await rig.speech.finish()
        #expect(await rig.speech.waitUntilDone() == .stopped)
        #expect(rig.fallback.texts.isEmpty)
        #expect(rig.player.chunks.count == 1)
    }

    @Test func stopWhileTheEndDrainsIsStopped() async throws {
        let rig = try Rig(holdPlayback: true)
        await rig.speech.append("Hi.")
        await rig.speech.finish()
        rig.socket.push(#"{"type":"start","sample_rate":24000,"channels":1}"#)
        rig.socket.pushBinary(pcm([1]))
        rig.socket.push(#"{"type":"end"}"#)
        try await rig.log.waitFor(.speaking(viaFallback: false))
        try await Task.sleep(for: .milliseconds(20))
        await rig.speech.stop()
        #expect(await rig.speech.waitUntilDone() == .stopped)
    }

    @Test func fallbackFrameSpeaksTheWholeReplyWithPOST() async throws {
        let rig = try Rig()
        await rig.speech.append("**Hi** there. ")
        await rig.speech.append("Bye.")
        rig.socket.push(#"{"type":"fallback"}"#)
        // The POST waits for the whole reply.
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.fallback.texts.isEmpty)
        await rig.speech.finish()
        #expect(await rig.speech.waitUntilDone() == .ended)
        #expect(rig.fallback.texts == ["Hi there. Bye."])
        #expect(rig.player.clips.map(\.mimeType) == ["audio/wav"])
        #expect(rig.player.chunks.isEmpty)
        try await waitUntil { rig.log.states.last == .ended }
        #expect(rig.log.states == [.preparing, .speaking(viaFallback: true), .ended])
    }

    @Test func dropBeforeAudioUsesTheFallback() async throws {
        let rig = try Rig()
        await rig.speech.append("Hi.")
        await rig.speech.finish()
        rig.socket.serverClose(closeCode: 1011)
        #expect(await rig.speech.waitUntilDone() == .ended)
        #expect(rig.fallback.texts == ["Hi."])
    }

    @Test func oldServerWithNoRouteUsesTheFallback() async throws {
        let rig = try Rig(connectError: GatewayWebSocketClosed(httpStatus: 404))
        await rig.speech.append("Hi.")
        await rig.speech.finish()
        #expect(await rig.speech.waitUntilDone() == .ended)
        #expect(rig.fallback.texts == ["Hi."])
    }

    @Test func dropAfterAudioKeepsWhatPlayed() async throws {
        let rig = try Rig()
        await rig.speech.append("Hi.")
        await rig.speech.finish()
        rig.socket.push(#"{"type":"start","sample_rate":24000,"channels":1}"#)
        rig.socket.pushBinary(pcm([1, 2]))
        try await rig.log.waitFor(.speaking(viaFallback: false))
        rig.socket.serverClose(closeCode: 1006)
        #expect(await rig.speech.waitUntilDone() == .ended)
        #expect(rig.fallback.texts.isEmpty)
    }

    @Test(arguments: [GatewayWebSocketClosed(closeCode: 4401), GatewayWebSocketClosed(closeCode: 4403),
                      GatewayWebSocketClosed(httpStatus: 401), GatewayWebSocketClosed(httpStatus: 403)])
    func refusedTokenFailsWithNoFallback(close: GatewayWebSocketClosed) async throws {
        let rig = try Rig()
        await rig.speech.append("Hi.")
        await rig.speech.finish()
        rig.socket.serverClose(closeCode: close.closeCode, httpStatus: close.httpStatus)
        #expect(await rig.speech.waitUntilDone() == .failed(.unauthorized))
        #expect(rig.fallback.texts.isEmpty)
        try await waitUntil { rig.refused.count == 1 }
    }

    @Test func refusedTokenOnTheFallbackPOSTFails() async throws {
        let rig = try Rig(fallbackError: HermesAPIError.unauthorized)
        await rig.speech.append("Hi.")
        await rig.speech.finish()
        rig.socket.push(#"{"type":"fallback"}"#)
        #expect(await rig.speech.waitUntilDone() == .failed(.unauthorized))
        try await waitUntil { rig.refused.count == 1 }
    }

    @Test func noLinkIsOffline() async throws {
        let rig = try Rig(connectError: GatewayWebSocketClosed(urlErrorCode: URLError.cannotConnectToHost.rawValue),
                          fallbackError: URLError(.cannotConnectToHost))
        await rig.speech.append("Hi.")
        await rig.speech.finish()
        #expect(await rig.speech.waitUntilDone() == .failed(.offline))
        #expect(rig.refused.count == 0)
    }

    @Test func serverErrorOnTheFallbackIsServer() async throws {
        let rig = try Rig(fallbackError: HermesAPIError.http(status: 500))
        await rig.speech.append("Hi.")
        await rig.speech.finish()
        rig.socket.push(#"{"type":"fallback"}"#)
        #expect(await rig.speech.waitUntilDone() == .failed(.server))
    }

    @Test func replyWithNothingToSpeakEnds() async throws {
        let rig = try Rig()
        await rig.speech.append("```\ncode only\n```")
        await rig.speech.finish()
        rig.socket.push(#"{"type":"fallback"}"#)
        #expect(await rig.speech.waitUntilDone() == .ended)
        #expect(rig.fallback.texts.isEmpty)
    }

    @Test func stopBeforeTheSocketOpensSendsNothing() async throws {
        let rig = try Rig()
        await rig.speech.stop()
        #expect(await rig.speech.waitUntilDone() == .stopped)
        await rig.speech.append("Hi.")
        #expect(rig.connector.urls.isEmpty)
    }

    @Test func framesDecode() {
        #expect(SpeakStreamConnection.decode(#"{"type":"start","sample_rate":16000,"channels":1}"#)
            == .start(sampleRate: 16000, channels: 1))
        #expect(SpeakStreamConnection.decode(#"{"type":"start"}"#) == .start(sampleRate: 24000, channels: 1))
        #expect(SpeakStreamConnection.decode(#"{"type":"end"}"#) == .end)
        #expect(SpeakStreamConnection.decode(#"{"type":"fallback"}"#) == .fallback)
        #expect(SpeakStreamConnection.decode(#"{"type":"later"}"#) == nil)
        #expect(SpeakStreamConnection.decode("not json") == nil)
    }

    @Test func errorsMap() {
        #expect(SpeechStreamError.from(GatewayWebSocketClosed(closeCode: 4401)) == .unauthorized)
        #expect(SpeechStreamError.from(GatewayWebSocketClosed(httpStatus: 403)) == .unauthorized)
        #expect(SpeechStreamError.from(GatewayWebSocketClosed(urlErrorCode: -1004)) == .offline)
        #expect(SpeechStreamError.from(GatewayWebSocketClosed(closeCode: 1011)) == .server)
        #expect(SpeechStreamError.from(GatewayWebSocketClosed(httpStatus: 500, urlErrorCode: -1011)) == .server)
        #expect(SpeechStreamError.from(HermesAPIError.unauthorized) == .unauthorized)
        #expect(SpeechStreamError.from(HermesAPIError.http(status: 403)) == .unauthorized)
        #expect(SpeechStreamError.from(GatewayError.notConnected) == .offline)
        #expect(SpeechStreamError.from(URLError(.notConnectedToInternet)) == .offline)
        #expect(SpeechStreamError.from(HermesAPIError.invalidResponse) == .server)
    }

    @Test func pcmChunksCarryAnOddByte() {
        var samples = PCM16Samples()
        // 0x7fff, then 0x8000 split across two chunks, then 0x0000.
        #expect(samples.samples(from: Data([0xff, 0x7f, 0x00])) == [Float(32767) / 32768])
        #expect(samples.samples(from: Data([0x80, 0x00, 0x00])) == [-1, 0])
        #expect(samples.samples(from: Data()) == [])
        #expect(samples.samples(from: Data([0x01])) == [])
        #expect(samples.samples(from: Data([0x00])) == [Float(1) / 32768])
    }

    @Test func logsHoldNoTextNoAudioAndNoToken() async throws {
        let secret = "SECRET-SPOKEN-4c1d"
        let leaks = Mutex<[String]>([])
        let id = HermesLog.addObserver { entry in
            if entry.message.contains(secret) || entry.message.contains(token) || entry.message.contains("AAEC") {
                leaks.withLock { $0.append(entry.message) }
            }
        }
        defer { HermesLog.removeObserver(id) }
        let rig = try Rig()
        await rig.speech.append(secret)
        await rig.speech.finish()
        rig.socket.push(#"{"type":"start","sample_rate":24000,"channels":1}"#)
        rig.socket.pushBinary(Data([0, 1, 2]))
        rig.socket.push(#"{"type":"end"}"#)
        #expect(await rig.speech.waitUntilDone() == .ended)
        let fallbackRig = try Rig()
        await fallbackRig.speech.append(secret)
        await fallbackRig.speech.finish()
        fallbackRig.socket.push(#"{"type":"fallback"}"#)
        #expect(await fallbackRig.speech.waitUntilDone() == .ended)
        #expect(leaks.withLock { $0 }.isEmpty)
        #expect(!String(describing: SpeechStreamError.from(GatewayWebSocketClosed(httpStatus: 401))).contains(token))
    }
}

/// The real `AVAudioEnginePCMPlayer`, on an engine in offline manual rendering mode. No audio hardware.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AVAudioEnginePCMPlayerTests {
    private static let rate = 24_000.0

    private func offlineEngine() throws -> (AVAudioEngine, AVAudioPCMBuffer) {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
        return (engine, output)
    }

    private func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(channel[$1])) }
    }

    /// Renders `blocks` blocks of 1024 frames. Returns the peak of all of them.
    /// The first block can be silent, because the node starts on a render boundary.
    @discardableResult
    private func render(_ engine: AVAudioEngine, _ output: AVAudioPCMBuffer, blocks: Int = 1) throws -> Float {
        var loudest: Float = 0
        for _ in 0..<blocks {
            _ = try engine.renderOffline(1_024, to: output)
            loudest = max(loudest, peak(output))
        }
        return loudest
    }

    @Test func playsThenStopsAtOnce() async throws {
        let (engine, output) = try offlineEngine()
        let player = AVAudioEnginePCMPlayer(engine: engine)
        try player.begin(sampleRate: Self.rate)
        player.enqueue(pcm([Int16](repeating: 16_384, count: 24_000))) // 1 s at half scale

        #expect(try render(engine, output, blocks: 3) > 0.4, "the PCM plays")

        player.stop()
        await player.drain() // returns at once after stop
        #expect(try render(engine, output, blocks: 3) < 0.001, "silence in the first block after stop")

        // The next reply plays on the same player.
        try player.begin(sampleRate: Self.rate)
        player.enqueue(pcm([Int16](repeating: 8_192, count: 4_096)))
        #expect(try render(engine, output, blocks: 3) > 0.2)
        player.shutdown()
    }

    @Test func drainReturnsAfterTheQueuedAudioPlayed() async throws {
        let (engine, output) = try offlineEngine()
        let player = AVAudioEnginePCMPlayer(engine: engine)
        try player.begin(sampleRate: Self.rate)
        player.enqueue(pcm([Int16](repeating: 1_000, count: 801))) // odd byte count across chunks below
        player.enqueue(Data([0x10]))
        let drained = Flag()
        let wait = Task {
            await player.drain()
            drained.raise()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(drained.count == 0, "the audio has not played yet")
        try render(engine, output, blocks: 4)
        try await waitUntil { drained.count == 1 }
        await wait.value
        player.shutdown()
    }

    @Test func playsAWAVClip() async throws {
        let (engine, output) = try offlineEngine()
        let player = AVAudioEnginePCMPlayer(engine: engine)
        let clip = SpokenAudio(data: wav(samples: [Int16](repeating: 12_000, count: 4_800), rate: 24_000),
                               mimeType: "audio/wav")
        let played = Flag()
        let task = Task {
            try await player.playClip(clip)
            played.raise()
        }
        try await waitUntil { engine.isRunning }
        try await Task.sleep(for: .milliseconds(30))
        #expect(try render(engine, output, blocks: 7) > 0.3)
        try await waitUntil { played.count == 1 }
        try await task.value
        player.shutdown()
    }

    @Test func badClipDoesNotDecode() {
        #expect(throws: VoiceReplyError.cannotDecode) {
            _ = try AVAudioEnginePCMPlayer.decode(SpokenAudio(data: Data("not audio".utf8), mimeType: "audio/wav"))
        }
    }

    private func wav(samples: [Int16], rate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let body = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + body))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(body))
        samples.forEach { append($0) }
        return data
    }
}
