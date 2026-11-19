import Foundation

/// Centralized lookup into the generated en / zh-Hans Localizable.strings tables.
enum L10n {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: .main, comment: "")
        return String(format: format, locale: Locale.current, arguments: args)
    }

    static func plural(_ key: String, count: Int, _ args: CVarArg...) -> String {
        let suffix = count == 1 ? "_one" : "_other"
        let specificKey = key + suffix
        let resolved = NSLocalizedString(specificKey, bundle: .main, value: "\u{0000}", comment: "")
        let format = resolved == "\u{0000}" ? NSLocalizedString(key + "_other", bundle: .main, comment: "") : resolved
        return String(format: format, locale: Locale.current, arguments: args)
    }

    static var isChineseLocale: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
    }
}
