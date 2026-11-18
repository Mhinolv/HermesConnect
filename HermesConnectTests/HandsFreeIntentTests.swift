import AppIntents
import Foundation
import HermesKit
import Testing
@testable import HermesConnect

// Issue #124: the "Start Hands-Free" Siri shortcut. Fakes only: no server, no microphone.

@MainActor
private final class HandsFreeMic: VoiceModeMicrophone {
    var access: VoiceModeMicrophoneAccess = .granted
    private(set) var activations = 0
    private(set) var isOpen = false

    func requestAccess() async -> Bool { false }
    func activate() throws { activations += 1 }
    func deactivate() {}
    func startClip(url _: URL) throws { isOpen = true }
    func stopClip() -> TimeInterval {
        isOpen = false
        return 1
    }
    func discardClip() { isOpen = false }
    func level() -> Float { -60 }
}

private final class MutePlayer: StreamedSpeechPlaying, @unchecked Sendable {
    func begin(sampleRate _: Double) throws {}
    func enqueue(_: Data) {}
    func drain() async {}
    func playClip(_: SpokenAudio) async throws {}
    func stop() {}
}

private struct NoSpeech: Error {}

@MainActor
@Suite(.serialized) struct HandsFreeIntentTests {
    private let home = ServerProfile(host: "home.example.com", displayName: "Home", hostKey: .sample)
    private let hostinger = ServerProfile(host: "100.64.0.9", displayName: "Hostinger", hostKey: .sample)

    private func voice(_ mic: HandsFreeMic) -> VoiceTabModel {
        let suite = "hands-free-\(UUID().uuidString)"
        return VoiceTabModel(sessions: ChatLaunch.makeOfflineSessions(), store: VoiceTargetStore(suite: suite),
                             modeStore: VoiceTabModeStore(suite: suite)) {
            VoiceModeSessionModel(controller: VoiceModeController(
                microphone: mic, player: MutePlayer(), makeSpeech: { _ in throw NoSpeech() },
                makeClipURL: { FileManager.default.temporaryDirectory.appending(path: "hands-free-\(UUID()).m4a") },
                removeFile: { _ in }, autoTick: false))
        }
    }

    /// The route of `RootView.startHandsFree()`: the normal switch, then the Voice tab session.
    private func run(_ request: HandsFreeRequest, app: AppModel, voice: VoiceTabModel) async {
        await HandsFreeLaunch.run(request, active: app.profile?.id, servers: Set(app.servers.map(\.id)),
                                  switchServer: { await app.switchServer(to: $0) },
                                  start: { await voice.startHandsFree(server: app.profile?.id) })
    }

    @Test func theIntentOpensTheAppAndHasTheDesignTitles() throws {
        #expect(String(localized: StartHandsFreeIntent.title) == "Start Hands-Free")
        #expect(StartHandsFreeIntent.supportedModes == .foreground)
        #expect(HermesShortcuts.appShortcuts.count == 3)
        let url = try #require(Bundle(for: AppModel.self).url(forResource: "extract", withExtension: "actionsdata",
                                                               subdirectory: "Metadata.appintents"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("StartHandsFreeIntent"))
        #expect(text.contains("Start Hands-Free in ${applicationName}"))
        #expect(text.contains("ServerEntity"))
    }

    @Test func performPostsTheChosenServerToTheInbox() async throws {
        _ = HandsFreeInbox.shared.next(isSetUp: true, isLocked: false)
        _ = try await StartHandsFreeIntent(server: ServerEntity(hostinger)).perform()
        #expect(HandsFreeInbox.shared.pending?.server == hostinger.id)
        _ = try await StartHandsFreeIntent(server: nil).perform()
        let request = try #require(HandsFreeInbox.shared.pending)
        #expect(request.server == nil, "no server uses the active server")
        #expect(HandsFreeInbox.shared.next(isSetUp: true, isLocked: true) == nil, "App Lock runs first")
        #expect(HandsFreeInbox.shared.next(isSetUp: true, isLocked: false) == .run(request))
    }

    @Test func theServerQueryListsTheSavedServersAndDefaultsToTheActiveOne() async throws {
        let old = ServerEntityQuery.loadList
        ServerEntityQuery.loadList = { [home, hostinger] in ServerList(servers: [home, hostinger], activeID: hostinger.id) }
        defer { ServerEntityQuery.loadList = old }
        let query = ServerEntityQuery()
        #expect(try await query.suggestedEntities().map(\.name) == ["Home", "Hostinger"])
        #expect(try await query.entities(for: [home.id, UUID()]).map(\.id) == [home.id])
        #expect(await query.defaultResult()?.id == hostinger.id)
        #expect(String(localized: ServerEntity(hostinger).displayRepresentation.title) == "Hostinger")
    }

    @Test func aServerThatIsNotActiveBecomesActiveBeforeTheSessionStarts() async {
        let app = AppModel.preview(servers: [home, hostinger], activeIndex: 0)
        let mic = HandsFreeMic()
        let voice = voice(mic)
        voice.serverChanged(home.id)
        await run(HandsFreeRequest(server: hostinger.id), app: app, voice: voice)
        #expect(app.profile?.id == hostinger.id)
        #expect(voice.isRunning)
        #expect(voice.mode == .handsFree)
        #expect(voice.state == .listening, "the Voice tab looks as if the owner tapped the ring")
        #expect(mic.activations == 1)
        #expect(mic.isOpen)
        // The onChange of the root runs after the switch. It does not end the session.
        voice.serverChanged(app.profile?.id)
        #expect(voice.isRunning)
        voice.end()
    }

    @Test func theActiveServerOrARemovedServerStartsWithNoSwitch() async {
        let app = AppModel.preview(servers: [home, hostinger], activeIndex: 0)
        let mic = HandsFreeMic()
        let voice = voice(mic)
        await run(HandsFreeRequest(server: UUID()), app: app, voice: voice)
        #expect(app.profile?.id == home.id)
        #expect(voice.isRunning)
        voice.end()
        await run(HandsFreeRequest(server: nil), app: app, voice: voice)
        #expect(app.profile?.id == home.id)
        #expect(voice.isRunning)
        voice.end()
    }

    @Test func noMicrophonePermissionShowsTheNormalVoiceTabError() async {
        let app = AppModel.preview(servers: [home], activeIndex: 0)
        let mic = HandsFreeMic()
        mic.access = .denied
        let voice = voice(mic)
        await run(HandsFreeRequest(server: nil), app: app, voice: voice)
        #expect(voice.state == .error(.microphoneOff))
        #expect(voice.display.action == .openSettings)
        #expect(!mic.isOpen)
        voice.end()
    }
}
