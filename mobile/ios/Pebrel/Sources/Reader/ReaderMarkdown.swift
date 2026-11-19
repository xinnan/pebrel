import Foundation

struct ReaderHeading: Identifiable, Equatable {
    let id: String
    let level: Int
    let title: String
}

struct ReaderDocument: Equatable {
    let html: String
    let bodyHTML: String
    let token: String
    let codeBlocks: [String]
    let links: [String]
    let headings: [ReaderHeading]
    let hasRichContent: Bool
}

enum ReaderMarkdown {
    static let scheme = "pebrel-reader"
    static let baseURL = URL(string: "pebrel-reader://local/")!

    static func isMarkdownPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }

    static func isImagePath(_ path: String) -> Bool {
        let ext = (path.lowercased() as NSString).pathExtension
        return ["png", "jpg", "jpeg", "webp", "gif", "bmp"].contains(ext)
    }

    static func languageForPath(_ path: String) -> String {
        let ext = (path.lowercased() as NSString).pathExtension
        switch ext {
        case "rs": return "rust"
        case "py": return "python"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "swift": return "swift"
        case "kt", "kts": return "kotlin"
        case "java": return "java"
        case "go": return "go"
        case "c", "h": return "c"
        case "cc", "cpp", "cxx", "hpp": return "cpp"
        case "cs": return "csharp"
        case "rb": return "ruby"
        case "php": return "php"
        case "sh", "bash", "zsh": return "bash"
        case "ps1": return "powershell"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "toml", "ini": return "ini"
        case "xml", "plist", "svg": return "xml"
        case "html", "htm": return "xml"
        case "css", "scss", "less": return "css"
        case "sql": return "sql"
        case "md", "markdown": return "markdown"
        case "lua", "luau": return "lua"
        case "dockerfile": return "dockerfile"
        default: return ""
        }
    }

    static func prepareSource(text: String, path: String, colors: ReaderColors, copyLabel: String) -> ReaderDocument {
        let lang = languageForPath(path)
        let lines = text.components(separatedBy: "\n")
        let lineNums = (1...max(1, lines.count)).map(String.init).joined(separator: "\n")
        let langClass = lang.isEmpty ? "" : " class=\"language-\(escapeAttr(lang))\""
        let body = """
        <div class="source-layout"><pre class="line-numbers" aria-hidden="true">\(lineNums)</pre><pre class="source-code"><code\(langClass)>\(escapeHTML(text))</code></pre></div>
        """
        return wrapDocument(body: body, colors: colors, codeBlocks: [text], links: [], headings: [], hasRich: false)
    }

    static func prepareMarkdown(text: String, colors: ReaderColors, copyLabel: String) -> ReaderDocument {
        var codeBlocks: [String] = []
        var links: [String] = []
        var headings: [ReaderHeading] = []
        var slugCounts: [String: Int] = [:]
        var hasRich = false

        func addCode(_ source: String) -> Int {
            let idx = codeBlocks.count
            codeBlocks.append(source)
            return idx
        }

        func addLink(_ href: String) -> Int {
            let idx = links.count
            links.append(href)
            return idx
        }

        func uniqueSlug(_ title: String) -> String {
            let base = title.lowercased()
                .replacingOccurrences(of: "[^a-z0-9\\u4e00-\\u9fff]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let clean = base.isEmpty ? "section" : base
            let n = slugCounts[clean, default: 0]
            slugCounts[clean] = n + 1
            return n == 0 ? clean : "\(clean)-\(n)"
        }

        func renderInline(_ raw: String) -> String {
            var out = ""
            let chars = Array(raw)
            let count = chars.count
            var i = 0

            while i < count {
                // Escaped char
                if chars[i] == "\\" && i + 1 < count {
                    let next = chars[i + 1]
                    if next == "(" || next == "[" {
                        let closing: [Character] = next == "(" ? ["\\", ")"] : ["\\", "]"]
                        if let end = findSequence(chars, closing, from: i + 2) {
                            let mathSrc = String(chars[(i + 2)..<end])
                            if !mathSrc.isEmpty && mathSrc.count <= 32768 {
                                hasRich = true
                                let idx = addCode(mathSrc)
                                let disp = next == "["
                                let cls = disp ? "formula formula-display" : "formula"
                                out += "<span class=\"\(cls)\" id=\"formula-\(idx)\"><span class=\"math-render\" data-display=\"\(disp ? "true" : "false")\">\(escapeHTML(mathSrc))</span><span class=\"formula-actions\"><a data-copy=\"\(idx)\" href=\"pebrel-copy:__TOKEN__:\(idx)\">\(escapeHTML(copyLabel))</a></span></span>"
                                i = end + 2
                                continue
                            }
                        }
                    }
                    out += escapeHTML(String(next))
                    i += 2
                    continue
                }

                // Inline code span
                if chars[i] == "`" {
                    var ticks = 0
                    while i + ticks < count && chars[i + ticks] == "`" { ticks += 1 }
                    let delim = Array(repeating: Character("`"), count: ticks)
                    if let end = findSequence(chars, delim, from: i + ticks) {
                        let inner = String(chars[(i + ticks)..<end]).trimmingCharacters(in: .whitespaces)
                        out += "<code>\(escapeHTML(inner))</code>"
                        i = end + ticks
                        continue
                    }
                }

                // Inline/display $...$ or $$...$$ math (guarding currency like $10)
                if chars[i] == "$" {
                    let isDouble = i + 1 < count && chars[i + 1] == "$"
                    let delimLen = isDouble ? 2 : 1
                    let delim = Array(repeating: Character("$"), count: delimLen)
                    if let end = findSequence(chars, delim, from: i + delimLen) {
                        let candidate = String(chars[(i + delimLen)..<end])
                        let looksCurrency = !isDouble && (candidate.first?.isWhitespace == true || candidate.last?.isWhitespace == true || candidate.allSatisfy { $0.isNumber || $0 == "." || $0 == "," })
                        if !candidate.isEmpty && !looksCurrency && candidate.count <= 32768 {
                            hasRich = true
                            let idx = addCode(candidate)
                            let cls = isDouble ? "formula formula-display" : "formula"
                            out += "<span class=\"\(cls)\" id=\"formula-\(idx)\"><span class=\"math-render\" data-display=\"\(isDouble ? "true" : "false")\">\(escapeHTML(candidate))</span><span class=\"formula-actions\"><a data-copy=\"\(idx)\" href=\"pebrel-copy:__TOKEN__:\(idx)\">\(escapeHTML(copyLabel))</a></span></span>"
                            i = end + delimLen
                            continue
                        }
                    }
                }

                // Image ![alt](url) -> link (never loads remote images)
                if chars[i] == "!" && i + 1 < count && chars[i + 1] == "[" {
                    if let closeBracket = findChar(chars, "]", from: i + 2),
                       closeBracket + 1 < count && chars[closeBracket + 1] == "(",
                       let closeParen = findChar(chars, ")", from: closeBracket + 2) {
                        let alt = String(chars[(i + 2)..<closeBracket])
                        let url = String(chars[(closeBracket + 2)..<closeParen]).trimmingCharacters(in: .whitespaces)
                        let idx = addLink(url)
                        let label = alt.isEmpty ? url : alt
                        out += "<a class=\"image-link\" href=\"pebrel-link:__TOKEN__:\(idx)\">\(escapeHTML(label))</a>"
                        i = closeParen + 1
                        continue
                    }
                }

                // Link [label](url)
                if chars[i] == "[" {
                    if let closeBracket = findChar(chars, "]", from: i + 1),
                       closeBracket + 1 < count && chars[closeBracket + 1] == "(",
                       let closeParen = findChar(chars, ")", from: closeBracket + 2) {
                        let label = String(chars[(i + 1)..<closeBracket])
                        let url = String(chars[(closeBracket + 2)..<closeParen]).trimmingCharacters(in: .whitespaces)
                        let idx = addLink(url)
                        out += "<a href=\"pebrel-link:__TOKEN__:\(idx)\">\(renderInline(label))</a>"
                        i = closeParen + 1
                        continue
                    }
                }

                // Bold **...**
                if chars[i] == "*" && i + 1 < count && chars[i + 1] == "*" {
                    if let end = findSequence(chars, ["*", "*"], from: i + 2) {
                        let inner = String(chars[(i + 2)..<end])
                        out += "<strong>\(renderInline(inner))</strong>"
                        i = end + 2
                        continue
                    }
                }

                // Strikethrough ~~...~~
                if chars[i] == "~" && i + 1 < count && chars[i + 1] == "~" {
                    if let end = findSequence(chars, ["~", "~"], from: i + 2) {
                        let inner = String(chars[(i + 2)..<end])
                        out += "<del>\(renderInline(inner))</del>"
                        i = end + 2
                        continue
                    }
                }

                // Italic *...*
                if chars[i] == "*" {
                    if let end = findChar(chars, "*", from: i + 1), end > i + 1 {
                        let inner = String(chars[(i + 1)..<end])
                        out += "<em>\(renderInline(inner))</em>"
                        i = end + 1
                        continue
                    }
                }

                out += escapeHTML(String(chars[i]))
                i += 1
            }
            return out
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var bodyParts: [String] = []
        var idx = 0

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                idx += 1
                continue
            }

            // Fenced display math $$ ... $$ or \[ ... \]
            if trimmed == "$$" || trimmed == "\\[" {
                let closing = trimmed == "$$" ? "$$" : "\\]"
                var mathLines: [String] = []
                idx += 1
                while idx < lines.count && lines[idx].trimmingCharacters(in: .whitespaces) != closing {
                    mathLines.append(lines[idx])
                    idx += 1
                }
                if idx < lines.count { idx += 1 }
                let mathSrc = mathLines.joined(separator: "\n")
                hasRich = true
                let codeIdx = addCode(mathSrc)
                bodyParts.append("<div class=\"formula formula-display\" id=\"formula-\(codeIdx)\"><span class=\"math-render\" data-display=\"true\">\(escapeHTML(mathSrc))</span><span class=\"formula-actions\"><a data-copy=\"\(codeIdx)\" href=\"pebrel-copy:__TOKEN__:\(codeIdx)\">\(escapeHTML(copyLabel))</a></span></div>")
                continue
            }

            // Fenced code block ``` or ~~~
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fenceChar = trimmed.first!
                let fenceLen = trimmed.prefix(while: { $0 == fenceChar }).count
                let lang = String(trimmed.dropFirst(fenceLen)).trimmingCharacters(in: .whitespaces).lowercased()
                let safeLang = lang.replacingOccurrences(of: "[^a-z0-9_+-]", with: "", options: .regularExpression)
                var codeLines: [String] = []
                idx += 1
                while idx < lines.count {
                    let t = lines[idx].trimmingCharacters(in: .whitespaces)
                    if t.prefix(while: { $0 == fenceChar }).count >= fenceLen && t.trimmingCharacters(in: CharacterSet(charactersIn: String(fenceChar))).isEmpty {
                        idx += 1
                        break
                    }
                    codeLines.append(lines[idx])
                    idx += 1
                }
                let src = codeLines.joined(separator: "\n")
                let codeIdx = addCode(src)
                if ["math", "latex", "tex"].contains(safeLang) {
                    hasRich = true
                    bodyParts.append("<div class=\"formula formula-display\" id=\"formula-\(codeIdx)\"><span class=\"math-render\" data-display=\"true\">\(escapeHTML(src))</span><span class=\"formula-actions\"><a data-copy=\"\(codeIdx)\" href=\"pebrel-copy:__TOKEN__:\(codeIdx)\">\(escapeHTML(copyLabel))</a></span></div>")
                } else if safeLang == "mermaid" {
                    hasRich = true
                    bodyParts.append("<figure class=\"diagram\" id=\"diagram-\(codeIdx)\"><div class=\"diagram-render\" data-diagram=\"\(codeIdx)\"></div><details><summary>Mermaid</summary><div class=\"code-block\"><a class=\"copy-code\" data-copy=\"\(codeIdx)\" href=\"pebrel-copy:__TOKEN__:\(codeIdx)\">\(escapeHTML(copyLabel))</a><pre><code class=\"language-mermaid\">\(escapeHTML(src))</code></pre></div></details></figure>")
                } else {
                    let cls = safeLang.isEmpty ? "" : " class=\"language-\(safeLang)\""
                    let caption = safeLang.isEmpty ? "" : "<figcaption>\(escapeHTML(safeLang))</figcaption>"
                    bodyParts.append("<figure class=\"code-block\"><a class=\"copy-code\" data-copy=\"\(codeIdx)\" href=\"pebrel-copy:__TOKEN__:\(codeIdx)\">\(escapeHTML(copyLabel))</a><pre><code\(cls)>\(escapeHTML(src))</code></pre>\(caption)</figure>")
                }
                continue
            }

            // ATX Heading
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if (1...6).contains(level), trimmed.count > level, trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " {
                    let title = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
                    let slug = uniqueSlug(title)
                    headings.append(ReaderHeading(id: slug, level: level, title: title))
                    bodyParts.append("<h\(level) id=\"\(escapeAttr(slug))\">\(renderInline(title))</h\(level)>")
                    idx += 1
                    continue
                }
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                bodyParts.append("<hr />")
                idx += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while idx < lines.count && lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let stripped = lines[idx].trimmingCharacters(in: .whitespaces).dropFirst()
                    quoteLines.append(stripped.hasPrefix(" ") ? String(stripped.dropFirst()) : String(stripped))
                    idx += 1
                }
                bodyParts.append("<blockquote><p>\(renderInline(quoteLines.joined(separator: "\n")))</p></blockquote>")
                continue
            }

            // GFM Table
            if trimmed.contains("|"), idx + 1 < lines.count, isTableSeparator(lines[idx + 1]) {
                let headers = splitTableRow(line)
                idx += 2
                var tableHTML = "<table><thead><tr>"
                for h in headers { tableHTML += "<th>\(renderInline(h))</th>" }
                tableHTML += "</tr></thead><tbody>"
                while idx < lines.count && lines[idx].contains("|") && !lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
                    let cols = splitTableRow(lines[idx])
                    tableHTML += "<tr>"
                    for cIdx in 0..<max(headers.count, cols.count) {
                        let cell = cIdx < cols.count ? cols[cIdx] : ""
                        tableHTML += "<td>\(renderInline(cell))</td>"
                    }
                    tableHTML += "</tr>"
                    idx += 1
                }
                tableHTML += "</tbody></table>"
                bodyParts.append(tableHTML)
                continue
            }

            // Unordered / Task list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                var items: [String] = []
                while idx < lines.count {
                    let t = lines[idx].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") else { break }
                    let content = String(t.dropFirst(2))
                    if content.hasPrefix("[ ] ") {
                        items.append("<li><input type=\"checkbox\" disabled /> \(renderInline(String(content.dropFirst(4))))</li>")
                    } else if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
                        items.append("<li><input type=\"checkbox\" disabled checked /> \(renderInline(String(content.dropFirst(4))))</li>")
                    } else {
                        items.append("<li>\(renderInline(content))</li>")
                    }
                    idx += 1
                }
                bodyParts.append("<ul>\(items.joined())</ul>")
                continue
            }

            // Ordered list
            if let dotRange = trimmed.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
                var items: [String] = []
                while idx < lines.count {
                    let t = lines[idx].trimmingCharacters(in: .whitespaces)
                    guard let r = t.range(of: "^\\d+\\.\\s+", options: .regularExpression) else { break }
                    items.append("<li>\(renderInline(String(t[r.upperBound...])))</li>")
                    idx += 1
                }
                _ = dotRange
                bodyParts.append("<ol>\(items.joined())</ol>")
                continue
            }

            // Paragraph
            var paraLines: [String] = [line]
            idx += 1
            while idx < lines.count {
                let next = lines[idx].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || next.hasPrefix("#") || next.hasPrefix("```") || next.hasPrefix("~~~") ||
                   next.hasPrefix(">") || next.hasPrefix("- ") || next.hasPrefix("* ") || next == "$$" {
                    break
                }
                paraLines.append(lines[idx])
                idx += 1
            }
            bodyParts.append("<p>\(renderInline(paraLines.joined(separator: "\n")))</p>")
        }

        let body = bodyParts.joined(separator: "\n")
        return wrapDocument(body: body, colors: colors, codeBlocks: codeBlocks, links: links, headings: headings, hasRich: hasRich)
    }

    static func resolveRelativeLink(basePath: String, link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.hasPrefix("http://"),
              !trimmed.hasPrefix("https://"),
              !trimmed.hasPrefix("mailto:") else {
            return nil
        }
        let withoutFragment = trimmed.components(separatedBy: "#").first ?? trimmed
        let withoutQuery = withoutFragment.components(separatedBy: "?").first ?? withoutFragment
        guard !withoutQuery.isEmpty else { return nil }

        let decoded = withoutQuery.removingPercentEncoding ?? withoutQuery
        let usesBackslash = basePath.contains("\\") && !basePath.hasPrefix("/")
        let normalizedBase = basePath.replacingOccurrences(of: "\\", with: "/")
        let normalizedTarget = decoded.replacingOccurrences(of: "\\", with: "/")

        let combined: String
        if normalizedTarget.hasPrefix("/") || (normalizedTarget.count >= 3 && normalizedTarget[normalizedTarget.index(normalizedTarget.startIndex, offsetBy: 1)] == ":") {
            combined = normalizedTarget
        } else {
            let parent = (normalizedBase as NSString).deletingLastPathComponent
            combined = parent.isEmpty ? normalizedTarget : "\(parent)/\(normalizedTarget)"
        }

        var stack: [String] = []
        let isRooted = combined.hasPrefix("/")
        let isUNC = combined.hasPrefix("//")
        for seg in combined.split(separator: "/").map(String.init) {
            if seg == "." || seg.isEmpty { continue }
            if seg == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(seg)
            }
        }
        var result = (isUNC ? "//" : (isRooted ? "/" : "")) + stack.joined(separator: "/")
        if usesBackslash {
            result = result.replacingOccurrences(of: "/", with: "\\")
        }
        return result
    }

    private static func wrapDocument(
        body: String,
        colors: ReaderColors,
        codeBlocks: [String],
        links: [String],
        headings: [ReaderHeading],
        hasRich: Bool
    ) -> ReaderDocument {
        let token = String(CryptoHelpers.sha256Hex(body).prefix(12))
        let resolvedBody = body.replacingOccurrences(of: "__TOKEN__", with: token)
        let csp = "default-src 'none'; style-src 'unsafe-inline' \(scheme):; script-src \(scheme):; font-src \(scheme):; img-src data:;"
        let html = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0" />
        <meta name="referrer" content="no-referrer" />
        <meta http-equiv="Content-Security-Policy" content="\(csp)" />
        <link rel="stylesheet" href="reader/katex/katex.min.css" />
        <link rel="stylesheet" href="reader/reader.css" />
        <style>
        :root {
          --background: \(colors.backgroundHex);
          --foreground: \(colors.foregroundHex);
          --muted: \(colors.mutedHex);
          --surface: \(colors.surfaceHex);
          --code-surface: \(colors.codeSurfaceHex);
          --border: \(colors.borderHex);
          --accent: \(colors.accentHex);
        }
        </style>
        </head>
        <body>
        <main>\(resolvedBody)</main>
        <script src="reader/highlight.min.js"></script>
        <script src="reader/katex/katex.min.js"></script>
        <script src="reader/reader-compat.js"></script>
        <script src="reader/mermaid/mermaid.min.js"></script>
        <script src="reader/extensions.js"></script>
        <script src="reader/reader.js"></script>
        </body>
        </html>
        """
        return ReaderDocument(
            html: html,
            bodyHTML: resolvedBody,
            token: token,
            codeBlocks: codeBlocks,
            links: links,
            headings: headings,
            hasRichContent: hasRich
        )
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") && trimmed.contains("|") else { return false }
        return trimmed.unicodeScalars.allSatisfy { s in
            s == "|" || s == "-" || s == ":" || s == " " || s == "\t"
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func findChar(_ chars: [Character], _ target: Character, from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == target { return i }
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
            for j in 0..<seq.count {
                if chars[i + j] != seq[j] { matched = false; break }
            }
            if matched { return i }
            i += 1
        }
        return nil
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeAttr(_ text: String) -> String {
        escapeHTML(text).replacingOccurrences(of: "'", with: "&#39;")
    }
}
