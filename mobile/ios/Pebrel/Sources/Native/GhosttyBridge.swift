import Foundation
import PebrelGhostty

struct TerminalRow: Equatable {
    let utf16: [UInt16]
    /// `columns * 6` ints: `[start, len, width, fgARGB, bgARGB, flags]`.
    let cells: [Int32]

    var text: String {
        String(utf16CodeUnits: utf16, count: utf16.count)
    }

    func cellText(column: Int) -> String {
        let base = column * 6
        guard base + 5 < cells.count else { return " " }
        let start = Int(cells[base])
        let len = Int(cells[base + 1])
        guard start >= 0, len > 0, start + len <= utf16.count else { return " " }
        return String(utf16CodeUnits: Array(utf16[start..<(start + len)]), count: len)
    }

    func plainLine(trimTrailing: Bool = true) -> String {
        let cols = cells.count / 6
        var result = ""
        result.reserveCapacity(cols)
        for x in 0..<cols {
            let width = cells[x * 6 + 2]
            if width == 0 { continue }
            result.append(cellText(column: x))
        }
        if trimTrailing {
            while result.last == " " { result.removeLast() }
        }
        return result
    }
}

struct TerminalHistory: Equatable {
    let first: Int64
    let oldest: Int64
    let end: Int64
    let liveStart: Int64
    let liveRows: Int
    let applicationScroll: Bool
}

struct TerminalFrame: Equatable {
    let columns: Int
    let rows: [TerminalRow]
    let cursorX: Int
    let cursorY: Int
    let cursorVisible: Bool
    let background: UInt32
    let cursorColor: UInt32
    let cursorStyle: Int
    let scrollTotal: Int
    let scrollOffset: Int
    let alternateScreen: Bool
    /// Desktop mirror chrome colors (optional): `[foregroundARGB, errorARGB]`.
    let desktopForeground: UInt32?
    let desktopError: UInt32?
    let wrapped: [Bool]?
    let history: TerminalHistory?
    /// Optional visual-row -> source cell index map produced by `TerminalReflow`.
    let sourceOffsets: [Int]?

    var rowCount: Int { rows.count }

    var isAtBottom: Bool {
        if let history {
            return history.first >= history.liveStart
        }
        return scrollTotal <= rows.count || scrollOffset >= scrollTotal - rows.count
    }

    func screenText() -> String {
        rows.map { $0.plainLine(trimTrailing: true) }.joined(separator: "\n")
    }

    func previewText(maxLines: Int = 6) -> String {
        let nonEmpty = rows.map { $0.plainLine(trimTrailing: true) }.filter { !$0.isEmpty }
        return nonEmpty.suffix(maxLines).joined(separator: "\n")
    }
}

enum GhosttyError: Error, LocalizedError {
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .engine(let code): return code
        }
    }
}

/// Serialized owner of a native `libghostty-vt` terminal instance.
/// Must only be accessed from its owning serial queue/actor.
final class GhosttyCore {
    private var handle: Int64
    private var rowCache: [TerminalRow] = []
    private var currentCols: Int
    private var currentRows: Int

    init(columns: Int = 80, rows: Int = 24, scrollback: Int = 1000) throws {
        var errPtr: UnsafePointer<CChar>?
        let h = pebrel_term_create(Int32(columns), Int32(rows), Int32(scrollback), &errPtr)
        guard h != 0 else {
            throw GhosttyError.engine(errPtr.map { String(cString: $0) } ?? "terminal_engine_failed")
        }
        self.handle = h
        self.currentCols = columns
        self.currentRows = rows
    }

    var isClosed: Bool { handle == 0 }

    func feed(_ data: Data) throws -> Data {
        guard handle != 0 else { return Data() }
        var replies = PebrelTermBytes(ptr: nil, len: 0)
        var errPtr: UnsafePointer<CChar>?
        let ok: Bool = data.withUnsafeBytes { buf in
            pebrel_term_feed(
                handle,
                buf.bindMemory(to: UInt8.self).baseAddress,
                data.count,
                &replies,
                &errPtr
            )
        }
        defer { pebrel_term_free_bytes(&replies) }
        guard ok else {
            throw GhosttyError.engine(errPtr.map { String(cString: $0) } ?? "terminal_engine_failed")
        }
        guard let ptr = replies.ptr, replies.len > 0 else { return Data() }
        return Data(bytes: ptr, count: replies.len)
    }

    func pollTitle() -> String? {
        guard handle != 0 else { return nil }
        var changed = false
        var bytes = PebrelTermBytes(ptr: nil, len: 0)
        var errPtr: UnsafePointer<CChar>?
        guard pebrel_term_title(handle, &changed, &bytes, &errPtr) else { return nil }
        defer { pebrel_term_free_bytes(&bytes) }
        guard changed else { return nil }
        guard let ptr = bytes.ptr, bytes.len > 0 else { return "" }
        return String(decoding: Data(bytes: ptr, count: bytes.len), as: UTF8.self)
    }

    func synchronizedOutput() -> Bool {
        guard handle != 0 else { return false }
        var enabled = false
        var errPtr: UnsafePointer<CChar>?
        guard pebrel_term_synchronized_output(handle, &enabled, &errPtr) else { return false }
        return enabled
    }

    func endSynchronizedOutput() {
        guard handle != 0 else { return }
        var errPtr: UnsafePointer<CChar>?
        _ = pebrel_term_end_synchronized_output(handle, &errPtr)
    }

    func resize(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) throws {
        guard handle != 0 else { return }
        let clampedCols = min(max(columns, 2), 400)
        let clampedRows = min(max(rows, 2), 200)
        let cw = min(max(cellWidth, 1), 256)
        let ch = min(max(cellHeight, 1), 256)
        var errPtr: UnsafePointer<CChar>?
        guard pebrel_term_resize(handle, Int32(clampedCols), Int32(clampedRows), Int32(cw), Int32(ch), &errPtr) else {
            throw GhosttyError.engine(errPtr.map { String(cString: $0) } ?? "terminal_engine_failed")
        }
        currentCols = clampedCols
        currentRows = clampedRows
        rowCache = []
    }

    func applyColors(_ values19: [UInt32]) {
        guard handle != 0, values19.count == 19 else { return }
        var errPtr: UnsafePointer<CChar>?
        _ = values19.withUnsafeBufferPointer { buf in
            pebrel_term_colors(handle, buf.baseAddress, &errPtr)
        }
    }

    func scroll(delta: Int) {
        guard handle != 0 else { return }
        pebrel_term_scroll(handle, Int32(clamping: delta))
    }

    func scrollToBottom() {
        guard handle != 0 else { return }
        pebrel_term_scroll(handle, Int32.max)
    }

    func scrollTo(offset: Int) {
        guard handle != 0 else { return }
        pebrel_term_scroll_to(handle, Int32(max(0, offset)))
    }

    func applicationScrollMode() -> Int {
        guard handle != 0 else { return 0 }
        var errPtr: UnsafePointer<CChar>?
        return Int(pebrel_term_application_scroll_mode(handle, &errPtr))
    }

    func wheel(lines: Int, column: Int, row: Int, applicationOnly: Bool) -> Data {
        guard handle != 0 else { return Data() }
        var bytes = PebrelTermBytes(ptr: nil, len: 0)
        var errPtr: UnsafePointer<CChar>?
        guard pebrel_term_wheel(
            handle,
            Int32(clamping: lines),
            Int32(column),
            Int32(row),
            applicationOnly,
            &bytes,
            &errPtr
        ) else {
            return Data()
        }
        defer { pebrel_term_free_bytes(&bytes) }
        guard let ptr = bytes.ptr, bytes.len > 0 else { return Data() }
        return Data(bytes: ptr, count: bytes.len)
    }

    func encodeKey(
        code: Int32,
        modifiers: Int32,
        action: Int32 = 1,
        text: String = "",
        unshifted: UInt32 = 0
    ) -> Data {
        guard handle != 0 else { return Data() }
        var bytes = PebrelTermBytes(ptr: nil, len: 0)
        var errPtr: UnsafePointer<CChar>?
        let utf8 = Array(text.utf8)
        let ok: Bool = utf8.withUnsafeBufferPointer { buf in
            pebrel_term_key(
                handle,
                code,
                modifiers,
                action,
                buf.baseAddress,
                utf8.count,
                unshifted,
                &bytes,
                &errPtr
            )
        }
        defer { pebrel_term_free_bytes(&bytes) }
        guard ok, let ptr = bytes.ptr, bytes.len > 0 else { return Data() }
        return Data(bytes: ptr, count: bytes.len)
    }

    func bracketedPaste() -> Bool {
        guard handle != 0 else { return false }
        return pebrel_term_bracketed_paste(handle)
    }

    func render() throws -> TerminalFrame {
        guard handle != 0 else {
            throw GhosttyError.engine("terminal_closed")
        }
        var snapshot = PebrelRenderSnapshot()
        var errPtr: UnsafePointer<CChar>?
        guard pebrel_term_render(handle, &snapshot, &errPtr) else {
            throw GhosttyError.engine(errPtr.map { String(cString: $0) } ?? "terminal_engine_failed")
        }
        defer { pebrel_term_free_snapshot(&snapshot) }

        let cols = Int(snapshot.meta.columns)
        let rowCount = Int(snapshot.meta.rows)
        if rowCache.count != rowCount {
            let emptyCells = [Int32](repeating: 0, count: cols * 6)
            rowCache = Array(repeating: TerminalRow(utf16: [], cells: emptyCells), count: rowCount)
        }

        if let dirtyPtr = snapshot.dirty_rows {
            for i in 0..<snapshot.dirty_row_count {
                let d = dirtyPtr[i]
                let idx = Int(d.row_index)
                guard idx >= 0, idx < rowCount else { continue }
                let utf16: [UInt16] = if let p = d.utf16_ptr, d.utf16_len > 0 {
                    Array(UnsafeBufferPointer(start: p, count: d.utf16_len))
                } else {
                    []
                }
                let cells: [Int32] = if let p = d.cells_ptr, d.cells_len > 0 {
                    Array(UnsafeBufferPointer(start: p, count: d.cells_len))
                } else {
                    [Int32](repeating: 0, count: cols * 6)
                }
                rowCache[idx] = TerminalRow(utf16: utf16, cells: cells)
            }
        }

        return TerminalFrame(
            columns: cols,
            rows: rowCache,
            cursorX: Int(snapshot.meta.cursor_x),
            cursorY: Int(snapshot.meta.cursor_y),
            cursorVisible: snapshot.meta.cursor_visible != 0,
            background: snapshot.meta.background,
            cursorColor: snapshot.meta.cursor_color,
            cursorStyle: Int(snapshot.meta.cursor_style),
            scrollTotal: Int(snapshot.meta.scroll_total),
            scrollOffset: Int(snapshot.meta.scroll_offset),
            alternateScreen: snapshot.meta.alternate_screen != 0,
            desktopForeground: nil,
            desktopError: nil,
            wrapped: nil,
            history: nil,
            sourceOffsets: nil
        )
    }

    func destroy() {
        if handle != 0 {
            pebrel_term_destroy(handle)
            handle = 0
            rowCache = []
        }
    }

    deinit {
        destroy()
    }
}
