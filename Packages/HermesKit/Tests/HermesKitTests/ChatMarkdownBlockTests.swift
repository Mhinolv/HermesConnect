import Foundation
import Testing
@testable import HermesKit

/// Issue #56: tables, lists, quotes, headings and rules in replies.
@Suite struct ChatMarkdownBlockTests {
    /// The reply in the owner's screenshot (`.team/qa/owner-56/01-table-raw.png`).
    static let grocery = """
    Two nearby grocery options in **Anaconda**, using the location your phone just reported:

    | Store | Estimated drive | Address |
    |---|---:|---|
    | **Albertsons** | **10 minutes · 7.1 miles** | 1300 E Park Ave. Listed hours: **7 a.m.–10 p.m. daily**. ([local.albertsons.com](https://local.albertsons.com/mt/anaconda/1300-e-park-ave.html)) |
    | **Stokes Market** | **14 minutes · 9.2 miles** | 1525 W Park Ave. ([stokesmarket.com](https://stokesmarket.com)) |

    I'd pick **Albertsons** for the shorter trip. Drive estimates don't include live traffic or road conditions.
    """

    private func plain(_ runs: [ChatTextRun]) -> String { runs.map(\.text).joined() }

    private func table(_ blocks: [ChatBlock]) throws -> ChatTable {
        for case .table(let table) in blocks { return table }
        throw TableMissing()
    }

    struct TableMissing: Error {}

    @Test func groceryTableParses() throws {
        let blocks = ChatMarkdown.blocks(Self.grocery)
        #expect(blocks.count == 3)
        guard case .paragraph(let intro) = blocks[0] else { Issue.record("no intro"); return }
        #expect(plain(intro).hasPrefix("Two nearby grocery options in Anaconda"))
        let table = try table(blocks)
        #expect(table.header.map(plain) == ["Store", "Estimated drive", "Address"])
        #expect(table.alignments == [.leading, .trailing, .leading])
        #expect(table.rows.count == 2)
        #expect(table.rows[0].map(plain) == [
            "Albertsons", "10 minutes · 7.1 miles",
            "1300 E Park Ave. Listed hours: 7 a.m.–10 p.m. daily. (local.albertsons.com)",
        ])
        #expect(table.rows[0][0].first?.isBold == true)
        guard case .paragraph(let outro) = blocks[2] else { Issue.record("no outro"); return }
        #expect(plain(outro).hasPrefix("I'd pick Albertsons"))
        // No raw pipes or delimiter row stay in the text.
        #expect(!ChatMarkdown.runs(Self.grocery).map(\.text).joined().contains("|"))
    }

    @Test func linksInTableCellsStay() throws {
        let table = try table(ChatMarkdown.blocks(Self.grocery))
        let links = table.rows.flatMap { $0.flatMap { $0.compactMap(\.link) } }
        #expect(links == [URL(string: "https://local.albertsons.com/mt/anaconda/1300-e-park-ave.html")!,
                          URL(string: "https://stokesmarket.com")!])
        // The flat runs keep them too, so VoiceOver gets an "Open" action for each.
        #expect(ChatMarkdown.runs(Self.grocery).compactMap(\.link).count == 2)
    }

    @Test func groceryCardsHaveHeaderCellLines() throws {
        let table = try table(ChatMarkdown.blocks(Self.grocery))
        let card = table.card(row: 0)
        #expect(plain(card.title) == "Albertsons")
        #expect(card.lines.map(\.header) == ["Estimated drive", "Address"])
        #expect(plain(card.lines[0].cell) == "10 minutes · 7.1 miles")
    }

    @Test func groceryTableIsAGridWhenItFitsAndCardsWhenNot() {
        // Column widths of the owner's table at body size: the address column is long.
        let widths: [Double] = [92, 170, 640]
        #expect(ChatTableLayout.style(columnWidths: widths, available: 280, largeText: false) == .cards)
        #expect(ChatTableLayout.style(columnWidths: widths, available: 1000, largeText: false) == .grid)
        // AX5: always cards, also when the grid fits.
        #expect(ChatTableLayout.style(columnWidths: widths, available: 1000, largeText: true) == .cards)
        // The gap between columns counts.
        let gap = ChatTableLayout.columnGap
        #expect(ChatTableLayout.style(columnWidths: [100, 100], available: 200 + gap + 1, largeText: false) == .grid)
        #expect(ChatTableLayout.style(columnWidths: [100, 100], available: 200 + gap - 1, largeText: false) == .cards)
    }

    @Test func voiceOverReadsRowsAsHeaderCellPairs() {
        let text = ChatMarkdown.accessibilityText(Self.grocery)
        #expect(text.contains("Store, Albertsons, Estimated drive, 10 minutes · 7.1 miles, Address, 1300 E Park Ave."))
        #expect(text.contains("Store, Stokes Market, Estimated drive, 14 minutes · 9.2 miles"))
        #expect(!text.contains("|"))
        #expect(!text.contains("**"))
    }

    @Test func bubbleLabelReadsTheTableRows() {
        let message = ChatMessage(id: "r", role: .assistant, text: Self.grocery, date: .now, reply: .complete)
        let label = ChatTimeline.accessibilityLabel(for: ChatTimeline.rows(for: [message])[0])
        #expect(label.hasPrefix("Hermes, Two nearby grocery options in Anaconda,"))
        #expect(label.contains("Store, Albertsons, Estimated drive, 10 minutes · 7.1 miles"))
        #expect(!label.contains("|"))
    }

    @Test func tableEdgeCases() throws {
        // No outer pipes, an escaped pipe, a pipe in code, a short row and a long row.
        let source = "a | b\n:-: | --\n`x|y` | c\\|d\nonly |\none | two | three"
        let table = try table(ChatMarkdown.blocks(source))
        #expect(table.alignments == [.center, .leading])
        #expect(table.rows.map { $0.map(plain) } == [["x|y", "c|d"], ["only", ""], ["one", "two"]])
        // A delimiter row with the wrong cell count is not a table.
        #expect(ChatMarkdown.blocks("| a | b |\n|---|\n| 1 | 2 |").allSatisfy { if case .table = $0 { false } else { true } })
    }

    @Test(arguments: Array(1...ChatMarkdownBlockTests.grocery.count))
    func streamingPrefixNeverCrashesAndOnlyCompleteRowsShow(length: Int) {
        let prefix = String(Self.grocery.prefix(length))
        let blocks = ChatMarkdown.blocks(prefix, streaming: true)
        for case .table(let table) in blocks {
            // Every row that shows has all of its cells. The partial row stays text.
            #expect(!table.rows.isEmpty)
            for row in table.rows { #expect(row.count == table.header.count) }
        }
        _ = ChatMarkdown.runs(prefix)
        _ = ChatMarkdown.accessibilityText(prefix)
    }

    @Test func streamingPartialRowStaysText() throws {
        let head = "| Store | Drive |\n|---|---:|\n| Albertsons | 10 min |\n"
        // The second row is half received: it shows as text under the table.
        let blocks = ChatMarkdown.blocks(head + "| Stokes | 14", streaming: true)
        #expect(try table(blocks).rows.count == 1)
        guard case .paragraph(let rest) = blocks.last else { Issue.record("no text"); return }
        #expect(plain(rest) == "| Stokes | 14")
        // A row with too few cells waits too, also with a closing pipe.
        #expect(try table(ChatMarkdown.blocks(head + "| Stokes |", streaming: true)).rows.count == 1)
        // The complete row joins the table.
        #expect(try table(ChatMarkdown.blocks(head + "| Stokes | 14 min |", streaming: true)).rows.count == 2)
        // A header and a delimiter with no complete row stay text while the reply streams.
        let early = ChatMarkdown.blocks("| Store | Drive |\n|---|---:|\n| Alb", streaming: true)
        #expect(early.allSatisfy { if case .table = $0 { false } else { true } })
        // A finished reply with no closing pipe on the last row keeps the row.
        #expect(try table(ChatMarkdown.blocks("a | b\n--|--\n1 | 2")).rows.count == 1)
    }

    @Test func bulletAndNumberedListsNestTwoLevels() {
        let source = "Plan:\n- Pack the **car**\n  - Snacks\n  - Water\n- Leave\n\n1. First\n2. Second\n   1. Inner"
        let blocks = ChatMarkdown.blocks(source)
        let items = blocks.compactMap { block -> (ChatListMarker, Int, String)? in
            guard case .listItem(let marker, let depth, let runs) = block else { return nil }
            return (marker, depth, plain(runs))
        }
        #expect(items.map(\.0) == [.bullet, .bullet, .bullet, .bullet, .number(1), .number(2), .number(1)])
        #expect(items.map(\.1) == [0, 1, 1, 0, 0, 0, 1])
        #expect(items.map(\.2) == ["Pack the car", "Snacks", "Water", "Leave", "First", "Second", "Inner"])
        guard case .listItem(_, _, let runs) = blocks[1] else { Issue.record("no item"); return }
        #expect(runs.contains(ChatTextRun("car", isBold: true)))
    }

    @Test func listItemContinuationLineJoinsTheItem() {
        let blocks = ChatMarkdown.blocks("- one\n  more\n- two")
        #expect(blocks.count == 2)
        guard case .listItem(_, _, let runs) = blocks[0] else { Issue.record("no item"); return }
        #expect(plain(runs) == "one\nmore")
    }

    @Test func quoteHoldsItsBlocks() {
        let blocks = ChatMarkdown.blocks("Said:\n> Leave **early**\n> - bring water\nOk")
        #expect(blocks.count == 3)
        guard case .quote(let inner) = blocks[1] else { Issue.record("no quote"); return }
        #expect(inner.count == 2)
        guard case .paragraph(let runs) = inner[0], case .listItem(.bullet, 0, let item) = inner[1] else {
            Issue.record("quote content"); return
        }
        #expect(plain(runs) == "Leave early")
        #expect(plain(item) == "bring water")
    }

    @Test func headingsAndRules() {
        let blocks = ChatMarkdown.blocks("# Title\n## Sub ##\n### Small\n#### Deep\n---\n* * *\n#1 not a heading\n#")
        guard blocks.count == 8 else { Issue.record("count \(blocks.count)"); return }
        #expect(blocks[0] == .heading(level: 1, [ChatTextRun("Title")]))
        #expect(blocks[1] == .heading(level: 2, [ChatTextRun("Sub")]))
        #expect(blocks[2] == .heading(level: 3, [ChatTextRun("Small")]))
        // H4 to H6 use the H3 style.
        #expect(blocks[3] == .heading(level: 3, [ChatTextRun("Deep")]))
        #expect(blocks[4] == .rule)
        #expect(blocks[5] == .rule)
        #expect(blocks[6] == .paragraph([ChatTextRun("#1 not a heading")]))
        #expect(blocks[7] == .heading(level: 1, []))
    }

    @Test func blankLinesSplitParagraphsAndPlainTextStays() {
        #expect(ChatMarkdown.blocks("a\nb\n\nc") == [.paragraph([ChatTextRun("a\nb")]), .paragraph([ChatTextRun("c")])])
        #expect(ChatMarkdown.blocks("Cost: 5 - 2 = 3, -5 degrees, 1.5 miles") ==
            [.paragraph([ChatTextRun("Cost: 5 - 2 = 3, -5 degrees, 1.5 miles")])])
        #expect(ChatMarkdown.blocks("") == [])
    }

    @Test func codeFenceInsideAListEndsTheList() {
        let blocks = ChatMarkdown.blocks("- a\n```\n- not a list\n```")
        #expect(blocks == [.listItem(.bullet, depth: 0, [ChatTextRun("a")]), .code("- not a list")])
    }

    @Test func flatRunsShowListMarksAndNoBlockSyntax() {
        let flat = ChatMarkdown.runs("# Plan\n- one\n2. two\n> quoted\n---\nend").map(\.text).joined()
        #expect(flat == "Plan\n• one\n2. two\nquoted\nend")
    }

    @Test func previewTextOfATableReplyHasNoPipes() {
        let preview = VoiceReplyText.previewText(Self.grocery)
        #expect(!preview.contains("|"))
        #expect(preview.contains("Albertsons, Estimated drive: 10 minutes · 7.1 miles, Address: 1300 E Park Ave."))
        #expect(!VoiceReplyText.spokenText(Self.grocery).contains("|"))
    }
}
