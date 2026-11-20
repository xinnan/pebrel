import Foundation
import SwiftUI

struct ChatInlineStyle {
    var baseFont: Font
    var codeFont: Font
    var foregroundColor: Color
    var linkColor: Color
    var codeBackground: Color
    var mathBackground: Color
    var imageLabel: String
    var isBold: Bool = false
    var isItalic: Bool = false
    var isStrikethrough: Bool = false
    var isUnderlined: Bool = false
    var link: URL? = nil

    func withForegroundColor(_ color: Color) -> ChatInlineStyle {
        var copy = self
        copy.foregroundColor = color
        return copy
    }
}

enum ChatMarkdownInline {
    private static let maxNestingDepth = 6
    static let maxMathLength = 32_768

    static func render(_ raw: String, style: ChatInlineStyle) -> AttributedString {
        var output = AttributedString()
        appendInline(Array(raw), style: style, depth: 0, into: &output)
        return output
    }

    static func containsInlineMath(_ text: String) -> Bool {
        let chars = Array(text)
        let count = chars.count
        var i = 0
        while i < count {
            if chars[i] == "\\" && i + 1 < count {
                let next = chars[i + 1]
                if next == "(" || next == "[" {
                    let closing: [Character] = next == "(" ? ["\\", ")"] : ["\\", "]"]
                    if let end = findSequence(chars, closing, from: i + 2) {
                        let innerLen = end - (i + 2)
                        if innerLen > 0 && innerLen <= maxMathLength {
                            return true
                        }
                    }
                }
                i += 2
                continue
            }
            if chars[i] == "`" {
                let ticks = countRun(chars, of: "`", from: i)
                if let end = findClosingBackticks(chars, count: ticks, from: i + ticks) {
                    i = end + ticks
                    continue
                }
            }
            if chars[i] == "$", matchDollarMath(chars, from: i) != nil {
                return true
            }
            i += 1
        }
        return false
    }

    static func safeLinkURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        guard scheme == "http" || scheme == "https" || scheme == "mailto" else {
            return nil
        }
        return url
    }

    static func countRun(_ chars: [Character], of target: Character, from start: Int) -> Int {
        var n = 0
        while start + n < chars.count && chars[start + n] == target { n += 1 }
        return n
    }

    // MARK: - Recursive Inline Renderer

    private static func appendInline(
        _ chars: [Character],
        style: ChatInlineStyle,
        depth: Int,
        into out: inout AttributedString
    ) {
        let count = chars.count
        var i = 0
        var plain = ""

        func flushPlain() {
            guard !plain.isEmpty else { return }
            out.append(makeStyledRun(plain, style: style))
            plain = ""
        }

        while i < count {
            let ch = chars[i]

            // Backslash escape or inline LaTeX \(...\) / \[...\]
            if ch == "\\" && i + 1 < count {
                let next = chars[i + 1]
                if next == "(" || next == "[" {
                    let closing: [Character] = next == "(" ? ["\\", ")"] : ["\\", "]"]
                    if let end = findSequence(chars, closing, from: i + 2) {
                        let mathSrc = String(chars[(i + 2)..<end])
                        if !mathSrc.isEmpty && mathSrc.count <= maxMathLength {
                            flushPlain()
                            out.append(makeMathRun(mathSrc, style: style))
                            i = end + 2
                            continue
                        }
                    }
                }
                if isEscapablePunctuation(next) {
                    plain.append(next)
                    i += 2
                    continue
                }
            }

            // Inline code span (`...` or ``...``)
            if ch == "`" {
                let ticks = countRun(chars, of: "`", from: i)
                if let end = findClosingBackticks(chars, count: ticks, from: i + ticks) {
                    var inner = String(chars[(i + ticks)..<end])
                    if inner.count >= 2 && inner.first == " " && inner.last == " " && !inner.allSatisfy({ $0 == " " }) {
                        inner = String(inner.dropFirst().dropLast())
                    }
                    flushPlain()
                    out.append(makeCodeRun(inner, style: style))
                    i = end + ticks
                    continue
                }
            }

            // Inline $...$ or $$...$$ math
            if ch == "$", let (mathSrc, nextIdx) = matchDollarMath(chars, from: i) {
                flushPlain()
                out.append(makeMathRun(mathSrc, style: style))
                i = nextIdx
                continue
            }

            // Image ![alt](url) -> never fetches remote image; renders as labeled link/text
            if ch == "!" && i + 1 < count && chars[i + 1] == "[",
               let parsed = parseBracketedLink(chars, openBracket: i + 1) {
                flushPlain()
                let labelText = parsed.label.isEmpty ? parsed.destination : parsed.label
                let display = style.imageLabel.isEmpty ? labelText : "\(style.imageLabel) · \(labelText)"
                var imgStyle = style
                imgStyle.foregroundColor = style.linkColor
                if let url = safeLinkURL(parsed.destination) {
                    imgStyle.link = url
                    imgStyle.isUnderlined = true
                }
                out.append(makeStyledRun(display, style: imgStyle))
                i = parsed.nextIndex
                continue
            }

            // Link [label](url)
            if ch == "[", depth < maxNestingDepth,
               let parsed = parseBracketedLink(chars, openBracket: i) {
                flushPlain()
                var linkStyle = style
                linkStyle.foregroundColor = style.linkColor
                if let url = safeLinkURL(parsed.destination) {
                    linkStyle.link = url
                    linkStyle.isUnderlined = true
                }
                appendInline(Array(parsed.label), style: linkStyle, depth: depth + 1, into: &out)
                i = parsed.nextIndex
                continue
            }

            // Bare autolink https://... or http://...
            if ch == "h",
               style.link == nil,
               let (urlString, url, nextIdx) = matchAutolink(chars, from: i) {
                flushPlain()
                var linkStyle = style
                linkStyle.foregroundColor = style.linkColor
                linkStyle.isUnderlined = true
                linkStyle.link = url
                out.append(makeStyledRun(urlString, style: linkStyle))
                i = nextIdx
                continue
            }

            // Bold + Italic ***...***
            if ch == "*" && i + 2 < count && chars[i + 1] == "*" && chars[i + 2] == "*",
               depth < maxNestingDepth,
               let end = findEmphasisClose(chars, delimiter: ["*", "*", "*"], from: i + 3) {
                flushPlain()
                var nextStyle = style
                nextStyle.isBold = true
                nextStyle.isItalic = true
                appendInline(Array(chars[(i + 3)..<end]), style: nextStyle, depth: depth + 1, into: &out)
                i = end + 3
                continue
            }

            // Bold **...**
            if ch == "*" && i + 1 < count && chars[i + 1] == "*",
               depth < maxNestingDepth,
               let end = findEmphasisClose(chars, delimiter: ["*", "*"], from: i + 2) {
                flushPlain()
                var nextStyle = style
                nextStyle.isBold = true
                appendInline(Array(chars[(i + 2)..<end]), style: nextStyle, depth: depth + 1, into: &out)
                i = end + 2
                continue
            }

            // Bold __...__ (word-boundary guarded so foo__bar__baz stays literal)
            if ch == "_" && i + 1 < count && chars[i + 1] == "_",
               depth < maxNestingDepth,
               isWordBoundaryBefore(chars, index: i),
               let end = findUnderscoreClose(chars, length: 2, from: i + 2) {
                flushPlain()
                var nextStyle = style
                nextStyle.isBold = true
                appendInline(Array(chars[(i + 2)..<end]), style: nextStyle, depth: depth + 1, into: &out)
                i = end + 2
                continue
            }

            // Strikethrough ~~...~~
            if ch == "~" && i + 1 < count && chars[i + 1] == "~",
               depth < maxNestingDepth,
               let end = findEmphasisClose(chars, delimiter: ["~", "~"], from: i + 2) {
                flushPlain()
                var nextStyle = style
                nextStyle.isStrikethrough = true
                appendInline(Array(chars[(i + 2)..<end]), style: nextStyle, depth: depth + 1, into: &out)
                i = end + 2
                continue
            }

            // Italic *...*
            if ch == "*",
               depth < maxNestingDepth,
               i + 1 < count,
               chars[i + 1] != "*",
               !chars[i + 1].isWhitespace,
               let end = findSingleStarClose(chars, from: i + 1) {
                flushPlain()
                var nextStyle = style
                nextStyle.isItalic = true
                appendInline(Array(chars[(i + 1)..<end]), style: nextStyle, depth: depth + 1, into: &out)
                i = end + 1
                continue
            }

            // Italic _..._ (word-boundary guarded so snake_case_name stays literal)
            if ch == "_",
               depth < maxNestingDepth,
               isWordBoundaryBefore(chars, index: i),
               i + 1 < count,
               chars[i + 1] != "_",
               !chars[i + 1].isWhitespace,
               let end = findUnderscoreClose(chars, length: 1, from: i + 1) {
                flushPlain()
                var nextStyle = style
                nextStyle.isItalic = true
                appendInline(Array(chars[(i + 1)..<end]), style: nextStyle, depth: depth + 1, into: &out)
                i = end + 1
                continue
            }

            plain.append(ch)
            i += 1
        }

        flushPlain()
    }

    // MARK: - AttributedString Run Builders

    private static func makeStyledRun(_ text: String, style: ChatInlineStyle) -> AttributedString {
        var container = AttributeContainer()
        var font = style.baseFont
        if style.isBold { font = font.bold() }
        if style.isItalic { font = font.italic() }
        container.swiftUI.font = font
        container.swiftUI.foregroundColor = style.foregroundColor
        if style.isUnderlined {
            container.swiftUI.underlineStyle = .single
        }
        if style.isStrikethrough {
            container.swiftUI.strikethroughStyle = .single
        }
        if let url = style.link {
            container[AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
        }
        return AttributedString(text, attributes: container)
    }

    private static func makeCodeRun(_ text: String, style: ChatInlineStyle) -> AttributedString {
        var container = AttributeContainer()
        container.swiftUI.font = style.codeFont
        container.swiftUI.foregroundColor = style.link != nil ? style.linkColor : style.foregroundColor
        container.swiftUI.backgroundColor = style.codeBackground
        if style.isStrikethrough {
            container.swiftUI.strikethroughStyle = .single
        }
        if let url = style.link {
            container[AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
        }
        return AttributedString(text, attributes: container)
    }

    private static func makeMathRun(_ text: String, style: ChatInlineStyle) -> AttributedString {
        var container = AttributeContainer()
        container.swiftUI.font = style.codeFont
        container.swiftUI.foregroundColor = style.foregroundColor
        container.swiftUI.backgroundColor = style.mathBackground
        return AttributedString(text, attributes: container)
    }

    // MARK: - Scanner Helpers

    private static func isEscapablePunctuation(_ ch: Character) -> Bool {
        switch ch {
        case "\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", "~", "|", "$", ">", "<":
            return true
        default:
            return false
        }
    }

    private static func isASCIIWordChar(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return (scalar >= "a" && scalar <= "z") ||
               (scalar >= "A" && scalar <= "Z") ||
               (scalar >= "0" && scalar <= "9") ||
               scalar == "_"
    }

    private static func isWordBoundaryBefore(_ chars: [Character], index: Int) -> Bool {
        guard index > 0 else { return true }
        return !isASCIIWordChar(chars[index - 1])
    }

    private static func isWordBoundaryAfter(_ chars: [Character], indexAfterClose: Int) -> Bool {
        guard indexAfterClose < chars.count else { return true }
        return !isASCIIWordChar(chars[indexAfterClose])
    }

    private static func findClosingBackticks(_ chars: [Character], count targetCount: Int, from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "`" {
                let run = countRun(chars, of: "`", from: i)
                if run == targetCount { return i }
                i += run
                continue
            }
            i += 1
        }
        return nil
    }

    private static func findSequence(_ chars: [Character], _ seq: [Character], from start: Int) -> Int? {
        guard !seq.isEmpty, start + seq.count <= chars.count else { return nil }
        var i = start
        let limit = chars.count - seq.count
        while i <= limit {
            var matched = true
            for j in 0..<seq.count where chars[i + j] != seq[j] {
                matched = false
                break
            }
            if matched { return i }
            i += 1
        }
        return nil
    }

    private static func matchDollarMath(_ chars: [Character], from start: Int) -> (String, Int)? {
        let count = chars.count
        let isDouble = start + 1 < count && chars[start + 1] == "$"
        let delimLen = isDouble ? 2 : 1
        let bodyStart = start + delimLen
        guard bodyStart < count else { return nil }
        if !isDouble && (chars[bodyStart].isWhitespace || chars[bodyStart] == "$") {
            return nil
        }

        var i = bodyStart
        while i < count {
            if chars[i] == "\\" && i + 1 < count {
                i += 2
                continue
            }
            if !isDouble && chars[i] == "\n" {
                return nil
            }
            if chars[i] == "$" {
                if isDouble {
                    if i + 1 < count && chars[i + 1] == "$" {
                        let candidate = String(chars[bodyStart..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !candidate.isEmpty && candidate.count <= maxMathLength {
                            return (candidate, i + 2)
                        }
                        return nil
                    }
                } else {
                    if i > bodyStart && !chars[i - 1].isWhitespace {
                        // Guard against "$10+$20" (digit immediately after closing '$')
                        if i + 1 < count && chars[i + 1].isNumber {
                            return nil
                        }
                        let candidate = String(chars[bodyStart..<i])
                        let looksCurrency = candidate.allSatisfy { $0.isNumber || $0 == "." || $0 == "," }
                        if !candidate.isEmpty && !looksCurrency && candidate.count <= maxMathLength {
                            return (candidate, i + 1)
                        }
                    }
                    return nil
                }
            }
            i += 1
        }
        return nil
    }

    private static func parseBracketedLink(
        _ chars: [Character],
        openBracket: Int
    ) -> (label: String, destination: String, nextIndex: Int)? {
        let count = chars.count
        var i = openBracket + 1
        var bracketDepth = 1
        while i < count && bracketDepth > 0 {
            if chars[i] == "\\" && i + 1 < count {
                i += 2
                continue
            }
            if chars[i] == "`" {
                let ticks = countRun(chars, of: "`", from: i)
                if let end = findClosingBackticks(chars, count: ticks, from: i + ticks) {
                    i = end + ticks
                    continue
                }
            }
            if chars[i] == "[" { bracketDepth += 1 }
            else if chars[i] == "]" { bracketDepth -= 1 }
            i += 1
        }
        guard bracketDepth == 0 else { return nil }
        let closeBracket = i - 1
        guard closeBracket + 1 < count && chars[closeBracket + 1] == "(" else { return nil }

        var j = closeBracket + 2
        var parenDepth = 1
        while j < count && parenDepth > 0 {
            if chars[j] == "\\" && j + 1 < count {
                j += 2
                continue
            }
            if chars[j] == "\n" { return nil }
            if chars[j] == "(" { parenDepth += 1 }
            else if chars[j] == ")" { parenDepth -= 1 }
            j += 1
        }
        guard parenDepth == 0 else { return nil }
        let closeParen = j - 1
        let label = String(chars[(openBracket + 1)..<closeBracket])
        let rawDest = String(chars[(closeBracket + 2)..<closeParen]).trimmingCharacters(in: .whitespaces)
        let dest = extractLinkDestination(rawDest)
        guard !dest.isEmpty else { return nil }
        return (label, dest, closeParen + 1)
    }

    private static func extractLinkDestination(_ raw: String) -> String {
        if raw.hasPrefix("<"), let close = raw.firstIndex(of: ">") {
            return String(raw[raw.index(after: raw.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
        }
        if let spaceIdx = raw.firstIndex(where: { $0.isWhitespace }) {
            return String(raw[..<spaceIdx])
        }
        return raw
    }

    private static func matchAutolink(_ chars: [Character], from start: Int) -> (String, URL, Int)? {
        if start > 0 {
            let prev = chars[start - 1]
            if isASCIIWordChar(prev) || prev == "/" || prev == "@" || prev == "." {
                return nil
            }
        }
        let count = chars.count
        let httpsPrefix: [Character] = Array("https://")
        let httpPrefix: [Character] = Array("http://")
        let hasHttps = start + httpsPrefix.count < count && Array(chars[start..<(start + httpsPrefix.count)]) == httpsPrefix
        let hasHttp = !hasHttps && start + httpPrefix.count < count && Array(chars[start..<(start + httpPrefix.count)]) == httpPrefix
        guard hasHttps || hasHttp else { return nil }

        var end = start
        while end < count {
            let c = chars[end]
            if c.isWhitespace || c == "<" || c == ">" || c == "\"" || c == "'" ||
               c == "，" || c == "。" || c == "；" || c == "：" || c == "）" || c == "】" || c == "》" {
                break
            }
            end += 1
        }
        var raw = String(chars[start..<end])
        while let last = raw.last, [".", ",", ";", ":", "!", "?"].contains(last) {
            raw.removeLast()
            end -= 1
        }
        while raw.hasSuffix(")") && raw.filter({ $0 == ")" }).count > raw.filter({ $0 == "(" }).count {
            raw.removeLast()
            end -= 1
        }
        while raw.hasSuffix("]") && raw.filter({ $0 == "]" }).count > raw.filter({ $0 == "[" }).count {
            raw.removeLast()
            end -= 1
        }
        guard raw.count > (hasHttps ? 8 : 7), let url = safeLinkURL(raw) else { return nil }
        return (raw, url, end)
    }

    private static func findEmphasisClose(
        _ chars: [Character],
        delimiter: [Character],
        from start: Int
    ) -> Int? {
        let len = delimiter.count
        guard start + len <= chars.count, !chars[start].isWhitespace else { return nil }
        var i = start
        let limit = chars.count - len
        while i <= limit {
            if chars[i] == "\\" && i + 1 < chars.count {
                i += 2
                continue
            }
            if chars[i] == "`" {
                let ticks = countRun(chars, of: "`", from: i)
                if let end = findClosingBackticks(chars, count: ticks, from: i + ticks) {
                    i = end + ticks
                    continue
                }
            }
            var matched = true
            for j in 0..<len where chars[i + j] != delimiter[j] {
                matched = false
                break
            }
            if matched && i > start && !chars[i - 1].isWhitespace {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func findSingleStarClose(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count {
                i += 2
                continue
            }
            if chars[i] == "`" {
                let ticks = countRun(chars, of: "`", from: i)
                if let end = findClosingBackticks(chars, count: ticks, from: i + ticks) {
                    i = end + ticks
                    continue
                }
            }
            if chars[i] == "*" {
                let run = countRun(chars, of: "*", from: i)
                if run == 2 {
                    i += 2
                    continue
                }
                if run == 3 && i > start && !chars[i - 1].isWhitespace {
                    return i + 2
                }
                if i > start && !chars[i - 1].isWhitespace {
                    return i
                }
            }
            i += 1
        }
        return nil
    }

    private static func findUnderscoreClose(_ chars: [Character], length: Int, from start: Int) -> Int? {
        guard start + length <= chars.count, !chars[start].isWhitespace else { return nil }
        var i = start
        let limit = chars.count - length
        while i <= limit {
            if chars[i] == "\\" && i + 1 < chars.count {
                i += 2
                continue
            }
            if chars[i] == "`" {
                let ticks = countRun(chars, of: "`", from: i)
                if let end = findClosingBackticks(chars, count: ticks, from: i + ticks) {
                    i = end + ticks
                    continue
                }
            }
            if chars[i] == "_" {
                let run = countRun(chars, of: "_", from: i)
                if run == length && i > start && !chars[i - 1].isWhitespace &&
                   isWordBoundaryAfter(chars, indexAfterClose: i + length) {
                    return i
                }
                i += run
                continue
            }
            i += 1
        }
        return nil
    }
}
