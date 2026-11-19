import Foundation
import Testing
@testable import HermesKit

// Issue #102: live mode in the Voice tab. Each state of the design notes table.
@Suite struct LiveTabDisplayTests {
    private func show(_ phase: LiveModePhase, muted: Bool = false, speaking: Bool = false, idle: Bool = false,
                      still: Bool = false, failure: String? = nil) -> VoiceTabDisplay? {
        VoiceTabDisplay.live(phase: phase, muted: muted, speaking: speaking, idleWarning: idle, stillWorking: still,
                             failure: failure)
    }

    @Test func eachLiveStateHasItsRingAndLines() throws {
        #expect(show(.idle) == nil)
        let connecting = try #require(show(.connecting))
        #expect(connecting.ring == .working)
        #expect(connecting.title == "Connecting…")
        #expect(!connecting.muteEnabled)
        #expect(connecting.isLive && connecting.isSession)

        let owner = try #require(show(.live))
        #expect(owner.ring == .listening, "blue while the owner has the floor")
        #expect(owner.title == "Live")
        #expect(owner.subtitle == "Speak any time")
        #expect(owner.muteEnabled)

        let hermes = try #require(show(.live, speaking: true))
        #expect(hermes.ring == .speaking, "the label color while Hermes talks")
        #expect(hermes.title == "Live")

        #expect(show(.working)?.title == "Hermes is working…")
        #expect(show(.working)?.subtitle == nil)
        #expect(show(.working, still: true)?.subtitle == "Still working…")
        #expect(show(.working)?.ring == .working)

        let muted = try #require(show(.live, muted: true, speaking: true))
        #expect(muted.ring == .muted)
        #expect(muted.title == "Muted")
        #expect(muted.subtitle == "Tap Mute to listen again")
        #expect(muted.muteOn)

        #expect(show(.reconnecting)?.title == "Reconnecting…")
        #expect(show(.reconnecting)?.ring == .working)
        #expect(show(.live, idle: true)?.subtitle == "Ending soon. Speak to continue.")
        #expect(show(.live, idle: true)?.ring == .listening)

        let failed = try #require(show(.failed, failure: "Could not reach OpenAI (ICE failed)."))
        #expect(failed.title == "Live mode stopped")
        #expect(failed.subtitle == "Could not reach OpenAI (ICE failed).")
        #expect(failed.action == .tryAgain)
        #expect(failed.action?.title == "Try Again")
        #expect(!failed.muteEnabled)
    }

    /// Issue #145: the chat socket dropped while Hermes works on a Live request. The #102 line shows.
    @Test func workingWhileTheChatReattachesSaysReconnecting() throws {
        let display = try #require(VoiceTabDisplay.live(phase: .working, muted: false, speaking: false,
                                                        idleWarning: false, stillWorking: true, reconnecting: true))
        #expect(display.title == "Reconnecting…")
        #expect(display.subtitle == nil)
        #expect(display.isLive)
        let live = try #require(VoiceTabDisplay.live(phase: .live, muted: false, speaking: false, idleWarning: false,
                                                     stillWorking: false, reconnecting: true))
        #expect(live.title == "Live")
    }

    @Test func ringTapAndAnnouncementsInLive() {
        #expect(VoiceTabDisplay.liveRingTap(.live) == .none)
        #expect(VoiceTabDisplay.liveRingTap(.working) == .none)
        #expect(VoiceTabDisplay.liveRingTap(.failed) == .resume)
        #expect(VoiceTabDisplay.liveAnnouncement(.working) == "Hermes is working")
        #expect(VoiceTabDisplay.liveAnnouncement(.live) == nil)
        #expect(VoiceTabDisplay.liveAnnouncement(.reconnecting) == nil)
    }

    @Test func voiceOverLabelAndMiniTitle() throws {
        let live = try #require(show(.live))
        #expect(live.liveAccessibilityLabel(elapsedSeconds: 134) == "Live Mode, Live. Speak any time, 2:14")
        #expect(try #require(show(.connecting)).liveAccessibilityLabel(elapsedSeconds: 0)
                == "Live Mode, Connecting…, 0:00")
        #expect(VoiceTabDisplay.liveMiniTitle(elapsedSeconds: 134) == "Live 2:14")
        #expect(VoiceTabDisplay.liveMiniTitle(elapsedSeconds: 3_600) == "Live 60:00")
        // Hands-free states are not live.
        #expect(!VoiceTabDisplay.make(state: .listening, muted: false, thinkingSeconds: 0).isLive)
    }

    @Test func theLineUnderThePicker() {
        let on = LiveAvailability(status: VoiceLiveStatus(mode: .gptLive, available: true))
        #expect(on == .available)
        #expect(on.line(server: "Hostinger", selected: true) == "About $0.05 a minute")
        #expect(on.line(server: "Hostinger", selected: false) == nil)
        let off = LiveAvailability(status: VoiceLiveStatus(mode: .chained, available: false))
        #expect(!off.isAvailable)
        #expect(off.line(server: "Ouro", selected: false) == "Live is not available on Ouro.")
        let reason = LiveAvailability(status: VoiceLiveStatus(mode: .chained, available: false,
                                                              reason: "GPT-Live is off on this server."))
        #expect(reason.line(server: "Ouro", selected: false) == "GPT-Live is off on this server.")
        let blank = LiveAvailability(status: VoiceLiveStatus(mode: .chained, available: false, reason: "  "))
        #expect(blank.line(server: "Ouro", selected: false) == "Live is not available on Ouro.")
        #expect(LiveAvailability.failed.line(server: "Ouro", selected: false) == "Live is not available on Ouro.")
        #expect(LiveAvailability.failed.line(server: nil, selected: false) == "Live is not available on this server.")
        #expect(LiveAvailability(status: nil) == .olderServer)
        #expect(LiveAvailability.olderServer.line(server: "Ouro", selected: false)
                == "This Hermes version has no Live mode.")
        #expect(LiveAvailability.checking.line(server: "Ouro", selected: false) == nil)
    }

    @Test func theModeStaysForEachServer() {
        let suite = "live-mode-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = VoiceTabModeStore(suite: suite)
        let home = UUID()
        let other = UUID()
        #expect(store.load(server: home) == .handsFree)
        store.save(.live, server: home)
        #expect(store.load(server: home) == .live)
        #expect(store.load(server: other) == .handsFree)
        store.save(.handsFree, server: other)
        #expect(VoiceTabModeStore(suite: suite).load(server: home) == .live)
        #expect(VoiceTabModeStore(suite: suite).load(server: other) == .handsFree)
    }
}
