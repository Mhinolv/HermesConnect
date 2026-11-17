#if DEBUG
import AVFoundation
import HermesKit
import UIKit

/// DEBUG only: the received files of `HERMES_DEMO=received-files` (issue #12). Each path gives one state:
/// a loaded image, a PDF that waits for a tap, an audio clip, a file with a progress ring, a missing file,
/// and an image over 50 MB that asks first.
enum ReceivedFileDemo {
    static let previewFile = ReceivedFile(path: "/home/hermes/.hermes/outputs/Q3 report.pdf")
    static let startedFiles = [ReceivedFile(path: "/home/hermes/.hermes/outputs/slow/raw-data.csv"),
                               ReceivedFile(path: "/home/hermes/.hermes/outputs/gone/old-data.xlsx")]

    static func messages(now: Date) -> [ChatMessage] {
        let start = now.addingTimeInterval(-2 * 60)
        return [
            ChatMessage(id: "rf1", role: .user, text: "Send me the Q3 chart, the report and the call recording.",
                        date: start, delivery: .delivered, userRowId: 501),
            ChatMessage(id: "rf2", role: .assistant, text: """
                Here are the files.
                MEDIA:/home/hermes/.hermes/outputs/q3-chart.png
                MEDIA:"/home/hermes/.hermes/outputs/Q3 report.pdf"
                MEDIA:/home/hermes/.hermes/outputs/call.wav
                """, date: start.addingTimeInterval(20), reply: .complete, promptId: "rf1"),
            ChatMessage(id: "rf3", role: .user, text: "And the raw data and the drone photo?",
                        date: start.addingTimeInterval(40), delivery: .delivered, userRowId: 503),
            ChatMessage(id: "rf4", role: .assistant, text: """
                MEDIA:/home/hermes/.hermes/outputs/slow/raw-data.csv
                MEDIA:/home/hermes/.hermes/outputs/gone/old-data.xlsx
                MEDIA:/home/hermes/.hermes/outputs/large/drone.jpg
                """, date: start.addingTimeInterval(55), reply: .complete, promptId: "rf3"),
        ]
    }

    /// Starts the downloads that show a state with no tap: the ring, the error.
    static func download(path: String, maxBytes: Int?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if path.contains("/gone/") { throw ReceivedFileError.notAvailable }
        if path.contains("/large/"), let maxBytes { throw ReceivedFileError.tooLarge(byteCount: maxBytes * 12 / 5) }
        if path.contains("/slow/") {
            progress(0.4)
            try await Task.sleep(for: .seconds(3600))
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "demo-\(UUID().uuidString)")
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg": try chart().write(to: url)
        case "pdf": try pdf().write(to: url)
        case "wav": try wav(to: url)
        default: try Data("month,revenue\nJul,120\nAug,140\nSep,155\n".utf8).write(to: url)
        }
        return url
    }

    private static func chart() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            for (index, height) in [320.0, 420, 520, 610].enumerated() {
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 160 + Double(index) * 240, y: 720 - height, width: 160, height: height))
            }
        }.pngData() ?? Data()
    }

    private static func pdf() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            ("Q3 Report\n\nRevenue grew 12 percent." as NSString).draw(
                in: CGRect(x: 72, y: 72, width: 468, height: 600),
                withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }
    }

    /// 6 s of a soft tone, so the audio bubble has a length and a waveform.
    private static func wav(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let frames = AVAudioFrameCount(16_000 * 6)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            let time = Double(index) / 16_000
            samples[index] = Float(sin(2 * .pi * 330 * time) * 0.3 * (0.5 + 0.5 * sin(2 * .pi * 0.7 * time)))
        }
        try file.write(from: buffer)
    }
}
#endif
