import HermesKit
import UIKit

/// The pending items above the text view (issue #8): 64 pt photo thumbnails (corner radius 10) and file
/// chips (icon, name, size). Each item has a "Remove" button. Hidden when nothing is pending.
final class AttachmentStripView: UIView {
    var onRemove: ((String) -> Void)?
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        let height = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint = height
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
            height,
        ])
        isHidden = true
        accessibilityLabel = "Attachments"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ items: [ChatAttachment]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items { stack.addArrangedSubview(tile(for: item)) }
        isHidden = items.isEmpty
        heightConstraint?.constant = items.isEmpty ? 0 : Self.height(for: traitCollection)
        if let last = stack.arrangedSubviews.last {
            layoutIfNeeded()
            scroll.scrollRectToVisible(last.frame, animated: false)
        }
    }

    /// 64 pt photos. File chips grow with the text size.
    static func height(for traits: UITraitCollection) -> CGFloat {
        let chip = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).lineHeight
            + UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits).lineHeight + 20
        return max(64, chip.rounded(.up)) + 12
    }

    private func tile(for item: ChatAttachment) -> UIView {
        let tile = UIView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        let content: UIView = item.showsAsImage ? thumbnail(for: item) : chip(for: item)
        tile.addSubview(content)
        let remove = UIButton(type: .system)
        remove.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark.circle.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 18))
        config.baseForegroundColor = .white
        config.background.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        config.background.cornerRadius = 12
        config.contentInsets = .zero
        remove.configuration = config
        remove.accessibilityLabel = "Remove"
        let id = item.id
        remove.addAction(UIAction { [weak self] _ in self?.onRemove?(id) }, for: .touchUpInside)
        tile.addSubview(remove)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: tile.topAnchor),
            content.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            remove.topAnchor.constraint(equalTo: tile.topAnchor, constant: 2),
            remove.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -2),
            remove.widthAnchor.constraint(equalToConstant: 24),
            remove.heightAnchor.constraint(equalToConstant: 24),
        ])
        // VoiceOver: one element per item, with "Remove" as an action.
        tile.isAccessibilityElement = true
        tile.accessibilityLabel = Self.accessibilityLabel(for: item)
        tile.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Remove") { [weak self] _ in
            self?.onRemove?(id)
            return true
        }]
        return tile
    }

    static func accessibilityLabel(for item: ChatAttachment) -> String {
        switch item.kind {
        case .photo: "Photo, attached"
        case .location: "Location, attached"
        case .file, .pdf: "\(item.name), \(AttachmentPayload.sizeText(item.byteCount)), attached"
        }
    }

    private func thumbnail(for item: ChatAttachment) -> UIView {
        let image = UIImageView(image: AttachmentThumbnails.image(for: item))
        image.translatesAutoresizingMaskIntoConstraints = false
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.layer.cornerRadius = 10
        image.backgroundColor = .secondarySystemFill
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 64),
            image.heightAnchor.constraint(equalToConstant: 64),
        ])
        return image
    }

    private func chip(for item: ChatAttachment) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: AttachmentFileText.symbol(for: item)))
        icon.tintColor = .secondaryLabel
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let name = UILabel()
        name.text = item.name
        name.font = .preferredFont(forTextStyle: .subheadline)
        name.adjustsFontForContentSizeCategory = true
        name.lineBreakMode = .byTruncatingMiddle
        let size = UILabel()
        size.text = AttachmentPayload.sizeText(item.byteCount)
        size.font = .preferredFont(forTextStyle: .caption1)
        size.adjustsFontForContentSizeCategory = true
        size.textColor = .secondaryLabel
        let labels = UIStackView(arrangedSubviews: [name, size])
        labels.axis = .vertical
        let row = UIStackView(arrangedSubviews: [icon, labels])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 30)
        row.backgroundColor = .secondarySystemFill
        row.layer.cornerRadius = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        return row
    }
}
