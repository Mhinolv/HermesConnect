import HermesKit
import UIKit

/// Issue #11: one reaction on a bubble. A 28 pt circle with a 14 pt SF Symbol (issue #49: solid, not glass).
struct ReactionBadge: Equatable {
    enum Corner { case topLeading, topTrailing }

    var symbolName: String
    var corner: Corner
    /// `true` for an owner tapback: white symbol on blue. `false` for an agent ack: `.label` on gray.
    var isOwner: Bool

    static let size: CGFloat = 28
    static let symbolSize: CGFloat = 14
    /// The part of the badge above the bubble. The row reserves this space, so the badge does not cover
    /// the bubble above it.
    static let overhang: CGFloat = 14

    /// The badges of one drawn bubble: the agent ack top-leading on an owner prompt, the owner tapback top-trailing.
    static func badges(for row: ChatRow) -> [ReactionBadge] {
        guard row.showsReactions else { return [] }
        var badges: [ReactionBadge] = []
        if row.message.role == .user, let ack = row.message.agentAck {
            badges.append(ReactionBadge(symbolName: ack.symbolName, corner: .topLeading, isOwner: false))
        }
        if let tapback = row.message.tapback {
            badges.append(ReactionBadge(symbolName: tapback.symbolName, corner: .topTrailing, isOwner: true))
        }
        return badges
    }

    /// The badge frame next to a bubble frame. The badge overlaps the top corner of the bubble.
    static func frame(corner: Corner, bubble: CGRect, rightToLeft: Bool = false) -> CGRect {
        let leading = corner == .topLeading
        let onLeft = leading != rightToLeft
        let x = onLeft ? bubble.minX - 10 : bubble.maxX - size + 10
        return CGRect(x: x, y: bubble.minY - overhang, width: size, height: size)
    }
}

/// One badge view. Issue #49: a solid circle with a ring in the screen color, like iMessage. Glass let the
/// bubble show through, so the badge looked dim and cut by the bubble edge.
final class ReactionBadgeView: UIView {
    let imageView = UIImageView()
    private(set) var symbolName: String?
    /// The ring between the badge and the bubble under it.
    static let ringWidth: CGFloat = 2

    init(isOwner: Bool) {
        super.init(frame: CGRect(x: 0, y: 0, width: ReactionBadge.size, height: ReactionBadge.size))
        // An owner tapback is blue with a white symbol. An agent ack is the incoming bubble gray.
        backgroundColor = isOwner ? .systemBlue : .systemGray5
        layer.cornerRadius = ReactionBadge.size / 2
        layer.borderWidth = Self.ringWidth
        imageView.contentMode = .center
        imageView.tintColor = isOwner ? .white : .label
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: ReactionBadge.symbolSize,
                                                                              weight: .semibold)
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        updateRing()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateRing() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateRing() {
        layer.borderColor = UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor
    }

    /// Changes the symbol with `.replace`. With Reduce Motion, or with no symbol before, it changes at once.
    func setSymbol(_ name: String, from previous: String?) {
        guard let image = UIImage(systemName: name) else { return }
        if let previous, previous != name, !UIAccessibility.isReduceMotionEnabled,
           let old = UIImage(systemName: previous) {
            imageView.image = old
            imageView.setSymbolImage(image, contentTransition: .replace)
        } else {
            imageView.image = image
        }
        symbolName = name
    }
}

/// The badges of one cell. It covers the cell content and puts each badge on a corner of the bubble.
final class ReactionBadgeOverlay: UIView {
    private var views: [ReactionBadge.Corner: ReactionBadgeView] = [:]
    private var badges: [ReactionBadge] = []
    weak var bubble: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The overlay of a cell, made on first use. It stays on top of the bubble.
    static func of(_ cell: UICollectionViewCell, bubble: UIView) -> ReactionBadgeOverlay {
        let overlay = cell.contentView.subviews.lazy.compactMap { $0 as? ReactionBadgeOverlay }.first
            ?? ReactionBadgeOverlay(frame: cell.contentView.bounds)
        if overlay.superview == nil { cell.contentView.addSubview(overlay) }
        cell.contentView.bringSubviewToFront(overlay)
        overlay.frame = cell.contentView.bounds
        overlay.bubble = bubble
        return overlay
    }

    /// `previous` gives the symbol that each corner showed before, for the `.replace` change.
    func show(_ badges: [ReactionBadge], previous: (ReactionBadge) -> String?) {
        self.badges = badges
        // One corner always holds one kind: the agent ack leading, the owner tapback trailing.
        for (corner, view) in views where !badges.contains(where: { $0.corner == corner }) {
            view.removeFromSuperview()
            views[corner] = nil
        }
        for badge in badges {
            let view = views[badge.corner] ?? {
                let view = ReactionBadgeView(isOwner: badge.isOwner)
                addSubview(view)
                views[badge.corner] = view
                return view
            }()
            view.setSymbol(badge.symbolName, from: previous(badge))
        }
        isHidden = badges.isEmpty
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let bubble else { return }
        let frame = bubble.convert(bubble.bounds, to: self)
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (corner, view) in views {
            view.frame = ReactionBadge.frame(corner: corner, bubble: frame, rightToLeft: rightToLeft)
        }
    }
}

/// Issue #11: the glass capsule with the six tapbacks (44 pt each). It shows above the bubble.
final class TapbackCapsuleView: UIVisualEffectView {
    static let itemSize: CGFloat = 44
    static let inset: CGFloat = 4
    var onSelect: ((Tapback) -> Void)?
    private var buttons: [UIButton] = []

    init(selected: Tapback?) {
        super.init(effect: UIGlassEffect())
        cornerConfiguration = .capsule()
        let width = CGFloat(Tapback.allCases.count) * Self.itemSize + 2 * Self.inset
        frame.size = CGSize(width: width, height: Self.itemSize + 2 * Self.inset)
        for (index, tapback) in Tapback.allCases.enumerated() {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: tapback.symbolName)
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            let isSelected = tapback == selected
            config.baseForegroundColor = isSelected ? .white : .label
            if isSelected {
                config.background.backgroundColor = .systemBlue
                config.cornerStyle = .capsule
            }
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.onSelect?(tapback)
            })
            button.frame = CGRect(x: Self.inset + CGFloat(index) * Self.itemSize, y: Self.inset,
                                  width: Self.itemSize, height: Self.itemSize)
            button.accessibilityLabel = isSelected ? "Remove \(tapback.title)" : "React \(tapback.title)"
            button.accessibilityTraits.insert(isSelected ? .selected : [])
            contentView.addSubview(button)
            buttons.append(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The capsule frame above a bubble, kept inside `bounds` (the safe area of the screen).
    static func frame(size: CGSize, above bubble: CGRect, outgoing: Bool, in bounds: CGRect) -> CGRect {
        var x = outgoing ? bubble.maxX - size.width : bubble.minX
        x = min(max(x, bounds.minX + 8), bounds.maxX - size.width - 8)
        var y = bubble.minY - size.height - 8
        if y < bounds.minY + 8 { y = bubble.maxY + 8 }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

/// The full-screen layer behind the capsule. A tap outside the capsule closes it.
final class TapbackPickerView: UIView {
    let capsule: TapbackCapsuleView
    var onDismiss: (() -> Void)?

    init(frame: CGRect, selected: Tapback?) {
        capsule = TapbackCapsuleView(selected: selected)
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.08)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(capsule)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        accessibilityViewIsModal = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard !capsule.frame.contains(gesture.location(in: self)) else { return }
        onDismiss?()
    }

    override func accessibilityPerformEscape() -> Bool {
        onDismiss?()
        return true
    }
}
