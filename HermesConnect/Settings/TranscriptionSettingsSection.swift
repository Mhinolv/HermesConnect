import HermesKit
import SwiftUI

/// Issue #44: Settings > Voice > "Transcription". Apple On-Device is the default.
struct TranscriptionSettingsSection: View {
    @AppStorage(TranscriptionEngine.settingsKey) private var engine: TranscriptionEngine = .appleOnDevice
    let parakeet: TranscriptionModelStore
    let apple: AppleSpeechAssets

    static let pickerTitle = "Transcription"
    static let footer = "Apple On-Device and Parakeet transcribe on this iPhone. Only the text is sent to Hermes."
    static let notDownloadedFooter = "Parakeet is not downloaded."
    static let failedText = "Download failed."
    static let appleDownloadTitle = "Download Apple Speech Model"

    init(parakeet: TranscriptionModelStore = OnDeviceTranscription.shared.parakeetModel,
         apple: AppleSpeechAssets = OnDeviceTranscription.shared.appleAssets) {
        self.parakeet = parakeet
        self.apple = apple
    }

    var body: some View {
        Section {
            Picker(Self.pickerTitle, selection: $engine) {
                ForEach(TranscriptionEngine.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            parakeetRow
            if usesApple { appleRow }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.footer)
                if engine == .parakeet, parakeet.state != .ready {
                    Text(Self.notDownloadedFooter)
                }
            }
        }
        .task { await apple.refresh() }
    }

    /// Apple On-Device runs for this choice: picked, or Parakeet picked and not downloaded.
    private var usesApple: Bool {
        engine == .appleOnDevice || (engine == .parakeet && parakeet.state != .ready)
    }

    @ViewBuilder private var parakeetRow: some View {
        switch parakeet.state {
        case .notDownloaded, .failed:
            LabeledContent("Parakeet") {
                Button(parakeet.downloadTitle) { parakeet.download() }
            }
            .accessibilityHint(parakeet.state == .failed ? Self.failedText : "")
            if parakeet.state == .failed {
                Text(Self.failedText).font(.footnote).foregroundStyle(.secondary)
            }
        case .downloading(let fraction):
            LabeledContent("Parakeet") {
                HStack(spacing: 12) {
                    ProgressRing(fraction: fraction)
                    Button("Cancel") { parakeet.cancel() }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityValue("\(Int(fraction * 100)) percent downloaded")
        case .ready:
            Button("Delete Model", role: .destructive) {
                Task { await parakeet.delete() }
            }
        }
    }

    @ViewBuilder private var appleRow: some View {
        switch apple.state {
        case .notInstalled, .failed:
            Button(Self.appleDownloadTitle) { apple.download() }
        case .downloading(let fraction):
            LabeledContent("Apple Speech Model") { ProgressRing(fraction: fraction) }
                .accessibilityValue("\(Int(fraction * 100)) percent downloaded")
        case .checking, .installed, .unsupported:
            EmptyView()
        }
    }
}

/// A small determinate ring for a model download.
private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

struct TranscriptionSettingsSection_Previews: PreviewProvider {
    static var previews: some View {
        Form { TranscriptionSettingsSection() }
    }
}
