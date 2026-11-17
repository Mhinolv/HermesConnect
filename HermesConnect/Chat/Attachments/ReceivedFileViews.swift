import HermesKit
import ImageIO
import MessageKit
import QuickLook
import UIKit

/// The image of a received photo bubble (issue #12). Before the load: a 240 x 180 pt gray box.
/// After it: max width 240 pt, aspect kept, from the image header (no relayout when the pixels come).
struct ReceivedPhotoItem: MediaItem {
    let file: ReceivedFile
    let fileURL: URL?
    let image: UIImage?
    var url: URL? { fileURL }
    var placeholderImage: UIImage { UIImage() }

    static let placeholder = CGSize(width: 240, height: 180)

    var size: CGSize {
        guard let fileURL, let pixels = ReceivedImageSize.pixels(of: fileURL), pixels.width > 0, pixels.height > 0 else {
            return Self.placeholder
        }
        let width = AttachmentPhotoItem.maxWidth
        return CGSize(width: width, height: min(width * pixels.height / pixels.width, width * 2).rounded())
    }

    /// The thumbnail cache of the outgoing photos takes the downloaded file too.
    static func thumbnailItem(_ file: ReceivedFile, url: URL) -> ChatAttachment {
        ChatAttachment(id: "received:" + url.path, kind: .photo, name: file.name, byteCount: 0, fileURL: url,
                       mimeType: "", upload: .attached)
    }
}

/// The pixel size from the image header. Read once per file (header only, fast).
enum ReceivedImageSize {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sizes: [URL: CGSize] = [:]

    static func pixels(of url: URL) -> CGSize? {
        if let size = lock.withLock({ sizes[url] }) { return size }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              var height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        // EXIF orientations 5 to 8 turn the image on its side.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        let size = CGSize(width: width, height: height)
        lock.withLock { sizes[url] = size }
        return size
    }
}

/// The file cell of a received file: an icon (a progress ring while it downloads), the name, then the state.
enum ReceivedFileText {
    static func symbol(for file: ReceivedFile, state: ReceivedFileState) -> String {
        if state == .notAvailable { return "exclamationmark.triangle" }
        switch file.kind {
        case .audio: return "waveform"
        case .image: return "photo"
        case .file: return file.fileExtension == "pdf" ? "doc.richtext.fill" : "doc.fill"
        }
    }

    /// The line under the name.
    static func detail(for state: ReceivedFileState, byteCount: Int?) -> String {
        switch state {
        case .idle: "Tap to download"
        case .downloading(let fraction): fraction.map { "Downloading… \(Int(($0 * 100).rounded()))%" } ?? "Downloading…"
        case .ready: byteCount.map(AttachmentPayload.sizeText) ?? ""
        case .needsConfirmation(let bytes): "\(AttachmentPayload.sizeText(bytes)) · Tap to download"
        case .notAvailable: "File not available"
        case .offline: "Connect to download"
        case .failed: "Download failed. Tap to retry."
        }
    }

    static func make(_ file: ReceivedFile, state: ReceivedFileState, byteCount: Int?,
                     traits: UITraitCollection) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let caption = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        let result = NSMutableAttributedString()
        let height = body.lineHeight * 0.95
        let icon: UIImage?
        if case .downloading(let fraction) = state {
            icon = ring(fraction: fraction, side: height)
        } else {
            let config = UIImage.SymbolConfiguration(font: UIFont.preferredFont(forTextStyle: .title2, compatibleWith: traits))
            let color: UIColor = state == .notAvailable ? .secondaryLabel : .label
            icon = UIImage(systemName: symbol(for: file, state: state), withConfiguration: config)?
                .withTintColor(color, renderingMode: .alwaysOriginal)
        }
        if let icon {
            let attachment = NSTextAttachment(image: icon)
            let width = icon.size.height > 0 ? height * icon.size.width / icon.size.height : height
            attachment.bounds = CGRect(x: 0, y: body.descender, width: width, height: height)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  ", attributes: [.font: body]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        result.append(NSAttributedString(string: AttachmentFileText.twoLineName(file.name), attributes: [
            .font: body, .foregroundColor: UIColor.label, .paragraphStyle: paragraph,
        ]))
        let detail = detail(for: state, byteCount: byteCount)
        if !detail.isEmpty {
            let color: UIColor = state == .failed ? .systemRed : .secondaryLabel
            result.append(NSAttributedString(string: "\n" + detail, attributes: [.font: caption, .foregroundColor: color]))
        }
        // The icon starts the line, so the line takes its style from the icon. One style on all of the text keeps
        // the name on one line (cut in the middle), as the bubble size expects.
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// The progress ring on the icon: a track and the done part. With no size yet, a quarter shows.
    static func ring(fraction: Double?, side: CGFloat) -> UIImage {
        let side = max(12, side)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            let rect = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 2, dy: 2)
            let track = UIBezierPath(ovalIn: rect)
            track.lineWidth = 3
            UIColor.tertiaryLabel.setStroke()
            track.stroke()
            let start = -CGFloat.pi / 2
            let done = UIBezierPath(arcCenter: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                                    startAngle: start, endAngle: start + 2 * .pi * CGFloat(max(0.05, fraction ?? 0.25)),
                                    clockwise: true)
            done.lineWidth = 3
            done.lineCapStyle = .round
            UIColor.systemBlue.setStroke()
            done.stroke()
        }
    }
}

/// The state over a received photo bubble: a `ProgressView` while it loads, else an icon and a short text.
@MainActor
enum ReceivedImageOverlay {
    static let tag = 0x12F1

    static func clear(on view: UIView) {
        view.viewWithTag(tag)?.removeFromSuperview()
    }

    static func update(on view: UIView, state: ReceivedFileState) {
        clear(on: view)
        let content: UIView
        switch state {
        case .ready:
            return
        case .idle, .downloading:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            content = spinner
        case .notAvailable:
            content = stack(symbol: "exclamationmark.triangle", text: "File not available")
        case .offline:
            content = stack(symbol: "wifi.slash", text: "Connect to download")
        case .failed:
            content = stack(symbol: "arrow.clockwise", text: "Tap to retry")
        case .needsConfirmation(let bytes):
            content = stack(symbol: "arrow.down.circle", text: "Download \(AttachmentPayload.sizeText(bytes))")
        }
        content.tag = tag
        content.isAccessibilityElement = false
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            content.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -16),
        ])
    }

    private static func stack(symbol: String, text: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = .secondaryLabel
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        label.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        return stack
    }
}

/// Quick Look for one downloaded file. Its share button gives "Save Image" and "Save to Files".
@MainActor
final class ReceivedFilePreview: NSObject, @preconcurrency QLPreviewControllerDataSource {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func numberOfPreviewItems(in _: QLPreviewController) -> Int { 1 }

    func previewController(_: QLPreviewController, previewItemAt _: Int) -> any QLPreviewItem { url as NSURL }

    /// `true` when Quick Look can show the file. Else the share sheet opens.
    static func canPreview(_ url: URL) -> Bool { QLPreviewController.canPreview(url as NSURL) }
}
