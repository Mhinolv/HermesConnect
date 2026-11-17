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

public enum ChatMarkdown {
    /// Splits text into styled runs. Inline syntax uses `AttributedString(markdown:)`.
    /// An open fence (a reply that still streams) makes the rest a code block.
    public static func runs(_ text: String) -> [ChatTextRun] {
        var runs: [ChatTextRun] = []
        for (index, block) in blocks(text).enumerated() {
            if index > 0 { runs.append(ChatTextRun("\n")) }
            switch block {
            case .prose(let prose): runs += inlineRuns(prose)
            case .code(let code): runs.append(ChatTextRun(code, isCodeBlock: true))
            }
        }
        return merged(runs)
    }

    enum Block: Equatable {
        case prose(String)
        case code(String)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var lines: [Substring] = []
        var inCode = false
        func flush() {
            let joined = lines.joined(separator: "\n")
            if inCode {
                blocks.append(.code(joined))
            } else {
                let prose = joined.trimmingCharacters(in: .newlines)
                if !prose.isEmpty { blocks.append(.prose(prose)) }
            }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                lines.append(line)
            }
        }
        if inCode || !lines.isEmpty { flush() }
        return blocks
    }

    private static func inlineRuns(_ prose: String) -> [ChatTextRun] {
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
