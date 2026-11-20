import Combine
import SwiftUI
import UIKit

// MARK: - Git Screen

struct GitScreen: View {
    @Environment(\.pebrelPalette) private var palette
    let target: DesktopGitTarget
    @ObservedObject var repository: SessionRepository
    let onBack: () -> Void

    @StateObject private var controller: DesktopGitController
    @State private var selectedTab = 0 // 0 = Changes, 1 = History
    @State private var commitMessage = ""
    @State private var showErrorDetail = false

    @MainActor
    init(target: DesktopGitTarget, repository: SessionRepository, onBack: @escaping () -> Void) {
        self.target = target
        self.repository = repository
        self.onBack = onBack
        _controller = StateObject(wrappedValue: repository.makeDesktopGit(target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            PebrelPageHeader(
                controller.activeDiffTitle != nil ? L10n.tr("git_diff") : L10n.tr("git_title"),
                subtitle: controller.activeDiffTitle ?? controller.snapshot?.root.split(separator: "/").last.map(String.init),
                onBack: {
                    if controller.activeDiffTitle != nil {
                        controller.closeDiff()
                    } else {
                        onBack()
                    }
                }
            ) {
                Button {
                    Task {
                        if selectedTab == 0 { await controller.refreshStatus() }
                        else { await controller.loadHistory(reset: true) }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 36, height: 36)
                }
                .foregroundStyle(palette.foreground)
            }

            if let diffText = controller.activeDiffText {
                gitDiffView(diffText)
            } else {
                Picker("", selection: $selectedTab) {
                    Text(L10n.tr("git_changes")).tag(0)
                    Text(L10n.tr("git_history")).tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .onChange(of: selectedTab) { next in
                    if next == 1 && controller.history.isEmpty {
                        Task { await controller.loadHistory(reset: true) }
                    }
                }

                if let problem = controller.problem {
                    HStack {
                        Text(problem.code).font(.caption).foregroundStyle(palette.error)
                        Spacer()
                        if !problem.detail.isEmpty {
                            Button(L10n.tr("git_error_details")) { showErrorDetail = true }.font(.caption.bold())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }

                if selectedTab == 0 {
                    gitChangesTab
                } else {
                    gitHistoryTab
                }
            }
        }
        .onAppear {
            commitMessage = repository.draft(for: target.draftKey)
            Task { await controller.refreshStatus() }
        }
        .onChange(of: commitMessage) { val in
            repository.setDraft(val, for: target.draftKey)
        }
        .alert(L10n.tr("operation_failed"), isPresented: $showErrorDetail) {
            Button(L10n.tr("close"), role: .cancel) {}
        } message: {
            Text(controller.problem?.detail ?? "")
        }
    }

    private var gitChangesTab: some View {
        VStack(spacing: 0) {
            if let snap = controller.snapshot {
                HStack(spacing: 8) {
                    Label(snap.branch, systemImage: "arrow.triangle.branch")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.foreground)
                    if snap.ahead > 0 || snap.behind > 0 {
                        Text("↑\(snap.ahead) ↓\(snap.behind)").font(.caption).foregroundStyle(palette.primary)
                    }
                    Spacer()
                    Menu {
                        Button(L10n.tr("git_stage_all")) { Task { await controller.stage(all: true) } }
                        Button(L10n.tr("git_unstage_all")) { Task { await controller.unstage(all: true) } }
                        Divider()
                        Button(L10n.tr("git_fetch")) { Task { await controller.fetch() } }
                        Button(L10n.tr("git_pull")) { Task { await controller.pull() } }
                        Button(L10n.tr("git_push")) { Task { await controller.push() } }
                        Button(L10n.tr("git_sync")) { Task { await controller.sync() } }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(palette.primary)
                    }
                    .disabled(controller.busy)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                List {
                    if !snap.stagedEntries.isEmpty {
                        Section(L10n.tr("git_staged", snap.stagedEntries.count)) {
                            gitTreeRows(entries: snap.stagedEntries, staged: true)
                        }
                    }
                    if !snap.unstagedEntries.isEmpty {
                        Section("\(L10n.tr("git_changes")) (\(snap.unstagedEntries.count))") {
                            gitTreeRows(entries: snap.unstagedEntries, staged: false)
                        }
                    }
                    if !snap.untrackedEntries.isEmpty {
                        Section("\(L10n.tr("git_section_untracked")) (\(snap.untrackedEntries.count))") {
                            gitTreeRows(entries: snap.untrackedEntries, staged: false)
                        }
                    }
                }
                .listStyle(.insetGrouped)

                // Pinned commit bar
                HStack(spacing: 8) {
                    TextField(L10n.tr("git_commit_message"), text: $commitMessage, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.tr("git_commit")) {
                        Task {
                            if await controller.commit(message: commitMessage) {
                                commitMessage = ""
                                repository.setDraft("", for: target.draftKey)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.primary)
                    .disabled(controller.busy || snap.stagedEntries.isEmpty || snap.hasConflicts || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(12)
                .pebrelGlassBar()
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func gitTreeRows(entries: [GitStatusEntry], staged: Bool) -> some View {
        let rows = GitTreeBuilder.build(entries: entries, collapsedFolders: controller.collapsedFolders)
        ForEach(rows) { row in
            HStack(spacing: 8) {
                if row.isDirectory {
                    Button {
                        if controller.collapsedFolders.contains(row.path) {
                            controller.collapsedFolders.remove(row.path)
                        } else {
                            controller.collapsedFolders.insert(row.path)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right").font(.caption2)
                            Image(systemName: "folder").foregroundStyle(palette.primary)
                            Text(row.name).font(.subheadline)
                        }
                        .padding(.leading, CGFloat(row.depth * 14))
                    }
                    .buttonStyle(.plain)
                } else if let entry = row.entry {
                    Button {
                        Task { await controller.openDiff(entry: entry, staged: staged) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: FileSymbol.systemName(name: row.name, isDirectory: false))
                                .foregroundStyle(palette.muted)
                            Text(row.name).font(.subheadline).lineLimit(1)
                            Spacer()
                            Text(entry.displayBadge)
                                .font(.caption.bold().monospaced())
                                .foregroundStyle(entry.conflict ? palette.error : palette.primary)
                        }
                        .padding(.leading, CGFloat(row.depth * 14))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            if staged { await controller.unstage(path: entry.path) }
                            else { await controller.stage(path: entry.path) }
                        }
                    } label: {
                        Image(systemName: staged ? "minus.circle" : "plus.circle")
                            .foregroundStyle(palette.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.busy)
                }
            }
        }
    }

    private var gitHistoryTab: some View {
        List {
            ForEach(controller.history) { commit in
                Button {
                    Task { await controller.openCommitDiff(commit) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(commit.subject).font(.subheadline.weight(.medium)).foregroundStyle(palette.foreground)
                        HStack(spacing: 8) {
                            Text(commit.shortHash).font(.caption.monospaced()).foregroundStyle(palette.primary)
                            Text(commit.author).font(.caption).foregroundStyle(palette.muted)
                            if !commit.refs.isEmpty {
                                Text(commit.refs).font(.caption2).foregroundStyle(palette.tertiary)
                            }
                        }
                    }
                }
            }
            if controller.hasMoreHistory {
                Button(L10n.tr("sftp_more")) {
                    Task { await controller.loadHistory(reset: false) }
                }
                .foregroundStyle(palette.primary)
            }
        }
        .listStyle(.plain)
    }

    private func gitDiffView(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        return VStack(spacing: 0) {
            if let entry = controller.activeDiffEntry {
                HStack {
                    Spacer()
                    Button(controller.activeDiffStaged ? L10n.tr("git_unstage") : L10n.tr("git_stage")) {
                        Task {
                            if controller.activeDiffStaged { await controller.unstage(path: entry.path) }
                            else { await controller.stage(path: entry.path) }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(palette.surfaceVariant)
            }
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        let bg: Color = line.hasPrefix("+") && !line.hasPrefix("+++")
                            ? palette.primary.opacity(0.12)
                            : (line.hasPrefix("-") && !line.hasPrefix("---") ? palette.error.opacity(0.12) : Color.clear)
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(palette.foreground)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                            .background(bg)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - AI Agent Conversations (Desktop & SSH)

struct DesktopConversationScreen: View {
    let desktop: ManagedDesktopSession
    let pane: DesktopPane
    let identity: ConversationIdentity
    @ObservedObject var repository: SessionRepository
    let onBack: () -> Void
    let onSwitcher: () -> Void
    let onOpenTab: (DesktopTab) -> Void

    @StateObject private var source: DesktopConversation

    @MainActor
    init(
        desktop: ManagedDesktopSession,
        pane: DesktopPane,
        identity: ConversationIdentity,
        repository: SessionRepository,
        onBack: @escaping () -> Void,
        onSwitcher: @escaping () -> Void,
        onOpenTab: @escaping (DesktopTab) -> Void
    ) {
        self.desktop = desktop
        self.pane = pane
        self.identity = identity
        self.repository = repository
        self.onBack = onBack
        self.onSwitcher = onSwitcher
        self.onOpenTab = onOpenTab
        _source = StateObject(wrappedValue: repository.makeDesktopConversation(
            desktopId: desktop.id,
            windowId: pane.window,
            paneId: pane.id,
            identity: identity
        ))
    }

    var body: some View {
        ConversationShellView(
            title: pane.agent?.displayName ?? sshAgentDisplayName(identity.kind),
            subtitle: "\(desktop.name) · \(pane.displayTitle)",
            draftKey: "\(desktop.id):chat:\(pane.window):\(pane.id):\(identity.session)",
            source: source,
            repository: repository,
            onBack: onBack,
            onSwitcher: onSwitcher
        )
    }
}

struct SshConversationScreen: View {
    let session: ManagedTerminalSession
    let kind: String
    @ObservedObject var repository: SessionRepository
    let onBack: () -> Void
    let onSwitcher: () -> Void

    @State private var source: SshConversation?

    var body: some View {
        Group {
            if let source {
                ConversationShellView(
                    title: sshAgentDisplayName(kind),
                    subtitle: session.title,
                    draftKey: session.id,
                    source: source,
                    repository: repository,
                    onBack: onBack,
                    onSwitcher: onSwitcher
                )
            } else {
                VStack {
                    PebrelPageHeader(L10n.tr("chat_title"), onBack: onBack)
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .onAppear {
            if source == nil {
                source = repository.makeSshConversation(for: session.id, kind: kind)
            }
        }
    }
}

private struct ConversationShellView<Source: ConversationSource & ObservableObject>: View {
    @Environment(\.pebrelPalette) private var palette
    @Environment(\.openURL) private var openURL
    let title: String
    let subtitle: String
    let draftKey: String
    @ObservedObject var source: Source
    @ObservedObject var repository: SessionRepository
    let onBack: () -> Void
    let onSwitcher: () -> Void

    @State private var page = ConversationPage(identity: ConversationIdentity(kind: "", session: "", epoch: nil))
    @State private var immersive = false
    @State private var expandedTools: Set<String> = []
    @State private var richReaderMessage: ConversationMessage?
    @State private var errorNotice: String?
    @State private var lastPromptShownAt = Date.distantPast
    @State private var runningStart = Date()
    @State private var elapsedSeconds = 0
    @State private var dummyDirect = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if !immersive {
                    PebrelPageHeader(title, subtitle: subtitle, onBack: onBack) {
                        HStack(spacing: 4) {
                            Button { immersive = true } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 34, height: 34)
                            }
                            Button(action: onSwitcher) {
                                Image(systemName: "rectangle.stack").frame(width: 34, height: 34)
                            }
                        }
                        .foregroundStyle(palette.foreground)
                    }
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if page.before != nil {
                                Button(L10n.tr("chat_older")) {
                                    Task { _ = try? await source.refresh(older: true) }
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(palette.primary)
                                .frame(maxWidth: .infinity)
                            }

                            if page.loaded && page.messages.isEmpty {
                                Text(L10n.tr("chat_empty"))
                                    .font(.subheadline)
                                    .foregroundStyle(palette.muted)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 32)
                            }

                            ForEach(page.messages) { msg in
                                messageRow(msg)
                                    .id(msg.id)
                            }
                            Color.clear.frame(height: 1).id("chat-bottom")
                        }
                        .padding(14)
                    }
                    .onChange(of: page.messages.last?.id) { _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                    }
                }

                if let errorNotice {
                    Text(errorNotice)
                        .font(.caption)
                        .foregroundStyle(palette.error)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }

                if let prompt = page.prompt {
                    promptCard(prompt)
                }

                statusLine

                CommandComposerView(
                    repository: repository,
                    draftKey: draftKey,
                    isConversation: true,
                    enabled: page.canSend,
                    extraShortcuts: [],
                    directMode: $dummyDirect,
                    focusedMode: $immersive,
                    onSendText: { text in
                        do {
                            try await source.send(text)
                            errorNotice = nil
                            return true
                        } catch {
                            errorNotice = error.localizedDescription
                            return false
                        }
                    },
                    onSendShortcut: { shortcut in
                        let supportedKeys: Set<String> = ["Ctrl+C", "Esc", "Tab", "←", "→", "↑", "↓"]
                        guard supportedKeys.contains(shortcut.label) else { return }
                        Task {
                            do {
                                try await source.key(shortcut.label)
                                errorNotice = nil
                            } catch {
                                errorNotice = error.localizedDescription
                            }
                        }
                    },
                    onToggleKeyboard: {},
                    onAttachFile: nil
                )
            }

            if immersive {
                Button { immersive = false } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .foregroundStyle(palette.foreground)
                        .frame(width: 38, height: 38)
                        .pebrelGlass(tier: .light, cornerRadius: 19)
                }
                .padding(14)
            }
        }
        .onReceive(source.pagePublisher) { next in
            if next.prompt?.id != page.prompt?.id {
                lastPromptShownAt = Date()
            }
            if next.state == "running" && page.state != "running" {
                runningStart = Date()
                elapsedSeconds = 0
            }
            page = next
        }
        .task {
            while !Task.isCancelled {
                do {
                    let changed = try await source.refresh(older: false)
                    errorNotice = nil
                    let delayMs: UInt64 = page.state == "running" ? (changed ? 800 : 1500) : 3000
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                } catch is CancellationError {
                    return
                } catch {
                    errorNotice = error.localizedDescription
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if page.state == "running" {
                    elapsedSeconds = Int(Date().timeIntervalSince(runningStart))
                }
            }
        }
        .sheet(item: $richReaderMessage) { msg in
            NavigationStack {
                let doc = ReaderMarkdown.prepareMarkdown(text: msg.text, colors: palette.readerColors, copyLabel: L10n.tr("reader_copy"))
                ReaderWebView(
                    document: doc,
                    colors: palette.readerColors,
                    scrollToHeadingId: nil,
                    onCopyCode: { idx in
                        if idx >= 0 && idx < doc.codeBlocks.count {
                            UIPasteboard.general.string = doc.codeBlocks[idx]
                        }
                    },
                    onOpenLink: { raw in
                        if let url = ChatMarkdownInline.safeLinkURL(raw) {
                            openURL(url)
                        }
                    }
                )
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.tr("close")) { richReaderMessage = nil }
                    }
                }
            }
            .presentationDetents([.large])
        }
    }

    @ViewBuilder
    private func messageRow(_ msg: ConversationMessage) -> some View {
        let codeFontFamily = repository.display.preferences.fontFamily
        switch msg.role {
        case "user":
            HStack {
                Spacer(minLength: 44)
                VStack(alignment: .leading, spacing: 6) {
                    ChatMarkdownView(text: msg.text, codeFontFamily: codeFontFamily)
                    if msg.truncated {
                        Text(L10n.tr("chat_content_clipped"))
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(palette.primary.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

        case "tool":
            let isExpanded = expandedTools.contains(msg.id)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if isExpanded { expandedTools.remove(msg.id) } else { expandedTools.insert(msg.id) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: toolIcon(msg.name))
                            .font(.caption)
                            .foregroundStyle(msg.isError ? palette.error : palette.primary)
                        Text(msg.name ?? "Tool")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.foreground)
                        Text(msg.text.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                        Spacer()
                        if !msg.complete {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: msg.isError ? "xmark.circle" : "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(msg.isError ? palette.error : palette.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    if !msg.text.isEmpty {
                        Text(msg.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(palette.foreground)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let detail = msg.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(palette.muted)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(palette.background, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(10)
            .pebrelGlass(tier: .light, cornerRadius: 12)

        default:
            let doc = ChatMarkdownParser.cachedParse(msg.text)
            VStack(alignment: .leading, spacing: 8) {
                if doc.blocks.isEmpty {
                    Text(msg.text)
                        .font(.body)
                        .foregroundStyle(palette.foreground)
                        .textSelection(.enabled)
                } else {
                    ChatMarkdownView(document: doc, codeFontFamily: codeFontFamily)
                }

                if msg.truncated {
                    Text(L10n.tr("chat_content_clipped"))
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }

                if doc.hasRichContent || doc.hasCodeOrTable {
                    HStack(spacing: 8) {
                        if doc.hasRichContent {
                            Text(L10n.tr("chat_rich_hint"))
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button {
                            richReaderMessage = msg
                        } label: {
                            Label(L10n.tr("chat_rich_reader"), systemImage: "doc.richtext")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(palette.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func promptCard(_ prompt: ConversationPrompt) -> some View {
        let displayOptions = (prompt.binary && prompt.options.isEmpty)
            ? [L10n.tr("chat_allow"), L10n.tr("chat_deny")]
            : prompt.options
        return VStack(alignment: .leading, spacing: 10) {
            Text(prompt.text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.foreground)
            ForEach(Array(displayOptions.enumerated()), id: \.offset) { idx, option in
                Button {
                    guard Date().timeIntervalSince(lastPromptShownAt) >= 0.35 else { return }
                    Task {
                        do { try await source.choose(prompt: prompt, index: idx) }
                        catch { errorNotice = error.localizedDescription }
                    }
                } label: {
                    HStack {
                        Text(prompt.binary ? option : "\(idx + 1). \(option)")
                            .font(.subheadline)
                            .foregroundStyle(idx == prompt.selected ? palette.onPrimary : palette.foreground)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(idx == prompt.selected ? palette.primary : palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .pebrelGlass(tier: .heavy, cornerRadius: 16)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var statusLine: some View {
        let isWaiting = page.state == "waiting_input" || page.state == "attention"
        return HStack(spacing: 8) {
            Circle()
                .fill(page.state == "running" ? palette.primary : (isWaiting ? palette.yellow : palette.tertiary))
                .frame(width: 8, height: 8)
            Text(page.state == "running" ? "\(title) · \(elapsedSeconds)s" : (page.activity.isEmpty ? page.state : page.activity))
                .font(.caption)
                .foregroundStyle(palette.muted)
                .lineLimit(1)
            Spacer()
            if page.state == "running" {
                Button(L10n.tr("chat_interrupt")) {
                    Task { try? await source.key("Esc") }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.error)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func toolIcon(_ name: String?) -> String {
        let lower = (name ?? "").lowercased()
        if lower.contains("bash") || lower.contains("shell") || lower.contains("exec") { return "terminal" }
        if lower.contains("read") || lower.contains("view") { return "doc.text" }
        if lower.contains("edit") || lower.contains("write") || lower.contains("patch") { return "pencil" }
        if lower.contains("search") || lower.contains("grep") || lower.contains("glob") { return "magnifyingglass" }
        if lower.contains("web") || lower.contains("fetch") { return "globe" }
        return "wrench"
    }
}
