import Foundation

enum DesktopScreenCodec {
    static func basePalette(from theme19: [UInt32]) -> [UInt32] {
        let fg = theme19.count > 0 ? (theme19[0] & 0x00FFFFFF) : 0xD8DEE9
        let bg = theme19.count > 1 ? (theme19[1] & 0x00FFFFFF) : 0x2E3440
        let cursor = theme19.count > 2 ? (theme19[2] & 0x00FFFFFF) : 0x88C0D0

        var palette = [UInt32](repeating: fg, count: 269)
        for i in 0..<16 {
            let idx = i + 3
            palette[i] = idx < theme19.count ? (theme19[idx] & 0x00FFFFFF) : fg
        }
        // 16..231: 6x6x6 xterm color cube
        let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
        for i in 0..<216 {
            let r = steps[i / 36]
            let g = steps[(i / 6) % 6]
            let b = steps[i % 6]
            palette[16 + i] = (r << 16) | (g << 8) | b
        }
        // 232..255: 24-step grayscale
        for i in 0..<24 {
            let v = UInt32(8 + i * 10)
            palette[232 + i] = (v << 16) | (v << 8) | v
        }
        palette[256] = fg
        palette[257] = bg
        palette[258] = cursor
        for i in 0..<8 {
            palette[259 + i] = palette[i]
        }
        palette[267] = fg
        palette[268] = fg
        return palette
    }

    static func parseFullScreen(_ dict: [String: Any], theme19: [UInt32]) -> TerminalFrame? {
        guard (dict["version"] as? Int) == 1,
              let columns = dict["columns"] as? Int, (1...400).contains(columns),
              let rawRows = dict["rows"] as? [[Any]], (1...200).contains(rawRows.count),
              columns * rawRows.count <= 40_000 else {
            return nil
        }

        var palette = basePalette(from: theme19)
        if !applyPaletteOverrides(dict["palette"], into: &palette) { return nil }

        var totalUtf8 = 0
        var rows: [TerminalRow] = []
        rows.reserveCapacity(rawRows.count)
        for rawRow in rawRows {
            guard let row = decodeRow(rawRow, columns: columns, palette: palette, totalUtf8: &totalUtf8) else {
                return nil
            }
            rows.append(row)
        }

        guard let cursor = parseCursor(dict["cursor"], columns: columns, rows: rows.count) else { return nil }
        let wrapped = parseWrapped(dict["wrapped"], expectedCount: rows.count)
        let history = parseHistory(dict["history"], rowCount: rows.count)

        let bgARGB = 0xFF000000 | palette[257]
        let cursorARGB = 0xFF000000 | palette[258]
        let fgARGB = 0xFF000000 | palette[256]
        let errARGB = 0xFF000000 | palette[1]

        let scrollTotal: Int
        let scrollOffset: Int
        if let history {
            scrollTotal = Int(min(Int64(Int.max), max(Int64(rows.count), history.end - history.oldest)))
            scrollOffset = Int(min(Int64(Int.max), max(0, history.first - history.oldest)))
        } else {
            scrollTotal = rows.count
            scrollOffset = 0
        }

        return TerminalFrame(
            columns: columns,
            rows: rows,
            cursorX: cursor.x,
            cursorY: cursor.y,
            cursorVisible: cursor.visible,
            background: bgARGB,
            cursorColor: cursorARGB,
            cursorStyle: 2,
            scrollTotal: scrollTotal,
            scrollOffset: scrollOffset,
            alternateScreen: history?.applicationScroll ?? false,
            desktopForeground: fgARGB,
            desktopError: errARGB,
            wrapped: wrapped,
            history: history,
            sourceOffsets: nil
        )
    }

    static func applyPaletteOverrides(_ raw: Any?, into palette: inout [UInt32]) -> Bool {
        guard let raw else { return true }
        guard let entries = raw as? [[Any]] else { return false }
        var seen = Set<Int>()
        for entry in entries {
            guard entry.count == 2,
                  let idx = entry[0] as? Int, (0..<269).contains(idx),
                  let rgb = (entry[1] as? NSNumber)?.int64Value, rgb >= 0, rgb <= 0xFFFFFF,
                  seen.insert(idx).inserted else {
                return false
            }
            palette[idx] = UInt32(rgb)
        }
        return true
    }

    static func decodeRow(_ rawRow: [Any], columns: Int, palette: [UInt32], totalUtf8: inout Int) -> TerminalRow? {
        var utf16: [UInt16] = []
        var cells = [Int32](repeating: 0, count: columns * 6)
        var col = 0
        for item in rawRow {
            guard let tuple = item as? [Any], tuple.count == 5,
                  let glyph = tuple[0] as? String, !glyph.isEmpty,
                  let width = tuple[1] as? Int, width == 1 || width == 2,
                  let fgVal = (tuple[2] as? NSNumber)?.int64Value,
                  let bgVal = (tuple[3] as? NSNumber)?.int64Value,
                  let flags = tuple[4] as? Int, (0...63).contains(flags),
                  col + width <= columns else {
                return nil
            }
            let glyphBytes = glyph.utf8.count
            guard glyphBytes <= 256, !CryptoHelpers.containsControlChar(glyph) else { return nil }
            totalUtf8 += glyphBytes
            guard totalUtf8 <= 128 * 1024 else { return nil }

            guard let fg = resolveColor(fgVal, palette: palette),
                  let bg = resolveColor(bgVal, palette: palette) else {
                return nil
            }

            let start = Int32(utf16.count)
            utf16.append(contentsOf: glyph.utf16)
            let len = Int32(utf16.count) - start

            let base = col * 6
            cells[base] = start
            cells[base + 1] = len
            cells[base + 2] = Int32(width)
            cells[base + 3] = Int32(bitPattern: 0xFF000000 | fg)
            cells[base + 4] = Int32(bitPattern: 0xFF000000 | bg)
            cells[base + 5] = Int32(flags)

            if width == 2 {
                let cBase = (col + 1) * 6
                cells[cBase] = start + len
                cells[cBase + 1] = 0
                cells[cBase + 2] = 0
                cells[cBase + 3] = Int32(bitPattern: 0xFF000000 | fg)
                cells[cBase + 4] = Int32(bitPattern: 0xFF000000 | bg)
                cells[cBase + 5] = Int32(flags)
            }
            col += width
        }
        guard col == columns else { return nil }
        return TerminalRow(utf16: utf16, cells: cells)
    }

    private static func resolveColor(_ value: Int64, palette: [UInt32]) -> UInt32? {
        if value >= 0 && value <= 0xFFFFFF {
            return UInt32(value)
        }
        if value < 0 {
            let idx = Int(-value - 1)
            if idx >= 0 && idx < palette.count {
                return palette[idx]
            }
        }
        return nil
    }

    static func parseCursor(_ raw: Any?, columns: Int, rows: Int) -> (x: Int, y: Int, visible: Bool)? {
        guard let arr = raw as? [NSNumber], arr.count == 3 else { return nil }
        let cx = arr[0].intValue
        let cy = arr[1].intValue
        let vis = arr[2].intValue
        guard vis == 0 || vis == 1 else { return nil }
        if vis == 1 {
            guard cx >= 0, cx < columns, cy >= 0, cy < rows else { return nil }
        }
        return (cx, cy, vis == 1)
    }

    static func parseWrapped(_ raw: Any?, expectedCount: Int) -> [Bool]? {
        guard let arr = raw as? [Bool], arr.count == expectedCount else { return nil }
        return arr
    }

    static func parseHistory(_ raw: Any?, rowCount: Int) -> TerminalHistory? {
        guard let obj = raw as? [String: Any],
              let first = (obj["first"] as? NSNumber)?.int64Value,
              let oldest = (obj["oldest"] as? NSNumber)?.int64Value,
              let end = (obj["end"] as? NSNumber)?.int64Value,
              let liveStart = (obj["live_start"] as? NSNumber)?.int64Value,
              let liveRows = obj["live_rows"] as? Int,
              let appScroll = obj["application_scroll"] as? Bool else {
            return nil
        }
        guard oldest >= 0, oldest <= first, first <= end,
              Int64(rowCount) <= end - first,
              (1...200).contains(liveRows),
              oldest <= liveStart, liveStart <= end,
              end - liveStart == Int64(liveRows) else {
            return nil
        }
        return TerminalHistory(
            first: first,
            oldest: oldest,
            end: end,
            liveStart: liveStart,
            liveRows: liveRows,
            applicationScroll: appScroll
        )
    }
}

/// Maintains baseline frame & applies incremental `screen_delta` updates.
final class DesktopScreenSync {
    private var targetKey: String = ""
    private(set) var sequence: Int64 = 0
    private var palette: [UInt32] = []
    private(set) var currentFrame: TerminalFrame?

    func reset() {
        targetKey = ""
        sequence = 0
        palette = []
        currentFrame = nil
    }

    func apply(target: String, response: [String: Any], theme19: [UInt32]) -> TerminalFrame? {
        let nextSeq = (response["screen_seq"] as? NSNumber)?.int64Value ?? 0

        if let full = response["screen"] as? [String: Any] {
            var pal = DesktopScreenCodec.basePalette(from: theme19)
            guard DesktopScreenCodec.applyPaletteOverrides(full["palette"], into: &pal),
                  let frame = DesktopScreenCodec.parseFullScreen(full, theme19: theme19) else {
                reset()
                return nil
            }
            targetKey = target
            sequence = nextSeq
            palette = pal
            currentFrame = frame
            return frame
        }

        if let delta = response["screen_delta"] as? [String: Any] {
            guard target == targetKey,
                  let old = currentFrame,
                  let base = (delta["base"] as? NSNumber)?.int64Value,
                  base == sequence,
                  nextSeq == sequence || nextSeq == sequence + 1 else {
                reset()
                return nil
            }

            var pal = palette
            if let palPatch = delta["palette"] {
                pal = DesktopScreenCodec.basePalette(from: theme19)
                guard DesktopScreenCodec.applyPaletteOverrides(palPatch, into: &pal) else {
                    reset()
                    return nil
                }
            }

            var rows = old.rows
            if let patchedRows = delta["rows"] as? [[Any]] {
                var lastIdx = -1
                var totalUtf8 = 0
                for item in patchedRows {
                    guard item.count == 2,
                          let rowIdx = item[0] as? Int,
                          rowIdx > lastIdx, rowIdx < rows.count,
                          let rawCells = item[1] as? [Any],
                          let decoded = DesktopScreenCodec.decodeRow(rawCells, columns: old.columns, palette: pal, totalUtf8: &totalUtf8) else {
                        reset()
                        return nil
                    }
                    rows[rowIdx] = decoded
                    lastIdx = rowIdx
                }
            }

            let cursor: (x: Int, y: Int, visible: Bool)
            if let rawCur = delta["cursor"] {
                guard let parsed = DesktopScreenCodec.parseCursor(rawCur, columns: old.columns, rows: rows.count) else {
                    reset()
                    return nil
                }
                cursor = parsed
            } else {
                cursor = (old.cursorX, old.cursorY, old.cursorVisible)
            }

            let wrapped = delta["wrapped"] != nil ? DesktopScreenCodec.parseWrapped(delta["wrapped"], expectedCount: rows.count) : old.wrapped
            let history = delta["history"] != nil ? DesktopScreenCodec.parseHistory(delta["history"], rowCount: rows.count) : old.history

            let scrollTotal = history.map { Int(min(Int64(Int.max), max(Int64(rows.count), $0.end - $0.oldest))) } ?? rows.count
            let scrollOffset = history.map { Int(min(Int64(Int.max), max(0, $0.first - $0.oldest))) } ?? 0

            let updated = TerminalFrame(
                columns: old.columns,
                rows: rows,
                cursorX: cursor.x,
                cursorY: cursor.y,
                cursorVisible: cursor.visible,
                background: 0xFF000000 | pal[257],
                cursorColor: 0xFF000000 | pal[258],
                cursorStyle: 2,
                scrollTotal: scrollTotal,
                scrollOffset: scrollOffset,
                alternateScreen: history?.applicationScroll ?? false,
                desktopForeground: 0xFF000000 | pal[256],
                desktopError: 0xFF000000 | pal[1],
                wrapped: wrapped,
                history: history,
                sourceOffsets: nil
            )
            sequence = nextSeq
            palette = pal
            currentFrame = updated
            return updated
        }

        return nil
    }
}

struct DesktopOutputState: Equatable {
    var target: String = ""
    var frame: TerminalFrame?
    var text: String = ""
    var loading: Bool = false
    var error: String?
}
