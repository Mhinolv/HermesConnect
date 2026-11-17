import FluidAudio
import Foundation
import HermesKit

/// Issue #44: NVIDIA Parakeet TDT 0.6B v3 (int8 encoder) on Core ML, through FluidAudio (Apache-2.0).
/// The encoder runs on the Neural Engine (FluidAudio default: `.cpuAndNeuralEngine`).
/// The models load on the first memo after launch and stay loaded until "Delete Model".
/// QA 52-1: FluidAudio is offline here (`ModelHub.offlineMode`), so a load error never downloads again.
/// The error goes to `onLoadFailure` (the model shows as damaged), and the memo uses the next step.
actor ParakeetTranscriber: OnDeviceTranscriber {
    enum Failure: Error { case notDownloaded }

    private let onLoadFailure: @Sendable () -> Void

    init(onLoadFailure: @escaping @Sendable () -> Void = {}) {
        self.onLoadFailure = onLoadFailure
    }

    /// The folder of the model in Application Support. FluidAudio keeps the repo folder name.
    static var directory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
    }

    /// About the size of the int8 encoder, decoder, joint, preprocessor and vocabulary (spike, 2026-11-17).
    static let sizeBytes: Int64 = 485_000_000

    private var manager: AsrManager?
    private var version: AsrModelVersion = .v3

    func transcribe(fileURL: URL) async throws -> String {
        let manager = try await loadedManager()
        var state = try TdtDecoderState(decoderLayers: version.decoderLayers)
        return try await manager.transcribe(fileURL, decoderState: &state).text
    }

    /// "Delete Model": free the loaded models before the files go.
    func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        let directory = Self.directory
        guard AsrModels.modelsExist(at: directory, version: .v3) else { throw Failure.notDownloaded }
        let manager = AsrManager(config: .default)
        do {
            let models = try await AsrModels.load(from: directory, version: .v3)
            try await manager.loadModels(models)
            version = models.version
        } catch {
            onLoadFailure()
            throw error
        }
        self.manager = manager
        return manager
    }
}

/// The FluidAudio download for `TranscriptionModelStore`. It reaches only Hugging Face
/// (`FluidInference/parakeet-tdt-0.6b-v3-coreml`), and only when the owner taps Download.
/// The app wraps it in `OfflineGatedDownloader`, so FluidAudio is online only while it runs.
struct ParakeetDownloader: TranscriptionModelDownloading {
    /// QA 52-1: FluidAudio may download only inside the owner's download. The app calls this at launch.
    static func setLibraryOffline(_ offline: Bool) { ModelHub.offlineMode = offline }
    static var isLibraryOffline: Bool { ModelHub.offlineMode }

    func isInstalled(at directory: URL) -> Bool {
        AsrModels.modelsExist(at: directory, version: .v3)
    }

    func download(to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await AsrModels.download(to: directory, version: .v3) { update in
            progress(update.fractionCompleted)
        }
        // The model can come back from Hugging Face: keep it out of the iCloud backup.
        var parent = directory.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? parent.setResourceValues(values)
    }
}
