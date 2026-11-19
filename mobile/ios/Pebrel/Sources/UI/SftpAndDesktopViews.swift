import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BinaryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - SFTP Browser & File Reader

struct SftpBrowserScreen: View {
    @Environment(\.pebrelPalette) private var palette
    let session: ManagedTerminalSession
    let client: SftpClient
    @Binding var path: String
    let onBack: () -> Void
    let onOpenFile: (SftpEntry) -> Void

    @State private var entries: [SftpEntry] = []
    @State private var resolvedPath = "."
    @State private var cursor: UInt64?
    @State private var loading = true
    @State private var showHidden = false
    @State private var errorMsg: String?
    @State private var transferStatus: String?
    @State private var showGoToPath = false
    @State private var pathInput = ""
    @State private var showMkdir = false
    @State private var mkdirName = ""
    @State private var renamingEntry: SftpEntry?
    @State private var renameText = ""
    @State private var deletingEntry: SftpEntry?
    @State private var showUploadPicker = false

    private var visibleEntries: [SftpEntry] {
        entries.filter { showHidden || !$0.name.hasPrefix(".") }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            PebrelPageHeader(resolvedPath, subtitle: session.host.name, onBack: onBack) {
                HStack(spacing: 4) {
                    Menu {
                        Button(L10n.tr("sftp_upload")) { showUploadPicker = true }
                        Button(L10n.tr("sftp_new_folder")) { mkdirName = ""; showMkdir = true }
                    } label: {
                        Image(systemName: "plus").frame(width: 36, height: 36)
                    }
                    Menu {
                        Button(L10n.tr("refresh")) { reload(target: resolvedPath) }
                        Button(L10n.tr("sftp_go_path")) { pathInput = resolvedPath; showGoToPath = true }
                        Toggle(L10n.tr("sftp_show_hidden"), isOn: $showHidden)
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 36, height: 36)
                    }
                }
                .foregroundStyle(palette.foreground)
            }

            if let transferStatus {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text(transferStatus).font(.caption).foregroundStyle(palette.foreground)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(palette.surfaceVariant)
            }

            if let errorMsg {
                HStack {
                    Text(errorMsg).font(.caption).foregroundStyle(palette.error)
                    Spacer()
                    Button(L10n.tr("retry")) { reload(target: resolvedPath) }.font(.caption.bold())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            List {
                if resolvedPath != "/" && resolvedPath != "." {
                    Button {
                        let parent = SftpPaths.parent(of: resolvedPath)
                        path = parent
                        reload(target: parent)
                    } label: {
                        Label("..", systemImage: "arrow.up.to.line")
                            .foregroundStyle(palette.primary)
                    }
                }

                if loading && entries.isEmpty {
                    HStack { ProgressView(); Text(L10n.tr("loading")) }
                }

                ForEach(visibleEntries) { entry in
                    HStack(spacing: 12) {
                        Button {
                            openEntry(entry)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: FileSymbol.systemName(name: entry.name, isDirectory: entry.isDirectory))
                                    .foregroundStyle(entry.isDirectory ? palette.primary : palette.muted)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).font(.subheadline).foregroundStyle(palette.foreground).lineLimit(1)
                                    HStack(spacing: 8) {
                                        if let size = entry.size, !entry.isDirectory {
                                            Text(CryptoHelpers.formatByteCount(size))
                                        }
                                        if let mod = entry.modified {
                                            Text(formatUnixTime(mod))
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(palette.muted)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Menu {
                            Button(L10n.tr("sftp_open")) { openEntry(entry) }
                            Button(L10n.tr("sftp_rename")) { renamingEntry = entry; renameText = entry.name }
                            Button(L10n.tr("sftp_delete"), role: .destructive) { deletingEntry = entry }
                        } label: {
                            Image(systemName: "ellipsis").foregroundStyle(palette.muted).frame(width: 30, height: 30)
                        }
                    }
                }

                if let nextCursor = cursor, entries.count < 8192 {
                    Button(L10n.tr("sftp_more")) {
                        loadMore(cursor: nextCursor)
                    }
                    .foregroundStyle(palette.primary)
                }
            }
            .listStyle(.plain)
            .refreshable { reload(target: resolvedPath) }
        }
        .onAppear { reload(target: path) }
        .onDisappear {
            if let old = cursor {
                Task { try? await client.closeList(cursor: old) }
            }
        }
        .fileImporter(isPresented: $showUploadPicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { uploadFile(url) }
        }
        .alert(L10n.tr("sftp_go_path"), isPresented: $showGoToPath) {
            TextField("/", text: $pathInput).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button(L10n.tr("sftp_open")) {
                let target = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty { path = target; reload(target: target) }
            }
            Button(L10n.tr("cancel"), role: .cancel) {}
        }
        .alert(L10n.tr("sftp_new_folder"), isPresented: $showMkdir) {
            TextField(L10n.tr("name"), text: $mkdirName)
            Button(L10n.tr("create")) {
                let name = mkdirName.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    do {
                        let target = try SftpPaths.child(parent: resolvedPath, name: name)
                        try await client.mkdir(path: target)
                        reload(target: resolvedPath)
                    } catch { errorMsg = error.localizedDescription }
                }
            }
            Button(L10n.tr("cancel"), role: .cancel) {}
        }
        .alert(L10n.tr("sftp_rename"), isPresented: Binding(
            get: { renamingEntry != nil },
            set: { if !$0 { renamingEntry = nil } }
        )) {
            TextField(L10n.tr("name"), text: $renameText)
            Button(L10n.tr("save")) {
                guard let entry = renamingEntry else { return }
                let destName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                renamingEntry = nil
                Task {
                    do {
                        let dest = try SftpPaths.child(parent: SftpPaths.parent(of: entry.path), name: destName)
                        try await client.rename(entry: entry, destination: dest)
                        reload(target: resolvedPath)
                    } catch { errorMsg = error.localizedDescription }
                }
            }
            Button(L10n.tr("cancel"), role: .cancel) { renamingEntry = nil }
        }
        .alert(L10n.tr("sftp_delete"), isPresented: Binding(
            get: { deletingEntry != nil },
            set: { if !$0 { deletingEntry = nil } }
        )) {
            Button(L10n.tr("sftp_delete"), role: .destructive) {
                guard let entry = deletingEntry else { return }
                deletingEntry = nil
                Task {
                    do {
                        try await client.remove(entry: entry)
                        reload(target: resolvedPath)
                    } catch { errorMsg = error.localizedDescription }
                }
            }
            Button(L10n.tr("cancel"), role: .cancel) { deletingEntry = nil }
        } message: {
            if let entry = deletingEntry { Text(entry.name) }
        }
    }

    private func reload(target: String) {
        if let old = cursor {
            cursor = nil
            Task { try? await client.closeList(cursor: old) }
        }
        loading = true
        errorMsg = nil
        Task {
            defer { loading = false }
            do {
                let listing = try await client.list(path: target)
                resolvedPath = listing.path
                path = listing.path
                entries = listing.entries
                cursor = listing.cursor
            } catch {
                errorMsg = error.localizedDescription
            }
        }
    }

    private func loadMore(cursor current: UInt64) {
        loading = true
        Task {
            defer { loading = false }
            do {
                let listing = try await client.list(path: resolvedPath, cursor: current)
                entries.append(contentsOf: listing.entries)
                cursor = listing.cursor
            } catch {
                errorMsg = error.localizedDescription
            }
        }
    }

    private func openEntry(_ entry: SftpEntry) {
        if entry.isDirectory {
            path = entry.path
            reload(target: entry.path)
        } else if entry.kind == "symlink" {
            Task {
                if let resolved = try? await client.stat(path: entry.path) {
                    if resolved.isDirectory {
                        path = resolved.path
                        reload(target: resolved.path)
                    } else {
                        onOpenFile(resolved)
                    }
                }
            }
        } else {
            onOpenFile(entry)
        }
    }

    private func uploadFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let fileName = TerminalAttachments.sanitizeFilename(url.lastPathComponent)
        transferStatus = "\(L10n.tr("sftp_upload")): \(fileName)"
        Task {
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                transferStatus = nil
            }
            do {
                let remotePath = try SftpPaths.child(parent: resolvedPath, name: fileName)
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value
                _ = try await client.upload(
                    remotePath: remotePath,
                    sourceURL: url,
                    expectedSize: size,
                    progress: { sent, total in
                        let tot = total.map { " / \(CryptoHelpers.formatByteCount($0))" } ?? ""
                        transferStatus = "\(fileName): \(CryptoHelpers.formatByteCount(sent))\(tot)"
                    }
                )
                reload(target: resolvedPath)
            } catch {
                errorMsg = error.localizedDescription
            }
        }
    }

    private func formatUnixTime(_ seconds: Int64) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}

struct SftpFileScreen: View {
    @Environment(\.pebrelPalette) private var palette
    @Environment(\.openURL) private var openURL
    let session: ManagedTerminalSession
    let client: SftpClient
    let tab: SftpTab
    let onBack: () -> Void
    let onSwitcher: () -> Void
    let onOpenLinkedFile: (SftpEntry) -> Void
    let onCloseTab: () -> Void

    @State private var loading = true
    @State private var rawData: Data?
    @State private var textContent: String?
    @State private var imageContent: UIImage?
    @State private var previewMode = true
    @State private var errorMsg: String?
    @State private var showOutline = false
    @State private var scrollToHeading: String?
    @State private var resetImageZoom = 0
    @State private var showExporter = false

    private var isMarkdown: Bool { ReaderMarkdown.isMarkdownPath(tab.file.name) }

    private var document: ReaderDocument? {
        guard let textContent else { return nil }
        if isMarkdown && previewMode {
            return ReaderMarkdown.prepareMarkdown(text: textContent, colors: palette.readerColors, copyLabel: L10n.tr("reader_copy"))
        }
        return ReaderMarkdown.prepareSource(text: textContent, path: tab.file.path, colors: palette.readerColors, copyLabel: L10n.tr("reader_copy"))
    }

    var body: some View {
        VStack(spacing: 0) {
            PebrelPageHeader(tab.file.name, subtitle: session.host.name, onBack: onBack) {
                HStack(spacing: 6) {
                    Button(action: onSwitcher) {
                        Image(systemName: "rectangle.stack").frame(width: 34, height: 34)
                    }
                    Menu {
                        Button(L10n.tr("refresh")) { load() }
                        if rawData != nil {
                            Button(L10n.tr("sftp_download")) { showExporter = true }
                        }
                        if let doc = document, !doc.headings.isEmpty {
                            Button(L10n.tr("reader_outline")) { showOutline = true }
                        }
                        if let textContent {
                            Button(L10n.tr("reader_copy")) { UIPasteboard.general.string = textContent }
                        }
                        if imageContent != nil {
                            Button(L10n.tr("reader_reset_zoom")) { resetImageZoom += 1 }
                        }
                        Button(L10n.tr("close"), role: .destructive, action: onCloseTab)
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 34, height: 34)
                    }
                }
                .foregroundStyle(palette.foreground)
            }

            if isMarkdown && textContent != nil {
                Picker("", selection: $previewMode) {
                    Text(L10n.tr("reader_preview")).tag(true)
                    Text(L10n.tr("reader_source")).tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            ZStack {
                if loading {
                    ProgressView()
                } else if let errorMsg {
                    VStack(spacing: 12) {
                        Text(errorMsg).font(.subheadline).foregroundStyle(palette.muted)
                        if rawData != nil {
                            Button(L10n.tr("sftp_download")) { showExporter = true }
                                .buttonStyle(.borderedProminent)
                                .tint(palette.primary)
                        }
                    }
                    .padding(24)
                } else if let imageContent {
                    ReaderImageView(image: imageContent, resetToken: $resetImageZoom)
                } else if let doc = document {
                    ReaderWebView(
                        document: doc,
                        colors: palette.readerColors,
                        scrollToHeadingId: scrollToHeading,
                        onCopyCode: { idx in
                            UIPasteboard.general.string = doc.codeBlocks[idx]
                        },
                        onOpenLink: { href in
                            handleLink(href)
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { load() }
        .sheet(isPresented: $showOutline) {
            NavigationStack {
                List(document?.headings ?? []) { h in
                    Button {
                        scrollToHeading = h.id
                        showOutline = false
                    } label: {
                        Text(h.title).padding(.leading, CGFloat(max(0, h.level - 1) * 12))
                    }
                }
                .navigationTitle(L10n.tr("reader_outline"))
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
        .fileExporter(
            isPresented: $showExporter,
            document: BinaryExportDocument(data: rawData ?? Data()),
            contentType: .data,
            defaultFilename: tab.file.name
        ) { _ in }
    }

    private func load() {
        loading = true
        errorMsg = nil
        Task {
            defer { loading = false }
            do {
                let res = try await client.preview(path: tab.file.path)
                rawData = res.data
                if ReaderMarkdown.isImagePath(tab.file.name), let img = UIImage(data: res.data) {
                    imageContent = img
                    textContent = nil
                } else if res.data.contains(0) {
                    errorMsg = L10n.tr("sftp_binary")
                } else if let str = String(data: res.data, encoding: .utf8) {
                    textContent = str
                    imageContent = nil
                } else {
                    errorMsg = L10n.tr("sftp_binary")
                }
            } catch {
                errorMsg = error.localizedDescription
            }
        }
    }

    private func handleLink(_ href: String) {
        if let url = URL(string: href), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            openURL(url)
            return
        }
        if let resolved = ReaderMarkdown.resolveRelativeLink(basePath: tab.file.path, link: href) {
            Task {
                if let entry = try? await client.stat(path: resolved), !entry.isDirectory {
                    onOpenLinkedFile(entry)
                }
            }
        }
    }
}

// MARK: - Desktop Tabs & Desktop File Reader

struct DesktopTabsScreen: View {
    @Environment(\.pebrelPalette) private var palette
    let desktopId: String
    @ObservedObject var repository: SessionRepository
    let onBack: () -> Void
    let onOpenTab: (DesktopTab) -> Void
    let onOpenPane: (DesktopPane) -> Void
    let onDisconnect: () -> Void

    @State private var showNewTerminal = false
    @State private var newTermCwd = ""
    @State private var showOpenFile = false
    @State private var openFilePath = ""
    @State private var showEditAddress = false
    @State private var lanAddressInput = ""

    private var desktop: ManagedDesktopSession? {
        repository.desktops.first { $0.id == desktopId }
    }

    var body: some View {
        VStack(spacing: 0) {
            PebrelPageHeader(desktop?.name ?? L10n.tr("computer_tabs"), subtitle: desktop.map { "\($0.transportLabel) · \($0.status)" }, onBack: onBack) {
                HStack(spacing: 4) {
                    if desktop?.allowInput == true && desktop?.status == "ready" {
                        Menu {
                            Button(L10n.tr("tab_new_terminal")) { newTermCwd = ""; showNewTerminal = true }
                            Button(L10n.tr("tab_open_file")) { openFilePath = ""; showOpenFile = true }
                        } label: {
                            Image(systemName: "plus").frame(width: 36, height: 36)
                        }
                    }
                    Menu {
                        if let profile = desktop?.relayProfile, profile.canRediscover {
                            Button(L10n.tr("computer_edit_address")) {
                                lanAddressInput = profile.url.replacingOccurrences(of: "wss://", with: "")
                                showEditAddress = true
                            }
                        }
                        if let profile = desktop?.relayProfile {
                            Button(L10n.tr("retry")) { _ = repository.connectRelay(profile) }
                        }
                        Button(L10n.tr("disconnect"), role: .destructive, action: onDisconnect)
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 36, height: 36)
                    }
                }
                .foregroundStyle(palette.foreground)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let desktop {
                        if desktop.status == "connecting" {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(L10n.tr("state_connecting")).font(.subheadline).foregroundStyle(palette.foreground)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pebrelGlass(tier: .heavy, cornerRadius: 14)
                        }

                        if let approval = desktop.approval {
                            VStack(spacing: 8) {
                                Text(L10n.tr("pair_awaiting_approval"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(palette.foreground)
                                Text(approval.formattedCode)
                                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                                    .foregroundStyle(palette.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(20)
                            .pebrelGlass(tier: .heavy, cornerRadius: 16)
                        }

                        if let fail = desktop.failure {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(fail.localizedMessage).font(.subheadline).foregroundStyle(palette.error)
                                if let profile = desktop.relayProfile {
                                    Button(L10n.tr("retry")) { _ = repository.connectRelay(profile) }
                                        .buttonStyle(.borderedProminent)
                                        .tint(palette.primary)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pebrelGlass(tier: .heavy, cornerRadius: 14)
                        }

                        ForEach(desktop.tabs) { tab in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Button { onOpenTab(tab) } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: FileSymbol.tabSystemName(kind: tab.kind))
                                                .foregroundStyle(palette.primary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(tab.displayTitle)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(palette.foreground)
                                                Text(tab.file?.path ?? tab.primaryPane?.cwd ?? tab.kind)
                                                    .font(.caption2)
                                                    .foregroundStyle(palette.muted)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            if tab.active {
                                                Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.tertiary)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    if desktop.allowInput && tab.tabId != nil {
                                        Button {
                                            Task { try? await repository.desktopTabsClient(for: desktop.id)?.close(tab) }
                                        } label: {
                                            Image(systemName: "xmark.circle").foregroundStyle(palette.muted)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                if tab.panes.count > 1 {
                                    ForEach(tab.panes) { p in
                                        Button { onOpenPane(p) } label: {
                                            HStack {
                                                Image(systemName: "rectangle.split.2x1").font(.caption).foregroundStyle(palette.muted)
                                                Text(p.displayTitle).font(.caption).foregroundStyle(palette.foreground)
                                                Spacer()
                                                Text(p.cwd).font(.caption2).foregroundStyle(palette.muted).lineLimit(1)
                                            }
                                            .padding(.leading, 26)
                                            .padding(.vertical, 4)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(14)
                            .pebrelGlass(tier: .heavy, cornerRadius: 14)
                        }
                    }
                }
                .padding(16)
            }
        }
        .alert(L10n.tr("tab_new_terminal"), isPresented: $showNewTerminal) {
            TextField("CWD (optional)", text: $newTermCwd).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button(L10n.tr("create")) {
                let win = desktop?.tabs.first?.window
                Task {
                    _ = try? await repository.desktopTabsClient(for: desktopId)?.newTerminal(windowId: win, cwd: newTermCwd)
                }
            }
            Button(L10n.tr("cancel"), role: .cancel) {}
        }
        .alert(L10n.tr("tab_open_file"), isPresented: $showOpenFile) {
            TextField("/path/to/file", text: $openFilePath).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button(L10n.tr("sftp_open")) {
                guard let win = desktop?.tabs.first?.window else { return }
                Task {
                    _ = try? await repository.desktopTabsClient(for: desktopId)?.openFile(windowId: win, path: openFilePath)
                }
            }
            Button(L10n.tr("cancel"), role: .cancel) {}
        }
        .alert(L10n.tr("computer_edit_address"), isPresented: $showEditAddress) {
            TextField(L10n.tr("ios_edit_address_hint"), text: $lanAddressInput)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Button(L10n.tr("save")) {
                if let profile = desktop?.relayProfile {
                    if !repository.updateRelayLanAddress(profile, address: lanAddressInput) {
                        repository.globalError = L10n.tr("service_address_error")
                    }
                }
            }
            Button(L10n.tr("cancel"), role: .cancel) {}
        }
    }
}

struct DesktopFileScreen: View {
    @Environment(\.pebrelPalette) private var palette
    @Environment(\.openURL) private var openURL
    let desktop: ManagedDesktopSession
    let tab: DesktopTab
    @ObservedObject var repository: SessionRepository
    let onBack: () -> Void
    let onSwitcher: () -> Void
    let onOpenTab: (DesktopTab) -> Void

    @State private var loading = true
    @State private var progressFraction: Double = 0
    @State private var loadedRevision: Int64?
    @State private var textContent: String?
    @State private var imageContent: UIImage?
    @State private var previewMode = true
    @State private var errorMsg: String?
    @State private var showOutline = false
    @State private var scrollToHeading: String?
    @State private var resetImageZoom = 0

    private var filePath: String { tab.file?.path ?? tab.displayTitle }
    private var isMarkdown: Bool { ReaderMarkdown.isMarkdownPath(filePath) }

    private var document: ReaderDocument? {
        guard let textContent else { return nil }
        if isMarkdown && previewMode {
            return ReaderMarkdown.prepareMarkdown(text: textContent, colors: palette.readerColors, copyLabel: L10n.tr("reader_copy"))
        }
        return ReaderMarkdown.prepareSource(text: textContent, path: filePath, colors: palette.readerColors, copyLabel: L10n.tr("reader_copy"))
    }

    var body: some View {
        VStack(spacing: 0) {
            PebrelPageHeader(tab.displayTitle, subtitle: desktop.name, onBack: onBack) {
                HStack(spacing: 6) {
                    Button { load() } label: { Image(systemName: "arrow.clockwise").frame(width: 34, height: 34) }
                    Button(action: onSwitcher) { Image(systemName: "rectangle.stack").frame(width: 34, height: 34) }
                    Menu {
                        if let doc = document, !doc.headings.isEmpty {
                            Button(L10n.tr("reader_outline")) { showOutline = true }
                        }
                        if let textContent {
                            Button(L10n.tr("reader_copy")) { UIPasteboard.general.string = textContent }
                        }
                        if imageContent != nil {
                            Button(L10n.tr("reader_reset_zoom")) { resetImageZoom += 1 }
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 34, height: 34)
                    }
                }
                .foregroundStyle(palette.foreground)
            }

            if let loadedRevision, let liveRev = tab.file?.revision, liveRev != loadedRevision {
                HStack {
                    Text(L10n.tr("reader_changed")).font(.caption)
                    Spacer()
                    Button(L10n.tr("refresh")) { load() }.font(.caption.bold())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(palette.surfaceVariant)
            }

            if isMarkdown && textContent != nil {
                Picker("", selection: $previewMode) {
                    Text(L10n.tr("reader_preview")).tag(true)
                    Text(L10n.tr("reader_source")).tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            ZStack {
                if loading {
                    VStack(spacing: 8) {
                        ProgressView(value: progressFraction)
                            .frame(width: 180)
                        Text(L10n.tr("loading")).font(.caption).foregroundStyle(palette.muted)
                    }
                } else if let errorMsg {
                    Text(errorMsg).font(.subheadline).foregroundStyle(palette.error).padding(24)
                } else if let imageContent {
                    ReaderImageView(image: imageContent, resetToken: $resetImageZoom)
                } else if let doc = document {
                    ReaderWebView(
                        document: doc,
                        colors: palette.readerColors,
                        scrollToHeadingId: scrollToHeading,
                        onCopyCode: { idx in UIPasteboard.general.string = doc.codeBlocks[idx] },
                        onOpenLink: { href in handleLink(href) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { load() }
        .sheet(isPresented: $showOutline) {
            NavigationStack {
                List(document?.headings ?? []) { h in
                    Button { scrollToHeading = h.id; showOutline = false } label: {
                        Text(h.title).padding(.leading, CGFloat(max(0, h.level - 1) * 12))
                    }
                }
                .navigationTitle(L10n.tr("reader_outline"))
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
    }

    private func load() {
        guard let tabsClient = repository.desktopTabsClient(for: desktop.id) else {
            errorMsg = L10n.tr("desktop_disconnected")
            loading = false
            return
        }
        loading = true
        errorMsg = nil
        Task {
            defer { loading = false }
            do {
                let payload = try await tabsClient.readFile(tab: tab) { got, total in
                    progressFraction = total > 0 ? Double(got) / Double(total) : 0
                }
                loadedRevision = tab.file?.revision
                if payload.kind == "image" || ReaderMarkdown.isImagePath(filePath), let img = UIImage(data: payload.bytes) {
                    imageContent = img
                    textContent = nil
                } else if let str = String(data: payload.bytes, encoding: .utf8) {
                    textContent = str
                    imageContent = nil
                } else {
                    errorMsg = L10n.tr("sftp_binary")
                }
            } catch {
                errorMsg = error.localizedDescription
            }
        }
    }

    private func handleLink(_ href: String) {
        if let url = URL(string: href), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            openURL(url)
            return
        }
        if let resolved = ReaderMarkdown.resolveRelativeLink(basePath: filePath, link: href) {
            Task {
                if let newTabId = try? await repository.desktopTabsClient(for: desktop.id)?.openFile(windowId: tab.window, path: resolved),
                   let found = repository.desktops.first(where: { $0.id == desktop.id })?.tabs.first(where: { $0.tabId == newTabId }) {
                    onOpenTab(found)
                }
            }
        }
    }
}
