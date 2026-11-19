import Foundation
import Testing
@testable import HermesKit

// Issue #138: the Now Playing text of a running session and the time away for the foreground reconnect.

@Suite struct HandsFreeBackgroundTests {
    @Test func nowPlayingShowsOnlyWhileASessionRuns() {
        #expect(HandsFreeNowPlayingInfo.make(handsFree: false, live: false, chatTitle: "Trip") == nil)
        #expect(HandsFreeNowPlayingInfo.make(handsFree: true, live: false, chatTitle: "Trip")
            == HandsFreeNowPlayingInfo(title: "Hermes Hands-Free", subtitle: "Trip"))
        #expect(HandsFreeNowPlayingInfo.make(handsFree: false, live: true, chatTitle: "New Chat")
            == HandsFreeNowPlayingInfo(title: "Hermes Live", subtitle: "New Chat"))
        // Live wins when both say they run (a Live session replaces Hands-Free).
        #expect(HandsFreeNowPlayingInfo.make(handsFree: true, live: true, chatTitle: "")?.title == "Hermes Live")
    }

    @Test func aSessionThatRunsKeepsTheAppAwake() {
        let left = Date(timeIntervalSince1970: 1_000)
        let now = left.addingTimeInterval(600)
        #expect(HandsFreeAwake.away(backgroundedAt: left, stoppedAt: nil, running: true, now: now) == 0)
        #expect(HandsFreeAwake.away(backgroundedAt: left, stoppedAt: left.addingTimeInterval(-50), running: true,
                                    now: now) == 0)
    }

    @Test func theClockStartsAtTheLaterOfBackgroundAndSessionEnd() {
        let left = Date(timeIntervalSince1970: 1_000)
        let now = left.addingTimeInterval(600)
        // No session: the whole time away counts.
        #expect(HandsFreeAwake.away(backgroundedAt: left, stoppedAt: nil, running: false, now: now) == 600)
        // A session that ended before the app left: the whole time away counts.
        #expect(HandsFreeAwake.away(backgroundedAt: left, stoppedAt: left.addingTimeInterval(-30), running: false,
                                    now: now) == 600)
        // The session ended 590 s after the move to the background (silence end): 10 s count.
        #expect(HandsFreeAwake.away(backgroundedAt: left, stoppedAt: left.addingTimeInterval(590), running: false,
                                    now: now) == 10)
        // A clock that goes back never gives a negative time.
        #expect(HandsFreeAwake.away(backgroundedAt: now.addingTimeInterval(5), stoppedAt: nil, running: false,
                                    now: now) == 0)
    }
}
