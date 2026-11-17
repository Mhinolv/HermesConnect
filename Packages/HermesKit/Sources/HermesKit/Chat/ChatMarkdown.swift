import Foundation

/// One styled run of bubble text. The app maps it to fonts (issue #6: inline Markdown, code blocks, links).
public struct ChatTextRun: Sendable, Equatable {
    public var text: String
    public var isBold = false
    public var isItalic = false
    /// Inline `code`.
    public var isCode = false
    /// A fenced ``` block. The text has no fences and no language tag.
    public var isCodeBlock = false
    public var link: URL?

    public init(_ text: String, isBold: Bool = false, isItalic: Bool = false, isCode: Bool = false,
                isCodeBlock: Bool = false, link: URL? = nil) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isCode = isCode
        self.isCodeBlock = isCodeBlock
        self.link = link
    }
}

/// Issue #56: one block of a reply. The app draws each kind. `ChatMarkdown.blocks` makes them.
public indirect enum ChatBlock: Sendable, Equatable {
    case paragraph([ChatTextRun])
    /// Level 1 to 3. H4 to H6 come as level 3.
    case heading(level: Int, [ChatTextRun])
    /// One list item. `depth` is 0 for the top level, 1 for a nested item (2 at most).
    case listItem(ChatListMarker, depth: Int, [ChatTextRun])
    /// A block quote with the blocks in it.
    case quote([ChatBlock])
    /// A fenced ``` block. The text has no fences and no language tag.
    case code(String)
    /// A horizontal rule (`---`, `***`, `___`).
    case rule
    case table(ChatTable)
}

public enum ChatListMarker: Sendable, Equatable {
    case bullet
    case number(Int)
}

/// Issue #56: a GitHub style table. Each row has one cell for each header cell.
public struct ChatTable: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable { case leading, center, trailing }

    public var header: [[ChatTextRun]]
    public var alignments: [Alignment]
    public var rows: [[[ChatTextRun]]]

    public init(header: [[ChatTextRun]], alignments: [Alignment], rows: [[[ChatTextRun]]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }

    /// The plain text of each header cell.
    public var headerTitles: [String] { header.map { $0.map(\.text).joined() } }

    /// A row as a card: the first cell is the title, then one "<header>: <cell>" line for each other cell.
    /// Empty cells have no line.
    public func card(row index: Int) -> (title: [ChatTextRun], lines: [(header: String, cell: [ChatTextRun])]) {
        let row = rows[index]
        let titles = headerTitles
        let lines = row.indices.dropFirst().compactMap { column -> (header: String, cell: [ChatTextRun])? in
            let cell = row[column]
            guard !cell.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            return (titles[column], cell)
        }
        return (row.first ?? [], lines)
    }

    /// VoiceOver text of a row: "<header>, <cell>" pairs (issue #56).
    public func accessibilityText(row index: Int) -> String {
        let titles = headerTitles
        return rows[index].enumerated().compactMap { column, cell -> String? in
            let text = cell.map(\.text).joined()
            guard !text.isEmpty else { return nil }
            return titles[column].isEmpty ? text : "\(titles[column]), \(text)"
        }.joined(separator: ", ")
    }
}

/// Issue #56: a table shows as a grid when its columns fit on one line each, else as one card for each row.
public enum ChatTableLayout {
    public enum Style: Sendable, Equatable { case grid, cards }

    /// The space between two grid columns. The grid line is in the middle of it.
    public static let columnGap: Double = 16

    /// `columnWidths` are the one-line widths of the widest cell of each column. Large text sizes always use cards.
    public static func style(columnWidths: [Double], available: Double, largeText: Bool) -> Style {
        guard !largeText, !columnWidths.isEmpty else { return .cards }
        let total = columnWidths.reduce(0, +) + columnGap * Double(columnWidths.count - 1)
        return total <= available ? .grid : .cards
    }
}

public enum ChatMarkdown {
    /// Splits text into styled runs, as one flat text. Inline syntax uses `AttributedString(markdown:)`.
    /// An open fence (a reply that still streams) makes the rest a code block.
    /// Issue #56: block marks go. A list item starts with "• " or its number, a table row reads "<header>: <cell>".
    public static func runs(_ text: String) -> [ChatTextRun] {
        merged(flatRuns(blocks(text)))
    }

    /// The text for VoiceOver: no Markdown marks, and a table row as "<header>, <cell>" pairs.
    public static func accessibilityText(_ text: String) -> String {
        accessibilityLines(blocks(text)).joined(separator: "\n")
    }

    /// Issue #56: the blocks of a reply. With `streaming`, the last line can be partial:
    /// a table row shows only when it is complete, and a table shows only with one complete row.
    public static func blocks(_ text: String, streaming: Bool = false) -> [ChatBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        var parser = BlockParser(lines: lines, streaming: streaming)
        return parser.parse()
    }

    private static func flatRuns(_ blocks: [ChatBlock]) -> [ChatTextRun] {
        var runs: [ChatTextRun] = []
        for block in blocks {
            var piece: [ChatTextRun] = []
            switch block {
            case .paragraph(let text), .heading(_, let text): piece = text
            case .listItem(let marker, let depth, let text):
                let mark = switch marker {
                case .bullet: "• "
                case .number(let number): "\(number). "
                }
                piece = [ChatTextRun(String(repeating: "  ", count: depth) + mark)] + text
            case .quote(let inner): piece = flatRuns(inner)
            case .code(let code): piece = [ChatTextRun(code, isCodeBlock: true)]
            case .rule: continue
            case .table(let table):
                for index in table.rows.indices {
                    if !piece.isEmpty { piece.append(ChatTextRun("\n")) }
                    let card = table.card(row: index)
                    var row = card.title
                    for line in card.lines {
                        row.append(ChatTextRun(row.isEmpty ? "\(line.header): " : ", \(line.header): "))
                        row += line.cell
                    }
                    piece += row
                }
            }
            if piece.isEmpty { continue }
            if !runs.isEmpty { runs.append(ChatTextRun("\n")) }
            runs += piece
        }
        return runs
    }

    private static func accessibilityLines(_ blocks: [ChatBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .paragraph(let text), .heading(_, let text), .listItem(_, _, let text): [text.map(\.text).joined()]
            case .quote(let inner): accessibilityLines(inner)
            case .code(let code): [code]
            case .rule: []
            case .table(let table): table.rows.indices.map(table.accessibilityText(row:))
            }
        }.filter { !$0.isEmpty }
    }

    /// Line by line block parser. GitHub style, with the parts that chat replies use.
    private struct BlockParser {
        let lines: [String]
        let streaming: Bool
        var index = 0
        var blocks: [ChatBlock] = []
        var paragraph: [String] = []
        /// The indents of the open list levels.
        var listIndents: [Int] = []

        init(lines: [String], streaming: Bool) {
            self.lines = lines
            self.streaming = streaming
        }

        mutating func parse() -> [ChatBlock] {
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    flushParagraph()
                    index += 1
                } else if trimmed.hasPrefix("```") {
                    flushParagraph()
                    listIndents = []
                    parseCode()
                } else if let table = tableAt(index) {
                    flushParagraph()
                    listIndents = []
                    blocks.append(.table(table.table))
                    index = table.next
                } else if let heading = ChatMarkdown.heading(line) {
                    flushParagraph()
                    listIndents = []
                    blocks.append(.heading(level: heading.level, ChatMarkdown.inlineRuns(heading.text)))
                    index += 1
                } else if ChatMarkdown.isRule(line) {
                    flushParagraph()
                    listIndents = []
                    blocks.append(.rule)
                    index += 1
                } else if ChatMarkdown.quoteBody(line) != nil {
                    flushParagraph()
                    listIndents = []
                    parseQuote()
                } else if let item = ChatMarkdown.listItem(line) {
                    flushParagraph()
                    parseListItem(item)
                } else {
                    if paragraph.isEmpty { listIndents = [] }
                    paragraph.append(line)
                    index += 1
                }
            }
            flushParagraph()
            return blocks
        }

        private mutating func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            paragraph = []
            guard !text.isEmpty else { return }
            blocks.append(.paragraph(ChatMarkdown.inlineRuns(text)))
        }

        /// An open fence (a reply that still streams) makes the rest a code block.
        private mutating func parseCode() {
            index += 1
            var code: [String] = []
            while index < lines.count {
                if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    index += 1
                    break
                }
                code.append(lines[index])
                index += 1
            }
            blocks.append(.code(code.joined(separator: "\n")))
        }

        private mutating func parseQuote() {
            var inner: [String] = []
            while index < lines.count, let body = ChatMarkdown.quoteBody(lines[index]) {
                inner.append(body)
                index += 1
            }
            var nested = BlockParser(lines: inner, streaming: streaming && index == lines.count)
            blocks.append(.quote(nested.parse()))
        }

        private mutating func parseListItem(_ item: (indent: Int, marker: ChatListMarker, text: String)) {
            while let last = listIndents.last, last > item.indent { listIndents.removeLast() }
            if let last = listIndents.last, last == item.indent {
                // A sibling at this level.
            } else {
                listIndents.append(item.indent)
            }
            let depth = min(2, listIndents.count - 1)
            var text = [item.text]
            index += 1
            // Continuation lines: any line that does not start a new block.
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("```") || ChatMarkdown.listItem(line) != nil
                    || ChatMarkdown.heading(line) != nil || ChatMarkdown.isRule(line)
                    || ChatMarkdown.quoteBody(line) != nil || tableAt(index) != nil { break }
                text.append(trimmed)
                index += 1
            }
            blocks.append(.listItem(item.marker, depth: depth, ChatMarkdown.inlineRuns(text.joined(separator: "\n"))))
        }

        /// A table: a header row, a delimiter row with the same cell count, then rows with a `|`.
        private func tableAt(_ start: Int) -> (table: ChatTable, next: Int)? {
            guard start + 1 < lines.count, lines[start].contains("|"), lines[start + 1].contains("|"),
                  isComplete(start + 1) else { return nil }
            let header = ChatMarkdown.cells(lines[start])
            guard let alignments = ChatMarkdown.alignments(lines[start + 1]), alignments.count == header.count,
                  !header.isEmpty else { return nil }
            var rows: [[String]] = []
            var next = start + 2
            while next < lines.count {
                let line = lines[next]
                guard line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty,
                      ChatMarkdown.heading(line) == nil, ChatMarkdown.quoteBody(line) == nil,
                      !line.trimmingCharacters(in: .whitespaces).hasPrefix("```") else { break }
                var cells = ChatMarkdown.cells(line)
                // While the reply streams, the last line waits for its newline, or for a closing `|` after each cell.
                if !isComplete(next) {
                    guard line.trimmingCharacters(in: .whitespaces).hasSuffix("|"), cells.count >= header.count else { break }
                }
                cells = Array(cells.prefix(header.count))
                cells += Array(repeating: "", count: header.count - cells.count)
                rows.append(cells)
                next += 1
            }
            if streaming, rows.isEmpty { return nil }
            let table = ChatTable(header: header.map(ChatMarkdown.inlineRuns), alignments: alignments,
                                  rows: rows.map { $0.map(ChatMarkdown.inlineRuns) })
            return (table, next)
        }

        /// A line is complete when a newline follows it, or when the reply is done.
        private func isComplete(_ line: Int) -> Bool {
            !streaming || line < lines.count - 1
        }
    }

    // MARK: Line kinds

    /// `# Title` to `###### Title`, with up to 3 spaces before. Closing `#`s go.
    static func heading(_ line: String) -> (level: Int, text: String)? {
        let body = line.drop { $0 == " " }
        guard line.count - body.count <= 3 else { return nil }
        let hashes = body.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        var rest = body.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        rest = rest.drop { $0 == " " || $0 == "\t" }
        var text = rest.trimmingCharacters(in: .whitespaces)
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing > 0, closing == text.count || text.dropLast(closing).last == " " {
            text = String(text.dropLast(closing)).trimmingCharacters(in: .whitespaces)
        }
        return (min(3, hashes), text)
    }

    /// `---`, `***` or `___` (spaces allowed): a thematic break.
    static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// The text after `>` (and one space), or `nil` for a line that is not a quote.
    static func quoteBody(_ line: String) -> String? {
        let body = line.drop { $0 == " " }
        guard line.count - body.count <= 3, body.first == ">" else { return nil }
        var rest = body.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    /// `- item`, `* item`, `+ item`, `1. item` or `1) item`.
    static func listItem(_ line: String) -> (indent: Int, marker: ChatListMarker, text: String)? {
        var indent = 0
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            indent += first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        let marker: ChatListMarker
        if let first = rest.first, "-*+".contains(first) {
            marker = .bullet
            rest = rest.dropFirst()
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
            rest = rest.dropFirst(digits.count)
            guard let mark = rest.first, mark == "." || mark == ")" else { return nil }
            marker = .number(number)
            rest = rest.dropFirst()
        }
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return (indent, marker, rest.trimmingCharacters(in: .whitespaces))
    }

    /// The cells of a table row. Outer pipes are optional. `\|` and a pipe in `code` do not split.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var inCode = false
        var characters = line.trimmingCharacters(in: .whitespaces)[...]
        if characters.first == "|" { characters = characters.dropFirst() }
        var escaped = false
        for character in characters {
            if escaped {
                cell += character == "|" ? "|" : "\\\(character)"
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                cell.append(character)
            } else if character == "|", !inCode {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell += "\\" }
        let last = cell.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || cells.isEmpty { cells.append(cell) }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The column alignments of a delimiter row (`|---|:---:|---:|`), or `nil` for any other line.
    static func alignments(_ line: String) -> [ChatTable.Alignment]? {
        let cells = cells(line)
        guard !cells.isEmpty else { return nil }
        var result: [ChatTable.Alignment] = []
        for cell in cells {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            result.append(left && right ? .center : right ? .trailing : .leading)
        }
        return result
    }

    static func inlineRuns(_ prose: String) -> [ChatTextRun] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: prose, options: options) else {
            return autolinked(ChatTextRun(prose))
        }
        var runs: [ChatTextRun] = []
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            let piece = ChatTextRun(String(parsed[run.range].characters),
                                    isBold: intent.contains(.stronglyEmphasized),
                                    isItalic: intent.contains(.emphasized),
                                    isCode: intent.contains(.code),
                                    link: run.link.flatMap(safeLink))
            runs += piece.link == nil && !piece.isCode ? autolinked(piece) : [piece]
        }
        return runs
    }

    /// Only web and mail links open. Other schemes stay plain text.
    private static func safeLink(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    /// Finds bare URLs ("https://…") in plain text.
    private static func autolinked(_ run: ChatTextRun) -> [ChatTextRun] {
        guard run.text.contains("://") || run.text.contains("www."),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return [run]
        }
        let text = run.text as NSString
        var result: [ChatTextRun] = []
        var cursor = 0
        for match in detector.matches(in: run.text, range: NSRange(location: 0, length: text.length)) {
            guard let url = match.url.flatMap(safeLink), url.scheme != "mailto" else { continue }
            if match.range.location > cursor {
                var before = run
                before.text = text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result.append(before)
            }
            var linked = run
            linked.text = text.substring(with: match.range)
            linked.link = url
            result.append(linked)
            cursor = match.range.location + match.range.length
        }
        if cursor < text.length {
            var rest = run
            rest.text = text.substring(from: cursor)
            result.append(rest)
        }
        return result.isEmpty ? [run] : result
    }

    /// Joins neighbor runs with the same style.
    private static func merged(_ runs: [ChatTextRun]) -> [ChatTextRun] {
        var result: [ChatTextRun] = []
        for run in runs where !run.text.isEmpty {
            if var last = result.last, last.isBold == run.isBold, last.isItalic == run.isItalic,
               last.isCode == run.isCode, last.isCodeBlock == run.isCodeBlock, last.link == run.link {
                last.text += run.text
                result[result.count - 1] = last
            } else {
                result.append(run)
            }
        }
        return result
    }
}
