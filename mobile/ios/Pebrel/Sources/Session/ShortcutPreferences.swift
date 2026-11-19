import Combine
import Foundation
import PebrelGhostty

/// Terminal keyboard shortcut matching Android's `TerminalShortcut` semantics.
struct TerminalShortcut: Equatable, Hashable, Identifiable {
    static let modShift: Int32 = 1
    static let modCtrl: Int32 = 2
    static let modAlt: Int32 = 4
    static let modMeta: Int32 = 8

    let label: String
    let code: Int32
    let modifiers: Int32
    let text: String
    let unshifted: UInt32
    /// Canonical key name for Desktop Runtime `pane.send_key` (nil if unsupported by desktop).
    let desktopKeyName: String?

    var id: String { "\(modifiers):\(code)" }

    static let defaults: [TerminalShortcut] = [
        "Ctrl+C", "Esc", "Tab", "Shift+Tab", "←", "→", "↑", "↓"
    ].compactMap(parse)

    static let tmuxPrefix: TerminalShortcut? = parse("Ctrl+B")

    static func parse(_ raw: String) -> TerminalShortcut? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 48 else { return nil }

        let parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        guard !parts.isEmpty, parts.count <= 5, parts.allSatisfy({ !$0.isEmpty }) else { return nil }

        var mods: Int32 = 0
        var modLabels: [String] = []
        for token in parts.dropLast() {
            switch token.lowercased() {
            case "shift":
                if (mods & modShift) != 0 { return nil }
                mods |= modShift
            case "ctrl", "control":
                if (mods & modCtrl) != 0 { return nil }
                mods |= modCtrl
            case "alt", "opt", "option":
                if (mods & modAlt) != 0 { return nil }
                mods |= modAlt
            case "meta", "cmd", "command", "super":
                if (mods & modMeta) != 0 { return nil }
                mods |= modMeta
            default:
                return nil
            }
        }
        if (mods & modCtrl) != 0 { modLabels.append("Ctrl") }
        if (mods & modAlt) != 0 { modLabels.append("Alt") }
        if (mods & modShift) != 0 { modLabels.append("Shift") }
        if (mods & modMeta) != 0 { modLabels.append("Meta") }

        let keyToken = parts.last!
        guard let resolved = resolveKey(keyToken, shift: (mods & modShift) != 0) else {
            return nil
        }

        let display = (modLabels + [resolved.label]).joined(separator: "+")
        return TerminalShortcut(
            label: display,
            code: resolved.code,
            modifiers: mods,
            text: resolved.text,
            unshifted: resolved.unshifted,
            desktopKeyName: resolved.desktopName
        )
    }

    private struct KeySpec {
        let label: String
        let code: Int32
        let text: String
        let unshifted: UInt32
        let desktopName: String?
    }

    private static func resolveKey(_ token: String, shift: Bool) -> KeySpec? {
        let lower = token.lowercased()
        switch lower {
        case "esc", "escape":
            return KeySpec(label: "Esc", code: Int32(PEBREL_KEY_ESCAPE.rawValue), text: "", unshifted: 0, desktopName: "escape")
        case "tab":
            return KeySpec(label: "Tab", code: Int32(PEBREL_KEY_TAB.rawValue), text: "", unshifted: 0, desktopName: "tab")
        case "enter", "return", "ret":
            return KeySpec(label: "Enter", code: Int32(PEBREL_KEY_ENTER.rawValue), text: "", unshifted: 0, desktopName: "enter")
        case "space":
            return KeySpec(label: "Space", code: Int32(PEBREL_KEY_SPACE.rawValue), text: " ", unshifted: 32, desktopName: nil)
        case "bs", "backspace":
            return KeySpec(label: "Backspace", code: Int32(PEBREL_KEY_BACKSPACE.rawValue), text: "", unshifted: 0, desktopName: "backspace")
        case "del", "delete":
            return KeySpec(label: "Delete", code: Int32(PEBREL_KEY_DELETE.rawValue), text: "", unshifted: 0, desktopName: "delete")
        case "ins", "insert":
            return KeySpec(label: "Insert", code: Int32(PEBREL_KEY_INSERT.rawValue), text: "", unshifted: 0, desktopName: "insert")
        case "home":
            return KeySpec(label: "Home", code: Int32(PEBREL_KEY_HOME.rawValue), text: "", unshifted: 0, desktopName: "home")
        case "end":
            return KeySpec(label: "End", code: Int32(PEBREL_KEY_END.rawValue), text: "", unshifted: 0, desktopName: "end")
        case "pgup", "pageup", "page_up":
            return KeySpec(label: "PgUp", code: Int32(PEBREL_KEY_PAGE_UP.rawValue), text: "", unshifted: 0, desktopName: "page_up")
        case "pgdn", "pagedown", "page_down":
            return KeySpec(label: "PgDn", code: Int32(PEBREL_KEY_PAGE_DOWN.rawValue), text: "", unshifted: 0, desktopName: "page_down")
        case "up", "↑":
            return KeySpec(label: "↑", code: Int32(PEBREL_KEY_ARROW_UP.rawValue), text: "", unshifted: 0, desktopName: "up")
        case "down", "↓":
            return KeySpec(label: "↓", code: Int32(PEBREL_KEY_ARROW_DOWN.rawValue), text: "", unshifted: 0, desktopName: "down")
        case "left", "←":
            return KeySpec(label: "←", code: Int32(PEBREL_KEY_ARROW_LEFT.rawValue), text: "", unshifted: 0, desktopName: "left")
        case "right", "→":
            return KeySpec(label: "→", code: Int32(PEBREL_KEY_ARROW_RIGHT.rawValue), text: "", unshifted: 0, desktopName: "right")
        default:
            break
        }

        if lower.hasPrefix("f"), let num = Int(lower.dropFirst()), (1...12).contains(num) {
            let code = Int32(PEBREL_KEY_F1.rawValue) + Int32(num - 1)
            return KeySpec(label: "F\(num)", code: code, text: "", unshifted: 0, desktopName: "f\(num)")
        }

        if token.count == 1, let scalar = token.unicodeScalars.first {
            let v = scalar.value
            if (65...90).contains(v) || (97...122).contains(v) {
                let upper = v >= 97 ? v - 32 : v
                let lowerV = upper + 32
                let offset = Int32(upper - 65)
                let ch = String(UnicodeScalar(shift ? upper : lowerV)!)
                return KeySpec(
                    label: String(UnicodeScalar(upper)!),
                    code: Int32(PEBREL_KEY_A.rawValue) + offset,
                    text: ch,
                    unshifted: lowerV,
                    desktopName: String(UnicodeScalar(lowerV)!)
                )
            }
            if (48...57).contains(v) {
                let offset = Int32(v - 48)
                let shiftedDigits = [")", "!", "@", "#", "$", "%", "^", "&", "*", "("]
                let text = shift ? shiftedDigits[Int(offset)] : String(UnicodeScalar(v)!)
                return KeySpec(
                    label: String(UnicodeScalar(v)!),
                    code: Int32(PEBREL_KEY_DIGIT_0.rawValue) + offset,
                    text: text,
                    unshifted: v,
                    desktopName: nil
                )
            }
        }
        return nil
    }
}

@MainActor
final class ShortcutPreferences: ObservableObject {
    static let maxKeys = 24
    private let key = "pebrel_custom_shortcuts"

    @Published private(set) var customShortcuts: [TerminalShortcut] = []

    init(defaults: UserDefaults = .standard) {
        let saved = defaults.stringArray(forKey: key) ?? []
        self.customShortcuts = saved.prefix(Self.maxKeys).compactMap(TerminalShortcut.parse)
    }

    func saveLines(_ lines: [String], defaults: UserDefaults = .standard) -> Result<[TerminalShortcut], ShortcutValidationError> {
        var parsed: [TerminalShortcut] = []
        var seen = Set<String>()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let shortcut = TerminalShortcut.parse(trimmed) else {
                return .failure(.invalid(trimmed))
            }
            if seen.contains(shortcut.id) {
                return .failure(.duplicate(shortcut.label))
            }
            if parsed.count >= Self.maxKeys {
                return .failure(.tooMany)
            }
            seen.insert(shortcut.id)
            parsed.append(shortcut)
        }
        customShortcuts = parsed
        defaults.set(parsed.map(\.label), forKey: key)
        return .success(parsed)
    }

    func combinedShortcuts(extra: [TerminalShortcut] = []) -> [TerminalShortcut] {
        var result: [TerminalShortcut] = []
        var seen = Set<String>()
        for item in extra + customShortcuts + TerminalShortcut.defaults {
            if seen.insert(item.id).inserted {
                result.append(item)
            }
        }
        return result
    }
}

enum ShortcutValidationError: Error, Equatable {
    case invalid(String)
    case duplicate(String)
    case tooMany
}
