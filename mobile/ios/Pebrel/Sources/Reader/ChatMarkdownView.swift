import SwiftUI
import UIKit

struct ChatMarkdownView: View {
    @Environment(\.pebrelPalette) private var palette

    let document: ChatMarkdownDocument
    let codeFontFamily: String
    var textColor: Color? = nil

    init(
        text: String,
        codeFontFamily: String = TerminalPreferenceValues.mapleFont,
        textColor: Color? = nil
    ) {
        self.document = ChatMarkdownParser.cachedParse(text)
        self.codeFontFamily = codeFontFamily
        self.textColor = textColor
    }

    init(
        document: ChatMarkdownDocument,
        codeFontFamily: String = TerminalPreferenceValues.mapleFont,
        textColor: Color? = nil
    ) {
        self.document = document
        self.codeFontFamily = codeFontFamily
        self.textColor = textColor
    }

    var body: some View {
        let style = ChatInlineStyle(
            baseFont: .body,
            codeFont: TerminalFontRegistry.swiftUIFont(family: codeFontFamily, size: 13.5),
            foregroundColor: textColor ?? palette.foreground,
            linkColor: palette.primary,
            codeBackground: palette.foreground.opacity(palette.isDark ? 0.14 : 0.08),
            mathBackground: palette.primary.opacity(palette.isDark ? 0.18 : 0.10),
            imageLabel: L10n.tr("reader_open_image")
        )
        ChatMarkdownBlocksView(
            blocks: document.blocks,
            style: style,
            codeFontFamily: codeFontFamily
        )
    }
}

private struct ChatMarkdownBlocksView: View {
    @Environment(\.pebrelPalette) private var palette

    let blocks: [ChatMarkdownBlock]
    let style: ChatInlineStyle
    let codeFontFamily: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(ChatMarkdownInline.render(text, style: style))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .heading(let level, let text):
            let headingFont = fontForHeading(level)
            let headingStyle = ChatInlineStyle(
                baseFont: headingFont,
                codeFont: TerminalFontRegistry.swiftUIFont(family: codeFontFamily, size: level <= 2 ? 14.5 : 13.5),
                foregroundColor: style.foregroundColor,
                linkColor: style.linkColor,
                codeBackground: style.codeBackground,
                mathBackground: style.mathBackground,
                imageLabel: style.imageLabel
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(ChatMarkdownInline.render(text, style: headingStyle))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if level <= 2 {
                    Rectangle()
                        .fill(palette.outlineVariant.opacity(0.6))
                        .frame(height: 0.5)
                }
            }
            .padding(.top, level <= 2 ? 4 : 2)

        case .quote(let inner):
            let quoteStyle = style.withForegroundColor(palette.muted)
            AnyView(
                ChatMarkdownBlocksView(
                    blocks: inner,
                    style: quoteStyle,
                    codeFontFamily: codeFontFamily
                )
            )
            .padding(.leading, 12)
            .padding(.vertical, 2)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(palette.primary.opacity(0.55))
                    .frame(width: 3)
            }

        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        listMarker(ordered: ordered, number: start + index, checked: item.checked)
                        AnyView(
                            ChatMarkdownBlocksView(
                                blocks: item.blocks,
                                style: style,
                                codeFontFamily: codeFontFamily
                            )
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .code(let language, let code):
            ChatCodeBoxView(
                code: code,
                label: language.isEmpty ? nil : language,
                codeFontFamily: codeFontFamily,
                isMath: false
            )

        case .math(let source):
            ChatCodeBoxView(
                code: source,
                label: "LaTeX",
                codeFontFamily: codeFontFamily,
                isMath: true
            )

        case .table(let headers, let alignments, let rows):
            ChatTableView(
                headers: headers,
                alignments: alignments,
                rows: rows,
                baseStyle: style,
                codeFontFamily: codeFontFamily
            )

        case .rule:
            Rectangle()
                .fill(palette.outlineVariant)
                .frame(height: 0.75)
                .padding(.vertical, 4)
        }
    }

    private func fontForHeading(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline.weight(.bold)
        case 3: return .subheadline.weight(.semibold)
        default: return .subheadline.weight(.medium)
        }
    }

    @ViewBuilder
    private func listMarker(ordered: Bool, number: Int, checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.subheadline)
                .foregroundStyle(checked ? palette.primary : palette.muted)
                .frame(minWidth: 18, alignment: .trailing)
                .padding(.top, 2)
        } else if ordered {
            Text("\(number).")
                .font(.body.monospacedDigit())
                .foregroundStyle(palette.muted)
                .frame(minWidth: 20, alignment: .trailing)
        } else {
            Text("•")
                .font(.body.weight(.semibold))
                .foregroundStyle(palette.muted)
                .frame(minWidth: 14, alignment: .center)
        }
    }
}

private struct ChatCodeBoxView: View {
    @Environment(\.pebrelPalette) private var palette

    let code: String
    let label: String?
    let codeFontFamily: String
    let isMath: Bool

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(label ?? "")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isMath ? palette.primary : palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    resetTask?.cancel()
                    resetTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if !Task.isCancelled {
                            copied = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                        Text(copied ? L10n.tr("reader_copied") : L10n.tr("reader_copy"))
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(copied ? palette.tertiary : palette.primary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 4)

            Rectangle()
                .fill(palette.outlineVariant.opacity(0.6))
                .frame(height: 0.5)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(TerminalFontRegistry.swiftUIFont(family: codeFontFamily, size: 12.5))
                    .foregroundStyle(palette.foreground)
                    .lineSpacing(3)
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            isMath
                ? palette.primary.opacity(palette.isDark ? 0.12 : 0.06)
                : palette.surfaceVariant.opacity(palette.isDark ? 0.85 : 0.75),
            in: shape
        )
        .overlay(
            shape.strokeBorder(
                isMath ? palette.primary.opacity(0.28) : palette.outlineVariant,
                lineWidth: 0.75
            )
        )
        .onDisappear {
            resetTask?.cancel()
        }
    }
}

private struct ChatTableCellItem: Identifiable {
    let id: Int
    let row: Int
    let col: Int
    let text: String
}

private struct ChatTableView: View {
    @Environment(\.pebrelPalette) private var palette

    let headers: [String]
    let alignments: [ChatTableAlignment]
    let rows: [[String]]
    let baseStyle: ChatInlineStyle
    let codeFontFamily: String

    var body: some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        if columnCount > 0 {
            let allRows = [headers] + rows
            let totalRows = allRows.count
            let cells: [ChatTableCellItem] = (0..<totalRows).flatMap { r in
                (0..<columnCount).map { c in
                    let value = c < allRows[r].count ? allRows[r][c] : ""
                    return ChatTableCellItem(id: r * columnCount + c, row: r, col: c, text: value)
                }
            }
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            ScrollView(.horizontal, showsIndicators: true) {
                ChatTableLayout(columnCount: columnCount, maxColumnWidth: 260) {
                    ForEach(cells) { cell in
                        let isHeader = cell.row == 0
                        let align = cell.col < alignments.count ? alignments[cell.col] : .leading
                        let cellStyle = ChatInlineStyle(
                            baseFont: isHeader ? .subheadline.weight(.semibold) : .subheadline,
                            codeFont: TerminalFontRegistry.swiftUIFont(family: codeFontFamily, size: 12.5),
                            foregroundColor: baseStyle.foregroundColor,
                            linkColor: baseStyle.linkColor,
                            codeBackground: baseStyle.codeBackground,
                            mathBackground: baseStyle.mathBackground,
                            imageLabel: baseStyle.imageLabel
                        )
                        let rowBg: Color = isHeader
                            ? palette.surfaceVariant.opacity(palette.isDark ? 0.90 : 0.85)
                            : (cell.row % 2 == 0 ? palette.surfaceVariant.opacity(0.32) : Color.clear)

                        Text(ChatMarkdownInline.render(cell.text, style: cellStyle))
                            .multilineTextAlignment(align.textAlignment)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align.frameAlignment)
                            .background(rowBg)
                            .overlay(alignment: .bottom) {
                                if cell.row < totalRows - 1 {
                                    Rectangle()
                                        .fill(palette.outlineVariant.opacity(isHeader ? 0.9 : 0.55))
                                        .frame(height: isHeader ? 0.75 : 0.5)
                                }
                            }
                            .overlay(alignment: .trailing) {
                                if cell.col < columnCount - 1 {
                                    Rectangle()
                                        .fill(palette.outlineVariant.opacity(0.45))
                                        .frame(width: 0.5)
                                }
                            }
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(palette.outlineVariant, lineWidth: 0.75))
            }
        }
    }
}

private struct ChatTableLayout: Layout {
    let columnCount: Int
    let maxColumnWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (colWidths, rowHeights) = measure(subviews: subviews)
        return CGSize(
            width: colWidths.reduce(0, +),
            height: rowHeights.reduce(0, +)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard columnCount > 0, !subviews.isEmpty else { return }
        let (colWidths, rowHeights) = measure(subviews: subviews)
        var y = bounds.minY
        for row in 0..<rowHeights.count {
            var x = bounds.minX
            let rh = rowHeights[row]
            for col in 0..<columnCount {
                let idx = row * columnCount + col
                guard idx < subviews.count else { break }
                let cw = colWidths[col]
                subviews[idx].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: cw, height: rh)
                )
                x += cw
            }
            y += rh
        }
    }

    private func measure(subviews: Subviews) -> ([CGFloat], [CGFloat]) {
        guard columnCount > 0, !subviews.isEmpty else { return ([], []) }
        let rowCount = (subviews.count + columnCount - 1) / columnCount
        var colWidths = Array(repeating: CGFloat(48), count: columnCount)

        for (index, subview) in subviews.enumerated() {
            let col = index % columnCount
            let ideal = subview.sizeThatFits(.unspecified).width.rounded(.up)
            let clamped = min(max(ideal, 48), maxColumnWidth)
            if clamped > colWidths[col] {
                colWidths[col] = clamped
            }
        }

        var rowHeights = Array(repeating: CGFloat(30), count: rowCount)
        for (index, subview) in subviews.enumerated() {
            let row = index / columnCount
            let col = index % columnCount
            let measured = subview.sizeThatFits(ProposedViewSize(width: colWidths[col], height: nil)).height.rounded(.up)
            let h = max(measured, 30)
            if h > rowHeights[row] {
                rowHeights[row] = h
            }
        }

        return (colWidths, rowHeights)
    }
}
