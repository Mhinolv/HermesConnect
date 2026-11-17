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

    @Test func footerSaysWhatLeavesThePhone() {
        #expect(TranscriptionSettingsSection.footer.contains("on this iPhone"))
        #expect(TranscriptionSettingsSection.notDownloadedFooter == "Parakeet is not downloaded.")
    }
}
