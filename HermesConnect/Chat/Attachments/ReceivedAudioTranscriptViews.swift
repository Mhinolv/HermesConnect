import HermesKit
import UIKit

/// Issue #50: the line under a received audio bubble. The style is the #9 memo transcript:
/// the transcript in `.footnote` `.secondaryLabel` (3 lines, a tap shows all), states in `.caption2`.
enum ReceivedAudioTranscriptText {
    static func make(_ state: AudioFileTranscript, traits: UITraitCollection) -> NSAttributedString {
        let caption = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits)
        switch state {
        case .done(let text):
            return NSAttributedString(string: text, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits),
                .foregroundColor: UIColor.secondaryLabel,
            ])
        case .none:
            // The action: a link color, with the symbol of the context menu item.
            let result = NSMutableAttributedString()
            let symbol = UIImage.SymbolConfiguration(font: caption)
            if let image = UIImage(systemName: symbolName, withConfiguration: symbol)?
                .withTintColor(.systemBlue, renderingMode: .alwaysOriginal) {
                let attachment = NSTextAttachment(image: image)
                attachment.bounds = CGRect(x: 0, y: (caption.capHeight - image.size.height) / 2,
                                           width: image.size.width, height: image.size.height)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " "))
            }
            result.append(NSAttributedString(string: state.caption))
            result.addAttributes([.font: caption, .foregroundColor: UIColor.systemBlue],
                                 range: NSRange(location: 0, length: result.length))
            return result
        default:
            let color: UIColor = state.isError ? .systemRed : .secondaryLabel
            return NSAttributedString(string: state.caption, attributes: [.font: caption, .foregroundColor: color])
        }
    }

    /// The SF Symbol of "Transcribe".
    static let symbolName = "text.bubble"

    /// What VoiceOver reads after the file label. `nil` before a run.
    static func spoken(_ state: AudioFileTranscript) -> String? {
        switch state {
        case .none: nil
        case .done(let text): "Transcript: \(text)"
        default: state.caption
        }
    }

    /// The alert of a tap on "Speech Recognition is off.", like "Microphone Access Off" (issue #9).
    @MainActor
    static func permissionAlert() -> UIAlertController {
        let alert = UIAlertController(title: "Speech Recognition Off",
                                      message: "Turn on Speech Recognition for Hermes in Settings to transcribe audio files on this iPhone.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let open = UIAlertAction(title: "Open Settings", style: .default) { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
        alert.addAction(open)
        alert.preferredAction = open
        return alert
    }
}
