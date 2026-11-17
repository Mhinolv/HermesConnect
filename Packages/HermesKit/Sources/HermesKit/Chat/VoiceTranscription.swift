import Foundation
import Observation

/// Settings > Voice > "Transcription" (issue #44). Apple On-Device is the default.
public enum TranscriptionEngine: String, CaseIterable, Sendable {
    /// iOS 26 `SpeechAnalyzer` / `SpeechTranscriber`, on-device only.
    case appleOnDevice = "apple"
    /// NVIDIA Parakeet TDT v3 on Core ML (FluidAudio). The owner downloads the model in Settings.
    case parakeet
    /// `POST /api/audio/transcribe` on the Hermes server (issue #9).
    case server

    /// The `UserDefaults` key of the picker.
    public static let settingsKey = "voice.transcriptionEngine"

    /// The saved choice. No value, or a value from a later build, gives Apple On-Device.
    public static func current(_ defaults: UserDefaults = .standard) -> TranscriptionEngine {
        defaults.string(forKey: settingsKey).flatMap(TranscriptionEngine.init(rawValue:)) ?? .appleOnDevice
    }

    public var title: String {
        switch self {
        case .appleOnDevice: "Apple On-Device"
        case .parakeet: "Parakeet"
        case .server: "Server"
        }
    }

    /// `true` when the transcript is made on the iPhone.
    public var isOnDevice: Bool { self != .server }
}

/// One on-device recognizer. It throws when it cannot run (no model, no permission, a decode error).
public protocol OnDeviceTranscriber: Sendable {
    func transcribe(fileURL: URL) async throws -> String
}

/// Picks the recognizer for a voice memo and falls back to the server (issue #44).
///
/// - Parakeet picked but not downloaded: Apple On-Device (design notes).
/// - An on-device failure or an empty on-device result: the server path. The memo is never lost.
/// - Server: only `POST /api/audio/transcribe`, as before.
public struct VoiceTranscription: Sendable {
    public var engine: @Sendable () -> TranscriptionEngine
    public var apple: (any OnDeviceTranscriber)?
    public var parakeet: (any OnDeviceTranscriber)?
    public var parakeetReady: @Sendable () -> Bool

    public init(engine: @escaping @Sendable () -> TranscriptionEngine, apple: (any OnDeviceTranscriber)?,
                parakeet: (any OnDeviceTranscriber)?, parakeetReady: @escaping @Sendable () -> Bool) {
        self.engine = engine
        self.apple = apple
        self.parakeet = parakeet
        self.parakeetReady = parakeetReady
    }

    /// The server path only: tests, previews and the demo transport.
    public static let server = VoiceTranscription(engine: { .server }, apple: nil, parakeet: nil,
                                                  parakeetReady: { false })

    /// The engine that runs for the next memo.
    public var effectiveEngine: TranscriptionEngine {
        let choice = engine()
        if choice == .parakeet, !parakeetReady() { return .appleOnDevice }
        return choice
    }

    /// The trimmed transcript. `server` runs `POST /api/audio/transcribe`; it runs only when the on-device
    /// path is off or fails. Neither the clip nor the text goes to a log.
    public func transcribe(fileURL: URL, server: @Sendable () async throws -> String) async throws -> String {
        let log = HermesLog(category: "voice")
        let chosen = effectiveEngine
        let recognizer: (any OnDeviceTranscriber)? = switch chosen {
        case .appleOnDevice: apple
        case .parakeet: parakeet
        case .server: nil
        }
        if let recognizer {
            do {
                let text = try await recognizer.transcribe(fileURL: fileURL)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    log.info("memo transcribed on device: \(chosen.rawValue)")
                    return text
                }
                log.notice("on-device transcript empty: \(chosen.rawValue), server fallback")
            } catch {
                log.notice("on-device transcription failed: \(chosen.rawValue), server fallback")
            }
        }
        return try await server().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Parakeet model store

/// Downloads one on-device model. The app uses FluidAudio. Tests use a fake.
public protocol TranscriptionModelDownloading: Sendable {
    /// `true` when `directory` holds a model that loads.
    func isInstalled(at directory: URL) -> Bool
    /// Downloads into `directory` and reports a fraction from 0 to 1. Task cancellation stops it.
    func download(to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// The Parakeet row of Settings > Voice (issue #44): "Download (<size>)", progress with Cancel, "Delete Model".
/// The download is the only network call of the on-device engines. It starts only when the owner taps Download.
@MainActor @Observable
public final class TranscriptionModelStore {
    public enum State: Sendable, Equatable {
        case notDownloaded
        /// The fraction from 0 to 1.
        case downloading(Double)
        case ready
        /// The last download failed. The row shows the Download button again.
        case failed
    }

    public private(set) var state: State
    public let sizeBytes: Int64
    @ObservationIgnored public nonisolated let directory: URL
    @ObservationIgnored private nonisolated let downloader: any TranscriptionModelDownloading
    @ObservationIgnored private let onDelete: @Sendable () async -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let log = HermesLog(category: "voice")

    public init(directory: URL, downloader: any TranscriptionModelDownloading, sizeBytes: Int64,
                onDelete: @escaping @Sendable () async -> Void = {}) {
        self.directory = directory
        self.downloader = downloader
        self.sizeBytes = sizeBytes
        self.onDelete = onDelete
        state = downloader.isInstalled(at: directory) ? .ready : .notDownloaded
    }

    /// Any thread. The voice memo path reads it for each memo.
    public nonisolated var isReady: Bool { downloader.isInstalled(at: directory) }

    /// "Download (485 MB)".
    public var downloadTitle: String {
        "Download (\(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)))"
    }

    public func download() {
        switch state {
        case .downloading, .ready: return
        case .notDownloaded, .failed: break
        }
        state = .downloading(0)
        let downloader = self.downloader
        let directory = self.directory
        log.info("model download started")
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.progress(fraction) }
        }
        task = Task { [weak self] in
            do {
                try await downloader.download(to: directory, progress: report)
                try Task.checkCancellation()
                self?.finish(.ready)
            } catch {
                guard !Task.isCancelled else { return }
                try? FileManager.default.removeItem(at: directory)
                self?.finish(.failed)
            }
        }
    }

    /// Cancel while it downloads: stop and remove the part files.
    public func cancel() {
        guard case .downloading = state else { return }
        task?.cancel()
        task = nil
        state = .notDownloaded
        log.info("model download cancelled")
        let directory = self.directory
        Task.detached { try? FileManager.default.removeItem(at: directory) }
    }

    /// "Delete Model". The memo path then uses Apple On-Device.
    public func delete() async {
        task?.cancel()
        task = nil
        await onDelete()
        let directory = self.directory
        await Task.detached { try? FileManager.default.removeItem(at: directory) }.value
        state = .notDownloaded
        log.info("model deleted")
    }

    private func progress(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(min(1, max(0, fraction)))
    }

    private func finish(_ result: State) {
        guard case .downloading = state else { return }
        task = nil
        state = result
        log.info("model download ended: \(result == .ready ? "ready" : "failed")")
    }
}
