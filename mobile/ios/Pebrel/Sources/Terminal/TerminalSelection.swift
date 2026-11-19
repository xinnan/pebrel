import Foundation

struct TerminalCellPoint: Equatable, Comparable {
    let column: Int
    let row: Int

    static func < (lhs: TerminalCellPoint, rhs: TerminalCellPoint) -> Bool {
        lhs.row != rhs.row ? lhs.row < rhs.row : lhs.column < rhs.column
    }
}

struct TerminalSelectionState: Equatable {
    let frame: TerminalFrame
    var anchor: TerminalCellPoint
    var focus: TerminalCellPoint

    var start: TerminalCellPoint { min(anchor, focus) }
    var end: TerminalCellPoint { max(anchor, focus) }

    func contains(column: Int, row: Int) -> Bool {
        let pt = TerminalCellPoint(column: column, row: row)
        return pt >= start && pt <= end
    }

    static func wordSelection(in frame: TerminalFrame, column: Int, row: Int) -> TerminalSelectionState? {
        guard row >= 0, row < frame.rows.count, frame.columns > 0 else { return nil }
        let clampedCol = snapLeadingColumn(in: frame.rows[row], column: column.clamped(to: 0...(frame.columns - 1)))
        let targetClass = wordClass(in: frame.rows[row], column: clampedCol)
        var left = clampedCol
        while left > 0 {
            let prev = snapLeadingColumn(in: frame.rows[row], column: left - 1)
            if wordClass(in: frame.rows[row], column: prev) != targetClass { break }
            left = prev
        }
        var right = snapTrailingColumn(in: frame.rows[row], column: clampedCol)
        while right + 1 < frame.columns {
            let nextLead = snapLeadingColumn(in: frame.rows[row], column: right + 1)
            if wordClass(in: frame.rows[row], column: nextLead) != targetClass { break }
            right = snapTrailingColumn(in: frame.rows[row], column: nextLead)
        }
        return TerminalSelectionState(
            frame: frame,
            anchor: TerminalCellPoint(column: left, row: row),
            focus: TerminalCellPoint(column: right, row: row)
        )
    }

    static func lineSelection(in frame: TerminalFrame, row: Int) -> TerminalSelectionState? {
        guard row >= 0, row < frame.rows.count, frame.columns > 0 else { return nil }
        return TerminalSelectionState(
            frame: frame,
            anchor: TerminalCellPoint(column: 0, row: row),
            focus: TerminalCellPoint(column: frame.columns - 1, row: row)
        )
    }

    static func selectAll(in frame: TerminalFrame) -> TerminalSelectionState? {
        guard !frame.rows.isEmpty, frame.columns > 0 else { return nil }
        return TerminalSelectionState(
            frame: frame,
            anchor: TerminalCellPoint(column: 0, row: 0),
            focus: TerminalCellPoint(column: frame.columns - 1, row: frame.rows.count - 1)
        )
    }

    func selectedText() -> String {
        guard !frame.rows.isEmpty, frame.columns > 0 else { return "" }
        let lo = start
        let hi = end
        var result = ""
        for y in lo.row...min(hi.row, frame.rows.count - 1) {
            let row = frame.rows[y]
            let cols = row.cells.count / 6
            let fromCol = (y == lo.row) ? lo.column.clamped(to: 0...max(0, cols - 1)) : 0
            let toCol = (y == hi.row) ? hi.column.clamped(to: 0...max(0, cols - 1)) : max(0, cols - 1)
            var line = ""
            if fromCol <= toCol {
                for x in fromCol...toCol {
                    let width = row.cells[x * 6 + 2]
                    if width == 0 { continue }
                    line.append(row.cellText(column: x))
                }
            }
            let softWrapped = (frame.wrapped != nil && y < frame.wrapped!.count) ? frame.wrapped![y] : false
            let fullEnd = toCol >= cols - 1
            if !softWrapped && (fullEnd || y < hi.row) {
                while line.last == " " { line.removeLast() }
            }
            result.append(line)
            if y < hi.row && !softWrapped {
                result.append("\n")
            }
        }
        return result
    }

    static func snapLeadingColumn(in row: TerminalRow, column: Int) -> Int {
        let cols = row.cells.count / 6
        guard cols > 0 else { return 0 }
        let c = column.clamped(to: 0...(cols - 1))
        if row.cells[c * 6 + 2] == 0 && c > 0 {
            return c - 1
        }
        return c
    }

    static func snapTrailingColumn(in row: TerminalRow, column: Int) -> Int {
        let cols = row.cells.count / 6
        guard cols > 0 else { return 0 }
        let c = column.clamped(to: 0...(cols - 1))
        if row.cells[c * 6 + 2] == 2 && c + 1 < cols {
            return c + 1
        }
        return c
    }

    private static func wordClass(in row: TerminalRow, column: Int) -> Int {
        let text = row.cellText(column: column)
        guard let scalar = text.unicodeScalars.first else { return 2 }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return 2 }
        if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || CharacterSet.nonBaseCharacters.contains(scalar) {
            return 1
        }
        return 0
    }
}
