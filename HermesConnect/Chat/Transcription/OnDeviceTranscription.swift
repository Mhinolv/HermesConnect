import Foundation
import HermesKit

/// Issue #44: the voice memo transcription of the app. One instance for the life of the app.
/// Settings > Voice shows `parakeetModel` and `appleAssets`. Each chat gets `transcription`.
@MainActor
final class OnDeviceTranscription {
    static let shared = OnDeviceTranscription()

    let parakeetModel: TranscriptionModelStore
    let appleAssets = AppleSpeechAssets()
    let transcription: VoiceTranscription

    private init() {
        let parakeet = ParakeetTranscriber()
        let store = TranscriptionModelStore(directory: ParakeetTranscriber.directory, downloader: ParakeetDownloader(),
                                            sizeBytes: ParakeetTranscriber.sizeBytes,
                                            onDelete: { await parakeet.unload() })
        parakeetModel = store
        transcription = VoiceTranscription(engine: { TranscriptionEngine.current() }, apple: AppleSpeechTranscriber(),
                                           parakeet: parakeet, parakeetReady: { store.isReady })
    }
}
