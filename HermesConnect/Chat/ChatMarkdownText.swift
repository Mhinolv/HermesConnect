import HermesKit
import UIKit

/// Issue #56: the Markdown blocks of a bubble (paragraphs, headings, lists, quotes, code, rules and tables)
/// as one attributed string. `ChatMarkdownView` draws it, with the bars, lines and cards of `ChatMarkdownDecoration`.
enum ChatMarkdownText {
    /// The quote bars of a range: `ChatMarkdownDecoration.QuoteBars`.
    static let quoteKey = NSAttributedString.Key("HermesConnectQuoteBars")
    /// A rule, a grid row or a card: `ChatMarkdownDecoration`.
    static let blockKey = NSAttributedString.Key("HermesConnectMarkdownBlock")

    /// The colors and fonts of one bubble.
    struct Style {
        let traits: UITraitCollection
        let outgoing: Bool

        var color: UIColor { outgoing ? .white : .label }
        var secondaryColor: UIColor { outgoing ? .white.withAlphaComponent(0.8) : .secondaryLabel }
        var lineColor: UIColor { outgoing ? .white.withAlphaComponent(0.45) : .separator }
        var barColor: UIColor { outgoing ? .white.withAlphaComponent(0.6) : .systemGray2 }
        var cardColor: UIColor { outgoing ? .white.withAlphaComponent(0.15) : .secondarySystemBackground }
        var codeBackground: UIColor { outgoing ? .white.withAlphaComponent(0.2) : .tertiarySystemFill }
        var linkColor: UIColor { outgoing ? .white : .link }

        var body: UIFont { font(.body) }
        var mono: UIFont {
            UIFontMetrics(forTextStyle: .body)
                .scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular), compatibleWith: traits)
        }

        func font(_ textStyle: UIFont.TextStyle, bold: Bool = false) -> UIFont {
            let font = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
            return bold ? font.adding(.traitBold) : font
        }

        /// 1 at the default text size. Indents and gaps grow with the text.
        var scale: CGFloat { body.pointSize / 17 }
        /// AX1 to AX5: tables show as cards.
        var largeText: Bool { traits.preferredContentSizeCategory.isAccessibilityCategory }
    }

    /// The bubble text of `markdown`. `width` is the widest text line in the bubble. With no width, tables show as cards.
    static func make(_ markdown: String, style: Style, width: CGFloat?, streaming: Bool = false) -> NSAttributedString {
        var renderer = Renderer(style: style, width: width)
        renderer.append(ChatMarkdown.blocks(markdown, streaming: streaming), indent: 0, bars: [])
        return renderer.result
    }

    /// Inline runs with fonts, colors and link targets.
    static func styled(_ runs: [ChatTextRun], font: UIFont, color: UIColor, style: Style) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            var runFont = run.isCode || run.isCodeBlock ? style.mono : font
            var symbolic: UIFontDescriptor.SymbolicTraits = []
            if run.isBold { symbolic.insert(.traitBold) }
            if run.isItalic { symbolic.insert(.traitItalic) }
            if !symbolic.isEmpty { runFont = runFont.adding(symbolic) }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
            if run.isCode || run.isCodeBlock { attributes[.backgroundColor] = style.codeBackground }
            if let link = run.link {
                attributes[ChatBubbleText.linkKey] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.foregroundColor] = style.linkColor
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    private struct Renderer {
        let style: Style
        let width: CGFloat?
        let result = NSMutableAttributedString()
        private var previous: ChatBlock?

        init(style: Style, width: CGFloat?) {
            self.style = style
            self.width = width
        }

        private var quoteIndent: CGFloat { (14 * style.scale).rounded() }
        private var levelIndent: CGFloat { (20 * style.scale).rounded() }

        mutating func append(_ blocks: [ChatBlock], indent: CGFloat, bars: [CGFloat]) {
            for block in blocks {
                if case .quote(let inner) = block {
                    let start = result.length
                    let barX = indent
                    append(inner, indent: indent + quoteIndent, bars: bars + [barX])
                    markQuote(from: start, bars: bars + [barX])
                    previous = block
                    continue
                }
                let piece = render(block, indent: indent)
                guard piece.length > 0 else { continue }
                if result.length > 0 {
                    let end = result.attributes(at: result.length - 1, effectiveRange: nil)
                    result.append(NSAttributedString(string: "\n", attributes: end))
                    addSpacingBefore(spacing(after: previous, before: block), to: piece)
                }
                result.append(piece)
                previous = block
            }
        }

        /// The space above a block. List items of one list sit close together.
        private func spacing(after previous: ChatBlock?, before block: ChatBlock) -> CGFloat {
            let line = style.body.lineHeight
            switch (previous, block) {
            case (.listItem?, .listItem): return 3 * style.scale
            case (_, .heading): return (line * 0.7).rounded()
            case (_, .table): return (line * 0.6).rounded()
            case (.table?, _): return (line * 0.6).rounded()
            default: return (line * 0.45).rounded()
            }
        }

        private func addSpacingBefore(_ spacing: CGFloat, to piece: NSMutableAttributedString) {
            let firstParagraph = (piece.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            let current = piece.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            let paragraph = (current ?? NSParagraphStyle()).mutableCopy() as! NSMutableParagraphStyle
            paragraph.paragraphSpacingBefore = max(paragraph.paragraphSpacingBefore, spacing)
            piece.addAttribute(.paragraphStyle, value: paragraph.copy(), range: firstParagraph)
        }

        /// The bars of a quote. An inner quote keeps the bars of the outer one.
        private func markQuote(from start: Int, bars: [CGFloat]) {
            // The newline before the quote ends the paragraph above it, so it gets no bar.
            let start = start > 0 ? start + 1 : start
            guard result.length > start else { return }
            let value = ChatMarkdownDecoration.QuoteBars(positions: bars, color: style.barColor,
                                                        width: max(3, (3 * style.scale).rounded()))
            let range = NSRange(location: start, length: result.length - start)
            result.enumerateAttribute(quoteKey, in: range) { existing, part, _ in
                if existing == nil { result.addAttribute(quoteKey, value: value, range: part) }
            }
        }

        private func paragraphStyle(indent: CGFloat, configure: (NSMutableParagraphStyle) -> Void = { _ in })
            -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent
            configure(paragraph)
            return paragraph.copy() as! NSParagraphStyle
        }

        private func render(_ block: ChatBlock, indent: CGFloat) -> NSMutableAttributedString {
            switch block {
            case .paragraph(let runs):
                let text = ChatMarkdownText.styled(runs, font: style.body, color: style.color, style: style)
                return withParagraph(text, paragraphStyle(indent: indent))
            case .heading(let level, let runs):
                let textStyle: UIFont.TextStyle = switch level {
                case 1: .title2
                case 2: .title3
                default: .headline
                }
                let text = ChatMarkdownText.styled(lineSeparated(runs), font: style.font(textStyle, bold: true),
                                                   color: style.color, style: style)
                text.addAttribute(.accessibilityTextHeadingLevel, value: level, range: NSRange(location: 0, length: text.length))
                return withParagraph(text, paragraphStyle(indent: indent))
            case .listItem(let marker, let depth, let runs):
                return listItem(marker, depth: depth, runs: runs, indent: indent)
            case .code(let code):
                let text = NSMutableAttributedString(string: code, attributes: [
                    .font: style.mono, .foregroundColor: style.color, .backgroundColor: style.codeBackground,
                ])
                return withParagraph(text, paragraphStyle(indent: indent))
            case .rule:
                let rule = ChatMarkdownDecoration(kind: .rule, color: style.lineColor)
                let font = UIFont.systemFont(ofSize: (8 * style.scale).rounded())
                return NSMutableAttributedString(string: " ", attributes: [
                    .font: font, .paragraphStyle: paragraphStyle(indent: indent), blockKey: rule,
                ])
            case .table(let table):
                return render(table, indent: indent)
            case .quote:
                return NSMutableAttributedString()
            }
        }

        private func withParagraph(_ text: NSMutableAttributedString, _ paragraph: NSParagraphStyle)
            -> NSMutableAttributedString {
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            return text
        }

        /// A newline inside a list item or a heading is a line break, not a new paragraph, so the indent stays.
        private func lineSeparated(_ runs: [ChatTextRun]) -> [ChatTextRun] {
            runs.map { run in
                var run = run
                run.text = run.text.replacingOccurrences(of: "\n", with: "\u{2028}")
                return run
            }
        }

        private func listItem(_ marker: ChatListMarker, depth: Int, runs: [ChatTextRun], indent: CGFloat)
            -> NSMutableAttributedString {
            let mark = switch marker {
            case .bullet: ["•", "◦", "▪"][min(depth, 2)]
            case .number(let number): "\(number)."
            }
            let markWidth = (mark as NSString).size(withAttributes: [.font: style.body]).width
            let start = indent + CGFloat(depth) * levelIndent
            let textStart = start + max(levelIndent, (markWidth + 6 * style.scale).rounded(.up))
            let text = NSMutableAttributedString(string: mark + "\t", attributes: [
                .font: style.body, .foregroundColor: marker == .bullet ? style.secondaryColor : style.color,
            ])
            text.append(ChatMarkdownText.styled(lineSeparated(runs), font: style.body, color: style.color, style: style))
            let paragraph = paragraphStyle(indent: textStart) { paragraph in
                paragraph.firstLineHeadIndent = start
                paragraph.tabStops = [NSTextTab(textAlignment: .natural, location: textStart)]
                paragraph.defaultTabInterval = textStart
            }
            return withParagraph(text, paragraph)
        }

        // MARK: Tables

        private func render(_ table: ChatTable, indent: CGFloat) -> NSMutableAttributedString {
            let font = style.font(.subheadline)
            let header = table.header.map { ChatMarkdownText.styled($0, font: font.adding(.traitBold), color: style.color, style: style) }
            let rows = table.rows.map { $0.map { ChatMarkdownText.styled($0, font: font, color: style.color, style: style) } }
            let widths = table.header.indices.map { column in
                ([header[column]] + rows.map { $0[column] }).map(oneLineWidth).max() ?? 0
            }
            let available = width.map { $0 - indent } ?? 0
            let layout = ChatTableLayout.style(columnWidths: widths.map(Double.init), available: Double(available),
                                               largeText: style.largeText || width == nil)
            switch layout {
            case .grid: return grid(table, header: header, rows: rows, widths: widths, indent: indent)
            case .cards: return cards(table, indent: indent)
            }
        }

        private func oneLineWidth(_ text: NSAttributedString) -> CGFloat {
            let size = text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            return size.width.rounded(.up) + 1
        }

        private func grid(_ table: ChatTable, header: [NSAttributedString], rows: [[NSAttributedString]],
                          widths: [CGFloat], indent: CGFloat) -> NSMutableAttributedString {
            let gap = CGFloat(ChatTableLayout.columnGap)
            var starts: [CGFloat] = []
            var x = indent
            for width in widths {
                starts.append(x)
                x += width + gap
            }
            let total = x - gap - indent
            let lines = starts.dropFirst().map { $0 - gap / 2 }
            let padding = (4 * style.scale).rounded()
            let all = [header] + rows
            let result = NSMutableAttributedString()
            for (index, cells) in all.enumerated() {
                let row = NSMutableAttributedString()
                var tabs: [NSTextTab] = []
                for (column, cell) in cells.enumerated() {
                    let alignment = table.alignments[column]
                    let location: CGFloat = switch alignment {
                    case .leading: starts[column]
                    case .center: starts[column] + widths[column] / 2
                    case .trailing: starts[column] + widths[column]
                    }
                    if column > 0 || alignment != .leading {
                        let textAlignment: NSTextAlignment = switch alignment {
                        case .leading: .natural
                        case .center: .center
                        case .trailing: .right
                        }
                        tabs.append(NSTextTab(textAlignment: textAlignment, location: location))
                        row.append(NSAttributedString(string: "\t", attributes: [.font: style.font(.subheadline)]))
                    }
                    row.append(cell)
                }
                let paragraph = paragraphStyle(indent: indent) { paragraph in
                    paragraph.tabStops = tabs
                    paragraph.lineBreakMode = .byClipping
                    paragraph.paragraphSpacingBefore = index == 0 ? 0 : padding
                    paragraph.paragraphSpacing = index == all.count - 1 ? 0 : padding
                }
                let decoration = ChatMarkdownDecoration(
                    kind: .gridRow(lines: lines, start: indent, width: total, isLast: index == all.count - 1,
                                   isHeader: index == 0),
                    color: style.lineColor)
                if index > 0 {
                    result.append(NSAttributedString(string: "\n", attributes: result.attributes(at: result.length - 1,
                                                                                                effectiveRange: nil)))
                }
                let range = NSRange(location: 0, length: row.length)
                row.addAttributes([.paragraphStyle: paragraph, blockKey: decoration], range: range)
                result.append(row)
            }
            return result
        }

        /// Each row as a card: the first cell in bold, then one "<header>: <cell>" line for each other cell.
        private func cards(_ table: ChatTable, indent: CGFloat) -> NSMutableAttributedString {
            let result = NSMutableAttributedString()
            let gap = (18 * style.scale).rounded()
            if table.rows.isEmpty {
                // A table with no rows: the header in bold.
                let text = NSMutableAttributedString(string: table.headerTitles.joined(separator: " · "),
                                                     attributes: [.font: style.font(.body, bold: true),
                                                                  .foregroundColor: style.color])
                return withParagraph(text, paragraphStyle(indent: indent))
            }
            for index in table.rows.indices {
                let card = table.card(row: index)
                var paragraphs: [NSMutableAttributedString] = []
                if !card.title.isEmpty {
                    paragraphs.append(ChatMarkdownText.styled(lineSeparated(card.title), font: style.font(.body, bold: true),
                                                              color: style.color, style: style))
                }
                for line in card.lines {
                    let text = NSMutableAttributedString(string: "\(line.header): ", attributes: [
                        .font: style.body, .foregroundColor: style.secondaryColor,
                    ])
                    text.append(ChatMarkdownText.styled(lineSeparated(line.cell), font: style.body, color: style.color,
                                                        style: style))
                    paragraphs.append(text)
                }
                guard !paragraphs.isEmpty else { continue }
                let decoration = ChatMarkdownDecoration(kind: .card(start: indent), color: style.cardColor)
                let cardText = NSMutableAttributedString()
                for (number, text) in paragraphs.enumerated() {
                    let paragraph = paragraphStyle(indent: indent) { paragraph in
                        paragraph.paragraphSpacingBefore = number == 0 ? (result.length == 0 ? 0 : gap) : 2 * style.scale
                        paragraph.paragraphSpacing = number == paragraphs.count - 1 ? (6 * style.scale).rounded() : 0
                    }
                    if number > 0 { cardText.append(NSAttributedString(string: "\n")) }
                    let start = cardText.length
                    cardText.append(text)
                    cardText.addAttribute(.paragraphStyle, value: paragraph,
                                          range: NSRange(location: start, length: cardText.length - start))
                    if number > 0 {
                        // The newline ends the paragraph before it, so it takes that style.
                        let previous = cardText.attributes(at: start - 2, effectiveRange: nil)
                        cardText.setAttributes(previous, range: NSRange(location: start - 1, length: 1))
                    }
                }
                cardText.addAttribute(blockKey, value: decoration, range: NSRange(location: 0, length: cardText.length))
                if result.length > 0 {
                    result.append(NSAttributedString(string: "\n", attributes: result.attributes(at: result.length - 1,
                                                                                                effectiveRange: nil)))
                }
                result.append(cardText)
            }
            return result
        }
    }
}

/// Issue #56: while a reply streams, its bubble does not get shorter. A table row that completes turns a few lines
/// of text into a card, which can be shorter. A spacer line keeps the height until the reply ends.
struct ChatStreamingHeights {
    private var heights: [String: CGFloat] = [:]

    mutating func hold(_ text: NSAttributedString, id: String, width: CGFloat, streaming: Bool) -> NSAttributedString {
        guard streaming else {
            heights[id] = nil
            return text
        }
        let height = Self.height(text, width: width)
        let held = heights[id] ?? 0
        guard height < held - 0.5 else {
            heights[id] = height
            return text
        }
        // The spacer line adds about the missing height. A second pass corrects the rest.
        var spacer = held - height
        var padded = Self.padded(text, spacer: spacer)
        let missing = held - Self.height(padded, width: width)
        if abs(missing) > 0.5 {
            spacer = max(1, spacer + missing)
            padded = Self.padded(text, spacer: spacer)
        }
        return padded
    }

    private static func padded(_ text: NSAttributedString, spacer: CGFloat) -> NSAttributedString {
        let padded = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = max(1, spacer)
        paragraph.maximumLineHeight = max(1, spacer)
        let end = padded.length > 0 ? padded.attributes(at: padded.length - 1, effectiveRange: nil) : [:]
        padded.append(NSAttributedString(string: "\n", attributes: end))
        padded.append(NSAttributedString(string: "\u{200B}", attributes: [.font: UIFont.systemFont(ofSize: 1),
                                                                           .paragraphStyle: paragraph]))
        return padded
    }

    mutating func removeAll() { heights = [:] }

    /// The text height at a width, as MessageKit measures it.
    static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container).height
    }
}

extension UIFont {
    /// The same font with more symbolic traits (bold, italic).
    func adding(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

/// Issue #56: a shape that `ChatMarkdownView` draws behind the text of a block.
/// The text keeps it under `ChatMarkdownText.blockKey`. One object for each block, so ranges do not merge.
final class ChatMarkdownDecoration: NSObject {
    enum Kind {
        /// A line across the text width.
        case rule
        /// One row of a grid: column lines at `lines`, and a line under the row unless it is the last one.
        case gridRow(lines: [CGFloat], start: CGFloat, width: CGFloat, isLast: Bool, isHeader: Bool)
        /// A rounded fill behind the lines of a card.
        case card(start: CGFloat)
    }

    /// The bars at the side of a quote, one for each quote level.
    final class QuoteBars: NSObject {
        let positions: [CGFloat]
        let color: UIColor
        let width: CGFloat

        init(positions: [CGFloat], color: UIColor, width: CGFloat) {
            self.positions = positions
            self.color = color
            self.width = width
        }
    }

    let kind: Kind
    let color: UIColor

    init(kind: Kind, color: UIColor) {
        self.kind = kind
        self.color = color
    }

    /// `true` when the text has a decoration, so the view must do the layout.
    static func has(in text: NSAttributedString) -> Bool {
        let range = NSRange(location: 0, length: text.length)
        var found = false
        for key in [ChatMarkdownText.blockKey, ChatMarkdownText.quoteKey] {
            text.enumerateAttribute(key, in: range) { value, _, stop in
                if value != nil {
                    found = true
                    stop.pointee = true
                }
            }
        }
        return found
    }

    /// Fills the shapes of the text. `origin` is the top left of the text container in the current context.
    static func draw(_ text: NSAttributedString, layoutManager: NSLayoutManager, container: NSTextContainer,
                     origin: CGPoint) {
        let range = NSRange(location: 0, length: text.length)
        let width = container.size.width
        func fragments(_ characters: NSRange) -> (frame: CGRect, used: CGRect) {
            let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            var frame = CGRect.null
            var used = CGRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, usedRect, _, _, _ in
                frame = frame.union(rect)
                used = used.union(usedRect)
            }
            return (frame.offsetBy(dx: origin.x, dy: origin.y), used.offsetBy(dx: origin.x, dy: origin.y))
        }
        let scale = UIScreen.main.scale
        let hairline = 1 / scale
        text.enumerateAttribute(ChatMarkdownText.blockKey, in: range) { value, characters, _ in
            guard let decoration = value as? ChatMarkdownDecoration else { return }
            let rects = fragments(characters)
            guard !rects.frame.isNull else { return }
            decoration.color.setFill()
            switch decoration.kind {
            case .rule:
                let y = (rects.used.midY * scale).rounded() / scale
                UIRectFill(CGRect(x: rects.frame.minX, y: y, width: max(0, width - rects.frame.minX + origin.x),
                                  height: hairline))
            case .gridRow(let lines, let start, let tableWidth, let isLast, let isHeader):
                for x in lines {
                    UIRectFill(CGRect(x: origin.x + x, y: rects.frame.minY, width: hairline, height: rects.frame.height))
                }
                if !isLast {
                    let thickness = isHeader ? max(hairline, 1) : hairline
                    UIRectFill(CGRect(x: origin.x + start, y: rects.frame.maxY - thickness / 2, width: tableWidth,
                                      height: thickness))
                }
            case .card(let start):
                let inset: CGFloat = 8
                let frame = CGRect(x: origin.x + start - inset, y: rects.used.minY - 6,
                                   width: width - start + inset * 2, height: rects.used.height + 12)
                UIBezierPath(roundedRect: frame, cornerRadius: 10).fill()
            }
        }
        text.enumerateAttribute(ChatMarkdownText.quoteKey, in: range) { value, characters, _ in
            guard let bars = value as? ChatMarkdownDecoration.QuoteBars else { return }
            let rects = fragments(characters)
            guard !rects.used.isNull else { return }
            bars.color.setFill()
            for x in bars.positions {
                UIBezierPath(roundedRect: CGRect(x: origin.x + x, y: rects.used.minY, width: bars.width,
                                                 height: rects.used.height),
                             cornerRadius: bars.width / 2).fill()
            }
        }
    }
}

/// Issue #56: draws the bubble text with TextKit 1, like `MessageLabel`, but keeps the paragraph style of each
/// paragraph (`MessageLabel` puts one style on all of the text). It also draws the decorations and finds links.
final class ChatMarkdownView: UIView {
    var textInsets: UIEdgeInsets = .zero {
        didSet { setNeedsDisplay() }
    }

    var attributedText: NSAttributedString? {
        didSet {
            storage.setAttributedString(attributedText ?? NSAttributedString())
            hasDecorations = attributedText.map(ChatMarkdownDecoration.has) ?? false
            setNeedsDisplay()
        }
    }

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()
    private var hasDecorations = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func layoutText() {
        container.size = CGSize(width: max(0, bounds.width - textInsets.left - textInsets.right),
                                height: .greatestFiniteMagnitude)
    }

    override func draw(_: CGRect) {
        guard storage.length > 0 else { return }
        layoutText()
        let origin = CGPoint(x: textInsets.left, y: textInsets.top)
        if hasDecorations {
            ChatMarkdownDecoration.draw(storage, layoutManager: layoutManager, container: container, origin: origin)
        }
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    /// The link under a point in this view.
    func link(at point: CGPoint) -> URL? {
        guard storage.length > 0 else { return nil }
        layoutText()
        let location = CGPoint(x: point.x - textInsets.left, y: point.y - textInsets.top)
        let glyph = layoutManager.glyphIndex(for: location, in: container)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -6, dy: -6).contains(location) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(ChatBubbleText.linkKey, at: index, effectiveRange: nil) as? URL
    }

    /// Issue #17: `true` when the point is on the quote line of a reply (the whole line, plus 6 pt).
    func isQuote(at point: CGPoint) -> Bool {
        guard storage.length > 0 else { return false }
        var range = NSRange()
        guard storage.attribute(ChatQuoteText.tapKey, at: 0, effectiveRange: &range) != nil else { return false }
        layoutText()
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let line = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let location = CGPoint(x: point.x - textInsets.left, y: point.y - textInsets.top)
        return location.y >= line.minY - 6 && location.y <= line.maxY + 6
    }
}

/// Issue #56: the decorations behind the text of a `UITextView` (TextKit 1), for the full reply sheet.
final class ChatMarkdownBackdrop: UIView {
    weak var textView: UITextView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_: CGRect) {
        guard let textView, textView.textStorage.length > 0 else { return }
        let text = textView.textStorage
        let inset = textView.textContainerInset
        ChatMarkdownDecoration.draw(text, layoutManager: textView.layoutManager, container: textView.textContainer,
                                    origin: CGPoint(x: inset.left, y: inset.top))
    }
}
