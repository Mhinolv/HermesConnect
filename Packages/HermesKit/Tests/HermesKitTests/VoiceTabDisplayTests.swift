import Foundation
import Testing
@testable import HermesKit

// Issue #101: the Voice tab text and ring for each engine state, the tap rules and the target chat choice.

@Suite struct VoiceTabDisplayTests {
    private func show(_ state: VoiceModeState, muted: Bool = false, seconds: Int = 0, barge: Bool = false)
        -> VoiceTabDisplay {
        VoiceTabDisplay.make(state: state, muted: muted, thinkingSeconds: seconds, afterBargeIn: barge)
    }

    @Test func eachStateHasTheTitleAndSubLineOfTheDesignNotes() {
        let rows: [(VoiceModeState, VoiceRingStyle, String, String?)] = [
            (.idle, .idle, "Tap to Talk", "Hermes answers out loud"),
            (.listening, .listening, "Listening", "Stops after a short pause"),
            (.transcribing, .working, "Transcribing…", "Hermes is working"),
            (.thinking, .working, "Thinking…", "Hermes is working · 0 s"),
            (.speaking, .speaking, "Speaking", "Tap or speak to interrupt"),
            (.interrupted, .listening, "Listening", "Reply stopped"),
            (.muted, .muted, "Muted", "Tap Mute to listen again"),
            (.paused(.call), .paused, "Paused", "A call paused voice mode"),
        ]
        for (state, ring, title, subtitle) in rows {
            let display = show(state)
            #expect(display.ring == ring, "\(state)")
            #expect(display.title == title, "\(state)")
            #expect(display.subtitle == subtitle, "\(state)")
            #expect(display.ringAccessibilityLabel == "Voice Mode, \(title)")
        }
        #expect(!show(.idle).isSession)
        #expect(show(.listening).isSession)
        #expect(show(.paused(.lock)).action == .resume)
        #expect(!show(.paused(.lock)).muteEnabled)
    }

    @Test func thinkingCountsSecondsThenSaysStillWorking() {
        #expect(show(.thinking, seconds: 6).subtitle == "Hermes is working · 6 s")
        #expect(show(.thinking, seconds: 9).subtitle == "Hermes is working · 9 s")
        #expect(show(.thinking, seconds: 10).subtitle == "Still working…")
        #expect(show(.thinking, seconds: 45).subtitle == "Still working…")
    }

    @Test func listeningAfterABargeInSaysReplyStopped() {
        #expect(show(.listening, barge: true).subtitle == "Reply stopped")
        #expect(show(.listening, barge: true).title == "Listening")
    }

    @Test func endedStatesShowIdleWithTheReason() {
        #expect(show(.ended(.end)) == show(.idle))
        #expect(show(.ended(.silence)).title == "Tap to Talk")
        #expect(show(.ended(.silence)).subtitle == "Voice mode ended after 30 s of silence")
        #expect(show(.ended(.stopWord)).subtitle == "Voice mode ended when you said “stop”")
        #expect(!show(.ended(.silence)).isSession)
    }

    @Test func errorsShowTheirActions() {
        #expect(show(.error(.microphoneOff)).action == .openSettings)
        #expect(show(.error(.microphoneOff)).title == "Microphone Off")
        #expect(show(.error(.offline)).action == .tryAgain)
        #expect(show(.error(.turnFailed)).action == .tryAgain)
        #expect(show(.error(.speakFailed)).subtitle == "The reply is in the chat")
        #expect(show(.error(.offline)).isSession)
    }

    @Test func muteKeyFollowsTheEngine() {
        #expect(show(.muted, muted: true).muteOn)
        #expect(show(.speaking, muted: true).muteOn)
        #expect(!show(.listening).muteOn)
        #expect(show(.listening).muteEnabled)
    }

    @Test func ringTapAndMagicTap() {
        #expect(VoiceTabDisplay.ringTap(.idle) == .start)
        #expect(VoiceTabDisplay.ringTap(.ended(.silence)) == .start)
        #expect(VoiceTabDisplay.ringTap(.speaking) == .interrupt)
        #expect(VoiceTabDisplay.ringTap(.paused(.background)) == .resume)
        #expect(VoiceTabDisplay.ringTap(.error(.offline)) == .resume)
        #expect(VoiceTabDisplay.ringTap(.listening) == .none)
        #expect(VoiceTabDisplay.ringTap(.thinking) == .none)
        #expect(VoiceTabDisplay.magicTap(.listening) == .send)
        #expect(VoiceTabDisplay.magicTap(.idle) == .start)
        #expect(VoiceTabDisplay.magicTap(.speaking) == .interrupt)
        #expect(VoiceTabDisplay.announcement(.thinking) == "Thinking")
        #expect(VoiceTabDisplay.announcement(.listening) == nil)
        #expect(VoiceTabDisplay.announcement(.speaking) == nil)
    }

    @Test func targetChoiceStaysAndAChatOfAnotherServerReadsAsActive() throws {
        let suite = "voice-target-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = VoiceTargetStore(suite: suite)
        let home = UUID()
        #expect(store.load(server: home) == .active)
        store.save(.new)
        #expect(store.load(server: home) == .new)
        #expect(VoiceTargetStore(suite: suite).load(server: nil) == .new)
        store.save(.chosen(id: "s7", title: "Weekend trip plan", server: home))
        #expect(store.load(server: home) == .chosen(id: "s7", title: "Weekend trip plan", server: home))
        #expect(store.load(server: UUID()) == .active)
        UserDefaults(suiteName: suite)?.set(Data("junk".utf8), forKey: VoiceTargetStore.defaultsKey)
        #expect(store.load(server: home) == .active)
    }

    @Test func activeChatIsTheOpenChatThenTheLastThenTheNewest() {
        let rows = [SessionListItem(id: "a"), SessionListItem(id: "b")]
        #expect(VoiceTargetResolver.activeSessionId(open: "o", lastActive: "l", rows: rows) == "o")
        #expect(VoiceTargetResolver.activeSessionId(open: nil, lastActive: "l", rows: rows) == "l")
        #expect(VoiceTargetResolver.activeSessionId(open: nil, lastActive: nil, rows: rows) == "a")
        #expect(VoiceTargetResolver.activeSessionId(open: nil, lastActive: nil, rows: []) == nil)
    }
}
