import AVFoundation
import Foundation
import HermesKit
import Testing
@testable import HermesConnect

// Issue #139: the quick ack clips in the Kokoro `af_bella` voice are in the app bundle and play on the
// Hands-Free engine. No test starts the engine or plays audio.

@MainActor
struct AckClipBundleTests {
    @Test func eachAckLineHasABundledClipThatDecodes() throws {
        for line in VoiceModeText.ackLines {
            let url = try #require(Bundle.main.url(forResource: VoiceModeAckClips.fileName(for: line),
                                                   withExtension: VoiceModeAckClips.fileExtension), "\(line)")
            let buffer = try VoiceModeAckClips.decode(url)
            #expect(buffer.frameLength > 0)
        }
    }

    @Test func theTextListIsInTheBundle() throws {
        let url = try #require(Bundle.main.url(forResource: "ack_lines", withExtension: "txt"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines == VoiceModeText.ackLines)
    }

    @Test func theAckPlaysOnTheEngineOfTheReply() {
        let microphone = AVVoiceModeMicrophone(environment: [:])
        #expect(microphone.ackPlayer.engine === microphone.player.engine)
        #expect(VoiceModeSessionModel.bundledAckVoice(microphone) is BundledAckVoice)
    }
}
