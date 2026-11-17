import Foundation
import Observation
import Synchronization

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
    /// Issue #50: the same, with the fraction of the audio done (0 to 1). A recognizer with no progress
    /// reports nothing. Task cancellation stops it.
    func transcribe(fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String
}

extension OnDeviceTranscriber {
    public func transcribe(fileURL: URL, progress _: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await transcribe(fileURL: fileURL)
    }
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

    /// The on-device recognizers to try, in order. Parakeet falls back to Apple On-Device (QA 52-1).
    var chain: [(TranscriptionEngine, any OnDeviceTranscriber)] {
        let steps: [(TranscriptionEngine, (any OnDeviceTranscriber)?)] = switch effectiveEngine {
        case .parakeet: [(.parakeet, parakeet), (.appleOnDevice, apple)]
        case .appleOnDevice: [(.appleOnDevice, apple)]
        case .server: []
        }
        return steps.compactMap { engine, recognizer in recognizer.map { (engine, $0) } }
    }

    /// The trimmed transcript. `server` runs `POST /api/audio/transcribe`; it runs only when the on-device
    /// path is off or every on-device step fails. Neither the clip nor the text goes to a log.
    public func transcribe(fileURL: URL, server: @Sendable () async throws -> String) async throws -> String {
        let log = HermesLog(category: "voice")
        for (engine, recognizer) in chain {
            do {
                let text = try await recognizer.transcribe(fileURL: fileURL)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    log.info("memo transcribed on device: \(engine.rawValue)")
                    return text
                }
                log.notice("on-device transcript empty: \(engine.rawValue), next step")
            } catch {
                log.notice("on-device transcription failed: \(engine.rawValue), next step")
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

/// QA 52-1: the model library may download on its own (FluidAudio purges a model that fails to load and
/// downloads it again). This wrapper keeps the library offline, except while the owner's download runs.
/// `setOffline` is `ModelHub.offlineMode` in the app. It is off at once when the wrapper is made.
public struct OfflineGatedDownloader: TranscriptionModelDownloading {
    private let base: any TranscriptionModelDownloading
    private let setOffline: @Sendable (Bool) -> Void

    public init(base: any TranscriptionModelDownloading, setOffline: @escaping @Sendable (Bool) -> Void) {
        self.base = base
        self.setOffline = setOffline
        setOffline(true)
    }

    public func isInstalled(at directory: URL) -> Bool { base.isInstalled(at: directory) }

    /// The only time the library may reach the network. It is offline again when the download ends or fails.
    public func download(to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        setOffline(false)
        defer { setOffline(true) }
        try await base.download(to: directory, progress: progress)
    }
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
        /// QA 52-1: the model is on disk but did not load. The row shows `damagedText` and Download.
        case damaged
    }

    public static let damagedText = "Parakeet model damaged. Download again."

    public private(set) var state: State
    public let sizeBytes: Int64
    @ObservationIgnored public nonisolated let directory: URL
    @ObservationIgnored private nonisolated let downloader: any TranscriptionModelDownloading
    /// Set by a failed load, on any thread. A damaged model is not ready, so memos skip Parakeet.
    @ObservationIgnored private nonisolated let damaged = Mutex(false)
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
    public nonisolated var isReady: Bool {
        !damaged.withLock { $0 } && downloader.isInstalled(at: directory)
    }

    /// The Parakeet recognizer calls this when the model on disk does not load. It never downloads again:
    /// the owner sees `damagedText` and taps Download.
    public nonisolated func reportLoadFailure() {
        damaged.withLock { $0 = true }
        Task { @MainActor [weak self] in self?.markDamaged() }
    }

    private nonisolated func clearDamage() { damaged.withLock { $0 = false } }

    private func markDamaged() {
        guard state == .ready else { return }
        state = .damaged
        log.notice("model damaged: load failed")
    }

    /// "Download (485 MB)".
    public var downloadTitle: String {
        "Download (\(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)))"
    }

    public func download() {
        switch state {
        case .downloading, .ready: return
        case .notDownloaded, .failed, .damaged: break
        }
        let wasDamaged = state == .damaged
        state = .downloading(0)
        let downloader = self.downloader
        let directory = self.directory
        log.info("model download started")
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.progress(fraction) }
        }
        task = Task { [weak self] in
            do {
                if wasDamaged {
                    // Download the whole model again: a resume could keep the bad files.
                    await Task.detached { try? FileManager.default.removeItem(at: directory) }.value
                    self?.clearDamage()
                }
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
        clearDamage()
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
