import Foundation
import Testing
@testable import HermesKit

/// Issue #124: the "Start Hands-Free" Siri shortcut. No server, no microphone.
@MainActor
@Suite struct HandsFreeShortcutTests {
    @Test func nothingWaitsGivesNoStep() {
        let inbox = HandsFreeInbox()
        #expect(inbox.next(isSetUp: true, isLocked: false) == nil)
    }

    @Test func appLockKeepsTheRequestUntilTheUnlock() {
        let inbox = HandsFreeInbox()
        let request = inbox.post(server: UUID())
        #expect(inbox.next(isSetUp: true, isLocked: true) == nil)
        #expect(inbox.pending == request)
        #expect(inbox.next(isSetUp: true, isLocked: false) == .run(request))
        #expect(inbox.pending == nil, "the request runs once")
        #expect(inbox.next(isSetUp: true, isLocked: false) == nil)
    }

    @Test func noSetupDropsTheRequestForTheSetupScreen() {
        let inbox = HandsFreeInbox()
        inbox.post(server: nil)
        #expect(inbox.next(isSetUp: false, isLocked: true) == .dropForSetup)
        #expect(inbox.pending == nil)
    }

    @Test func aNewerRunReplacesTheOneThatWaits() {
        let inbox = HandsFreeInbox()
        inbox.post(server: UUID())
        let lab = UUID()
        let newer = inbox.post(server: lab)
        #expect(inbox.next(isSetUp: true, isLocked: false) == .run(newer))
        #expect(newer.server == lab)
    }

    @Test func switchTargetOnlyForAKnownServerThatIsNotActive() {
        let home = UUID(), lab = UUID(), removed = UUID()
        let servers: Set = [home, lab]
        #expect(HandsFreeLaunch.switchTarget(HandsFreeRequest(server: lab), active: home, servers: servers) == lab)
        #expect(HandsFreeLaunch.switchTarget(HandsFreeRequest(server: home), active: home, servers: servers) == nil)
        #expect(HandsFreeLaunch.switchTarget(HandsFreeRequest(server: nil), active: home, servers: servers) == nil)
        #expect(HandsFreeLaunch.switchTarget(HandsFreeRequest(server: removed), active: home, servers: servers) == nil)
    }

    @Test func runSwitchesBeforeTheSessionStarts() async {
        let home = UUID(), lab = UUID()
        var steps: [String] = []
        await HandsFreeLaunch.run(HandsFreeRequest(server: lab), active: home, servers: [home, lab],
                                  switchServer: { steps.append("switch \($0 == lab)") },
                                  start: { steps.append("start") })
        #expect(steps == ["switch true", "start"])
    }

    @Test func runOnTheActiveServerStartsWithNoSwitch() async {
        let home = UUID()
        var steps: [String] = []
        await HandsFreeLaunch.run(HandsFreeRequest(server: nil), active: home, servers: [home],
                                  switchServer: { _ in steps.append("switch") },
                                  start: { steps.append("start") })
        #expect(steps == ["start"])
    }
}
