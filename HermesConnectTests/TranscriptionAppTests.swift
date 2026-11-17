import Foundation
import HermesKit
import Testing
@testable import HermesConnect

/// Issue #44: the app wiring of on-device transcription. No model downloads in tests.
@MainActor
@Suite(.serialized) struct TranscriptionAppTests {
    @Test func parakeetIsNotInstalledInAnEmptyFolder() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-\(UUID().uuidString)")
        #expect(!ParakeetDownloader().isInstalled(at: empty))
    }

    @Test func parakeetWithNoModelFallsBackToApple() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: TranscriptionEngine.settingsKey)
        defer { defaults.set(saved, forKey: TranscriptionEngine.settingsKey) }
        let shared = OnDeviceTranscription.shared
        defaults.removeObject(forKey: TranscriptionEngine.settingsKey)
        #expect(shared.transcription.effectiveEngine == .appleOnDevice)
        defaults.set(TranscriptionEngine.server.rawValue, forKey: TranscriptionEngine.settingsKey)
        #expect(shared.transcription.effectiveEngine == .server)
        if !shared.parakeetModel.isReady {
            defaults.set(TranscriptionEngine.parakeet.rawValue, forKey: TranscriptionEngine.settingsKey)
            #expect(shared.transcription.effectiveEngine == .appleOnDevice)
            #expect(shared.parakeetModel.downloadTitle.hasPrefix("Download ("))
        }
    }

    @Test func liveSessionsUseTheOnDeviceTranscription() {
        #expect(OnDeviceTranscription.shared.transcription.apple != nil)
        #expect(OnDeviceTranscription.shared.transcription.parakeet != nil)
    }

    /// QA 52-1: FluidAudio is offline from launch, so a model that fails to load never downloads again.
    @Test func modelLibraryIsOfflineAfterLaunchAndAfterADownload() async throws {
        OnDeviceTranscription.lockModelNetwork()
        _ = OnDeviceTranscription.shared
        #expect(ParakeetDownloader.isLibraryOffline)
        let probe = OnlineProbe()
        let gate = OfflineGatedDownloader(base: probe, setOffline: ParakeetDownloader.setLibraryOffline)
        try await gate.download(to: FileManager.default.temporaryDirectory) { _ in }
        #expect(probe.wasOnline)
        #expect(ParakeetDownloader.isLibraryOffline)
    }

    @Test func damagedTextShowsInSettings() {
        #expect(TranscriptionModelStore.damagedText == "Parakeet model damaged. Download again.")
    }

    @Test func footerSaysWhatLeavesThePhone() {
        #expect(TranscriptionSettingsSection.footer.contains("on this iPhone"))
        #expect(TranscriptionSettingsSection.notDownloadedFooter == "Parakeet is not downloaded.")
    }
}

/// Reads the real FluidAudio switch while the "download" runs. Nothing goes to the network.
private final class OnlineProbe: TranscriptionModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var _wasOnline = false
    var wasOnline: Bool { lock.withLock { _wasOnline } }
    func isInstalled(at _: URL) -> Bool { false }
    func download(to _: URL, progress _: @escaping @Sendable (Double) -> Void) async throws {
        let online = !ParakeetDownloader.isLibraryOffline
        lock.withLock { _wasOnline = online }
    }
}
