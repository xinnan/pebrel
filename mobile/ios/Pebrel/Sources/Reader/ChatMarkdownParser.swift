import Foundation
import SwiftUI

enum ChatTableAlignment: Equatable {
    case leading
    case center
    case trailing

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

struct ChatMarkdownListItem: Equatable {
    let checked: Bool?
    let blocks: [ChatMarkdownBlock]
}

indirect enum ChatMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case quote([ChatMarkdownBlock])
    case list(ordered: Bool, start: Int, items: [ChatMarkdownListItem])
    case code(language: String, code: String)
    case math(String)
    case table(headers: [String], alignments: [ChatTableAlignment], rows: [[String]])
    case rule
}

struct ChatMarkdownDocument: Equatable {
    let blocks: [ChatMarkdownBlock]
    let hasRichContent: Bool
    let hasCodeOrTable: Bool
}

private final class ChatMarkdownCacheEntry: NSObject {
    let document: ChatMarkdownDocument
    init(_ document: ChatMarkdownDocument) {
        self.document = document
    }
}

enum ChatMarkdownParser {
    private static let maxNestingDepth = 6
    private static let cache: NSCache<NSString, ChatMarkdownCacheEntry> = {
        let c = NSCache<NSString, ChatMarkdownCacheEntry>()
        c.countLimit = 128
        return c
    }()

    static func cachedParse(_ raw: String) -> ChatMarkdownDocument {
        let key = raw as NSString
        if let entry = cache.object(forKey: key) {
            return entry.document
        }
        let doc = parse(raw)
        cache.setObject(ChatMarkdownCacheEntry(doc), forKey: key)
        return doc
    }

    static func parse(_ raw: String) -> ChatMarkdownDocument {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var hasRich = false
        var hasCodeOrTable = false
        let blocks = parseBlocks(lines, depth: 0, hasRich: &hasRich, hasCodeOrTable: &hasCodeOrTable)
        return ChatMarkdownDocument(
            blocks: blocks,
            hasRichContent: hasRich,
            hasCodeOrTable: hasCodeOrTable
        )
    }

    // MARK: - Block Parsing

    private struct FenceInfo {
        let char: Character
        let length: Int
        let language: String
    }

    private struct ListMarker {
        let indent: Int
        let ordered: Bool
        let number: Int
        let contentIndent: Int
        let rest: String
    }

    private static func parseBlocks(
        _ lines: [String],
        depth: Int,
        hasRich: inout Bool,
        hasCodeOrTable: inout Bool
    ) -> [ChatMarkdownBlock] {
        var blocks: [ChatMarkdownBlock] = []
        var idx = 0

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                idx += 1
                continue
            }

            // Single-line display math: $$...$$ or \[...\]
            if let singleMath = matchSingleLineDisplayMath(trimmed) {
                hasRich = true
                blocks.append(.math(singleMath))
                idx += 1
                continue
            }

            // Multi-line display math fence: $$ or \[
            if trimmed == "$$" || trimmed == "\\[" {
                let closing = trimmed == "$$" ? "$$" : "\\]"
                var mathLines: [String] = []
                idx += 1
                while idx < lines.count && lines[idx].trimmingCharacters(in: .whitespaces) != closing {
                    mathLines.append(lines[idx])
                    idx += 1
                }
                if idx < lines.count { idx += 1 }
                hasRich = true
                blocks.append(.math(mathLines.joined(separator: "\n")))
                continue
            }

            // Fenced code block (``` or ~~~)
            if let fence = matchOpeningFence(line) {
                var codeLines: [String] = []
                idx += 1
                while idx < lines.count {
                    if isClosingFence(lines[idx], char: fence.char, minLength: fence.length) {
                        idx += 1
                        break
                    }
                    codeLines.append(lines[idx])
                    idx += 1
                }
                let src = codeLines.joined(separator: "\n")
                if ["math", "latex", "tex"].contains(fence.language) {
                    hasRich = true
                    blocks.append(.math(src))
                } else {
                    if fence.language == "mermaid" {
                        hasRich = true
                    }
                    hasCodeOrTable = true
                    blocks.append(.code(language: fence.language, code: src))
                }
                continue
            }

            // ATX Heading (# .. ######)
            if let heading = matchHeading(line) {
                if ChatMarkdownInline.containsInlineMath(heading.text) { hasRich = true }
                blocks.append(.heading(level: heading.level, text: heading.text))
                idx += 1
                continue
            }

            // Horizontal rule (---, ***, ___)
            if isHorizontalRule(line) {
                blocks.append(.rule)
                idx += 1
                continue
            }

            // Blockquote (> ...)
            if isBlockquoteLine(line) {
                var quoteLines: [String] = []
                while idx < lines.count && isBlockquoteLine(lines[idx]) {
                    quoteLines.append(stripQuotePrefix(lines[idx]))
                    idx += 1
                }
                if depth < maxNestingDepth {
                    let inner = parseBlocks(
                        quoteLines,
                        depth: depth + 1,
                        hasRich: &hasRich,
                        hasCodeOrTable: &hasCodeOrTable
                    )
                    if !inner.isEmpty {
                        blocks.append(.quote(inner))
                    }
                } else {
                    let fallback = quoteLines.joined(separator: "\n")
                    if ChatMarkdownInline.containsInlineMath(fallback) { hasRich = true }
                    blocks.append(.quote([.paragraph(fallback)]))
                }
                continue
            }

            // GFM Table
            if trimmed.contains("|"),
               idx + 1 < lines.count,
               let alignments = parseTableAlignments(lines[idx + 1]) {
                let rawHeaders = splitTableRow(line)
                let colCount = max(rawHeaders.count, alignments.count)
                let headers = padRow(rawHeaders, to: colCount)
                let paddedAlignments = alignments + Array(repeating: .leading, count: max(0, colCount - alignments.count))
                idx += 2
                var rows: [[String]] = []
                while idx < lines.count {
                    let rowLine = lines[idx]
                    let rowTrimmed = rowLine.trimmingCharacters(in: .whitespaces)
                    if rowTrimmed.isEmpty ||
                       !rowTrimmed.contains("|") ||
                       matchOpeningFence(rowLine) != nil ||
                       matchHeading(rowLine) != nil ||
                       isHorizontalRule(rowLine) ||
                       isBlockquoteLine(rowLine) {
                        break
                    }
                    rows.append(padRow(splitTableRow(rowLine), to: colCount))
                    idx += 1
                }
                for cell in headers where ChatMarkdownInline.containsInlineMath(cell) { hasRich = true }
                for row in rows {
                    for cell in row where ChatMarkdownInline.containsInlineMath(cell) { hasRich = true }
                }
                hasCodeOrTable = true
                blocks.append(.table(headers: headers, alignments: paddedAlignments, rows: rows))
                continue
            }

            // Unordered / Ordered / Task List
            if let firstMarker = matchListMarker(line) {
                let listBlock = parseList(
                    lines,
                    index: &idx,
                    firstMarker: firstMarker,
                    depth: depth,
                    hasRich: &hasRich,
                    hasCodeOrTable: &hasCodeOrTable
                )
                blocks.append(listBlock)
                continue
            }

            // Paragraph
            var paraLines: [String] = [line]
            idx += 1
            while idx < lines.count {
                let nextLine = lines[idx]
                let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty ||
                   matchSingleLineDisplayMath(nextTrimmed) != nil ||
                   nextTrimmed == "$$" ||
                   nextTrimmed == "\\[" ||
                   matchOpeningFence(nextLine) != nil ||
                   matchHeading(nextLine) != nil ||
                   isHorizontalRule(nextLine) ||
                   isBlockquoteLine(nextLine) ||
                   matchListMarker(nextLine) != nil {
                    break
                }
                if nextTrimmed.contains("|"),
                   idx + 1 < lines.count,
                   parseTableAlignments(lines[idx + 1]) != nil {
                    break
                }
                paraLines.append(nextLine)
                idx += 1
            }
            let paraText = paraLines.joined(separator: "\n")
            if ChatMarkdownInline.containsInlineMath(paraText) { hasRich = true }
            blocks.append(.paragraph(paraText))
        }

        return blocks
    }

    private static func parseList(
        _ lines: [String],
        index idx: inout Int,
        firstMarker: ListMarker,
        depth: Int,
        hasRich: inout Bool,
        hasCodeOrTable: inout Bool
    ) -> ChatMarkdownBlock {
        let baseIndent = firstMarker.indent
        let isOrdered = firstMarker.ordered
        let startNumber = firstMarker.number
        var items: [ChatMarkdownListItem] = []

        while idx < lines.count {
            guard !isHorizontalRule(lines[idx]),
                  let marker = matchListMarker(lines[idx]),
                  marker.ordered == isOrdered,
                  marker.indent <= baseIndent + 1 else {
                break
            }

            var firstContent = marker.rest
            var checked: Bool? = nil
            if !isOrdered {
                if firstContent.hasPrefix("[ ] ") {
                    checked = false
                    firstContent = String(firstContent.dropFirst(4))
                } else if firstContent.hasPrefix("[x] ") || firstContent.hasPrefix("[X] ") {
                    checked = true
                    firstContent = String(firstContent.dropFirst(4))
                } else if firstContent == "[ ]" {
                    checked = false
                    firstContent = ""
                } else if firstContent == "[x]" || firstContent == "[X]" {
                    checked = true
                    firstContent = ""
                }
            }

            let minChildIndent = baseIndent + 2
            let preferredIndent = max(marker.contentIndent, minChildIndent)
            var childStripIndent: Int? = nil
            var itemLines: [String] = [firstContent]
            var activeFence: (Character, Int)? = matchOpeningFence(firstContent).map { ($0.char, $0.length) }
            idx += 1

            while idx < lines.count {
                let rawLine = lines[idx]
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty {
                    var lookahead = idx + 1
                    while lookahead < lines.count && lines[lookahead].trimmingCharacters(in: .whitespaces).isEmpty {
                        lookahead += 1
                    }
                    if activeFence != nil {
                        itemLines.append("")
                        idx += 1
                        continue
                    }
                    if lookahead < lines.count && leadingIndent(lines[lookahead]) >= minChildIndent {
                        itemLines.append("")
                        idx += 1
                        continue
                    }
                    if lookahead < lines.count,
                       !isHorizontalRule(lines[lookahead]),
                       let nextMarker = matchListMarker(lines[lookahead]),
                       nextMarker.ordered == isOrdered,
                       nextMarker.indent <= baseIndent + 1 {
                        idx = lookahead
                    }
                    break
                }

                let ind = leadingIndent(rawLine)
                if let fence = activeFence {
                    let stripCols = childStripIndent ?? min(preferredIndent, ind)
                    let stripped = stripLeadingIndent(rawLine, maxColumns: min(stripCols, ind))
                    itemLines.append(stripped)
                    if isClosingFence(stripped, char: fence.0, minLength: fence.1) {
                        activeFence = nil
                    }
                    idx += 1
                    continue
                }

                if ind >= minChildIndent {
                    let stripCols = childStripIndent ?? min(preferredIndent, ind)
                    childStripIndent = stripCols
                    let stripped = stripLeadingIndent(rawLine, maxColumns: stripCols)
                    if let fence = matchOpeningFence(stripped) {
                        activeFence = (fence.char, fence.length)
                    }
                    itemLines.append(stripped)
                    idx += 1
                    continue
                }

                if isHorizontalRule(rawLine) ||
                   matchListMarker(rawLine) != nil ||
                   matchOpeningFence(rawLine) != nil ||
                   matchHeading(rawLine) != nil ||
                   isBlockquoteLine(rawLine) ||
                   trimmed == "$$" ||
                   trimmed == "\\[" ||
                   matchSingleLineDisplayMath(trimmed) != nil {
                    break
                }
                if trimmed.contains("|"),
                   idx + 1 < lines.count,
                   parseTableAlignments(lines[idx + 1]) != nil {
                    break
                }

                // Lazy continuation line
                itemLines.append(trimmed)
                idx += 1
            }

            let childBlocks: [ChatMarkdownBlock]
            if depth < maxNestingDepth {
                let parsed = parseBlocks(
                    itemLines,
                    depth: depth + 1,
                    hasRich: &hasRich,
                    hasCodeOrTable: &hasCodeOrTable
                )
                childBlocks = parsed.isEmpty ? [.paragraph("")] : parsed
            } else {
                let text = itemLines.joined(separator: "\n")
                if ChatMarkdownInline.containsInlineMath(text) { hasRich = true }
                childBlocks = [.paragraph(text)]
            }
            items.append(ChatMarkdownListItem(checked: checked, blocks: childBlocks))
        }

        return .list(ordered: isOrdered, start: startNumber, items: items)
    }

    // MARK: - Block Matchers

    private static func leadingIndent(_ line: String) -> Int {
        var cols = 0
        for ch in line {
            if ch == " " { cols += 1 }
            else if ch == "\t" { cols += 4 }
            else { break }
        }
        return cols
    }

    private static func stripLeadingIndent(_ line: String, maxColumns: Int) -> String {
        var remaining = maxColumns
        var index = line.startIndex
        while index < line.endIndex && remaining > 0 {
            let ch = line[index]
            if ch == " " {
                remaining -= 1
                index = line.index(after: index)
            } else if ch == "\t" {
                remaining = max(0, remaining - 4)
                index = line.index(after: index)
            } else {
                break
            }
        }
        return String(line[index...])
    }

    private static func matchSingleLineDisplayMath(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$") && trimmed.count > 4 {
            let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty && inner.count <= ChatMarkdownInline.maxMathLength && !inner.contains("$$") {
                return inner
            }
        }
        if trimmed.hasPrefix("\\[") && trimmed.hasSuffix("\\]") && trimmed.count > 4 {
            let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty && inner.count <= ChatMarkdownInline.maxMathLength {
                return inner
            }
        }
        return nil
    }

    private static func matchOpeningFence(_ line: String) -> FenceInfo? {
        guard leadingIndent(line) <= 3 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let fenceLen = trimmed.prefix(while: { $0 == first }).count
        guard fenceLen >= 3 else { return nil }
        let info = String(trimmed.dropFirst(fenceLen)).trimmingCharacters(in: .whitespaces)
        if first == "`" && info.contains("`") { return nil }
        let firstToken = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let lang = firstToken.lowercased().replacingOccurrences(
            of: "[^a-z0-9_+#.-]",
            with: "",
            options: .regularExpression
        )
        return FenceInfo(char: first, length: fenceLen, language: lang)
    }

    private static func isClosingFence(_ line: String, char: Character, minLength: Int) -> Bool {
        guard leadingIndent(line) <= 3 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let run = trimmed.prefix(while: { $0 == char }).count
        return run >= minLength && run == trimmed.count
    }

    private static func matchHeading(_ line: String) -> (level: Int, text: String)? {
        guard leadingIndent(line) <= 3 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        if let first = rest.first, first != " " && first != "\t" {
            return nil
        }
        var title = String(rest).trimmingCharacters(in: .whitespaces)
        if title.hasSuffix("#") {
            var end = title.endIndex
            while end > title.startIndex && title[title.index(before: end)] == "#" {
                end = title.index(before: end)
            }
            if end == title.startIndex {
                title = ""
            } else {
                let beforeHash = title[title.index(before: end)]
                if beforeHash == " " || beforeHash == "\t" {
                    title = String(title[..<end]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return (level, title)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        guard leadingIndent(line) <= 3 else { return false }
        let compact = line.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let marker = compact.first else { return false }
        guard marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private static func isBlockquoteLine(_ line: String) -> Bool {
        guard leadingIndent(line) <= 3 else { return false }
        return line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private static func stripQuotePrefix(_ line: String) -> String {
        let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmedLeading.first == ">" else { return line }
        let after = trimmedLeading.dropFirst()
        if after.first == " " { return String(after.dropFirst()) }
        return String(after)
    }

    private static func matchListMarker(_ line: String) -> ListMarker? {
        let ind = leadingIndent(line)
        let body = stripLeadingIndent(line, maxColumns: ind)
        guard !body.isEmpty else { return nil }

        if let first = body.first, first == "-" || first == "*" || first == "+" {
            let after = body.dropFirst()
            if let sep = after.first, sep == " " || sep == "\t" {
                let rest = String(after.dropFirst())
                return ListMarker(indent: ind, ordered: false, number: 1, contentIndent: ind + 2, rest: rest)
            }
            return nil
        }

        var digitsEnd = body.startIndex
        var digitCount = 0
        while digitsEnd < body.endIndex && body[digitsEnd].isASCII && body[digitsEnd].isNumber && digitCount < 9 {
            digitsEnd = body.index(after: digitsEnd)
            digitCount += 1
        }
        guard digitCount > 0, digitsEnd < body.endIndex else { return nil }
        let delim = body[digitsEnd]
        guard delim == "." || delim == ")" else { return nil }
        let afterDelim = body.index(after: digitsEnd)
        guard afterDelim < body.endIndex, body[afterDelim] == " " || body[afterDelim] == "\t" else {
            return nil
        }
        let number = Int(body[..<digitsEnd]) ?? 1
        let restStart = body.index(after: afterDelim)
        let rest = String(body[restStart...])
        return ListMarker(
            indent: ind,
            ordered: true,
            number: number,
            contentIndent: ind + digitCount + 2,
            rest: rest
        )
    }

    private static func parseTableAlignments(_ line: String) -> [ChatTableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") && trimmed.contains("-") else { return nil }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return nil }
        var alignments: [ChatTableAlignment] = []
        for rawCell in cells {
            let cell = rawCell.trimmingCharacters(in: .whitespaces)
            guard !cell.isEmpty else { return nil }
            let leftColon = cell.hasPrefix(":")
            let rightColon = cell.hasSuffix(":")
            let middle = cell.dropFirst(leftColon ? 1 : 0).dropLast(rightColon ? 1 : 0)
            guard !middle.isEmpty && middle.allSatisfy({ $0 == "-" }) else { return nil }
            if leftColon && rightColon {
                alignments.append(.center)
            } else if rightColon {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }

        let chars = Array(trimmed)
        var cells: [String] = []
        var current = ""
        var i = 0
        var inCodeTicks = 0

        while i < chars.count {
            let ch = chars[i]
            if ch == "\\" && i + 1 < chars.count && chars[i + 1] == "|" && inCodeTicks == 0 {
                current.append("|")
                i += 2
                continue
            }
            if ch == "`" {
                let run = ChatMarkdownInline.countRun(chars, of: "`", from: i)
                for _ in 0..<run { current.append("`") }
                if inCodeTicks == 0 {
                    inCodeTicks = run
                } else if inCodeTicks == run {
                    inCodeTicks = 0
                }
                i += run
                continue
            }
            if ch == "|" && inCodeTicks == 0 {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                i += 1
                continue
            }
            current.append(ch)
            i += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func padRow(_ row: [String], to count: Int) -> [String] {
        if row.count >= count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }
}
