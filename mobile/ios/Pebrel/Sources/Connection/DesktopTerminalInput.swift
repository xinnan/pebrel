import Foundation
import PebrelGhostty

/// Ordered non-replaying input channel targeting a specific Desktop pane.
final class DesktopTerminalInput {
    private let client: DesktopRuntimeClient
    private let windowId: Int64
    private let paneId: Int64
    private let onAccepted: () -> Void
    private let onRejected: (String, Bool) -> Void
    private var closed = false
    private let lock = NSLock()

    init(
        client: DesktopRuntimeClient,
        windowId: Int64,
        paneId: Int64,
        onAccepted: @escaping () -> Void,
        onRejected: @escaping (String, Bool) -> Void
    ) {
        self.client = client
        self.windowId = windowId
        self.paneId = paneId
        self.onAccepted = onAccepted
        self.onRejected = onRejected
    }

    func submit(_ text: String) async -> Bool {
        guard let cmds = encodeText(text, appendEnter: true) else { return false }
        return await dispatch(cmds)
    }

    func sendText(_ text: String) async -> Bool {
        guard let cmds = encodeText(text, appendEnter: false) else { return false }
        return await dispatch(cmds)
    }

    func paste(_ text: String) async -> Bool {
        guard text.utf8.count <= 8192,
              !CryptoHelpers.containsControlChar(text) else {
            return false
        }
        return await dispatch([("pane.prompt", [
            "window_id": windowId,
            "pane_id": paneId,
            "text": text,
            "submit": false,
        ])])
    }

    func sendShortcut(_ shortcut: TerminalShortcut) async -> Bool {
        guard (shortcut.modifiers & TerminalShortcut.modMeta) == 0 else { return false }
        guard let keyName = shortcut.desktopKeyName else {
            if !shortcut.text.isEmpty && shortcut.modifiers == 0 {
                return await sendText(shortcut.text)
            }
            return false
        }
        let isLetter = keyName.count == 1 && keyName >= "a" && keyName <= "z"
        let hasCtrl = (shortcut.modifiers & TerminalShortcut.modCtrl) != 0
        let hasAlt = (shortcut.modifiers & TerminalShortcut.modAlt) != 0
        let hasShift = (shortcut.modifiers & TerminalShortcut.modShift) != 0
        if isLetter && !hasCtrl && !hasAlt {
            return await sendText(hasShift ? keyName.uppercased() : keyName)
        }
        return await dispatch([("pane.send_key", [
            "window_id": windowId,
            "pane_id": paneId,
            "key": keyName,
            "modifiers": [
                "shift": hasShift,
                "control": hasCtrl,
                "alt": hasAlt,
            ],
        ])])
    }

    func sendKeyCode(code: Int32, modifiers: Int32, text: String) async -> Bool {
        guard (modifiers & TerminalShortcut.modMeta) == 0 else { return false }
        let hasShift = (modifiers & TerminalShortcut.modShift) != 0
        let hasCtrl = (modifiers & TerminalShortcut.modCtrl) != 0
        let hasAlt = (modifiers & TerminalShortcut.modAlt) != 0

        if let name = desktopKeyName(for: code) {
            let isLetter = name.count == 1 && name >= "a" && name <= "z"
            if isLetter && !hasCtrl && !hasAlt {
                return await sendText(text.isEmpty ? (hasShift ? name.uppercased() : name) : text)
            }
            return await dispatch([("pane.send_key", [
                "window_id": windowId,
                "pane_id": paneId,
                "key": name,
                "modifiers": [
                    "shift": hasShift,
                    "control": hasCtrl,
                    "alt": hasAlt,
                ],
            ])])
        }
        if !text.isEmpty && !hasCtrl && !hasAlt {
            return await sendText(text)
        }
        return false
    }

    func scroll(lines: Int, column: Int, row: Int) async {
        guard client.capabilities.terminalScroll, lines != 0 else { return }
        let clampedLines = lines.clamped(to: -32...32)
        let clampedCol = column.clamped(to: 0...399)
        let clampedRow = row.clamped(to: 0...199)
        _ = await dispatch([("pane.scroll", [
            "window_id": windowId,
            "pane_id": paneId,
            "lines": clampedLines,
            "column": clampedCol,
            "row": clampedRow,
        ])])
    }

    private func encodeText(_ text: String, appendEnter: Bool) -> [(String, [String: Any])]? {
        guard text.utf8.count <= 8192 else { return nil }
        for scalar in text.unicodeScalars {
            if CryptoHelpers.isControlScalar(scalar) && scalar != "\r" && scalar != "\n" && scalar != "\t" {
                return nil
            }
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var cmds: [(String, [String: Any])] = []
        var segment = ""

        func flushSegment() {
            if !segment.isEmpty {
                cmds.append(("pane.prompt", [
                    "window_id": windowId,
                    "pane_id": paneId,
                    "text": segment,
                    "submit": false,
                ]))
                segment = ""
            }
        }

        for ch in normalized {
            if ch == "\n" || ch == "\r" {
                flushSegment()
                cmds.append(("pane.send_key", [
                    "window_id": windowId,
                    "pane_id": paneId,
                    "key": "enter",
                    "modifiers": ["shift": false, "control": false, "alt": false],
                ]))
            } else if ch == "\t" {
                flushSegment()
                cmds.append(("pane.send_key", [
                    "window_id": windowId,
                    "pane_id": paneId,
                    "key": "tab",
                    "modifiers": ["shift": false, "control": false, "alt": false],
                ]))
            } else {
                segment.append(ch)
            }
        }
        flushSegment()
        if appendEnter {
            cmds.append(("pane.send_key", [
                "window_id": windowId,
                "pane_id": paneId,
                "key": "enter",
                "modifiers": ["shift": false, "control": false, "alt": false],
            ]))
        }
        guard cmds.count <= 128 else { return nil }
        return cmds
    }

    private func dispatch(_ cmds: [(String, [String: Any])]) async -> Bool {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        if isClosed { return false }

        do {
            for (method, params) in cmds {
                _ = try await client.request(method: method, params: params)
            }
            onAccepted()
            return true
        } catch let rpc as DesktopRpcFailure {
            onRejected(rpc.code, false)
            return false
        } catch {
            lock.lock()
            closed = true
            lock.unlock()
            onRejected("delivery_unknown", true)
            return false
        }
    }

    private func desktopKeyName(for code: Int32) -> String? {
        let aVal = Int32(PEBREL_KEY_A.rawValue)
        let zVal = Int32(PEBREL_KEY_Z.rawValue)
        if code >= aVal && code <= zVal {
            return String(UnicodeScalar(UInt32(97 + (code - aVal)))!)
        }
        let f1Val = Int32(PEBREL_KEY_F1.rawValue)
        let f12Val = Int32(PEBREL_KEY_F12.rawValue)
        if code >= f1Val && code <= f12Val {
            return "f\(code - f1Val + 1)"
        }
        switch UInt32(code) {
        case PEBREL_KEY_ENTER.rawValue: return "enter"
        case PEBREL_KEY_ESCAPE.rawValue: return "escape"
        case PEBREL_KEY_TAB.rawValue: return "tab"
        case PEBREL_KEY_BACKSPACE.rawValue: return "backspace"
        case PEBREL_KEY_DELETE.rawValue: return "delete"
        case PEBREL_KEY_ARROW_LEFT.rawValue: return "left"
        case PEBREL_KEY_ARROW_RIGHT.rawValue: return "right"
        case PEBREL_KEY_ARROW_UP.rawValue: return "up"
        case PEBREL_KEY_ARROW_DOWN.rawValue: return "down"
        case PEBREL_KEY_HOME.rawValue: return "home"
        case PEBREL_KEY_END.rawValue: return "end"
        case PEBREL_KEY_INSERT.rawValue: return "insert"
        case PEBREL_KEY_PAGE_UP.rawValue: return "page_up"
        case PEBREL_KEY_PAGE_DOWN.rawValue: return "page_down"
        default: return nil
        }
    }
}
