import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SshTerminalScreen: View {
    @Environment(\.pebrelPalette) private var palette
    let session: ManagedTerminalSession
    @ObservedObject var repository: SessionRepository

    let onBack: () -> Void
    let onSwitcher: () -> Void
    let onEditHost: () -> Void
    let onClose: () -> Void
    let onOpenSftp: () -> Void
    let onOpenConversation: (String) -> Void
    let onAttachRemote: (RemoteAttachment) -> Void

    @State private var directMode = true
    @State private var focusedMode = false
    @State private var focusTrigger = 0
    @State private var showCloseConfirm = false
    @State private var showRemoteSessions = false
    @State private var showAttachPicker = false
    @State private var attaching = false
    @State private var showRetryCredentials = false
    @State private var retryPassword = ""
    @State private var zoomBannerText: String?
    @State private var copyToast: String?

    private var extraShortcuts: [TerminalShortcut] {
        let usesMux = session.host.sessionMode != .shell || session.attachment != nil || session.foreground?.multiplexer != nil
        if usesMux, let b = TerminalShortcut.tmuxPrefix { return [b] }
        return []
    }

    var body: some View {
        VStack(spacing: 0) {
            if !focusedMode {
                terminalHeader
            }

            if session.hasConnected && (session.status == "ended" || session.status == "failed") {
                HStack {
                    Text(session.status == "ended" ? L10n.tr("state_ended") : (session.failure?.rawValue ?? L10n.tr("state_disconnected")))
                        .font(.caption)
                        .foregroundStyle(palette.foreground)
                    Spacer()
                    Button(L10n.tr("retry")) {
                        if session.failure == .auth || session.failure == .key {
                            showRetryCredentials = true
                        } else {
                            repository.retrySsh(id: session.id)
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(palette.surfaceVariant)
            }

            ZStack {
                TerminalCanvasView(
                    frame: session.frame,
                    fontFamily: repository.display.preferences.fontFamily,
                    fontSize: CGFloat(repository.display.preferences.fontSize),
                    cursorStyle: repository.display.preferences.cursorStyle,
                    cursorBlink: repository.display.preferences.cursorBlink,
                    pinchZoomEnabled: repository.display.preferences.pinchZoom,
                    directInputEnabled: directMode && session.status == "ready",
                    focusTrigger: focusTrigger,
                    isSnapshotMirror: false,
                    onGridSizeChanged: { cols, rows, cw, ch in
                        repository.terminalSession(for: session.id)?.resize(columns: cols, rows: rows, cellWidth: cw, cellHeight: ch)
                    },
                    onTextInput: { text in
                        _ = repository.terminalSession(for: session.id)?.sendText(text)
                    },
                    onKeyInput: { code, mods, text, unshifted in
                        _ = repository.terminalSession(for: session.id)?.sendKey(code: code, modifiers: mods, text: text, unshifted: unshifted)
                    },
                    onScrollLines: { lines, col, row in
                        repository.terminalSession(for: session.id)?.scrollViewport(delta: lines, column: col, row: row)
                    },
                    onScrollOffset: { offset in
                        repository.terminalSession(for: session.id)?.scrollTo(offset: offset)
                    },
                    onFontSizeChanged: { size in
                        repository.display.update { $0.fontSize = Int(size.rounded()) }
                    },
                    onZoomGestureActive: { active, size in
                        zoomBannerText = active ? "\(Int(size.rounded())) pt" : nil
                    },
                    onCopyText: { _ in
                        showToast(L10n.tr("terminal_copied"))
                    }
                )

                if !session.hasConnected && (session.status == "connecting" || session.status == "failed") {
                    initialSshOverlay
                }

                if focusedMode {
                    VStack {
                        HStack {
                            Spacer()
                            Button { focusedMode = false } label: {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .foregroundStyle(palette.foreground)
                                    .frame(width: 36, height: 36)
                                    .pebrelGlass(tier: .light, cornerRadius: 18)
                            }
                            .padding(12)
                        }
                        Spacer()
                    }
                }

                if let zoomBannerText {
                    Text(zoomBannerText)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(palette.foreground)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .pebrelGlass(tier: .heavy, cornerRadius: 12)
                }

                if let copyToast {
                    VStack {
                        Spacer()
                        Text(copyToast)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.foreground)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .pebrelGlass(tier: .heavy, cornerRadius: 12)
                            .padding(.bottom, 12)
                    }
                }

                if attaching {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.tr("attachment_uploading")).font(.caption)
                    }
                    .padding(18)
                    .pebrelGlass(tier: .heavy, cornerRadius: 14)
                }
            }

            CommandComposerView(
                repository: repository,
                draftKey: session.id,
                isConversation: false,
                enabled: session.status == "ready",
                extraShortcuts: extraShortcuts,
                directMode: $directMode,
                focusedMode: $focusedMode,
                onSendText: { text in
                    guard let term = repository.terminalSession(for: session.id) else { return false }
                    let ok = term.sendText(text + "\r")
                    return ok
                },
                onSendShortcut: { shortcut in
                    _ = repository.terminalSession(for: session.id)?.sendShortcut(shortcut)
                },
                onToggleKeyboard: {
                    focusTrigger += 1
                },
                onAttachFile: { showAttachPicker = true }
            )
        }
        .onAppear {
            directMode = repository.display.preferences.directInput
        }
        .sheet(isPresented: $showRemoteSessions) {
            RemoteSessionSheet(sessionId: session.id, repository: repository, onAttach: onAttachRemote)
                .environment(\.pebrelPalette, palette)
        }
        .fileImporter(isPresented: $showAttachPicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                uploadAttachment(url: url)
            }
        }
        .alert(L10n.tr("close_session"), isPresented: $showCloseConfirm) {
            Button(L10n.tr("close_session"), role: .destructive, action: onClose)
            Button(L10n.tr("cancel"), role: .cancel) {}
        }
        .alert(L10n.tr("authentication"), isPresented: $showRetryCredentials) {
            SecureField(L10n.tr("password"), text: $retryPassword)
            Button(L10n.tr("connect")) {
                let secret = ZeroizedBytes(utf8: retryPassword)
                retryPassword = ""
                repository.retrySsh(id: session.id, newPassword: secret)
            }
            Button(L10n.tr("cancel"), role: .cancel) { retryPassword = "" }
        }
    }

    private var terminalHeader: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                    .frame(width: 36, height: 36)
            }

            Button(action: onSwitcher) {
                HStack(spacing: 6) {
                    if session.status == "connecting" {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Circle()
                            .fill(session.status == "ready" ? palette.tertiary : palette.error)
                            .frame(width: 8, height: 8)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                        if let fg = session.foreground, !fg.label.isEmpty {
                            Text(fg.label)
                                .font(.caption2)
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .pebrelGlass(tier: .light, cornerRadius: 12)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            if let agent = session.foreground?.agent {
                Button { onOpenConversation(agent) } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundStyle(palette.primary)
                        .frame(width: 36, height: 36)
                }
            }

            Button(action: onOpenSftp) {
                Image(systemName: "folder")
                    .foregroundStyle(session.status == "ready" ? palette.foreground : palette.muted)
                    .frame(width: 36, height: 36)
            }
            .disabled(session.status != "ready")

            Menu {
                if session.status == "ready" {
                    Button(L10n.tr("remote_sessions")) { showRemoteSessions = true }
                }
                Button(L10n.tr("edit_host"), action: onEditHost)
                Button(L10n.tr("close_session"), role: .destructive) { showCloseConfirm = true }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(palette.foreground)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .pebrelGlassBar()
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.outlineVariant).frame(height: 0.5)
        }
    }

    private var initialSshOverlay: some View {
        VStack(spacing: 14) {
            if let trust = repository.trustRequest, trust.ownerId == session.id {
                Text(L10n.tr("verify_host")).font(.headline).foregroundStyle(palette.foreground)
                Text(session.host.endpointLabel).font(.caption).foregroundStyle(palette.muted)
                Text(trust.fingerprint)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.foreground)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 12) {
                    Button(L10n.tr("cancel"), role: .cancel) { repository.answerTrust(accepted: false) }
                    Button(L10n.tr("trust_connect")) { repository.answerTrust(accepted: true) }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.primary)
                }
            } else if session.status == "connecting" {
                ProgressView()
                Text(session.stage.rawValue).font(.subheadline).foregroundStyle(palette.foreground)
                Text(session.host.endpointLabel).font(.caption).foregroundStyle(palette.muted)
            } else {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(palette.error)
                Text(session.failure?.rawValue ?? L10n.tr("operation_failed")).font(.headline).foregroundStyle(palette.foreground)
                HStack(spacing: 12) {
                    Button(L10n.tr("edit_host"), action: onEditHost)
                    Button(L10n.tr("retry")) {
                        if session.failure == .auth || session.failure == .key {
                            showRetryCredentials = true
                        } else {
                            repository.retrySsh(id: session.id)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.primary)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: 320)
        .pebrelGlass(tier: .heavy, cornerRadius: 18)
    }

    private func uploadAttachment(url: URL) {
        guard let client = repository.sftpClient(for: session.id) else { return }
        attaching = true
        Task {
            defer { attaching = false }
            do {
                let remotePath = try await TerminalAttachments.uploadToSsh(sourceURL: url, files: client)
                let quoted = CryptoHelpers.shellSingleQuote(remotePath)
                let current = repository.draft(for: session.id)
                let next = current.isEmpty ? quoted : "\(current) \(quoted)"
                if next.count <= 8192 {
                    repository.setDraft(next, for: session.id)
                    directMode = false
                    showToast(L10n.tr("attachment_added"))
                } else {
                    UIPasteboard.general.string = remotePath
                    showToast(L10n.tr("attachment_draft_full"))
                }
            } catch {
                repository.globalError = error.localizedDescription
            }
        }
    }

    private func showToast(_ text: String) {
        copyToast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copyToast == text { copyToast = nil }
        }
    }
}

struct DesktopTerminalScreen: View {
    @Environment(\.pebrelPalette) private var palette
    let desktop: ManagedDesktopSession
    let pane: DesktopPane
    @ObservedObject var repository: SessionRepository

    let onBack: () -> Void
    let onSwitcher: () -> Void
    let onOpenGit: () -> Void
    let onOpenConversation: () -> Void

    @State private var directMode = true
    @State private var focusedMode = false
    @State private var focusTrigger = 0
    @State private var fitWidthTrigger = 0
    @State private var showDetails = false
    @State private var zoomBannerText: String?

    private var paneIdentity: String {
        "\(desktop.id):\(pane.window):\(pane.id)"
    }

    private var currentFrame: TerminalFrame? {
        repository.desktopOutput.target == paneIdentity ? repository.desktopOutput.frame : nil
    }

    private var currentText: String {
        repository.desktopOutput.target == paneIdentity ? repository.desktopOutput.text : ""
    }

    var body: some View {
        VStack(spacing: 0) {
            if !focusedMode {
                desktopHeader
            }

            if !desktop.allowInput {
                HStack {
                    Image(systemName: "lock").font(.caption)
                    Text(L10n.tr("composer_pc_read_only_short")).font(.caption)
                    Spacer()
                }
                .foregroundStyle(palette.muted)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(palette.surfaceVariant)
            }

            ZStack {
                if let frame = currentFrame {
                    TerminalCanvasView(
                        frame: frame,
                        fontFamily: repository.display.preferences.fontFamily,
                        fontSize: CGFloat(repository.display.preferences.fontSize),
                        snapshotZoom: CGFloat(repository.display.preferences.desktopZoom),
                        wrapLines: repository.display.preferences.desktopWrapLines,
                        cursorStyle: TerminalPreferenceValues.blockCursor,
                        cursorBlink: false,
                        pinchZoomEnabled: repository.display.preferences.pinchZoom,
                        directInputEnabled: directMode && desktop.allowInput && desktop.status == "ready",
                        focusTrigger: focusTrigger,
                        fitWidthTrigger: fitWidthTrigger,
                        isSnapshotMirror: true,
                        onGridSizeChanged: nil,
                        onTextInput: { text in
                            guard let input = repository.desktopTerminalInput(for: desktop.id, windowId: pane.window, paneId: pane.id) else { return }
                            Task { _ = await input.sendText(text) }
                        },
                        onKeyInput: { code, mods, text, _ in
                            guard let input = repository.desktopTerminalInput(for: desktop.id, windowId: pane.window, paneId: pane.id) else { return }
                            Task { _ = await input.sendKeyCode(code: code, modifiers: mods, text: text) }
                        },
                        onScrollLines: { lines, col, row in
                            if let hist = frame.history, !hist.applicationScroll {
                                let nextStart = max(hist.oldest, min(hist.liveStart, hist.first + Int64(lines)))
                                repository.requestDesktopHistoryPage(start: nextStart >= hist.liveStart ? nil : nextStart)
                            } else if let input = repository.desktopTerminalInput(for: desktop.id, windowId: pane.window, paneId: pane.id) {
                                Task { await input.scroll(lines: lines, column: col, row: row) }
                            }
                        },
                        onScrollOffset: nil,
                        onHistoryPage: { start in
                            repository.requestDesktopHistoryPage(start: start)
                        },
                        onFontSizeChanged: nil,
                        onSnapshotZoomChanged: { scale in
                            repository.display.update { $0.desktopZoom = Double(scale) }
                        },
                        onZoomGestureActive: { active, size in
                            zoomBannerText = active ? "\(Int(size.rounded())) pt" : nil
                        },
                        onCopyText: nil
                    )
                    .id(paneIdentity)
                } else if !currentText.isEmpty {
                    ScrollView([.vertical, .horizontal]) {
                        Text(currentText)
                            .font(TerminalFontRegistry.swiftUIFont(family: repository.display.preferences.fontFamily, size: CGFloat(repository.display.preferences.fontSize)))
                            .foregroundStyle(palette.foreground)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.tr("loading")).font(.caption).foregroundStyle(palette.muted)
                    }
                }

                if let zoomBannerText {
                    Text(zoomBannerText)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .pebrelGlass(tier: .heavy, cornerRadius: 12)
                }
            }

            CommandComposerView(
                repository: repository,
                draftKey: paneIdentity,
                isConversation: false,
                enabled: desktop.allowInput && desktop.status == "ready",
                extraShortcuts: [],
                directMode: $directMode,
                focusedMode: $focusedMode,
                onSendText: { text in
                    guard let input = repository.desktopTerminalInput(for: desktop.id, windowId: pane.window, paneId: pane.id) else { return false }
                    return await input.submit(text)
                },
                onSendShortcut: { shortcut in
                    guard let input = repository.desktopTerminalInput(for: desktop.id, windowId: pane.window, paneId: pane.id) else { return }
                    Task { _ = await input.sendShortcut(shortcut) }
                },
                onToggleKeyboard: { focusTrigger += 1 },
                onAttachFile: nil
            )
        }
        .task(id: "\(paneIdentity):\(desktop.status):\(desktop.connectionGeneration)") {
            directMode = repository.display.preferences.directInput
            if desktop.status == "ready" {
                repository.startWatchingDesktopPane(desktopId: desktop.id, windowId: pane.window, paneId: pane.id)
            }
        }
        .onDisappear {
            repository.stopWatchingDesktopPane(target: paneIdentity)
        }
        .alert(pane.displayTitle, isPresented: $showDetails) {
            Button(L10n.tr("close"), role: .cancel) {}
        } message: {
            Text("Computer: \(desktop.name)\nCWD: \(pane.cwd)\nProgram: \(pane.runningProgram)\nState: \(pane.taskState)")
        }
    }

    private var desktopHeader: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                    .frame(width: 36, height: 36)
            }

            Button(action: onSwitcher) {
                HStack(spacing: 6) {
                    Circle().fill(desktop.status == "ready" ? palette.tertiary : palette.error).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(pane.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(palette.foreground).lineLimit(1)
                        Text("\(desktop.name) · \(pane.cwd)").font(.caption2).foregroundStyle(palette.muted).lineLimit(1)
                    }
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(palette.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .pebrelGlass(tier: .light, cornerRadius: 12)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            if pane.sshDestination == nil {
                Button(action: onOpenGit) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(desktop.status == "ready" ? palette.foreground : palette.muted)
                        .frame(width: 36, height: 36)
                }
                .disabled(desktop.status != "ready")
            }

            if let kind = pane.agent?.kind, (kind == "claude" || kind == "codex") {
                Button(action: onOpenConversation) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundStyle(palette.primary)
                        .frame(width: 36, height: 36)
                }
            }

            Menu {
                Toggle(L10n.tr("terminal_wrap_lines"), isOn: Binding(
                    get: { repository.display.preferences.desktopWrapLines },
                    set: { val in repository.display.update { $0.desktopWrapLines = val } }
                ))
                Button(L10n.tr("terminal_fit_width")) {
                    if repository.display.preferences.desktopWrapLines {
                        repository.display.update { $0.desktopWrapLines = false }
                    }
                    fitWidthTrigger += 1
                }
                Button(L10n.tr("terminal_reset_zoom")) {
                    repository.display.update { $0.desktopZoom = 1.0 }
                }
                Button(L10n.tr("terminal_details")) { showDetails = true }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(palette.foreground)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .pebrelGlassBar()
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.outlineVariant).frame(height: 0.5)
        }
    }
}
