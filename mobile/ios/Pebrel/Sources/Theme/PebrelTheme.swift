import SwiftUI
import UIKit

struct PebrelThemeDefinition: Decodable, Identifiable, Equatable {
    let shell: [Int]
    let background: [Int]
    let foreground: [Int]
    let muted: [Int]
    let accent: [Int]
    let selected: [Int]
    let line: [Int]
    let red: [Int]
    let green: [Int]
    let yellow: [Int]
    let blue: [Int]
    let purple: [Int]
    let cyan: [Int]
    let frame: [Int]
    let ansi: [[Int]]

    var id: String { "" }
}

struct ReaderColors: Equatable {
    let backgroundHex: String
    let foregroundHex: String
    let mutedHex: String
    let surfaceHex: String
    let codeSurfaceHex: String
    let borderHex: String
    let accentHex: String
}

struct PebrelPalette: Equatable {
    let name: String
    let isDark: Bool
    let background: Color
    let surface: Color
    let surfaceContainer: Color
    let surfaceContainerHigh: Color
    let surfaceVariant: Color
    let foreground: Color
    let muted: Color
    let primary: Color
    let onPrimary: Color
    let tertiary: Color
    let outline: Color
    let outlineVariant: Color
    let error: Color
    let yellow: Color
    let blue: Color
    let purple: Color
    let cyan: Color
    let bgRGB: (Double, Double, Double)
    let fgRGB: (Double, Double, Double)
    let mutedRGB: (Double, Double, Double)
    let accentRGB: (Double, Double, Double)
    let shellRGB: (Double, Double, Double)
    let selectedRGB: (Double, Double, Double)
    let lineRGB: (Double, Double, Double)
    let terminalColors: [UInt32]

    var readerColors: ReaderColors {
        ReaderColors(
            backgroundHex: Self.hex(bgRGB),
            foregroundHex: Self.hex(fgRGB),
            mutedHex: Self.hex(mutedRGB),
            surfaceHex: Self.hex(shellRGB),
            codeSurfaceHex: Self.hex(selectedRGB),
            borderHex: Self.hex(lineRGB),
            accentHex: Self.hex(accentRGB)
        )
    }

    static func == (lhs: PebrelPalette, rhs: PebrelPalette) -> Bool {
        lhs.name == rhs.name &&
        lhs.isDark == rhs.isDark &&
        lhs.terminalColors == rhs.terminalColors
    }

    static func hex(_ rgb: (Double, Double, Double)) -> String {
        let r = Int((rgb.0 * 255).rounded()).clamped(to: 0...255)
        let g = Int((rgb.1 * 255).rounded()).clamped(to: 0...255)
        let b = Int((rgb.2 * 255).rounded()).clamped(to: 0...255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    static func colorFromARGB(_ argb: UInt32) -> Color {
        let a = Double((argb >> 24) & 0xFF) / 255.0
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    static func uiColorFromARGB(_ argb: UInt32) -> UIColor {
        let a = CGFloat((argb >> 24) & 0xFF) / 255.0
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    static func rgbTuple(_ triple: [Int]) -> (Double, Double, Double) {
        guard triple.count >= 3 else { return (0, 0, 0) }
        return (Double(triple[0]) / 255.0, Double(triple[1]) / 255.0, Double(triple[2]) / 255.0)
    }

    static func argbFromTriple(_ triple: [Int]) -> UInt32 {
        guard triple.count >= 3 else { return 0xFF000000 }
        return 0xFF000000 |
            (UInt32(triple[0] & 0xFF) << 16) |
            (UInt32(triple[1] & 0xFF) << 8) |
            UInt32(triple[2] & 0xFF)
    }

    static func rgbFromARGB(_ argb: UInt32) -> (Double, Double, Double) {
        (
            Double((argb >> 16) & 0xFF) / 255.0,
            Double((argb >> 8) & 0xFF) / 255.0,
            Double(argb & 0xFF) / 255.0
        )
    }

    static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }

    static func contrastRatio(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func lerp(_ a: (Double, Double, Double), _ b: (Double, Double, Double), t: Double) -> (Double, Double, Double) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    static func color(_ rgb: (Double, Double, Double), opacity: Double = 1.0) -> Color {
        Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2, opacity: opacity)
    }

    /// Creates a temporary theme overlay adopting a remote Desktop terminal frame's palette.
    func adoptingDesktopFrame(_ frame: TerminalFrame?) -> PebrelPalette {
        guard let frame, let fgARGB = frame.desktopForeground, let errARGB = frame.desktopError else {
            return self
        }
        let bg = Self.rgbFromARGB(frame.background)
        let fg = Self.rgbFromARGB(fgARGB)
        let accent = Self.rgbFromARGB(frame.cursorColor)
        let err = Self.rgbFromARGB(errARGB)
        let surface = Self.lerp(bg, fg, t: 0.06)
        let muted = Self.lerp(bg, fg, t: 0.72)
        let outline = Self.lerp(bg, fg, t: 0.40)
        let line = Self.lerp(bg, fg, t: 0.20)
        let dark = Self.luminance(bg) < 0.35
        return PebrelPalette(
            name: "\(name):desktop",
            isDark: dark,
            background: Self.color(bg),
            surface: Self.color(surface),
            surfaceContainer: Self.color(surface),
            surfaceContainerHigh: Self.color(surface),
            surfaceVariant: Self.color(surface),
            foreground: Self.color(fg),
            muted: Self.color(muted),
            primary: Self.color(accent),
            onPrimary: Self.color(bg),
            tertiary: tertiary,
            outline: Self.color(outline),
            outlineVariant: Self.color(line),
            error: Self.color(err),
            yellow: yellow,
            blue: blue,
            purple: purple,
            cyan: cyan,
            bgRGB: bg,
            fgRGB: fg,
            mutedRGB: muted,
            accentRGB: accent,
            shellRGB: surface,
            selectedRGB: surface,
            lineRGB: line,
            terminalColors: terminalColors
        )
    }
}

final class PebrelThemeCatalog {
    static let shared = PebrelThemeCatalog()

    static let lightThemeOrder = [
        "BreezeLight", "MintLight", "SilverLight", "NordLight", "Paper",
        "LimestoneLight", "LinenLight", "CatppuccinLatte", "GlassLight"
    ]
    static let darkThemeOrder = [
        "BreezeDark", "MintDark", "Nord", "CatppuccinMocha",
        "CatppuccinFrappe", "CatppuccinMacchiato", "GlassDark"
    ]

    let definitions: [String: PebrelThemeDefinition]

    private init() {
        if let url = Bundle.main.url(forResource: "themes", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: PebrelThemeDefinition].self, from: data),
           !decoded.isEmpty {
            self.definitions = decoded
        } else {
            self.definitions = [
                "MintLight": Self.fallbackMintLight,
                "Nord": Self.fallbackNord,
            ]
        }
    }

    func palette(named rawName: String, systemIsDark: Bool) -> PebrelPalette {
        let resolvedName: String
        if rawName == "system" {
            resolvedName = systemIsDark ? "Nord" : "MintLight"
        } else if definitions[rawName] != nil {
            resolvedName = rawName
        } else {
            resolvedName = systemIsDark ? "Nord" : "MintLight"
        }
        let def = definitions[resolvedName] ?? Self.fallbackMintLight
        return buildPalette(name: resolvedName, def: def)
    }

    func swatches(for name: String) -> [Color] {
        guard let def = definitions[name] else { return [] }
        return [def.background, def.foreground, def.red, def.green, def.blue]
            .map { PebrelPalette.color(PebrelPalette.rgbTuple($0)) }
    }

    private func buildPalette(name: String, def: PebrelThemeDefinition) -> PebrelPalette {
        let bg = PebrelPalette.rgbTuple(def.background)
        let fg = PebrelPalette.rgbTuple(def.foreground)
        let muted = PebrelPalette.rgbTuple(def.muted)
        let accent = PebrelPalette.rgbTuple(def.accent)
        let shell = PebrelPalette.rgbTuple(def.shell)
        let selected = PebrelPalette.rgbTuple(def.selected)
        let line = PebrelPalette.rgbTuple(def.line)
        let frame = PebrelPalette.rgbTuple(def.frame)
        let red = PebrelPalette.rgbTuple(def.red)
        let green = PebrelPalette.rgbTuple(def.green)
        let yellow = PebrelPalette.rgbTuple(def.yellow)
        let blue = PebrelPalette.rgbTuple(def.blue)
        let purple = PebrelPalette.rgbTuple(def.purple)
        let cyan = PebrelPalette.rgbTuple(def.cyan)
        let isDark = PebrelPalette.luminance(bg) < 0.35

        var termColors: [UInt32] = [
            PebrelPalette.argbFromTriple(def.foreground),
            PebrelPalette.argbFromTriple(def.background),
            PebrelPalette.argbFromTriple(def.accent),
        ]
        for index in 0..<16 {
            let entry = index < def.ansi.count ? def.ansi[index] : def.foreground
            termColors.append(PebrelPalette.argbFromTriple(entry))
        }

        return PebrelPalette(
            name: name,
            isDark: isDark,
            background: PebrelPalette.color(bg),
            surface: PebrelPalette.color(shell),
            surfaceContainer: PebrelPalette.color(bg),
            surfaceContainerHigh: PebrelPalette.color(shell),
            surfaceVariant: PebrelPalette.color(selected),
            foreground: PebrelPalette.color(fg),
            muted: PebrelPalette.color(muted),
            primary: PebrelPalette.color(accent),
            onPrimary: PebrelPalette.color(bg),
            tertiary: PebrelPalette.color(green),
            outline: PebrelPalette.color(frame),
            outlineVariant: PebrelPalette.color(line),
            error: PebrelPalette.color(red),
            yellow: PebrelPalette.color(yellow),
            blue: PebrelPalette.color(blue),
            purple: PebrelPalette.color(purple),
            cyan: PebrelPalette.color(cyan),
            bgRGB: bg,
            fgRGB: fg,
            mutedRGB: muted,
            accentRGB: accent,
            shellRGB: shell,
            selectedRGB: selected,
            lineRGB: line,
            terminalColors: termColors
        )
    }

    private static let fallbackMintLight = PebrelThemeDefinition(
        shell: [244, 249, 246], background: [250, 253, 251], foreground: [24, 42, 34],
        muted: [92, 114, 103], accent: [20, 128, 92], selected: [224, 240, 232],
        line: [215, 230, 222], red: [198, 56, 62], green: [26, 132, 82],
        yellow: [168, 118, 22], blue: [36, 108, 186], purple: [128, 72, 174],
        cyan: [24, 132, 144], frame: [184, 206, 194],
        ansi: Array(repeating: [24, 42, 34], count: 16)
    )

    private static let fallbackNord = PebrelThemeDefinition(
        shell: [46, 52, 64], background: [46, 52, 64], foreground: [216, 222, 233],
        muted: [144, 156, 174], accent: [136, 192, 208], selected: [67, 76, 94],
        line: [59, 66, 82], red: [191, 97, 106], green: [163, 190, 140],
        yellow: [235, 203, 139], blue: [129, 161, 193], purple: [180, 142, 173],
        cyan: [143, 188, 187], frame: [76, 86, 106],
        ansi: Array(repeating: [216, 222, 233], count: 16)
    )
}

private struct PebrelPaletteKey: EnvironmentKey {
    static let defaultValue: PebrelPalette = PebrelThemeCatalog.shared.palette(named: "MintLight", systemIsDark: false)
}

extension EnvironmentValues {
    var pebrelPalette: PebrelPalette {
        get { self[PebrelPaletteKey.self] }
        set { self[PebrelPaletteKey.self] = newValue }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
