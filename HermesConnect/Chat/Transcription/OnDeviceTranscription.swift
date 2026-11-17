import Foundation
import HermesKit
import Synchronization

/// Issue #44: the voice memo transcription of the app. One instance for the life of the app.
/// Settings > Voice shows `parakeetModel` and `appleAssets`. Each chat gets `transcription`.
@MainActor
final class OnDeviceTranscription {
    static let shared = OnDeviceTranscription()

    let parakeetModel: TranscriptionModelStore
    let appleAssets = AppleSpeechAssets()
    let transcription: VoiceTranscription

    /// QA 52-1: FluidAudio starts offline. Call it first at launch, before any model code runs.
    static func lockModelNetwork() {
        ParakeetDownloader.setLibraryOffline(true)
    }

    private init() {
        let relay = LoadFailureRelay()
        let parakeet = ParakeetTranscriber(onLoadFailure: { relay.report() })
        let downloader = OfflineGatedDownloader(base: ParakeetDownloader(),
                                                setOffline: ParakeetDownloader.setLibraryOffline)
        let store = TranscriptionModelStore(directory: ParakeetTranscriber.directory, downloader: downloader,
                                            sizeBytes: ParakeetTranscriber.sizeBytes,
                                            onDelete: { await parakeet.unload() })
        relay.attach(store)
        parakeetModel = store
        transcription = VoiceTranscription(engine: { TranscriptionEngine.current() }, apple: AppleSpeechTranscriber(),
                                           parakeet: parakeet, parakeetReady: { store.isReady })
    }
}

/// Sends a Parakeet load failure to the model store. The store is made after the recognizer.
private final class LoadFailureRelay: Sendable {
    private let store = Mutex<TranscriptionModelStore?>(nil)
    func attach(_ model: TranscriptionModelStore) { store.withLock { $0 = model } }
    func report() { store.withLock { $0 }?.reportLoadFailure() }
}
