import SwiftUI
import UIKit

/// Direct-mode shortcut toolbar + Compose multi-line command editor + History suggestions
/// + Push-to-talk local Whisper voice input + Custom shortcut editor + Remote sessions sheet.
struct CommandComposerView: View {
    @Environment(\.pebrelPalette) private var palette
    @ObservedObject var repository: SessionRepository

    let draftKey: String
    let isConversation: Bool
    let enabled: Bool
    let extraShortcuts: [TerminalShortcut]
    @Binding var directMode: Bool
    @Binding var focusedMode: Bool
    let onSendText: (String) async -> Bool
    let onSendShortcut: (TerminalShortcut) -> Void
    let onToggleKeyboard: () -> Void
    let onAttachFile: (() -> Void)?

    @State private var draft = ""
    @State private var undoDraft: String?
    @State private var expanded = false
    @State private var showShortcutEditor = false
    @State private var showAuxRow = true
    @State private var sending = false
    @State private var voiceTooLong = false
    @State private var showVoiceSheet = false
    @StateObject private var voice = VoiceInputController()
    @FocusState private var editorFocused: Bool

    private var allShortcuts: [TerminalShortcut] {
        repository.shortcuts.combinedShortcuts(extra: extraShortcuts)
    }

    private var suggestions: [String] {
        guard !isConversation, repository.display.preferences.suggestions, editorFocused else { return [] }
        return repository.commandUsage.suggestions(for: draft, scope: draftKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            if voice.state.phase == .recording || voice.state.phase == .transcribing {
                voiceOverlayBanner
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            if !suggestions.isEmpty && !directMode {
                suggestionStrip
            }

            if directMode && !isConversation {
                directToolbar
            } else {
                composeCard
            }
        }
        .onAppear {
            draft = repository.draft(for: draftKey)
            voice.checkModel()
        }
        .onChange(of: draft) { next in
            if next.count > 8192 {
                draft = String(next.prefix(8192))
            }
            repository.setDraft(draft, for: draftKey)
        }
        .onChange(of: draftKey) { nextKey in
            draft = repository.draft(for: nextKey)
        }
        .sheet(isPresented: $showShortcutEditor) {
            ShortcutEditorSheet(shortcuts: repository.shortcuts)
                .environment(\.pebrelPalette, palette)
        }
        .sheet(isPresented: $showVoiceSheet) {
            VoiceModelSheet(controller: voice)
                .environment(\.pebrelPalette, palette)
        }
        .alert(L10n.tr("attachment_failed"), isPresented: $voiceTooLong) {
            Button(L10n.tr("close"), role: .cancel) {}
        } message: {
            Text(L10n.tr("composer_voice_too_long"))
        }
    }

    private var directToolbar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(allShortcuts) { item in
                        Button {
                            onSendShortcut(item)
                        } label: {
                            Text(item.label)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(palette.foreground)
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                                .background(palette.surfaceVariant.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                    }
                }
                .padding(.horizontal, 8)
            }

            Rectangle()
                .fill(palette.outlineVariant)
                .frame(width: 0.5, height: 24)

            Button { showShortcutEditor = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.muted)
                    .frame(width: 34, height: 34)
            }

            Button { directMode = false } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.primary)
                    .frame(width: 34, height: 34)
            }

            Button(action: onToggleKeyboard) {
                Image(systemName: "keyboard")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.foreground)
                    .frame(width: 34, height: 34)
            }
        }
        .padding(.trailing, 6)
        .frame(height: 50)
        .pebrelGlassBar()
        .overlay(alignment: .top) {
            Rectangle().fill(palette.outlineVariant).frame(height: 0.5)
        }
    }

    private var suggestionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { item in
                    Button {
                        undoDraft = draft
                        draft = item
                    } label: {
                        Text(item)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .pebrelGlass(tier: .heavy, cornerRadius: 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var composeCard: some View {
        VStack(spacing: 6) {
            if !isConversation && showAuxRow {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(allShortcuts) { item in
                            Button {
                                onSendShortcut(item)
                            } label: {
                                Text(item.label)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(palette.foreground)
                                    .padding(.horizontal, 8)
                                    .frame(height: 28)
                                    .background(palette.surfaceVariant.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .disabled(!enabled)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .padding(.top, 4)
            }

            VStack(spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    TextField(
                        isConversation ? L10n.tr("chat_compose") : L10n.tr("composer_placeholder"),
                        text: $draft,
                        axis: .vertical
                    )
                    .font(isConversation ? .body : TerminalFontRegistry.swiftUIFont(family: repository.display.preferences.fontFamily, size: 14))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(expanded ? 8 : 3)
                    .focused($editorFocused)
                    .autocorrectionDisabled(!isConversation)
                    .textInputAutocapitalization(isConversation ? .sentences : .never)
                    .disabled(!enabled)

                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .frame(width: 28, height: 28)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                HStack(spacing: 8) {
                    Menu {
                        if let onAttachFile {
                            Button(L10n.tr("composer_attach"), action: onAttachFile)
                        }
                        if !isConversation {
                            Button(L10n.tr("custom_shortcuts")) { showShortcutEditor = true }
                            Button(showAuxRow ? L10n.tr("composer_hide_aux_keys") : L10n.tr("composer_aux_keys")) { showAuxRow.toggle() }
                            Button(focusedMode ? L10n.tr("composer_exit_focus") : L10n.tr("composer_focus")) { focusedMode.toggle() }
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(palette.muted)
                            .frame(width: 34, height: 34)
                    }

                    if !isConversation {
                        Button { directMode = true } label: {
                            Image(systemName: "terminal")
                                .font(.system(size: 16))
                                .foregroundStyle(palette.muted)
                                .frame(width: 32, height: 32)
                        }
                    }

                    if let previous = undoDraft {
                        Button {
                            draft = previous
                            undoDraft = nil
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 15))
                                .foregroundStyle(palette.muted)
                                .frame(width: 32, height: 32)
                        }
                    }

                    Spacer()

                    ComposerVoiceButton(
                        controller: voice,
                        onOpenModelSheet: { showVoiceSheet = true },
                        onTranscript: { spoken in
                            if let merged = VoiceInputController.appendVoiceDraft(draft, spoken: spoken) {
                                undoDraft = draft
                                draft = merged
                            } else {
                                voiceTooLong = true
                            }
                        }
                    )

                    Button {
                        let toSend = draft
                        guard !toSend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isConversation else { return }
                        sending = true
                        Task {
                            defer { sending = false }
                            let ok = await onSendText(toSend)
                            if ok {
                                if !isConversation {
                                    repository.commandUsage.record(toSend, scope: draftKey)
                                }
                                if draft == toSend {
                                    undoDraft = toSend
                                    draft = ""
                                }
                            }
                        }
                    } label: {
                        ZStack {
                            Circle().fill(enabled && !sending ? palette.primary : palette.muted.opacity(0.4))
                            if sending {
                                ProgressView().tint(palette.onPrimary)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(palette.onPrimary)
                            }
                        }
                        .frame(width: 34, height: 34)
                    }
                    .disabled(!enabled || sending)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .pebrelGlass(tier: .heavy, cornerRadius: 20)
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(editorFocused ? palette.primary : palette.outlineVariant, lineWidth: editorFocused ? 1.5 : 0.5)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private var voiceOverlayBanner: some View {
        HStack(spacing: 10) {
            if voice.state.phase == .recording {
                VoiceMeterBars(level: voice.state.level, tint: voice.state.cancelArmed ? palette.error : palette.primary)
                Text("\(voice.state.seconds)s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.foreground)
                Text(voice.state.cancelArmed ? L10n.tr("voice_release_cancel") : L10n.tr("voice_slide_cancel"))
                    .font(.caption)
                    .foregroundStyle(voice.state.cancelArmed ? palette.error : palette.muted)
                    .lineLimit(1)
            } else {
                ProgressView()
                Text(L10n.tr("voice_transcribing"))
                    .font(.caption)
                    .foregroundStyle(palette.foreground)
            }
            Spacer()
            Button(L10n.tr("cancel")) {
                voice.cancelRecordingOrTranscription()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.error)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .pebrelGlass(tier: .heavy, cornerRadius: 14)
    }
}

private struct ComposerVoiceButton: View {
    @Environment(\.pebrelPalette) private var palette
    @ObservedObject var controller: VoiceInputController
    let onOpenModelSheet: () -> Void
    let onTranscript: @MainActor (String) -> Void

    @State private var pressed = false

    var body: some View {
        Image(systemName: controller.state.phase == .recording ? "mic.fill" : "mic")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(controller.state.phase == .ready || controller.state.phase == .recording ? palette.primary : palette.muted)
            .frame(width: 34, height: 34)
            .background(
                Circle().fill(controller.state.phase == .recording ? palette.primary.opacity(0.18) : Color.clear)
            )
            .contentShape(Circle())
            .onTapGesture {
                onOpenModelSheet()
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !pressed {
                            if controller.state.phase == .ready {
                                pressed = true
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                controller.startRecording()
                            }
                        } else if controller.state.phase == .recording {
                            controller.setCancelArmed(value.translation.height < -72)
                        }
                    }
                    .onEnded { _ in
                        if pressed {
                            pressed = false
                            controller.finishRecording(onTranscript: onTranscript)
                        }
                    }
            )
            .accessibilityLabel(L10n.tr("composer_voice"))
    }
}

private struct VoiceMeterBars: View {
    let level: Float
    let tint: Color
    private let weights: [CGFloat] = [0.35, 0.5, 0.7, 0.85, 0.95, 1.0, 0.95, 0.85, 0.7, 0.5, 0.35]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<weights.count, id: \.self) { i in
                let h = max(4, min(20, CGFloat(level) * 20 * weights[i] + 3))
                Capsule()
                    .fill(tint)
                    .frame(width: 2.5, height: h)
            }
        }
        .frame(height: 20)
    }
}

struct VoiceModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pebrelPalette) private var palette
    @ObservedObject var controller: VoiceInputController

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Whisper · Base")
                    .font(.headline)
                    .foregroundStyle(palette.foreground)
                Text(L10n.tr("voice_model_description"))
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)

                switch controller.state.phase {
                case .checking:
                    ProgressView()
                case .missing:
                    Button(L10n.tr("voice_download")) {
                        controller.downloadModel()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.primary)
                case .downloading:
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(controller.state.progress))
                        HStack {
                            Text("\(Int(controller.state.progress * 100))%").font(.caption).foregroundStyle(palette.muted)
                            Spacer()
                            Button(L10n.tr("cancel"), role: .destructive) { controller.cancelDownload() }
                        }
                    }
                case .ready, .recording, .transcribing:
                    HStack {
                        Label(L10n.tr("voice_model_ready"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(palette.tertiary)
                        Spacer()
                        Button(L10n.tr("voice_remove"), role: .destructive) {
                            controller.removeModel()
                        }
                    }
                }

                if let err = controller.state.error {
                    Text(String(describing: err))
                        .font(.caption)
                        .foregroundStyle(palette.error)
                }
                Spacer()
            }
            .padding(20)
            .background(palette.background.ignoresSafeArea())
            .navigationTitle(L10n.tr("composer_voice"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("close")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct ShortcutEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pebrelPalette) private var palette
    @ObservedObject var shortcuts: ShortcutPreferences

    @State private var text = ""
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("custom_shortcuts_hint"))
                    .font(.footnote)
                    .foregroundStyle(palette.muted)

                TextEditor(text: $text)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(minHeight: 180)
                    .padding(8)
                    .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                if let errorMsg {
                    Text(errorMsg).font(.caption).foregroundStyle(palette.error)
                }
                Spacer()
            }
            .padding(18)
            .background(palette.background.ignoresSafeArea())
            .navigationTitle(L10n.tr("custom_shortcuts"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("save")) {
                        let lines = text.components(separatedBy: .newlines)
                        switch shortcuts.saveLines(lines) {
                        case .success:
                            dismiss()
                        case .failure(let err):
                            switch err {
                            case .invalid(let v): errorMsg = "Invalid: \(v)"
                            case .duplicate(let v): errorMsg = "Duplicate: \(v)"
                            case .tooMany: errorMsg = "Max \(ShortcutPreferences.maxKeys) shortcuts"
                            }
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                text = shortcuts.customShortcuts.map(\.label).joined(separator: "\n")
            }
        }
    }
}

struct RemoteSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pebrelPalette) private var palette

    let sessionId: String
    @ObservedObject var repository: SessionRepository
    let onAttach: (RemoteAttachment) -> Void

    @State private var entries: [RemoteSessionEntry] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack { ProgressView(); Text(L10n.tr("loading")) }
                } else if entries.isEmpty {
                    Text(L10n.tr("remote_sessions_empty")).foregroundStyle(palette.muted)
                } else {
                    ForEach(entries, id: \.uniqueId) { entry in
                        Section("\(entry.kind) · \(entry.name)") {
                            Button {
                                onAttach(RemoteAttachment(
                                    kind: entry.kind,
                                    sessionId: entry.id,
                                    sessionName: entry.name,
                                    identity: entry.identity,
                                    windowId: nil,
                                    paneId: nil
                                ))
                                dismiss()
                            } label: {
                                Label(L10n.tr("connect"), systemImage: "terminal")
                            }

                            ForEach(entry.windows) { win in
                                Button {
                                    onAttach(RemoteAttachment(
                                        kind: entry.kind,
                                        sessionId: entry.id,
                                        sessionName: entry.name,
                                        identity: entry.identity,
                                        windowId: win.id,
                                        paneId: win.paneId
                                    ))
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text("#\(win.index) \(win.name)")
                                        Spacer()
                                        if win.active {
                                            Image(systemName: "checkmark").foregroundStyle(palette.primary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("remote_sessions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("close")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.tr("refresh")) { reload() }
                }
            }
            .onAppear { reload() }
        }
    }

    private func reload() {
        loading = true
        Task {
            entries = await repository.discoverRemoteSessions(for: sessionId)
            loading = false
        }
    }
}
