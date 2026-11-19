import SwiftUI
import UIKit

struct SettingsScreen: View {
    @Environment(\.pebrelPalette) private var palette
    @ObservedObject var repository: SessionRepository
    let initialSubpage: String
    let onBack: () -> Void
    let onOpenComputers: () -> Void

    @State private var subpage = ""
    @State private var showShortcutEditor = false
    @State private var noticesText = ""

    var body: some View {
        VStack(spacing: 0) {
            PebrelPageHeader(headerTitle, onBack: {
                if subpage.isEmpty { onBack() } else { subpage = "" }
            })

            Group {
                switch subpage {
                case "theme": themeSubpage
                case "font": fontSubpage
                case "cursor": cursorSubpage
                case "scrolling": scrollingSubpage
                case "input": inputSubpage
                case "notices": noticesSubpage
                case "about": aboutSubpage
                case "licenses": licensesSubpage
                default: rootMenu
                }
            }
        }
        .onAppear {
            if !initialSubpage.isEmpty { subpage = initialSubpage }
            if noticesText.isEmpty,
               let url = Bundle.main.resourceURL?.appendingPathComponent("licenses/THIRD-PARTY-NOTICES.md"),
               let txt = try? String(contentsOf: url, encoding: .utf8) {
                noticesText = txt
            }
        }
        .sheet(isPresented: $showShortcutEditor) {
            ShortcutEditorSheet(shortcuts: repository.shortcuts)
                .environment(\.pebrelPalette, palette)
        }
    }

    private var headerTitle: String {
        switch subpage {
        case "theme": return L10n.tr("theme_settings")
        case "font": return L10n.tr("terminal_font_and_size")
        case "cursor": return L10n.tr("terminal_cursor")
        case "scrolling": return L10n.tr("terminal_history")
        case "input": return L10n.tr("input_group")
        case "notices": return L10n.tr("notifications")
        case "about": return L10n.tr("about")
        case "licenses": return L10n.tr("ios_notices_title")
        default: return L10n.tr("settings")
        }
    }

    private var rootMenu: some View {
        List {
            Section(L10n.tr("raw_terminal")) {
                navRow(L10n.tr("theme_settings"), value: repository.display.themeName == "system" ? L10n.tr("follow_system") : repository.display.themeName) { subpage = "theme" }
                navRow(L10n.tr("terminal_font_and_size"), value: "\(repository.display.preferences.fontFamily) · \(repository.display.preferences.fontSize)pt") { subpage = "font" }
                navRow(L10n.tr("terminal_cursor"), value: repository.display.preferences.cursorStyle) { subpage = "cursor" }
                navRow(L10n.tr("terminal_history"), value: "\(repository.display.preferences.scrollbackLines)") { subpage = "scrolling" }
            }

            Section(L10n.tr("input_group")) {
                navRow(L10n.tr("input_settings"), value: repository.display.preferences.directInput ? L10n.tr("direct_input") : L10n.tr("local_compose")) { subpage = "input" }
                Toggle(L10n.tr("terminal_pinch_zoom"), isOn: Binding(
                    get: { repository.display.preferences.pinchZoom },
                    set: { val in repository.display.update { $0.pinchZoom = val } }
                ))
                Toggle(L10n.tr("completion_settings"), isOn: Binding(
                    get: { repository.display.preferences.suggestions },
                    set: { val in repository.display.update { $0.suggestions = val } }
                ))
            }

            Section(L10n.tr("connection_group")) {
                navRow(L10n.tr("computers"), value: "\(repository.relays.count)", action: onOpenComputers)
            }

            Section(L10n.tr("app_group")) {
                navRow(L10n.tr("notifications"), value: "") { subpage = "notices" }
                navRow(L10n.tr("ios_notices_title"), value: "") { subpage = "licenses" }
                navRow(L10n.tr("about"), value: "") { subpage = "about" }
            }

            Section {
                Text(L10n.tr("ios_background_boundary"))
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func navRow(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(palette.foreground)
                Spacer()
                Text(value).font(.subheadline).foregroundStyle(palette.muted)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(palette.muted)
            }
        }
    }

    private var previewBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("$ pebrel status --mobile")
            Text("connected · Ghostty VT · russh 0.62")
                .foregroundStyle(palette.primary)
        }
        .font(TerminalFontRegistry.swiftUIFont(family: repository.display.preferences.fontFamily, size: CGFloat(repository.display.preferences.fontSize)))
        .foregroundStyle(palette.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(palette.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(palette.outlineVariant, lineWidth: 1) }
    }

    private var themeSubpage: some View {
        List {
            Section { previewBanner }
            Section {
                themeChoiceRow(id: "system", label: L10n.tr("follow_system"), swatches: [])
            }
            Section(L10n.tr("light_themes")) {
                ForEach(PebrelThemeCatalog.lightThemeOrder, id: \.self) { name in
                    themeChoiceRow(id: name, label: name, swatches: PebrelThemeCatalog.shared.swatches(for: name))
                }
            }
            Section(L10n.tr("dark_themes")) {
                ForEach(PebrelThemeCatalog.darkThemeOrder, id: \.self) { name in
                    themeChoiceRow(id: name, label: name, swatches: PebrelThemeCatalog.shared.swatches(for: name))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func themeChoiceRow(id: String, label: String, swatches: [Color]) -> some View {
        Button {
            repository.display.setTheme(id)
        } label: {
            HStack(spacing: 10) {
                Text(label).foregroundStyle(palette.foreground)
                Spacer()
                if !swatches.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(0..<swatches.count, id: \.self) { idx in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(swatches[idx])
                                .frame(width: 14, height: 14)
                                .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.gray.opacity(0.3), lineWidth: 0.5) }
                        }
                    }
                }
                if repository.display.themeName == id {
                    Image(systemName: "checkmark").foregroundStyle(palette.primary)
                }
            }
        }
    }

    private var fontSubpage: some View {
        List {
            Section { previewBanner }
            Section(L10n.tr("font_settings")) {
                fontChoice(id: TerminalPreferenceValues.mapleFont, label: "Maple Mono NF CN")
                fontChoice(id: TerminalPreferenceValues.jetbrainsFont, label: "JetBrains Mono")
                fontChoice(id: TerminalPreferenceValues.systemFont, label: L10n.tr("terminal_system_font"))
            }
            Section("\(L10n.tr("font_size")): \(repository.display.preferences.fontSize) pt") {
                Slider(
                    value: Binding(
                        get: { Double(repository.display.preferences.fontSize) },
                        set: { val in repository.display.update { $0.fontSize = Int(val.rounded()) } }
                    ),
                    in: Double(TerminalPreferenceValues.minFontSize)...Double(TerminalPreferenceValues.maxFontSize),
                    step: 1
                )
            }
        }
        .listStyle(.insetGrouped)
    }

    private func fontChoice(id: String, label: String) -> some View {
        Button {
            repository.display.update { $0.fontFamily = id }
        } label: {
            HStack {
                Text(label).foregroundStyle(palette.foreground)
                Spacer()
                if repository.display.preferences.fontFamily == id {
                    Image(systemName: "checkmark").foregroundStyle(palette.primary)
                }
            }
        }
    }

    private var cursorSubpage: some View {
        List {
            Section { previewBanner }
            Section(L10n.tr("terminal_cursor_shape")) {
                cursorChoice(id: TerminalPreferenceValues.blockCursor, label: L10n.tr("terminal_cursor_block"))
                cursorChoice(id: TerminalPreferenceValues.barCursor, label: L10n.tr("terminal_cursor_bar"))
                cursorChoice(id: TerminalPreferenceValues.underlineCursor, label: L10n.tr("terminal_cursor_underline"))
            }
            Section {
                Toggle(L10n.tr("terminal_cursor_blink"), isOn: Binding(
                    get: { repository.display.preferences.cursorBlink },
                    set: { val in repository.display.update { $0.cursorBlink = val } }
                ))
            }
        }
        .listStyle(.insetGrouped)
    }

    private func cursorChoice(id: String, label: String) -> some View {
        Button {
            repository.display.update { $0.cursorStyle = id }
        } label: {
            HStack {
                Text(label).foregroundStyle(palette.foreground)
                Spacer()
                if repository.display.preferences.cursorStyle == id {
                    Image(systemName: "checkmark").foregroundStyle(palette.primary)
                }
            }
        }
    }

    private var scrollingSubpage: some View {
        let choices = [500, 1000, 2000, 5000].filter { $0 <= repository.display.maxScrollbackLines }
        return List {
            Section(L10n.tr("terminal_history")) {
                ForEach(choices, id: \.self) { count in
                    Button {
                        repository.display.update { $0.scrollbackLines = count }
                    } label: {
                        HStack {
                            Text("\(count)").foregroundStyle(palette.foreground)
                            Spacer()
                            if repository.display.preferences.scrollbackLines == count {
                                Image(systemName: "checkmark").foregroundStyle(palette.primary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var inputSubpage: some View {
        List {
            Section(L10n.tr("input_settings")) {
                Button {
                    repository.display.update { $0.directInput = true }
                } label: {
                    HStack {
                        Text(L10n.tr("direct_input")).foregroundStyle(palette.foreground)
                        Spacer()
                        if repository.display.preferences.directInput { Image(systemName: "checkmark").foregroundStyle(palette.primary) }
                    }
                }
                Button {
                    repository.display.update { $0.directInput = false }
                } label: {
                    HStack {
                        Text(L10n.tr("local_compose")).foregroundStyle(palette.foreground)
                        Spacer()
                        if !repository.display.preferences.directInput { Image(systemName: "checkmark").foregroundStyle(palette.primary) }
                    }
                }
            }
            Section {
                Button(L10n.tr("custom_shortcuts")) { showShortcutEditor = true }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var noticesSubpage: some View {
        List {
            Section {
                Text(L10n.tr("notice_boundary")).font(.subheadline).foregroundStyle(palette.muted)
                Button(L10n.tr("open_notifications")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var aboutSubpage: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.5.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return List {
            Section {
                HStack { Text("Pebrel iOS"); Spacer(); Text("\(version) (\(build))").foregroundStyle(palette.muted) }
                Text(L10n.tr("ios_local_shell_body")).font(.footnote).foregroundStyle(palette.muted)
                Text(L10n.tr("ios_background_boundary")).font(.footnote).foregroundStyle(palette.muted)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var licensesSubpage: some View {
        ScrollView {
            Text(noticesText.isEmpty ? "GPL-3.0-only" : noticesText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(palette.foreground)
                .textSelection(.enabled)
                .padding(16)
        }
    }
}
