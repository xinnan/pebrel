import SwiftUI
import UIKit

struct HostIconEntry: Decodable, Identifiable, Equatable {
    let id: String
    let glyph: String
    let zh: String
    let en: String

    var localizedLabel: String {
        L10n.isChineseLocale ? zh : en
    }
}

final class HostIconCatalog {
    static let shared = HostIconCatalog()

    let entries: [HostIconEntry]
    private let byId: [String: HostIconEntry]

    private init() {
        if let url = Bundle.main.url(forResource: "host-icons", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([HostIconEntry].self, from: data),
           !decoded.isEmpty {
            self.entries = decoded
            self.byId = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        } else {
            let fallback = [HostIconEntry(id: "term", glyph: "\u{f120}", zh: "终端", en: "Terminal")]
            self.entries = fallback
            self.byId = ["term": fallback[0]]
        }
    }

    func entry(for id: String) -> HostIconEntry {
        byId[id] ?? byId["term"] ?? entries[0]
    }

    static func desktopOsIcon(_ raw: String?) -> String {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return "term"
        }
        switch value {
        case "windows", "win32": return "windows"
        case "macos", "darwin": return "macos"
        case "linux", "ubuntu", "debian", "centos", "rhel", "fedora", "rocky",
             "alpine", "arch", "suse", "nixos", "kali", "freebsd":
            return value
        default:
            return "term"
        }
    }
}

/// Renders an OS/host Nerd Font glyph using the bundled Maple Mono NF CN font.
struct HostGlyphView: View {
    @Environment(\.pebrelPalette) private var palette

    let iconId: String
    var size: CGFloat = 20
    var tint: Color?

    var body: some View {
        let glyph = HostIconCatalog.shared.entry(for: iconId).glyph
        Text(glyph)
            .font(TerminalFontRegistry.swiftUIFont(family: "maple", size: size))
            .foregroundStyle(tint ?? palette.primary)
            .frame(width: size * 1.25, height: size * 1.25)
    }
}

enum TerminalFontRegistry {
    static let mapleFontName = "MapleMono-NF-CN-Regular"
    static let jetbrainsFontName = "JetBrainsMono-Regular"

    static func uiFont(family: String, size: CGFloat) -> UIFont {
        let clamped = max(8, min(32, size))
        switch family {
        case "jetbrains":
            if let f = UIFont(name: jetbrainsFontName, size: clamped) { return f }
        case "system":
            return UIFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
        default:
            if let f = UIFont(name: mapleFontName, size: clamped) { return f }
            if let f = UIFont(name: "Maple Mono NF CN", size: clamped) { return f }
        }
        return UIFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
    }

    static func swiftUIFont(family: String, size: CGFloat) -> Font {
        Font(uiFont(family: family, size: size))
    }
}

/// Maps file names, extensions, and directory types to SF Symbols & semantic tints.
enum FileSymbol {
    static func systemName(name: String, isDirectory: Bool, isExpanded: Bool = false) -> String {
        if isDirectory {
            return isExpanded ? "folder.fill" : "folder"
        }
        let lower = name.lowercased()
        if lower.hasPrefix(".git") { return "arrow.triangle.branch" }
        if lower == "dockerfile" || lower == "containerfile" { return "shippingbox" }
        if lower == "makefile" || lower == "justfile" || lower == "cmakelists.txt" { return "wrench.and.screwdriver" }
        if lower.hasPrefix("readme") { return "book.pages" }

        let ext = (lower as NSString).pathExtension
        switch ext {
        case "swift", "rs", "py", "kt", "kts", "java", "go", "c", "h", "cc", "cpp", "hpp", "cs",
             "js", "jsx", "ts", "tsx", "vue", "svelte", "php", "rb", "lua", "luau", "dart":
            return "chevron.left.forwardslash.chevron.right"
        case "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd":
            return "terminal"
        case "md", "markdown", "txt", "rst", "adoc":
            return "doc.plaintext"
        case "json", "toml", "yaml", "yml", "xml", "plist", "ini", "env", "conf", "cfg":
            return "curlybraces"
        case "html", "htm", "css", "scss", "less", "svg":
            return "globe"
        case "sql", "sqlite", "db", "csv", "tsv":
            return "tablecells"
        case "png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "ico":
            return "photo"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "gz", "tgz", "xz", "bz2", "7z", "rar", "ipa", "apk":
            return "doc.zipper"
        case "mp3", "wav", "m4a", "flac", "ogg":
            return "waveform"
        case "mp4", "mov", "mkv", "webm", "avi":
            return "film"
        case "pem", "key", "pub", "crt", "cer", "p12":
            return "key"
        case "lock":
            return "lock.doc"
        case "log":
            return "text.alignleft"
        default:
            return "doc"
        }
    }

    static func tabSystemName(kind: String) -> String {
        switch kind {
        case "document": return "doc.richtext"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "image": return "photo"
        default: return "terminal"
        }
    }
}
