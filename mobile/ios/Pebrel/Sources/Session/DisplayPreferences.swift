import Combine
import Foundation

enum TerminalPreferenceValues {
    static let mapleFont = "maple"
    static let jetbrainsFont = "jetbrains"
    static let systemFont = "system"
    static let barCursor = "bar"
    static let underlineCursor = "underline"
    static let blockCursor = "block"
    static let minFontSize = 8
    static let maxFontSize = 32
    static let defaultTheme = "MintLight"
}

struct TerminalPreferences: Equatable {
    var fontFamily: String = TerminalPreferenceValues.mapleFont
    var fontSize: Int = 16
    var cursorStyle: String = TerminalPreferenceValues.blockCursor
    var cursorBlink: Bool = true
    var pinchZoom: Bool = true
    var suggestions: Bool = true
    var directInput: Bool = true
    var scrollbackLines: Int = 1000
    var desktopZoom: Double = 1.0
    var desktopWrapLines: Bool = false

    func normalized(maxScrollback: Int = 5000) -> TerminalPreferences {
        var copy = self
        if copy.fontFamily != TerminalPreferenceValues.jetbrainsFont &&
           copy.fontFamily != TerminalPreferenceValues.systemFont {
            copy.fontFamily = TerminalPreferenceValues.mapleFont
        }
        copy.fontSize = copy.fontSize.clamped(to: TerminalPreferenceValues.minFontSize...TerminalPreferenceValues.maxFontSize)
        copy.scrollbackLines = copy.scrollbackLines.clamped(to: 500...maxScrollback)
        if !copy.desktopZoom.isFinite {
            copy.desktopZoom = 1.0
        } else {
            copy.desktopZoom = copy.desktopZoom.clamped(to: 0.2...5.0)
        }
        if copy.cursorStyle != TerminalPreferenceValues.barCursor &&
           copy.cursorStyle != TerminalPreferenceValues.underlineCursor {
            copy.cursorStyle = TerminalPreferenceValues.blockCursor
        }
        return copy
    }
}

@MainActor
final class DisplayPreferences: ObservableObject {
    let maxScrollbackLines: Int

    @Published private(set) var preferences: TerminalPreferences
    @Published private(set) var themeName: String
    @Published private(set) var connectionOnboardingCompleted: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let physicalRAM = ProcessInfo.processInfo.physicalMemory
        self.maxScrollbackLines = physicalRAM < 2_500_000_000 ? 1000 : 5000

        let storedTheme = defaults.string(forKey: "pebrel_theme") ?? TerminalPreferenceValues.defaultTheme
        self.themeName = storedTheme
        self.connectionOnboardingCompleted = defaults.bool(forKey: "pebrel_connection_onboarding_completed")

        let loaded = TerminalPreferences(
            fontFamily: defaults.string(forKey: "pebrel_font_family") ?? TerminalPreferenceValues.mapleFont,
            fontSize: defaults.object(forKey: "pebrel_font_size") as? Int ?? 16,
            cursorStyle: defaults.string(forKey: "pebrel_cursor_style") ?? TerminalPreferenceValues.blockCursor,
            cursorBlink: defaults.object(forKey: "pebrel_cursor_blink") as? Bool ?? true,
            pinchZoom: defaults.object(forKey: "pebrel_pinch_zoom") as? Bool ?? true,
            suggestions: defaults.object(forKey: "pebrel_suggestions") as? Bool ?? true,
            directInput: defaults.object(forKey: "pebrel_direct_input") as? Bool ?? true,
            scrollbackLines: defaults.object(forKey: "pebrel_scrollback_lines") as? Int ?? 1000,
            desktopZoom: defaults.object(forKey: "pebrel_desktop_zoom") as? Double ?? 1.0,
            desktopWrapLines: defaults.bool(forKey: "pebrel_desktop_wrap_lines")
        ).normalized(maxScrollback: maxScrollbackLines)
        self.preferences = loaded
    }

    func update(_ transform: (inout TerminalPreferences) -> Void) {
        var next = preferences
        transform(&next)
        next = next.normalized(maxScrollback: maxScrollbackLines)
        preferences = next
        defaults.set(next.fontFamily, forKey: "pebrel_font_family")
        defaults.set(next.fontSize, forKey: "pebrel_font_size")
        defaults.set(next.cursorStyle, forKey: "pebrel_cursor_style")
        defaults.set(next.cursorBlink, forKey: "pebrel_cursor_blink")
        defaults.set(next.pinchZoom, forKey: "pebrel_pinch_zoom")
        defaults.set(next.suggestions, forKey: "pebrel_suggestions")
        defaults.set(next.directInput, forKey: "pebrel_direct_input")
        defaults.set(next.scrollbackLines, forKey: "pebrel_scrollback_lines")
        defaults.set(next.desktopZoom, forKey: "pebrel_desktop_zoom")
        defaults.set(next.desktopWrapLines, forKey: "pebrel_desktop_wrap_lines")
    }

    func setTheme(_ name: String) {
        themeName = name
        defaults.set(name, forKey: "pebrel_theme")
    }

    func completeConnectionOnboarding() {
        guard !connectionOnboardingCompleted else { return }
        connectionOnboardingCompleted = true
        defaults.set(true, forKey: "pebrel_connection_onboarding_completed")
    }
}
