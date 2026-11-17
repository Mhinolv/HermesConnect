#if DEBUG
import Foundation
import HermesKit

/// DEBUG only: the Parakeet row states for the issue #44 screenshots. Nothing downloads.
@MainActor
enum TranscriptionSettingsDemo {
    private struct Downloader: TranscriptionModelDownloading {
        let installed: Bool
        func isInstalled(at _: URL) -> Bool { installed }
        func download(to _: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
            progress(0.42)
            try await Task.sleep(for: .seconds(3600))
        }
    }

    /// One store per launch. The App body runs more than once, and a new store would restart the demo.
    private static var cached: TranscriptionModelStore?

    static func store(for scenario: DemoChatTransport.Scenario) -> TranscriptionModelStore {
        if let cached { return cached }
        let engine: TranscriptionEngine = scenario == .voiceSettings ? .appleOnDevice : .parakeet
        UserDefaults.standard.set(engine.rawValue, forKey: TranscriptionEngine.settingsKey)
        let store = TranscriptionModelStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("demo-parakeet"),
            downloader: Downloader(installed: scenario == .voiceSettingsReady || scenario == .voiceSettingsDamaged),
            sizeBytes: ParakeetTranscriber.sizeBytes)
        if scenario == .voiceSettingsDownloading { store.download() }
        if scenario == .voiceSettingsDamaged { store.reportLoadFailure() }
        cached = store
        return store
    }
}
#endif
