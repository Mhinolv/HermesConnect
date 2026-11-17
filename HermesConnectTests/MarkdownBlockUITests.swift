import Foundation
import HermesKit
import MessageKit
import Testing
import UIKit
@testable import HermesConnect

/// Issue #56: tables, lists, quotes, headings and rules in the bubble and in the full reply sheet.
@MainActor
@Suite(.serialized) struct MarkdownBlockUITests {
    /// The reply in the owner's screenshot (`.team/qa/owner-56/01-table-raw.png`).
    static let grocery = """
    Two nearby grocery options in **Anaconda**, using the location your phone just reported:

    | Store | Estimated drive | Address |
    |---|---:|---|
    | **Albertsons** | **10 minutes · 7.1 miles** | 1300 E Park Ave. Listed hours: **7 a.m.–10 p.m. daily**. ([local.albertsons.com](https://local.albertsons.com/mt/anaconda/1300-e-park-ave.html)) |
    | **Stokes Market** | **14 minutes · 9.2 miles** | 1525 W Park Ave. ([stokesmarket.com](https://stokesmarket.com)) |

    I'd pick **Albertsons** for the shorter trip. Drive estimates don't include live traffic or road conditions.
    """

    private let date = Date(timeIntervalSince1970: 1_763_290_000)
    private let large = UITraitCollection(preferredContentSizeCategory: .large)
    private let ax5 = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)

    private func reply(_ text: String, streaming: Bool = false) -> ChatMessage {
        ChatMessage(id: "r", role: .assistant, text: text, date: date, reply: streaming ? .streaming : .complete)
    }

    /// The bubble text width on an iPhone 18 Pro (402 pt).
    private var phoneWidth: CGFloat { ChatBubbleText.maxWidth(threadWidth: 402, outgoing: false) }

    private func decorations(_ text: NSAttributedString) -> [ChatMarkdownDecoration] {
        var result: [ChatMarkdownDecoration] = []
        text.enumerateAttribute(ChatMarkdownText.blockKey, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let decoration = value as? ChatMarkdownDecoration, !result.contains(decoration) { result.append(decoration) }
        }
        return result
    }

    private func gridRows(_ text: NSAttributedString) -> Int {
        decorations(text).filter { if case .gridRow = $0.kind { true } else { false } }.count
    }

    private func cards(_ text: NSAttributedString) -> Int {
        decorations(text).filter { if case .card = $0.kind { true } else { false } }.count
    }

    /// The height of the text at a width, as MessageKit measures it.
    private func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container).height
    }

    // MARK: Tables

    @Test func groceryTableIsCardsInAPhoneBubble() {
        let text = ChatBubbleText.make(reply(Self.grocery), traits: large, width: phoneWidth)
        #expect(!text.string.contains("|"))
        #expect(!text.string.contains("---"))
        #expect(cards(text) == 2)
        #expect(gridRows(text) == 0)
        #expect(text.string.contains("Albertsons\nEstimated drive: 10 minutes · 7.1 miles\nAddress: 1300 E Park Ave."))
        // The first column is bold.
        let title = (text.string as NSString).range(of: "Stokes Market")
        let font = text.attribute(.font, at: title.location, effectiveRange: nil) as? UIFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    @Test func groceryTableIsAGridWhenItFits() {
        let text = ChatBubbleText.make(reply(Self.grocery), traits: large, width: 1100)
        #expect(gridRows(text) == 3)
        #expect(cards(text) == 0)
        #expect(text.string.contains("Store\tEstimated drive\tAddress"))
        // The grid rows never wrap: each row is one line.
        let row = (text.string as NSString).range(of: "Albertsons")
        let paragraph = text.attribute(.paragraphStyle, at: row.location, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.lineBreakMode == .byClipping)
        #expect(paragraph?.tabStops.count == 2)
        #expect(paragraph?.tabStops.first?.alignment == .right)
    }

    @Test func groceryTableIsCardsAtAX5WithNoClippedText() {
        let text = ChatBubbleText.make(reply(Self.grocery), traits: ax5, width: 1100)
        #expect(cards(text) == 2)
        #expect(gridRows(text) == 0)
        // No line clips: no paragraph uses the one-line grid mode, so long cells wrap.
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            #expect((value as? NSParagraphStyle)?.lineBreakMode != .byClipping)
        }
        // Each line fits in the AX5 phone bubble.
        let width = ChatBubbleText.maxWidth(threadWidth: 402, outgoing: false)
        let storage = NSTextStorage(attributedString: ChatBubbleText.make(reply(Self.grocery), traits: ax5, width: width))
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        #expect(manager.usedRect(for: container).width <= width)
        let glyphs = manager.glyphRange(for: container)
        #expect(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).length == storage.length)
    }

    @Test func linksInTableCellsAreTappable() throws {
        for width in [phoneWidth, 1100] {
            let text = ChatBubbleText.make(reply(Self.grocery), traits: large, width: width)
            let view = ChatMarkdownView(frame: CGRect(x: 0, y: 0, width: width + 32, height: height(text, width: width) + 14))
            view.textInsets = UIEdgeInsets(top: 7, left: 18, bottom: 7, right: 14)
            view.attributedText = text
            // The point of the link text, from a layout of the same text.
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            let range = (text.string as NSString).range(of: "stokesmarket.com")
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let point = CGPoint(x: rect.midX + 18, y: rect.midY + 7)
            #expect(view.link(at: point) == URL(string: "https://stokesmarket.com"))
            #expect(view.link(at: CGPoint(x: 20, y: 9)) == nil)
        }
    }

    @Test func tableBubbleCellUsesTheMarkdownView() throws {
        let prompt = ChatMessage(id: "u", role: .user, text: "What grocery stores are near me?", date: date,
                                 delivery: .delivered, userRowId: 1)
        var answer = reply(Self.grocery)
        answer.promptId = "u"
        let model = ChatViewModel(transport: OfflineChatTransport(), messages: [prompt, answer])
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(),
                                            voiceFolder: FileManager.default.temporaryDirectory)
        controller.autoPlayEnabled = { false }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        controller.messagesCollectionView.layoutIfNeeded()
        controller.messagesCollectionView.layoutIfNeeded()
        let cell = try #require(controller.messagesCollectionView.cellForItem(at: IndexPath(item: 0, section: 1))
            as? ChatTextCell)
        #expect(cell.messageLabel.isHidden)
        #expect(cell.markdownView.attributedText?.string.contains("Estimated drive: 10 minutes") == true)
        #expect(cell.markdownView.frame == cell.messageContainerView.bounds)
        // The bubble is tall enough for the text it draws.
        let text = try #require(cell.markdownView.attributedText)
        let inner = cell.messageContainerView.bounds.inset(by: cell.markdownView.textInsets)
        #expect(height(text, width: inner.width) <= inner.height + 1)
        // VoiceOver reads each row as header and cell pairs.
        #expect(cell.accessibilityLabel?.contains("Store, Albertsons, Estimated drive, 10 minutes · 7.1 miles") == true)
    }

    @Test func fullReplySheetUsesTheSameRenderer() throws {
        let text = ChatBubbleText.make(reply(Self.grocery), traits: large, width: 402 - 32)
        let sheet = ReplyTextViewController(text: text)
        sheet.loadViewIfNeeded()
        sheet.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        sheet.view.layoutIfNeeded()
        #expect(sheet.textView.textLayoutManager == nil)
        let shown = try #require(sheet.textView.attributedText)
        #expect(shown.string.contains("Estimated drive: 10 minutes · 7.1 miles"))
        #expect(!shown.string.contains("|"))
        let link = (shown.string as NSString).range(of: "stokesmarket.com")
        #expect(shown.attribute(.link, at: link.location, effectiveRange: nil) as? URL == URL(string: "https://stokesmarket.com"))
    }

    // MARK: Streaming

    @Test func streamingTableNeverCrashesOrJumpsBack() {
        var lastRows = 0
        var lastHeight: CGFloat = 0
        var heights = ChatStreamingHeights()
        let source = Self.grocery as NSString
        for length in 1...source.length {
            let prefix = source.substring(to: length)
            let made = ChatBubbleText.make(reply(prefix, streaming: true), traits: large, width: phoneWidth)
            let text = heights.hold(made, id: "r", width: phoneWidth, streaming: true)
            let height = height(text, width: phoneWidth)
            #expect(height > 0)
            // Cards only grow: a card that shows never goes away, and only complete rows show.
            let rows = cards(text)
            #expect(rows >= lastRows)
            let complete = ChatMarkdown.blocks(prefix, streaming: true).reduce(0) { count, block in
                if case .table(let table) = block { count + table.rows.count } else { count }
            }
            #expect(rows == complete)
            // When a row completes, the bubble does not get shorter (no jump back).
            #expect(height >= lastHeight - 0.5, "length \(length): \(lastHeight) -> \(height)")
            lastRows = rows
            lastHeight = height
        }
        #expect(lastRows == 2)
        // The finished reply drops the spacer.
        let done = heights.hold(ChatBubbleText.make(reply(Self.grocery), traits: large, width: phoneWidth), id: "r",
                                width: phoneWidth, streaming: false)
        #expect(!done.string.contains("\u{200B}"))
    }

    @Test func streamingPartialRowShowsAsText() {
        let partial = "| Store | Drive |\n|---|---:|\n| Albertsons | 10 min |\n| Stokes | 14"
        let text = ChatBubbleText.make(reply(partial, streaming: true), traits: large, width: phoneWidth)
        #expect(text.string.hasSuffix("| Stokes | 14"))
        let done = ChatBubbleText.make(reply(partial + " min |", streaming: true), traits: large, width: phoneWidth)
        #expect(!done.string.contains("|"))
    }

    // MARK: Lists, quotes, headings, rules

    @Test func listsHaveMarksAndNestedIndents() throws {
        let text = ChatBubbleText.make(reply("- Pack\n  - Snacks\n1. First\n2. Second"), traits: large, width: phoneWidth)
        #expect(text.string == "•\tPack\n◦\tSnacks\n1.\tFirst\n2.\tSecond")
        let ns = text.string as NSString
        func style(_ word: String) -> NSParagraphStyle? {
            text.attribute(.paragraphStyle, at: ns.range(of: word).location, effectiveRange: nil) as? NSParagraphStyle
        }
        let top = try #require(style("Pack"))
        let nested = try #require(style("Snacks"))
        #expect(nested.firstLineHeadIndent > top.firstLineHeadIndent)
        #expect(nested.headIndent > top.headIndent)
        // A wrapped line starts under the text, not under the mark.
        #expect(top.headIndent == top.tabStops.first?.location)
    }

    @Test func quoteHasASideBarAndAnIndent() throws {
        let text = ChatBubbleText.make(reply("Before\n> Quoted **line**\nAfter"), traits: large, width: phoneWidth)
        #expect(text.string == "Before\nQuoted line\nAfter")
        let ns = text.string as NSString
        let quoted = ns.range(of: "Quoted")
        let bars = text.attribute(ChatMarkdownText.quoteKey, at: quoted.location, effectiveRange: nil)
            as? ChatMarkdownDecoration.QuoteBars
        #expect(bars?.positions == [0])
        #expect(text.attribute(ChatMarkdownText.quoteKey, at: 0, effectiveRange: nil) == nil)
        #expect(text.attribute(ChatMarkdownText.quoteKey, at: ns.range(of: "After").location, effectiveRange: nil) == nil)
        let paragraph = try #require(text.attribute(.paragraphStyle, at: quoted.location, effectiveRange: nil)
            as? NSParagraphStyle)
        #expect(paragraph.headIndent > 0)
    }

    @Test func headingsAreBoldSizesAndRulesDraw() throws {
        let text = ChatBubbleText.make(reply("# One\n## Two\n### Three\nBody\n\n---\nEnd"), traits: large,
                                       width: phoneWidth)
        #expect(text.string == "One\nTwo\nThree\nBody\n \nEnd")
        let ns = text.string as NSString
        func font(_ word: String) throws -> UIFont {
            try #require(text.attribute(.font, at: ns.range(of: word).location, effectiveRange: nil) as? UIFont)
        }
        let body = try font("Body")
        #expect(try font("One").pointSize > font("Two").pointSize)
        #expect(try font("Two").pointSize > body.pointSize)
        #expect(try font("Three").pointSize >= body.pointSize)
        for word in ["One", "Two", "Three"] {
            #expect(try font(word).fontDescriptor.symbolicTraits.contains(.traitBold))
        }
        let rules = decorations(text).filter { if case .rule = $0.kind { true } else { false } }
        #expect(rules.count == 1)
    }

    @Test func plainTextStaysTheSame() {
        let text = ChatBubbleText.make(reply("line 1\nline 2"), traits: large, width: phoneWidth)
        #expect(text.string == "line 1\nline 2")
        #expect(decorations(text).isEmpty)
    }
}
