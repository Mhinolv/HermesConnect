import Foundation
import Synchronization

// Issue #130: the audio diagnostics of #127 also go to a small file in the app container, so main can read
// them after a drive (`xcrun devicectl device copy from --domain-type appDataContainer`).
// Port types, category, mode and options only. No audio, no text, no ids.

/// Appends one line per audio event to `Library/Caches/audio_diag.log`. It keeps the last `limit` lines.
/// Safe on any queue: AVFAudio callbacks can call it.
public final class AudioDiagnosticsFile: Sendable {
    public static let fileName = "audio_diag.log"
    public static let limit = 500

    /// The file in `Library/Caches` of the app container.
    public static let shared: AudioDiagnosticsFile = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return AudioDiagnosticsFile(url: caches.appendingPathComponent(fileName))
    }()

    public let url: URL
    private let limit: Int
    private let now: @Sendable () -> Date
    /// The lines in the file. `nil` until the first append reads the file.
    private let lines = Mutex<[String]?>(nil)
    /// Issue #165: true while a file write waits on `writer`. Appends in that time join that write.
    private let writePending = Mutex(false)
    /// Issue #165: the file writes run here, not on the queue of the caller (often the main actor).
    private let writer = DispatchQueue(label: "HermesConnect.AudioDiagnosticsFile", qos: .utility)

    public init(url: URL, limit: Int = AudioDiagnosticsFile.limit, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.limit = max(1, limit)
        self.now = now
    }

    /// Adds `line` with the time in front. A serial queue then writes the file again. Errors stay silent:
    /// diagnostics only. Issue #165: the caller does no file write. The first append reads the file once.
    public func append(_ line: String) {
        let stamp = ISO8601DateFormatter.string(from: now(), timeZone: TimeZone(identifier: "UTC")!,
                                                formatOptions: [.withInternetDateTime])
        let entry = stamp + " " + line.replacingOccurrences(of: "\n", with: " ")
        lines.withLock { cache in
            var all = cache ?? Self.read(url)
            all.append(entry)
            if all.count > limit { all.removeFirst(all.count - limit) }
            cache = all
        }
        let schedule = writePending.withLock { pending in
            defer { pending = true }
            return !pending
        }
        guard schedule else { return }
        writer.async { [self] in writeFile() }
    }

    /// Returns when the file has every line that was appended before the call (tests and checks).
    public func flush() {
        writer.sync {}
    }

    /// On `writer` only. Writes the lines in memory now.
    private func writeFile() {
        writePending.withLock { $0 = false }
        guard let all = lines.withLock({ $0 }) else { return }
        let data = Data((all.joined(separator: "\n") + "\n").utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The lines in the file now (tests and checks).
    public func read() -> [String] {
        lines.withLock { $0 ?? Self.read(url) }
    }

    private static func read(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
