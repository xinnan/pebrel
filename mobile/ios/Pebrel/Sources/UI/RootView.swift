import SwiftUI

enum AppRoute: Equatable {
    case onboarding
    case home
    case hosts
    case computers
    case terminal(sessionId: String)
    case sshChat(sessionId: String, kind: String)
    case sftp(sessionId: String)
    case sftpFile(sessionId: String, tabId: String)
    case desktop(desktopId: String)
    case pane(desktopId: String, windowId: Int64, paneId: Int64, processId: Int64?)
    case desktopFile(desktopId: String, windowId: Int64, tabId: String, processId: Int64?)
    case git(target: DesktopGitTarget)
    case conversation(desktopId: String, windowId: Int64, paneId: Int64, kind: String, session: String, processId: Int64?)
    case settings(initial: String)
}

struct RootView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @ObservedObject var repository: SessionRepository
    @ObservedObject var notificationDelegate: NotificationRouteDelegate

    @State private var route: AppRoute = .home
    @State private var initializedRoute = false
    @State private var sftpPaths: [String: String] = [:]
    @State private var suppressedConversations: Set<String> = []

    // Global sheets & dialogs
    @State private var showSwitcher = false
    @State private var showNewConnection = false
    @State private var showHostForm = false
    @State private var editingHost: HostProfile?
    @State private var deletingHost: HostProfile?
    @State private var loginHost: HostProfile?
    @State private var pendingAttachment: RemoteAttachment?
    @State private var showRelayForm = false
    @State private var showRelayDeploy = false
    @State private var showLocalShellInfo = false
    @State private var pendingSheetAction: (() -> Void)?

    private var basePalette: PebrelPalette {
        PebrelThemeCatalog.shared.palette(
            named: repository.display.themeName,
            systemIsDark: systemColorScheme == .dark
        )
    }

    private var activePalette: PebrelPalette {
        if case .pane(let deskId, let winId, let paneId, _) = route,
           repository.desktopOutput.target == "\(deskId):\(winId):\(paneId)" {
            return basePalette.adoptingDesktopFrame(repository.desktopOutput.frame)
        }
        return basePalette
    }

    var body: some View {
        ZStack {
            activePalette.background.ignoresSafeArea()
            currentScreen
        }
        .environment(\.pebrelPalette, activePalette)
        .preferredColorScheme(activePalette.isDark ? .dark : .light)
        .onAppear {
            if !initializedRoute {
                initializedRoute = true
                route = repository.display.connectionOnboardingCompleted ? .home : .onboarding
            }
            repository.setTerminalColors(basePalette.terminalColors)
        }
        .onChange(of: basePalette) { next in
            repository.setTerminalColors(next.terminalColors)
        }
        .onChange(of: notificationDelegate.pendingDeepLink) { link in
            guard let link else { return }
            notificationDelegate.pendingDeepLink = nil
            if let desk = repository.desktops.first(where: { $0.id == link.desktopId }),
               let pane = desk.panes.first(where: { $0.id == link.paneId && $0.window == link.windowId }) {
                openDesktopPane(desktopId: link.desktopId, pane: pane, processIdOverride: link.processId)
            } else {
                route = .pane(desktopId: link.desktopId, windowId: link.windowId, paneId: link.paneId, processId: link.processId)
            }
        }
        .sheet(isPresented: $showNewConnection, onDismiss: runPendingSheetAction) {
            NewConnectionSheet(
                onComputer: { pendingSheetAction = { showRelayForm = true }; showNewConnection = false },
                onSshHost: { pendingSheetAction = { editingHost = nil; showHostForm = true }; showNewConnection = false },
                onLocalShellInfo: { pendingSheetAction = { showLocalShellInfo = true }; showNewConnection = false },
                onDeployRelay: { pendingSheetAction = { showRelayDeploy = true }; showNewConnection = false }
            )
            .environment(\.pebrelPalette, activePalette)
        }
        .sheet(isPresented: $showSwitcher) {
            SessionSwitcherSheet(
                repository: repository,
                currentSessionId: activeSessionId,
                currentDesktopId: activeDesktopId,
                onNewSshTab: { sid in
                    if let newId = repository.newSshTab(from: sid) {
                        showSwitcher = false
                        route = .terminal(sessionId: newId)
                    }
                },
                onOpenHosts: { showSwitcher = false; route = .hosts },
                onOpenSession: { sid in showSwitcher = false; openSshSession(sessionId: sid) },
                onOpenSftpTab: { tab in showSwitcher = false; route = .sftpFile(sessionId: tab.sessionId, tabId: tab.id) },
                onCloseSftpTab: { tab in repository.closeSftpTab(id: tab.id) },
                onOpenDesktop: { did in showSwitcher = false; route = .desktop(desktopId: did) },
                onOpenDesktopTab: { did, tab in showSwitcher = false; openDesktopTab(desktopId: did, tab: tab) },
                onOpenDesktopPane: { did, pane in showSwitcher = false; openDesktopPane(desktopId: did, pane: pane) }
            )
            .environment(\.pebrelPalette, activePalette)
        }
        .sheet(isPresented: $showHostForm) {
            HostFormSheet(
                initial: editingHost,
                repository: repository,
                allowConnect: true,
                onSaved: { host, secret, connectNow in
                    showHostForm = false
                    finishOnboardingIfNeeded()
                    if connectNow, let secret {
                        let sid = repository.openSsh(host: host, password: secret)
                        route = .terminal(sessionId: sid)
                    }
                }
            )
            .environment(\.pebrelPalette, activePalette)
        }
        .sheet(item: $loginHost) { host in
            LoginFormSheet(
                host: host,
                repository: repository,
                attachmentLabel: pendingAttachment?.title,
                onConnect: { secret, asDesktop, allowInput in
                    let att = pendingAttachment
                    pendingAttachment = nil
                    loginHost = nil
                    finishOnboardingIfNeeded()
                    if asDesktop {
                        let did = repository.connectDesktopOverSsh(host: host, password: secret, allowInput: allowInput)
                        route = .desktop(desktopId: did)
                    } else {
                        let sid = repository.openSsh(host: host, password: secret, attachment: att)
                        route = .terminal(sessionId: sid)
                    }
                }
            )
            .environment(\.pebrelPalette, activePalette)
        }
        .sheet(isPresented: $showRelayForm, onDismiss: runPendingSheetAction) {
            RelayFormSheet(
                onConnect: { rawJSON in
                    if let did = repository.importRelayInvitation(rawJSON) {
                        showRelayForm = false
                        finishOnboardingIfNeeded()
                        route = .desktop(desktopId: did)
                    }
                },
                onConnectProfile: { profile in
                    let did = repository.connectRelay(profile)
                    showRelayForm = false
                    finishOnboardingIfNeeded()
                    route = .desktop(desktopId: did)
                },
                onDeploy: {
                    pendingSheetAction = { showRelayDeploy = true }
                    showRelayForm = false
                }
            )
            .environment(\.pebrelPalette, activePalette)
        }
        .sheet(isPresented: $showRelayDeploy) {
            RelayDeploymentSheet(repository: repository)
                .environment(\.pebrelPalette, activePalette)
        }
        .alert(L10n.tr("delete_host"), isPresented: Binding(
            get: { deletingHost != nil },
            set: { if !$0 { deletingHost = nil } }
        )) {
            Button(L10n.tr("delete_host"), role: .destructive) {
                if let host = deletingHost {
                    repository.deleteHost(host)
                    deletingHost = nil
                }
            }
            Button(L10n.tr("cancel"), role: .cancel) { deletingHost = nil }
        } message: {
            if let host = deletingHost {
                Text(L10n.tr("delete_host_confirm", host.name))
            }
        }
        .alert(L10n.tr("ios_local_shell_title"), isPresented: $showLocalShellInfo) {
            Button(L10n.tr("close"), role: .cancel) {}
        } message: {
            Text(L10n.tr("ios_local_shell_body"))
        }
        .alert(L10n.tr("verify_host"), isPresented: Binding(
            get: {
                guard let req = repository.trustRequest else { return false }
                if case .terminal(let sid) = route, req.ownerId == sid { return false }
                return true
            },
            set: { if !$0 { repository.answerTrust(accepted: false) } }
        )) {
            Button(L10n.tr("trust_connect")) { repository.answerTrust(accepted: true) }
            Button(L10n.tr("cancel"), role: .cancel) { repository.answerTrust(accepted: false) }
        } message: {
            if let req = repository.trustRequest {
                Text("\(req.host.name) (\(req.host.endpointLabel))\n\n\(req.fingerprint)")
            }
        }
        .alert(L10n.tr("operation_failed"), isPresented: Binding(
            get: { repository.globalError != nil },
            set: { if !$0 { repository.globalError = nil } }
        )) {
            Button(L10n.tr("close"), role: .cancel) { repository.globalError = nil }
        } message: {
            Text(repository.globalError ?? "")
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch route {
        case .onboarding:
            OnboardingView(
                onComputer: { showRelayForm = true },
                onSshHost: { editingHost = nil; showHostForm = true },
                onLocalShellInfo: { showLocalShellInfo = true },
                onLater: {
                    repository.display.completeConnectionOnboarding()
                    route = .home
                }
            )

        case .home:
            HomeView(
                repository: repository,
                onOpenSession: { openSshSession(sessionId: $0) },
                onOpenSwitcher: { showSwitcher = true },
                onOpenHosts: { route = .hosts },
                onConnectHost: { connectHost($0) },
                onEditHost: { editingHost = $0; showHostForm = true },
                onDeleteHost: { deletingHost = $0 },
                onAddHost: { editingHost = nil; showHostForm = true },
                onOpenDesktop: { route = .desktop(desktopId: $0) },
                onConnectRelay: { did in route = .desktop(desktopId: repository.connectRelay(did)) },
                onOpenComputers: { route = .computers },
                onAddRelay: { showRelayForm = true },
                onDeployRelay: { showRelayDeploy = true },
                onOpenPane: { did, pane in openDesktopPane(desktopId: did, pane: pane) },
                onOpenTab: { did, tab in openDesktopTab(desktopId: did, tab: tab) },
                onOpenSettings: { initial in route = .settings(initial: initial) },
                onOpenNewSheet: { showNewConnection = true },
                onLocalShellInfo: { showLocalShellInfo = true }
            )

        case .hosts:
            HostsScreen(
                hosts: repository.hosts,
                onBack: { route = .home },
                onAdd: { editingHost = nil; showHostForm = true },
                onConnect: { connectHost($0) },
                onEdit: { editingHost = $0; showHostForm = true },
                onDelete: { deletingHost = $0 }
            )

        case .computers:
            ComputersScreen(
                repository: repository,
                onBack: { route = .home },
                onOpenDesktop: { route = .desktop(desktopId: $0) },
                onConnectRelay: { profile in route = .desktop(desktopId: repository.connectRelay(profile)) },
                onAddRelay: { showRelayForm = true }
            )

        case .terminal(let sessionId):
            if let session = repository.sessions.first(where: { $0.id == sessionId }) {
                SshTerminalScreen(
                    session: session,
                    repository: repository,
                    onBack: { route = .home },
                    onSwitcher: { showSwitcher = true },
                    onEditHost: {
                        editingHost = repository.hosts.first(where: { $0.id == session.host.id }) ?? session.host
                        showHostForm = true
                        repository.closeTerminal(id: session.id)
                        route = .home
                    },
                    onClose: {
                        repository.closeTerminal(id: session.id)
                        route = .home
                    },
                    onOpenSftp: { route = .sftp(sessionId: session.id) },
                    onOpenConversation: { kind in
                        suppressedConversations.remove(ConversationAutoEntry.sshKey(sessionId: session.id, kind: kind))
                        route = .sshChat(sessionId: session.id, kind: kind)
                    },
                    onAttachRemote: { att in
                        if let newId = repository.newSshTab(from: session.id, attachment: att) {
                            route = .terminal(sessionId: newId)
                        }
                    }
                )
                .id(sessionId)
                .onAppear {
                    maybeAutoEnterSshConversation(session: session)
                }
                .onChange(of: session.foreground) { _ in
                    maybeAutoEnterSshConversation(session: session)
                }
                .onChange(of: session.status) { _ in
                    maybeAutoEnterSshConversation(session: session)
                }
            } else {
                Color.clear.onAppear { route = .home }
            }

        case .sshChat(let sessionId, let kind):
            if let session = repository.sessions.first(where: { $0.id == sessionId }) {
                SshConversationScreen(
                    session: session,
                    kind: kind,
                    repository: repository,
                    onBack: { route = .home },
                    onOpenTerminal: {
                        suppressedConversations.insert(ConversationAutoEntry.sshKey(sessionId: sessionId, kind: kind))
                        route = .terminal(sessionId: sessionId)
                    },
                    onSwitcher: { showSwitcher = true }
                )
                .id("\(sessionId):\(kind)")
            } else {
                Color.clear.onAppear { route = .home }
            }

        case .sftp(let sessionId):
            if let session = repository.sessions.first(where: { $0.id == sessionId }),
               let client = repository.sftpClient(for: sessionId) {
                SftpBrowserScreen(
                    session: session,
                    client: client,
                    path: Binding(
                        get: { sftpPaths[sessionId] ?? "." },
                        set: { sftpPaths[sessionId] = $0 }
                    ),
                    onBack: { route = .terminal(sessionId: sessionId) },
                    onOpenFile: { entry in
                        let tab = repository.openSftpTab(sessionId: sessionId, entry: entry)
                        route = .sftpFile(sessionId: sessionId, tabId: tab.id)
                    }
                )
                .id(sessionId)
            } else {
                Color.clear.onAppear { route = .home }
            }

        case .sftpFile(let sessionId, let tabId):
            if let session = repository.sessions.first(where: { $0.id == sessionId }),
               let client = repository.sftpClient(for: sessionId),
               let tab = repository.sftpTabs.first(where: { $0.id == tabId && $0.sessionId == sessionId }) {
                SftpFileScreen(
                    session: session,
                    client: client,
                    tab: tab,
                    onBack: { route = .sftp(sessionId: sessionId) },
                    onSwitcher: { showSwitcher = true },
                    onOpenLinkedFile: { entry in
                        let nextTab = repository.openSftpTab(sessionId: sessionId, entry: entry)
                        route = .sftpFile(sessionId: sessionId, tabId: nextTab.id)
                    },
                    onCloseTab: {
                        repository.closeSftpTab(id: tab.id)
                        if let next = repository.sftpTabs.last(where: { $0.sessionId == sessionId }) {
                            route = .sftpFile(sessionId: sessionId, tabId: next.id)
                        } else {
                            route = .sftp(sessionId: sessionId)
                        }
                    }
                )
                .id("\(sessionId):\(tabId)")
            } else {
                Color.clear.onAppear { route = .sftp(sessionId: sessionId) }
            }

        case .desktop(let desktopId):
            DesktopTabsScreen(
                desktopId: desktopId,
                repository: repository,
                onBack: { route = .home },
                onOpenTab: { tab in openDesktopTab(desktopId: desktopId, tab: tab) },
                onOpenPane: { pane in openDesktopPane(desktopId: desktopId, pane: pane) },
                onDisconnect: {
                    repository.closeDesktop(id: desktopId)
                    route = .home
                }
            )
            .id(desktopId)

        case .pane(let desktopId, let windowId, let paneId, let processId):
            if let desktop = repository.desktops.first(where: { $0.id == desktopId }),
               let pane = desktop.panes.first(where: { $0.id == paneId && $0.window == windowId }),
               (processId == nil || processId == desktop.runtimeProcess) {
                DesktopTerminalScreen(
                    desktop: desktop,
                    pane: pane,
                    repository: repository,
                    onBack: { route = .desktop(desktopId: desktopId) },
                    onSwitcher: { showSwitcher = true },
                    onOpenGit: {
                        let target = DesktopGitTarget(
                            desktopId: desktopId,
                            windowId: windowId,
                            paneId: paneId,
                            cwd: pane.cwd,
                            generation: desktop.connectionGeneration,
                            runtimeProcess: desktop.runtimeProcess ?? 0
                        )
                        route = .git(target: target)
                    },
                    onOpenConversation: {
                        if let ag = pane.agent {
                            let sid = ag.sessionId ?? ""
                            if !sid.isEmpty {
                                suppressedConversations.remove(ConversationAutoEntry.desktopKey(
                                    desktopId: desktopId,
                                    windowId: windowId,
                                    paneId: paneId,
                                    kind: ag.kind,
                                    session: sid
                                ))
                            }
                            route = .conversation(
                                desktopId: desktopId,
                                windowId: windowId,
                                paneId: paneId,
                                kind: ag.kind,
                                session: sid,
                                processId: desktop.runtimeProcess
                            )
                        }
                    }
                )
                .id("\(desktopId):\(windowId):\(paneId)")
                .onAppear {
                    maybeAutoEnterDesktopConversation(desktop: desktop, pane: pane, processId: processId)
                }
                .onChange(of: pane.agent) { _ in
                    maybeAutoEnterDesktopConversation(desktop: desktop, pane: pane, processId: processId)
                }
            } else {
                DesktopSessionChangedView(
                    reconnecting: repository.desktops.first(where: { $0.id == desktopId })?.status == "connecting",
                    onBack: { route = .desktop(desktopId: desktopId) }
                )
            }

        case .desktopFile(let desktopId, let windowId, let tabId, let processId):
            if let desktop = repository.desktops.first(where: { $0.id == desktopId }),
               let tab = desktop.tabs.first(where: { $0.tabId == tabId && $0.window == windowId }),
               tab.readable,
               (processId == nil || processId == desktop.runtimeProcess) {
                DesktopFileScreen(
                    desktop: desktop,
                    tab: tab,
                    repository: repository,
                    onBack: { route = .desktop(desktopId: desktopId) },
                    onSwitcher: { showSwitcher = true },
                    onOpenTab: { next in openDesktopTab(desktopId: desktopId, tab: next) }
                )
                .id("\(desktopId):\(windowId):\(tabId)")
            } else {
                DesktopSessionChangedView(
                    reconnecting: repository.desktops.first(where: { $0.id == desktopId })?.status == "connecting",
                    onBack: { route = .desktop(desktopId: desktopId) }
                )
            }

        case .git(let target):
            GitScreen(
                target: target,
                repository: repository,
                onBack: {
                    route = .pane(
                        desktopId: target.desktopId,
                        windowId: target.windowId,
                        paneId: target.paneId,
                        processId: target.runtimeProcess
                    )
                }
            )
            .id("\(target.desktopId):\(target.windowId):\(target.paneId)")

        case .conversation(let desktopId, let windowId, let paneId, let kind, let session, let processId):
            if let desktop = repository.desktops.first(where: { $0.id == desktopId }),
               let pane = desktop.panes.first(where: { $0.id == paneId && $0.window == windowId }),
               (processId == nil || processId == desktop.runtimeProcess) {
                let effectiveSession = session.isEmpty ? (pane.agent?.kind == kind ? (pane.agent?.sessionId ?? "") : "") : session
                if DesktopConversation.supportedKinds.contains(kind) && !effectiveSession.isEmpty {
                    DesktopConversationScreen(
                        desktop: desktop,
                        pane: pane,
                        identity: ConversationIdentity(kind: kind, session: effectiveSession, epoch: nil),
                        repository: repository,
                        onBack: {
                            route = .desktop(desktopId: desktopId)
                        },
                        onOpenTerminal: {
                            suppressedConversations.insert(ConversationAutoEntry.desktopKey(
                                desktopId: desktopId,
                                windowId: windowId,
                                paneId: paneId,
                                kind: kind,
                                session: effectiveSession
                            ))
                            route = .pane(desktopId: desktopId, windowId: windowId, paneId: paneId, processId: processId)
                        },
                        onSwitcher: { showSwitcher = true },
                        onOpenTab: { tab in openDesktopTab(desktopId: desktopId, tab: tab) }
                    )
                    .id("\(desktopId):\(windowId):\(paneId):\(kind):\(effectiveSession)")
                } else {
                    VStack(spacing: 0) {
                        PebrelPageHeader(L10n.tr("chat_title"), onBack: {
                            route = .desktop(desktopId: desktopId)
                        })
                        VStack(spacing: 12) {
                            Text(L10n.tr("chat_unavailable"))
                                .font(.subheadline)
                                .foregroundStyle(activePalette.muted)
                                .multilineTextAlignment(.center)
                            Button(L10n.tr("ios_session_terminal")) {
                                route = .pane(desktopId: desktopId, windowId: windowId, paneId: paneId, processId: processId)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(activePalette.primary)
                        }
                        .padding(24)
                        Spacer()
                    }
                }
            } else {
                DesktopSessionChangedView(
                    reconnecting: false,
                    onBack: { route = .desktop(desktopId: desktopId) }
                )
            }

        case .settings(let initial):
            SettingsScreen(
                repository: repository,
                initialSubpage: initial,
                onBack: { route = .home },
                onOpenComputers: { route = .computers }
            )
        }
    }

    private var activeSessionId: String? {
        switch route {
        case .terminal(let id), .sshChat(let id, _), .sftp(let id), .sftpFile(let id, _):
            return id
        default:
            return nil
        }
    }

    private var activeDesktopId: String? {
        switch route {
        case .desktop(let id), .pane(let id, _, _, _), .desktopFile(let id, _, _, _), .conversation(let id, _, _, _, _, _):
            return id
        case .git(let target):
            return target.desktopId
        default:
            return nil
        }
    }

    private func finishOnboardingIfNeeded() {
        if route == .onboarding {
            repository.display.completeConnectionOnboarding()
        }
    }

    private func runPendingSheetAction() {
        guard let action = pendingSheetAction else { return }
        pendingSheetAction = nil
        action()
    }

    private func connectHost(_ host: HostProfile, attachment: RemoteAttachment? = nil) {
        if !repository.hasSavedPassword(for: host) && !host.hasPrivateKey {
            pendingAttachment = attachment
            loginHost = host
            return
        }
        if let secret = repository.passwordForConnection(host, explicit: nil) {
            let sid = repository.openSsh(host: host, password: secret, attachment: attachment)
            route = .terminal(sessionId: sid)
        } else {
            pendingAttachment = attachment
            loginHost = host
        }
    }

    private func openSshSession(sessionId: String) {
        if let session = repository.sessions.first(where: { $0.id == sessionId }),
           let kind = ConversationAutoEntry.sshKind(for: session) {
            suppressedConversations.remove(ConversationAutoEntry.sshKey(sessionId: sessionId, kind: kind))
            route = .sshChat(sessionId: sessionId, kind: kind)
        } else {
            route = .terminal(sessionId: sessionId)
        }
    }

    private func openDesktopPane(desktopId: String, pane: DesktopPane, processIdOverride: Int64? = nil) {
        let proc = processIdOverride ?? repository.desktops.first(where: { $0.id == desktopId })?.runtimeProcess
        if let target = ConversationAutoEntry.desktopTarget(for: pane) {
            suppressedConversations.remove(ConversationAutoEntry.desktopKey(
                desktopId: desktopId,
                windowId: pane.window,
                paneId: pane.id,
                kind: target.kind,
                session: target.session
            ))
            route = .conversation(
                desktopId: desktopId,
                windowId: pane.window,
                paneId: pane.id,
                kind: target.kind,
                session: target.session,
                processId: proc
            )
        } else {
            route = .pane(desktopId: desktopId, windowId: pane.window, paneId: pane.id, processId: proc)
        }
    }

    private func maybeAutoEnterDesktopConversation(
        desktop: ManagedDesktopSession,
        pane: DesktopPane,
        processId: Int64?
    ) {
        guard case .pane(let curDesk, let curWin, let curPane, _) = route,
              curDesk == desktop.id, curWin == pane.window, curPane == pane.id else {
            return
        }
        if let target = ConversationAutoEntry.desktopTarget(for: pane) {
            let key = ConversationAutoEntry.desktopKey(
                desktopId: desktop.id,
                windowId: pane.window,
                paneId: pane.id,
                kind: target.kind,
                session: target.session
            )
            guard !suppressedConversations.contains(key) else { return }
            route = .conversation(
                desktopId: desktop.id,
                windowId: pane.window,
                paneId: pane.id,
                kind: target.kind,
                session: target.session,
                processId: processId ?? desktop.runtimeProcess
            )
        } else if pane.agent == nil {
            let prefix = ConversationAutoEntry.desktopPanePrefix(
                desktopId: desktop.id,
                windowId: pane.window,
                paneId: pane.id
            )
            suppressedConversations = suppressedConversations.filter { !$0.hasPrefix(prefix) }
        }
    }

    private func maybeAutoEnterSshConversation(session: ManagedTerminalSession) {
        guard case .terminal(let curSid) = route, curSid == session.id else { return }
        if let kind = ConversationAutoEntry.sshKind(for: session) {
            let key = ConversationAutoEntry.sshKey(sessionId: session.id, kind: kind)
            guard !suppressedConversations.contains(key) else { return }
            route = .sshChat(sessionId: session.id, kind: kind)
        } else if session.foreground?.agent == nil {
            let prefix = ConversationAutoEntry.sshSessionPrefix(sessionId: session.id)
            suppressedConversations = suppressedConversations.filter { !$0.hasPrefix(prefix) }
        }
    }

    private func openDesktopTab(desktopId: String, tab: DesktopTab) {
        guard let desk = repository.desktops.first(where: { $0.id == desktopId }) else { return }
        if desk.allowInput && desk.status == "ready" && tab.tabId != nil && !tab.active {
            Task { try? await repository.desktopTabsClient(for: desktopId)?.focus(tab) }
        }
        if let pane = tab.primaryPane {
            openDesktopPane(desktopId: desktopId, pane: pane)
        } else if tab.readable, let tid = tab.tabId {
            route = .desktopFile(desktopId: desktopId, windowId: tab.window, tabId: tid, processId: desk.runtimeProcess)
        }
    }
}

private struct DesktopSessionChangedView: View {
    @Environment(\.pebrelPalette) private var palette
    let reconnecting: Bool
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PebrelPageHeader(L10n.tr("computer_tabs"), onBack: onBack)
            VStack(spacing: 14) {
                Text(reconnecting ? L10n.tr("desktop_reconnecting") : L10n.tr("desktop_session_changed"))
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)
                    .multilineTextAlignment(.center)
                Button(L10n.tr("computer_tabs"), action: onBack)
                    .buttonStyle(.borderedProminent)
                    .tint(palette.primary)
            }
            .padding(24)
            Spacer()
        }
    }
}
