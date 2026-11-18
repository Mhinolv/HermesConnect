import HermesKit
import MessageKit
import UIKit

/// Issue #120: the tool row under a reply. Collapsed: `wrench.and.screwdriver`, "Used 3 tools" and
/// `chevron.right`, `.caption1`, secondary, 44 pt high. A tap shows the list inline (`chevron.down`): each tool
/// name, its summary and its duration, in call order. Never the args or the results.
enum ChatToolsLayout {
    static let minHeaderHeight: CGFloat = 44
    /// The list box: inset 12 pt, row gap 6 pt, radius 12.
    static let listInset: CGFloat = 12
    static let rowGap: CGFloat = 6
    static let cornerRadius: CGFloat = 12
    /// The space between the name and the duration, and between the header and the list.
    static let gap: CGFloat = 8
    static let summaryLines = 2

    struct RowFrames: Equatable {
        var name: CGRect
        var duration: CGRect
        var summary: CGRect?
        /// The whole row, for VoiceOver.
        var row: CGRect
    }

    struct Frames: Equatable {
        var header: CGRect
        var list: CGRect?
        /// In the coordinates of the list box.
        var rows: [RowFrames]
        var size: CGSize
    }

    static func header(_ tools: [ChatToolCall], expanded: Bool, traits: UITraitCollection) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        let color = UIColor.secondaryLabel
        let text = NSMutableAttributedString()
        func symbol(_ name: String) {
            guard let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(font: font))?
                .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
            text.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
        }
        symbol("wrench.and.screwdriver")
        text.append(NSAttributedString(string: " \(ChatToolText.rowTitle(tools)) "))
        symbol(expanded ? "chevron.down" : "chevron.right")
        text.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: text.length))
        return text
    }

    static func name(_ tool: ChatToolCall, traits: UITraitCollection) -> NSAttributedString {
        let size = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits).pointSize
        return NSAttributedString(string: tool.name, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular), .foregroundColor: UIColor.label,
        ])
    }

    static func summary(_ tool: ChatToolCall, traits: UITraitCollection) -> NSAttributedString? {
        guard let summary = tool.summary else { return nil }
        return NSAttributedString(string: summary, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits),
            .foregroundColor: UIColor.secondaryLabel,
        ])
    }

    static func duration(_ tool: ChatToolCall, traits: UITraitCollection) -> NSAttributedString {
        let size = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits).pointSize
        return NSAttributedString(string: ChatToolText.duration(tool.duration), attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel,
        ])
    }

    static func frames(_ tools: [ChatToolCall], expanded: Bool, traits: UITraitCollection, width: CGFloat) -> Frames {
        let headerText = header(tools, expanded: expanded, traits: traits)
        let headerHeight = max(minHeaderHeight, height(headerText, width: width, lines: 0))
        let header = CGRect(x: 0, y: 0, width: width, height: headerHeight)
        guard expanded, !tools.isEmpty else {
            return Frames(header: header, list: nil, rows: [], size: CGSize(width: width, height: ceil(headerHeight)))
        }
        let inner = max(0, width - 2 * listInset)
        var rows: [RowFrames] = []
        var y = listInset
        for tool in tools {
            let durationText = duration(tool, traits: traits)
            let durationWidth = min(ceil(durationText.size().width), inner / 2)
            let nameWidth = max(0, inner - durationWidth - gap)
            let nameHeight = height(name(tool, traits: traits), width: nameWidth, lines: 0)
            let durationHeight = height(durationText, width: durationWidth, lines: 1)
            let name = CGRect(x: listInset, y: y, width: nameWidth, height: nameHeight)
            let duration = CGRect(x: listInset + inner - durationWidth, y: y, width: durationWidth,
                                  height: durationHeight)
            var bottom = max(name.maxY, duration.maxY)
            var summaryFrame: CGRect?
            if let summary = summary(tool, traits: traits) {
                // The summary spans the row under the name and the duration.
                let frame = CGRect(x: listInset, y: bottom + 2, width: inner,
                                   height: height(summary, width: inner, lines: summaryLines))
                summaryFrame = frame
                bottom = frame.maxY
            }
            rows.append(RowFrames(name: name, duration: duration, summary: summaryFrame,
                                  row: CGRect(x: listInset, y: y, width: inner, height: bottom - y)))
            y = bottom + rowGap
        }
        let listHeight = ceil(y - rowGap + listInset)
        let list = CGRect(x: 0, y: header.maxY, width: width, height: listHeight)
        return Frames(header: header, list: list, rows: rows, size: CGSize(width: width, height: ceil(list.maxY)))
    }

    static func size(_ tools: [ChatToolCall], expanded: Bool, traits: UITraitCollection, maxWidth: CGFloat) -> CGSize {
        frames(tools, expanded: expanded, traits: traits, width: maxWidth).size
    }

    /// The height of `text` in `width`. `lines` 0 is no limit.
    static func height(_ text: NSAttributedString, width: CGFloat, lines: Int) -> CGFloat {
        let full = ceil(text.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
        guard lines > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont else { return full }
        // The label needs a little more than `lineHeight` per line, else it drops the last line.
        return min(full, ceil(font.lineHeight * CGFloat(lines) + font.leading + 2))
    }
}

final class ChatToolsCell: MessageContentCell {
    /// The 44 pt tap target of the row. A tap opens or closes the list.
    let headerButton = UIButton(type: .custom)
    let headerLabel = UILabel()
    let listView = UIView()
    private(set) var rowViews: [ChatToolRowView] = []
    private var tools: [ChatToolCall] = []
    private var expanded = false
    private var cellTraits: UITraitCollection = .current

    var onToggle: (() -> Void)?

    override func setupSubviews() {
        super.setupSubviews()
        // MessageKit's `messageContainerView` is a `UIImageView`, which takes no touches by default (issue #111).
        messageContainerView.isUserInteractionEnabled = true
        headerLabel.numberOfLines = 0
        headerLabel.isUserInteractionEnabled = false
        headerButton.addSubview(headerLabel)
        headerButton.contentHorizontalAlignment = .leading
        headerButton.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .primaryActionTriggered)
        headerButton.accessibilityTraits = .button
        headerButton.accessibilityHint = ChatToolText.rowHint
        messageContainerView.addSubview(headerButton)
        listView.backgroundColor = .secondarySystemBackground
        listView.layer.cornerRadius = ChatToolsLayout.cornerRadius
        listView.layer.cornerCurve = .continuous
        messageContainerView.addSubview(listView)
    }

    func configure(tools: [ChatToolCall], expanded: Bool, traits: UITraitCollection) {
        self.tools = tools
        self.expanded = expanded
        cellTraits = traits
        headerLabel.attributedText = ChatToolsLayout.header(tools, expanded: expanded, traits: traits)
        headerButton.accessibilityLabel = ChatToolText.rowTitle(tools)
        headerButton.accessibilityValue = ChatToolText.rowValue(expanded: expanded)
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = expanded ? tools.map { tool in
            let view = ChatToolRowView()
            view.configure(tool, traits: traits)
            listView.addSubview(view)
            return view
        } : []
        listView.isHidden = !expanded
        messageContainerView.accessibilityElements = [headerButton] + rowViews
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggle = nil
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []
        tools = []
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = ChatToolsLayout.frames(tools, expanded: expanded, traits: cellTraits,
                                            width: messageContainerView.bounds.width)
        headerButton.frame = frames.header
        headerLabel.frame = headerButton.bounds
        listView.frame = frames.list ?? .zero
        for (view, row) in zip(rowViews, frames.rows) {
            view.frame = row.row
            view.layout(row)
        }
    }
}

/// One tool of the open list. VoiceOver reads it as one element: "web_search, Searched 4 pages, 1.2 seconds".
final class ChatToolRowView: UIView {
    let nameLabel = UILabel()
    let summaryLabel = UILabel()
    let durationLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        nameLabel.numberOfLines = 0
        summaryLabel.numberOfLines = ChatToolsLayout.summaryLines
        summaryLabel.lineBreakMode = .byTruncatingTail
        durationLabel.numberOfLines = 1
        durationLabel.textAlignment = .right
        for label in [nameLabel, summaryLabel, durationLabel] { addSubview(label) }
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ tool: ChatToolCall, traits: UITraitCollection) {
        nameLabel.attributedText = ChatToolsLayout.name(tool, traits: traits)
        summaryLabel.attributedText = ChatToolsLayout.summary(tool, traits: traits)
        summaryLabel.isHidden = tool.summary == nil
        durationLabel.attributedText = ChatToolsLayout.duration(tool, traits: traits)
        accessibilityLabel = ChatToolText.accessibilityLabel(tool)
    }

    /// `frames` are in the coordinates of the list box. The labels sit in the row view.
    func layout(_ frames: ChatToolsLayout.RowFrames) {
        let origin = frames.row.origin
        nameLabel.frame = frames.name.offsetBy(dx: -origin.x, dy: -origin.y)
        durationLabel.frame = frames.duration.offsetBy(dx: -origin.x, dy: -origin.y)
        summaryLabel.frame = frames.summary?.offsetBy(dx: -origin.x, dy: -origin.y) ?? .zero
    }
}
