import AVFoundation
import Foundation
import HermesKit
import Testing
import WebRTC
@testable import HermesConnect

// Issue #109: Live Voice failed after the first session in one app run. These tests use the real
// `WebRTCLiveConnection` on the Simulator, with no server: `makeOffer` makes a local offer only.
// No answer goes in, so no media flows and the mic does not record.

@MainActor
@Suite(.serialized) struct LiveModeTeardownTests {
    /// The end of a session must give the audio session back to `RTCAudioSession`. Before the fix, `close()`
    /// went around it, so its `isActive` stayed `true`. Each later start then did not activate the session.
    @Test func endReleasesTheWebRTCAudioSession() async throws {
        let audio = RTCAudioSession.sharedInstance()
        let first = WebRTCLiveConnection()
        _ = try await first.makeOffer()
        #expect(audio.isActive)
        first.close()
        #expect(!audio.isActive, "the end left RTCAudioSession active, so the next start cannot activate it")

        let second = WebRTCLiveConnection()
        _ = try await second.makeOffer()
        #expect(audio.isActive)
        second.close()
        #expect(!audio.isActive)
    }

    /// Hang up closes the peer and the data channel, and stops the mic track.
    @Test func closeStopsTheMicAndClosesThePeerAndTheChannel() async throws {
        let connection = WebRTCLiveConnection()
        _ = try await connection.makeOffer()
        connection.close()
        let teardown = try #require(connection.teardown)
        #expect(teardown.peerState == .closed)
        #expect(teardown.channelState == .closed || teardown.channelState == .closing)
        #expect(teardown.micEnabled == false)
        #expect(teardown.senders == 0)
        #expect(teardown.audioReleased)
        #expect(!RTCAudioSession.sharedInstance().isActive)
    }

    /// The controller closes an old peer 500 ms after "End". That late close must not stop a new session.
    @Test func lateCloseOfAnOldSessionKeepsTheNewSessionAudio() async throws {
        let audio = RTCAudioSession.sharedInstance()
        let old = WebRTCLiveConnection()
        _ = try await old.makeOffer()
        let new = WebRTCLiveConnection()
        _ = try await new.makeOffer()
        old.close()
        #expect(audio.isActive)
        new.close()
        #expect(!audio.isActive)
    }

    /// An End before the start task runs: the offer fails, and no audio activation stays open.
    @Test func closeBeforeTheOfferLeavesNoAudioActive() async throws {
        let connection = WebRTCLiveConnection()
        connection.close()
        await #expect(throws: LiveModeError.step(.offer, code: nil)) { _ = try await connection.makeOffer() }
        #expect(!RTCAudioSession.sharedInstance().isActive)
    }
}
