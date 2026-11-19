import Foundation

/// Read-only visual reflow for desktop terminal mirrors when `desktopWrapLines == true`.
/// Never alters the desktop PTY dimensions or re-parses ANSI escape sequences.
enum TerminalReflow {
    static func reflow(_ source: TerminalFrame, columns: Int) -> TerminalFrame {
        let targetCols = max(2, columns)
        guard targetCols < source.columns, !source.rows.isEmpty else {
            return source
        }

        var outRows: [TerminalRow] = []
        var outWrapped: [Bool] = []
        var outOffsets: [Int] = []
        var curUtf16: [UInt16] = []
        var curCells: [Int32] = []
        var curCol = 0
        var curRowStartOffset = 0

        var cursorOutX = 0
        var cursorOutY = 0
        var cursorMapped = false
        let bgARGB = Int32(bitPattern: source.background)

        func flushRow(wrapped: Bool) {
            while curCol < targetCols {
                let start = Int32(curUtf16.count)
                curUtf16.append(UInt16(32))
                curCells.append(contentsOf: [start, 1, 1, bgARGB, bgARGB, 0])
                curCol += 1
            }
            outRows.append(TerminalRow(utf16: curUtf16, cells: curCells))
            outWrapped.append(wrapped)
            outOffsets.append(curRowStartOffset)
            curUtf16 = []
            curCells = []
            curCol = 0
        }

        for (rowIdx, row) in source.rows.enumerated() {
            let srcCols = row.cells.count / 6
            let softWrapped = (source.wrapped != nil && rowIdx < source.wrapped!.count) ? source.wrapped![rowIdx] : false

            var limitCol = srcCols
            if !softWrapped {
                limitCol = 0
                for x in stride(from: srcCols - 1, through: 0, by: -1) {
                    let base = x * 6
                    let start = Int(row.cells[base])
                    let len = Int(row.cells[base + 1])
                    let width = Int(row.cells[base + 2])
                    let bg = row.cells[base + 4]
                    let flags = row.cells[base + 5]
                    let isCursorHere = source.cursorVisible && rowIdx == source.cursorY && x == source.cursorX
                    let isBlankSpace = width == 1 && len == 1 && start < row.utf16.count && row.utf16[start] == 32
                    if isCursorHere || bg != bgARGB || flags != 0 || !isBlankSpace {
                        limitCol = min(srcCols, x + max(1, width))
                        break
                    }
                }
                if limitCol == 0 && source.cursorVisible && rowIdx == source.cursorY {
                    limitCol = min(srcCols, source.cursorX + 1)
                }
            }

            if curCol == 0 {
                curRowStartOffset = rowIdx * source.columns
            }

            var x = 0
            while x < limitCol {
                let base = x * 6
                let start = Int(row.cells[base])
                let len = Int(row.cells[base + 1])
                let width = Int(row.cells[base + 2])
                let fg = row.cells[base + 3]
                let bg = row.cells[base + 4]
                let flags = row.cells[base + 5]

                if width == 0 {
                    x += 1
                    continue
                }
                let effectiveWidth = min(max(1, width), targetCols)
                if curCol + effectiveWidth > targetCols {
                    flushRow(wrapped: true)
                    curRowStartOffset = rowIdx * source.columns + x
                }

                if source.cursorVisible && rowIdx == source.cursorY && x == source.cursorX {
                    cursorOutX = curCol
                    cursorOutY = outRows.count
                    cursorMapped = true
                }

                let dstStart = Int32(curUtf16.count)
                if start >= 0 && len > 0 && start + len <= row.utf16.count {
                    curUtf16.append(contentsOf: row.utf16[start..<(start + len)])
                } else {
                    curUtf16.append(32)
                }
                let dstLen = Int32(curUtf16.count) - dstStart
                curCells.append(contentsOf: [dstStart, dstLen, Int32(effectiveWidth), fg, bg, flags])
                curCol += 1
                if effectiveWidth == 2 {
                    curCells.append(contentsOf: [dstStart + dstLen, 0, 0, fg, bg, flags])
                    curCol += 1
                }
                x += max(1, width)
            }

            if !softWrapped {
                if source.cursorVisible && rowIdx == source.cursorY && !cursorMapped {
                    cursorOutX = min(curCol, targetCols - 1)
                    cursorOutY = outRows.count
                    cursorMapped = true
                }
                flushRow(wrapped: false)
            }
        }

        if curCol > 0 || outRows.isEmpty {
            flushRow(wrapped: false)
        }

        return TerminalFrame(
            columns: targetCols,
            rows: outRows,
            cursorX: cursorMapped ? cursorOutX : min(source.cursorX, targetCols - 1),
            cursorY: cursorMapped ? cursorOutY : min(source.cursorY, max(0, outRows.count - 1)),
            cursorVisible: source.cursorVisible && cursorMapped,
            background: source.background,
            cursorColor: source.cursorColor,
            cursorStyle: source.cursorStyle,
            scrollTotal: max(outRows.count, source.scrollTotal),
            scrollOffset: source.scrollOffset,
            alternateScreen: source.alternateScreen,
            desktopForeground: source.desktopForeground,
            desktopError: source.desktopError,
            wrapped: outWrapped,
            history: source.history,
            sourceOffsets: outOffsets
        )
    }
}
