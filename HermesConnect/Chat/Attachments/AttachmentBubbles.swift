import HermesKit
import MessageKit
import UIKit
import UniformTypeIdentifiers

/// The photo of a photo bubble or a location card (issue #8). Max width 240 pt, aspect kept.
struct AttachmentPhotoItem: MediaItem {
    let attachment: ChatAttachment
    /// The decoded thumbnail when the bubble was made. `thumbnailsReady()` fills in a late one.
    let image: UIImage?
    var url: URL? { attachment.fileURL }
    var placeholderImage: UIImage { UIImage() }

    static let maxWidth: CGFloat = 240

    var size: CGSize {
        let width = CGFloat(attachment.pixelWidth ?? 4)
        let height = CGFloat(attachment.pixelHeight ?? 3)
        guard width > 0, height > 0 else { return CGSize(width: Self.maxWidth, height: 180) }
        // Very tall screenshots stop at twice the width, so one bubble does not fill the thread.
        return CGSize(width: Self.maxWidth, height: min(Self.maxWidth * height / width, Self.maxWidth * 2).rounded())
    }
}

/// Small decoded images for the bubbles and the pending strip. Decoded once, off the main thread.
@MainActor
enum AttachmentThumbnails {
    private static let cache = NSCache<NSString, UIImage>()
    private static var loading: Set<String> = []
    /// The thread redraws when a thumbnail is ready.
    static var onReady: [ObjectIdentifier: () -> Void] = [:]

    static func image(for item: ChatAttachment) -> UIImage? {
        if let image = cache.object(forKey: item.id as NSString) { return image }
        load(item)
        return nil
    }

    private static func load(_ item: ChatAttachment) {
        guard !loading.contains(item.id) else { return }
        loading.insert(item.id)
        let url = item.fileURL
        let id = item.id
        Task.detached(priority: .userInitiated) {
            let thumbnail: UIImage? = {
                guard let full = UIImage(contentsOfFile: url.path) else { return nil }
                return full.preparingThumbnail(of: CGSize(width: 720, height: 1440).aspectFit(full.size)) ?? full
            }()
            await MainActor.run {
                loading.remove(id)
                guard let thumbnail else { return }
                cache.setObject(thumbnail, forKey: id as NSString)
                onReady.values.forEach { $0() }
            }
        }
    }
}

private extension CGSize {
    /// The largest size with the aspect of `source` that fits in this size.
    func aspectFit(_ source: CGSize?) -> CGSize {
        guard let source, source.width > 0, source.height > 0 else { return self }
        let scale = min(width / source.width, height / source.height, 1)
        return CGSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
    }
}

/// The file cell (issue #8, #12 uses it for received files): icon from the type, name in 2 lines, size.
enum AttachmentFileText {
    static func symbol(for item: ChatAttachment) -> String {
        if item.kind == .pdf || item.mimeType == "application/pdf" { return "doc.richtext.fill" }
        return "doc.fill"
    }

    static func make(_ item: ChatAttachment, outgoing: Bool, traits: UITraitCollection) -> NSAttributedString {
        let color: UIColor = outgoing ? .white : .label
        let secondary: UIColor = outgoing ? .white.withAlphaComponent(0.75) : .secondaryLabel
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let caption = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        let result = NSMutableAttributedString()
        let config = UIImage.SymbolConfiguration(font: UIFont.preferredFont(forTextStyle: .title2, compatibleWith: traits))
        if let icon = UIImage(systemName: symbol(for: item), withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            // The icon follows the text size: one body line high.
            let attachment = NSTextAttachment(image: icon)
            let height = body.lineHeight * 0.95
            let width = icon.size.height > 0 ? height * icon.size.width / icon.size.height : height
            attachment.bounds = CGRect(x: 0, y: body.descender, width: width, height: height)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  ", attributes: [.font: body]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        result.append(NSAttributedString(string: twoLineName(item.name), attributes: [
            .font: body, .foregroundColor: color, .paragraphStyle: paragraph,
        ]))
        // Issue #12: a cell from a server `@file:` ref has no local bytes, so it has no size.
        var details = item.byteCount > 0 ? [AttachmentPayload.sizeText(item.byteCount)] : []
        switch item.upload {
        case .uploading: details.append("Uploading…")
        case .failed: details.append("Upload failed")
        case .pending, .attached: break
        }
        if !details.isEmpty {
            result.append(NSAttributedString(string: "\n" + details.joined(separator: " · "),
                                             attributes: [.font: caption, .foregroundColor: secondary]))
        }
        return result
    }

    /// The label has no per-run line limit, so a long name is cut to about 2 lines here.
    static func twoLineName(_ name: String, limit: Int = 60) -> String {
        guard name.count > limit else { return name }
        return String(name.prefix(limit / 2 - 1)) + "…" + String(name.suffix(limit / 2 - 1))
    }
}

/// The circular ring on a bubble while its attach call runs. The call has no byte progress, so it spins.
final class AttachmentProgressRing: UIView {
    static let tag = 0x8A77
    private let ring = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        tag = Self.tag
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.35)
        layer.cornerRadius = 22
        ring.strokeColor = UIColor.white.cgColor
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 3
        ring.lineCap = .round
        ring.strokeEnd = 0.75
        layer.addSublayer(ring)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 10, dy: 10)).cgPath
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, ring.animation(forKey: "spin") == nil else { return }
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
    }

    /// Puts a ring on `view` while `uploading`, and takes it away after.
    static func update(on view: UIView, uploading: Bool, failed: Bool) {
        view.viewWithTag(tag)?.removeFromSuperview()
        view.viewWithTag(tag + 1)?.removeFromSuperview()
        if uploading {
            let ring = AttachmentProgressRing(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
            ring.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            ring.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
            view.addSubview(ring)
        } else if failed {
            let icon = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill",
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 28)))
            icon.tag = tag + 1
            icon.tintColor = .white
            icon.sizeToFit()
            icon.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            icon.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
            view.addSubview(icon)
        }
    }
}
