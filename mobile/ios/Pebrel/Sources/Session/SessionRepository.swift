import Combine
import Foundation
import Network

struct HostTrustRequest: Identifiable, Equatable {
    let id = UUID()
    let ownerId: String
    let host: HostProfile
    let fingerprint: String
}

struct ManagedTerminalSession: Identifiable, Equatable {
    let id: String
    let host: HostProfile
    let attachment: RemoteAttachment?
    var title: String
    var status: String // "connecting" | "ready" | "failed" | "ended"
    var stage: SshStage
    var failure: SshFailureKind?
    var hasConnected: Bool
    var foreground: SshForeground?
    var previewText: String
    var frame: TerminalFrame?

    static func == (lhs: ManagedTerminalSession, rhs: ManagedTerminalSession) -> Bool {
        lhs.id == rhs.id &&
        lhs.host == rhs.host &&
        lhs.title == rhs.title &&
        lhs.status == rhs.status &&
        lhs.stage == rhs.stage &&
        lhs.failure == rhs.failure &&
        lhs.hasConnected == rhs.hasConnected &&
        lhs.foreground == rhs.foreground &&
        lhs.previewText == rhs.previewText &&
        lhs.frame == rhs.frame
    }
}

struct ManagedDesktopSession: Identifiable, Equatable {
    let id: String
    var name: String
    var hostIcon: String
    var transportLabel: String
    var relayProfile: RelayProfile?
    var sshHost: HostProfile?
    var status: String // "connecting" | "ready" | "failed"
    var allowInput: Bool
    var hasConnected: Bool
    var failure: DesktopFailureKind?
    var approval: DesktopPairingApproval?
    var runtimeProcess: Int64?
    var connectionGeneration: Int64
    var tabs: [DesktopTab]
    var panes: [DesktopPane]
}

/// Central application repository owning live SSH sessions, paired Desktop workspaces,
/// SFTP tabs, drafts, saved hosts/relays, foreground reconnect probes, and mDNS auto-recovery.
@MainActor
final class SessionRepository: ObservableObject {
    let display = DisplayPreferences()
    let shortcuts = ShortcutPreferences()
    let commandUsage = CommandUsageStore()

    @Published private(set) var sessions: [ManagedTerminalSession] = []
    @Published private(set) var sftpTabs: [SftpTab] = []
    @Published private(set) var desktops: [ManagedDesktopSession] = []
    @Published private(set) var hosts: [HostProfile] = []
    @Published private(set) var relays: [RelayProfile] = []
    @Published private(set) var savedPasswordIds: Set<String> = []
    @Published private(set) var desktopOutput = DesktopOutputState()
    @Published var trustRequest: HostTrustRequest?
    @Published var globalError: String?

    private let hostStore = HostStore()
    private let relayStore = RelayProfileStore()
    private let desktopReconnect = DesktopReconnectScheduler()
    private let lanRecovery = PairingDiscovery()
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "io.github.kuddev.pebrel.network")

    private var sshConnections: [String: SshConnection] = [:]
    private var terminalSessions: [String: TerminalSession] = [:]
    private var sftpClients: [String: SftpClient] = [:]
    private var liveSshSecrets: [String: ZeroizedBytes] = [:]
    private var sshReconnectTasks: [String: Task<Void, Never>] = [:]
    private var sshForegroundTasks: [String: Task<Void, Never>] = [:]

    private var desktopClients: [String: DesktopRuntimeClient] = [:]
    private var desktopTasks: [String: Task<Void, Never>] = [:]
    private var desktopTransitions: [String: DesktopTransitions] = [:]
    private var screenWatchTask: Task<Void, Never>?
    private var screenSync = DesktopScreenSync()
    private var screenHistoryStart: Int64?
    private var screenWakeContinuation: CheckedContinuation<Void, Never>?
    private var trustContinuation: CheckedContinuation<Bool, Never>?

    private var drafts: [String: String] = [:]
    private var currentTerminalColors: [UInt32] = []
    private var nextGeneration: Int64 = 1
    private var isForeground = true
    private var lastNetworkStatus: NWPath.Status?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        self.hosts = hostStore.load()
        self.relays = relayStore.load()
        self.savedPasswordIds = KeychainStore.shared.savedPasswordIds()
        self.currentTerminalColors = PebrelThemeCatalog.shared
            .palette(named: display.themeName, systemIsDark: false)
            .terminalColors

        display.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        shortcuts.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        lanRecovery.onDiscovered = { [weak self] computer in
            Task { @MainActor in self?.handleDiscoveredLanComputer(computer) }
        }
        startNetworkMonitor()
    }

    // MARK: - Theme & Drafts

    func setTerminalColors(_ colors19: [UInt32]) {
        guard colors19.count == 19 else { return }
        currentTerminalColors = colors19
        for session in terminalSessions.values {
            session.setColors(colors19)
        }
    }

    func draft(for key: String) -> String { drafts[key] ?? "" }
    func setDraft(_ value: String, for key: String) { drafts[key] = value }

    // MARK: - Lifecycle

    func foregroundChanged(_ foreground: Bool) {
        isForeground = foreground
        desktopReconnect.setForeground(foreground)
        if foreground {
            probeReadyDesktops()
            refreshLanRecovery()
        } else {
            lanRecovery.stop()
        }
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = self.lastNetworkStatus != nil && self.lastNetworkStatus != path.status
                self.lastNetworkStatus = path.status
                guard changed, self.isForeground, path.status == .satisfied else { return }
                self.handleNetworkRestored()
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func handleNetworkRestored() {
        for desktop in desktops where desktop.hasConnected {
            if let profile = desktop.relayProfile {
                if desktop.status == "ready", let client = desktopClients[desktop.id] {
                    Task {
                        let ok = await client.probeHealth()
                        if !ok {
                            client.close()
                            self.desktopFailed(id: desktop.id, kind: .network, immediate: true)
                        }
                    }
                } else if desktop.failure?.isRetryable != false {
                    _ = connectRelay(profile)
                }
            }
        }
        refreshLanRecovery()
    }

    private func probeReadyDesktops() {
        for desktop in desktops where desktop.status == "ready" {
            guard let client = desktopClients[desktop.id], !client.recentlyActive else { continue }
            Task {
                let ok = await client.probeHealth()
                if !ok {
                    client.close()
                    self.desktopFailed(id: desktop.id, kind: .network, immediate: true)
                }
            }
        }
    }

    private func refreshLanRecovery() {
        let needsDiscovery = isForeground && desktops.contains { d in
            d.hasConnected && d.status != "ready" && d.approval == nil &&
            d.relayProfile?.canRediscover == true && d.failure?.isRetryable != false
        }
        if needsDiscovery {
            lanRecovery.start()
        } else {
            lanRecovery.stop()
        }
    }

    private func handleDiscoveredLanComputer(_ computer: DiscoveredComputer) {
        for index in relays.indices {
            if let updated = relays[index].discoveredAt(address: computer.address, pin: computer.pin) {
                relays[index] = updated
                relayStore.save(relays)
                if let desk = desktops.first(where: { $0.id == updated.workspaceId && $0.status != "ready" }) {
                    _ = connectRelay(updated)
                    _ = desk
                }
            }
        }
    }

    // MARK: - Host Management & Credentials

    func hasSavedPassword(for host: HostProfile) -> Bool {
        savedPasswordIds.contains(host.id) && KeychainStore.shared.hasSavedPassword(for: host.id)
    }

    func clearHostPassword(_ host: HostProfile) {
        KeychainStore.shared.deleteHostPassword(for: host.id)
        savedPasswordIds = KeychainStore.shared.savedPasswordIds()
    }

    func saveHost(_ host: HostProfile, password: ZeroizedBytes?, rememberPassword: Bool) -> Bool {
        if rememberPassword, let password, !password.isEmpty {
            guard KeychainStore.shared.saveHostPassword(password, for: host.id) else {
                globalError = L10n.tr("credential_save_failed")
                return false
            }
            savedPasswordIds = KeychainStore.shared.savedPasswordIds()
        }
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
        hostStore.save(hosts)
        return true
    }

    func deleteHost(_ host: HostProfile) {
        KeychainStore.shared.deleteHostPassword(for: host.id)
        if !host.keyId.isEmpty {
            KeychainStore.shared.deletePrivateKey(for: host.keyId)
        }
        hosts.removeAll { $0.id == host.id }
        hostStore.save(hosts)
        savedPasswordIds = KeychainStore.shared.savedPasswordIds()
    }

    func passwordForConnection(_ host: HostProfile, explicit: ZeroizedBytes?) -> ZeroizedBytes? {
        if let explicit, !explicit.isEmpty {
            return ZeroizedBytes(explicit.copyBytes())
        }
        if let saved = KeychainStore.shared.loadHostPassword(for: host.id) {
            return saved
        }
        if host.hasPrivateKey {
            return ZeroizedBytes([]) // Allow unencrypted private key
        }
        return nil
    }

    // MARK: - Trust Prompt

    func answerTrust(accepted: Bool) {
        let cont = trustContinuation
        trustContinuation = nil
        trustRequest = nil
        cont?.resume(returning: accepted)
    }

    func requestHostTrust(ownerId: String, host: HostProfile, fingerprint: String) async -> Bool {
        trustContinuation?.resume(returning: false)
        trustContinuation = nil
        return await withCheckedContinuation { cont in
            trustRequest = HostTrustRequest(ownerId: ownerId, host: host, fingerprint: fingerprint)
            trustContinuation = cont
        }
    }

    private func persistHostFingerprint(hostId: String, fingerprint: String) {
        if let idx = hosts.firstIndex(where: { $0.id == hostId }) {
            hosts[idx].fingerprint = fingerprint
            hostStore.save(hosts)
        }
    }

    // MARK: - SSH Sessions

    func openSsh(host: HostProfile, password: ZeroizedBytes, attachment: RemoteAttachment? = nil) -> String {
        DesktopNotificationCenter.requestAuthorizationIfNeeded()
        let id = "ssh:\(UUID().uuidString)"
        let title = attachment?.title ?? host.name
        let term = TerminalSession(
            columns: 80,
            rows: 24,
            scrollback: display.preferences.scrollbackLines,
            colors: currentTerminalColors
        )
        terminalSessions[id] = term
        liveSshSecrets[id] = ZeroizedBytes(password.copyBytes())

        let model = ManagedTerminalSession(
            id: id,
            host: host,
            attachment: attachment,
            title: title,
            status: "connecting",
            stage: .network,
            failure: nil,
            hasConnected: false,
            foreground: nil,
            previewText: "",
            frame: term.latestFrame()
        )
        sessions.append(model)

        term.onFrame = { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self, let idx = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                self.sessions[idx].frame = frame
                let preview = frame.previewText(maxLines: 6)
                if !preview.isEmpty { self.sessions[idx].previewText = preview }
            }
        }
        term.onTitle = { [weak self] newTitle in
            Task { @MainActor [weak self] in
                guard let self, !newTitle.isEmpty,
                      let idx = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                self.sessions[idx].title = newTitle
            }
        }

        startSshConnection(id: id, reconnecting: false)
        return id
    }

    func newSshTab(from sourceId: String, attachment: RemoteAttachment? = nil) -> String? {
        guard let existing = sessions.first(where: { $0.id == sourceId }) else { return nil }
        let secret = liveSshSecrets[sourceId] ?? passwordForConnection(existing.host, explicit: nil)
        guard let secret else { return nil }
        return openSsh(host: existing.host, password: secret, attachment: attachment)
    }

    func retrySsh(id: String, newPassword: ZeroizedBytes? = nil) {
        if let newPassword {
            liveSshSecrets[id] = ZeroizedBytes(newPassword.copyBytes())
        }
        sshReconnectTasks[id]?.cancel()
        sshReconnectTasks.removeValue(forKey: id)
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].status = "connecting"
        sessions[idx].failure = nil
        sessions[idx].stage = .network
        startSshConnection(id: id, reconnecting: sessions[idx].hasConnected)
    }

    func closeTerminal(id: String) {
        sshReconnectTasks[id]?.cancel()
        sshReconnectTasks.removeValue(forKey: id)
        sshForegroundTasks[id]?.cancel()
        sshForegroundTasks.removeValue(forKey: id)
        sshConnections[id]?.close()
        sshConnections.removeValue(forKey: id)
        terminalSessions[id]?.close()
        terminalSessions.removeValue(forKey: id)
        sftpClients.removeValue(forKey: id)
        liveSshSecrets[id]?.wipe()
        liveSshSecrets.removeValue(forKey: id)
        sftpTabs.removeAll { $0.sessionId == id }
        sessions.removeAll { $0.id == id }
    }

    func terminalSession(for id: String) -> TerminalSession? {
        terminalSessions[id]
    }

    func sftpClient(for sessionId: String) -> SftpClient? {
        sftpClients[sessionId]
    }

    func sshConnection(for sessionId: String) -> SshConnection? {
        sshConnections[sessionId]
    }

    func openSftpTab(sessionId: String, entry: SftpEntry) -> SftpTab {
        if let existing = sftpTabs.first(where: { $0.sessionId == sessionId && $0.file.path == entry.path }) {
            return existing
        }
        let tab = SftpTab(id: UUID().uuidString, sessionId: sessionId, file: entry)
        sftpTabs.append(tab)
        return tab
    }

    func closeSftpTab(id: String) {
        sftpTabs.removeAll { $0.id == id }
    }

    func discoverRemoteSessions(for sessionId: String) async -> [RemoteSessionEntry] {
        guard let conn = sshConnections[sessionId], conn.isReady else { return [] }
        let discovered = await RemoteSessions.discover { cmd in try await conn.query(cmd) }
        return discovered.sessions
    }

    func makeSshConversation(for sessionId: String, kind: String) -> SshConversation? {
        guard let conn = sshConnections[sessionId],
              let scriptURL = Bundle.main.url(forResource: "ssh_agent_chat", withExtension: "py"),
              let scriptData = try? Data(contentsOf: scriptURL) else {
            return nil
        }
        let client = SshAgentChatClient(scriptData: scriptData) { cmd in try await conn.query(cmd) }
        return SshConversation(
            kind: kind,
            chat: client,
            terminal: { [weak self] in self?.terminalSessions[sessionId] },
            isReady: { [weak self] in self?.sessions.first(where: { $0.id == sessionId })?.status == "ready" }
        )
    }

    private func startSshConnection(id: String, reconnecting: Bool) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }),
              let term = terminalSessions[id] else { return }
        let sessionModel = sessions[idx]
        let host = hosts.first(where: { $0.id == sessionModel.host.id }) ?? sessionModel.host

        sshConnections[id]?.close()
        let conn = SshConnection(host: host, attachment: sessionModel.attachment)
        sshConnections[id] = conn
        term.attachTransport(conn)

        sftpClients[id] = SftpClient(
            execute: { [weak conn] req in
                guard let conn else { throw NativeSshError(code: "SFTP_CLOSED") }
                return try conn.sftpRequest(req)
            },
            recover: { [weak self] in
                guard let self else { throw NativeSshError(code: "SFTP_CLOSED") }
                try await self.waitForSshReady(id: id)
            },
            isActive: { [weak conn] in conn?.isReady == true }
        )

        conn.onStage = { [weak self] stage in
            Task { @MainActor [weak self] in
                guard let self, let i = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                self.sessions[i].stage = stage
            }
        }
        conn.onVerifyHostKey = { [weak self] fp in
            guard let self else { return false }
            let accepted = await self.requestHostTrust(ownerId: id, host: host, fingerprint: fp)
            if accepted {
                await self.persistHostFingerprint(hostId: host.id, fingerprint: fp)
            }
            return accepted
        }
        conn.onOutput = { [weak term] data in
            term?.feed(data)
        }
        conn.onReady = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let i = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                self.sessions[i].status = "ready"
                self.sessions[i].hasConnected = true
                self.sessions[i].failure = nil
                self.startSshForegroundPolling(id: id)
            }
        }
        conn.onEnded = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let i = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                self.sessions[i].status = "ended"
                self.sshForegroundTasks[id]?.cancel()
            }
        }
        conn.onFailure = { [weak self] kind in
            Task { @MainActor [weak self] in
                guard let self, let i = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                self.sessions[i].status = "failed"
                self.sessions[i].failure = kind
                self.sshForegroundTasks[id]?.cancel()
                if kind == .auth || kind == .key {
                    self.liveSshSecrets[id]?.wipe()
                    self.liveSshSecrets.removeValue(forKey: id)
                } else if kind.isRetryable && self.sessions[i].hasConnected && self.isForeground {
                    self.scheduleSshReconnect(id: id)
                }
            }
        }

        let password = liveSshSecrets[id] ?? ZeroizedBytes([])
        let privateKey = host.hasPrivateKey ? (KeychainStore.shared.loadPrivateKey(for: host.keyId) ?? ZeroizedBytes([])) : ZeroizedBytes([])
        let geom = term.currentGeometry()

        Task {
            await conn.connect(password: password, privateKey: privateKey, geometry: geom, reconnecting: reconnecting)
        }
    }

    private func scheduleSshReconnect(id: String) {
        sshReconnectTasks[id]?.cancel()
        sshReconnectTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.sessions.contains(where: { $0.id == id && $0.status == "failed" }) else { return }
            self.retrySsh(id: id)
        }
    }

    private func waitForSshReady(id: String) async throws {
        for _ in 0..<30 {
            try Task.checkCancellation()
            if sessions.first(where: { $0.id == id })?.status == "ready" { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw NativeSshError(code: "SFTP_TIMEOUT")
    }

    private func startSshForegroundPolling(id: String) {
        sshForegroundTasks[id]?.cancel()
        guard let scriptURL = Bundle.main.url(forResource: "ssh_agent_chat", withExtension: "py"),
              let scriptData = try? Data(contentsOf: scriptURL) else {
            return
        }
        sshForegroundTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.isForeground,
                      let conn = self.sshConnections[id], conn.isReady else { continue }
                let client = SshAgentChatClient(scriptData: scriptData) { cmd in try await conn.query(cmd) }
                if let fg = try? await client.foreground() {
                    if let idx = self.sessions.firstIndex(where: { $0.id == id }) {
                        self.sessions[idx].foreground = fg
                    }
                }
            }
        }
    }

    // MARK: - Paired Desktop Computers (LAN / Relay / SSH Desktop)

    func importRelayInvitation(_ rawJSON: String) -> String? {
        guard let profile = RelayProfile.parse(rawJSON) else {
            globalError = L10n.tr("invalid_relay_invite")
            return nil
        }
        return connectRelay(profile)
    }

    func connectRelay(_ profile: RelayProfile) -> String {
        DesktopNotificationCenter.requestAuthorizationIfNeeded()
        let workspaceId = profile.workspaceId
        let saved = relays.first { $0.id == profile.id }
        let attempt = RelayRouteAttempt.forProfile(profile, saved: saved)
        let primary = attempt.routes.first ?? profile

        nextGeneration += 1
        let gen = nextGeneration
        desktopTasks[workspaceId]?.cancel()
        desktopClients[workspaceId]?.close()
        desktopClients.removeValue(forKey: workspaceId)
        desktopReconnect.cancel(workspaceId)

        if let idx = desktops.firstIndex(where: { $0.id == workspaceId }) {
            desktops[idx].status = "connecting"
            desktops[idx].failure = nil
            desktops[idx].approval = nil
            desktops[idx].relayProfile = primary
            desktops[idx].transportLabel = primary.isLan ? "LAN" : "Relay"
            desktops[idx].connectionGeneration = gen
        } else {
            desktops.append(ManagedDesktopSession(
                id: workspaceId,
                name: primary.name,
                hostIcon: primary.hostOs,
                transportLabel: primary.isLan ? "LAN" : "Relay",
                relayProfile: primary,
                sshHost: nil,
                status: "connecting",
                allowInput: false,
                hasConnected: false,
                failure: nil,
                approval: nil,
                runtimeProcess: nil,
                connectionGeneration: gen,
                tabs: [],
                panes: []
            ))
        }

        desktopTasks[workspaceId] = Task { [weak self] in
            await self?.runRelayAttempt(workspaceId: workspaceId, routes: attempt.routes, generation: gen)
        }
        return workspaceId
    }

    func connectDesktopOverSsh(host: HostProfile, password: ZeroizedBytes, allowInput: Bool) -> String {
        DesktopNotificationCenter.requestAuthorizationIfNeeded()
        let workspaceId = "ssh-desktop:\(host.id)"
        nextGeneration += 1
        let gen = nextGeneration
        desktopTasks[workspaceId]?.cancel()
        desktopClients[workspaceId]?.close()

        let privateKey = host.hasPrivateKey ? (KeychainStore.shared.loadPrivateKey(for: host.keyId) ?? ZeroizedBytes([])) : ZeroizedBytes([])

        if let idx = desktops.firstIndex(where: { $0.id == workspaceId }) {
            desktops[idx].status = "connecting"
            desktops[idx].failure = nil
            desktops[idx].connectionGeneration = gen
        } else {
            desktops.append(ManagedDesktopSession(
                id: workspaceId,
                name: host.name,
                hostIcon: host.icon,
                transportLabel: "SSH",
                relayProfile: nil,
                sshHost: host,
                status: "connecting",
                allowInput: allowInput,
                hasConnected: false,
                failure: nil,
                approval: nil,
                runtimeProcess: nil,
                connectionGeneration: gen,
                tabs: [],
                panes: []
            ))
        }

        let transport = SshDesktopTransport(
            host: host,
            password: password,
            privateKey: privateKey,
            allowInput: allowInput
        ) { [weak self] h, fp in
            guard let self else { return false }
            let accepted = await self.requestHostTrust(ownerId: workspaceId, host: h, fingerprint: fp)
            if accepted { await self.persistHostFingerprint(hostId: h.id, fingerprint: fp) }
            return accepted
        }
        let client = DesktopRuntimeClient(transport: transport, allowInput: allowInput)
        bindDesktopClient(client, workspaceId: workspaceId, generation: gen, relayTransport: nil)

        desktopTasks[workspaceId] = Task { [weak self] in
            do {
                try await client.connect()
            } catch {
                let kind = DesktopFailureClassifier.classify(error)
                self?.desktopFailed(id: workspaceId, kind: kind, immediate: false)
            }
        }
        return workspaceId
    }

    func forgetRelay(_ profile: RelayProfile) {
        closeDesktop(id: profile.workspaceId)
        relays.removeAll { $0.id == profile.id }
        relayStore.save(relays)
    }

    func updateRelayLanAddress(_ profile: RelayProfile, address: String) -> Bool {
        guard let updated = profile.atLanAddress(address) else { return false }
        if let idx = relays.firstIndex(where: { $0.id == profile.id }) {
            relays[idx] = updated
            relayStore.save(relays)
        }
        _ = connectRelay(updated)
        return true
    }

    func closeDesktop(id: String) {
        desktopReconnect.cancel(id)
        desktopTasks[id]?.cancel()
        desktopTasks.removeValue(forKey: id)
        desktopClients[id]?.close()
        desktopClients.removeValue(forKey: id)
        desktops.removeAll { $0.id == id }
        if desktopOutput.target.hasPrefix("\(id):") {
            stopWatchingDesktopPane()
        }
        refreshLanRecovery()
    }

    func desktopRuntimeClient(for id: String) -> DesktopRuntimeClient? {
        desktopClients[id]
    }

    func desktopTabsClient(for id: String) -> DesktopTabsClient? {
        guard let client = desktopClients[id] else { return nil }
        return DesktopTabsClient(client: client) { [weak self] in
            self?.desktops.first(where: { $0.id == id })?.allowInput ?? false
        }
    }

    func desktopTerminalInput(for desktopId: String, windowId: Int64, paneId: Int64) -> DesktopTerminalInput? {
        guard let client = desktopClients[desktopId] else { return nil }
        return DesktopTerminalInput(
            client: client,
            windowId: windowId,
            paneId: paneId,
            onAccepted: { [weak self] in
                Task { @MainActor [weak self] in self?.triggerImmediateScreenRefresh() }
            },
            onRejected: { [weak self] code, _ in
                Task { @MainActor [weak self] in self?.globalError = code }
            }
        )
    }

    func makeDesktopConversation(desktopId: String, windowId: Int64, paneId: Int64, identity: ConversationIdentity) -> DesktopConversation {
        DesktopConversation(windowId: windowId, paneId: paneId, identity: identity) { [weak self] in
            guard let self,
                  let desk = self.desktops.first(where: { $0.id == desktopId && $0.status == "ready" }),
                  let client = self.desktopClients[desktopId] else {
                return nil
            }
            return (client, desk.allowInput)
        }
    }

    func makeDesktopGit(target: DesktopGitTarget) -> DesktopGitController {
        DesktopGitController(target: target) { [weak self] in
            guard let self,
                  let desk = self.desktops.first(where: { $0.id == target.desktopId && $0.status == "ready" }),
                  desk.connectionGeneration == target.generation,
                  desk.runtimeProcess == target.runtimeProcess,
                  let client = self.desktopClients[target.desktopId] else {
                return nil
            }
            return (client, desk.allowInput)
        }
    }

    // MARK: - Desktop Pane Output Streaming / Polling

    func startWatchingDesktopPane(desktopId: String, windowId: Int64, paneId: Int64) {
        let target = "\(desktopId):\(windowId):\(paneId)"
        if desktopOutput.target == target && screenWatchTask != nil { return }
        stopWatchingDesktopPane(target: nil)
        screenSync.reset()
        screenHistoryStart = nil
        desktopOutput = DesktopOutputState(target: target, frame: nil, text: "", loading: true, error: nil)

        screenWatchTask = Task { [weak self] in
            await self?.runDesktopPaneWatch(desktopId: desktopId, windowId: windowId, paneId: paneId, target: target)
        }
    }

    func stopWatchingDesktopPane(target: String? = nil) {
        if let target, desktopOutput.target != target { return }
        screenWatchTask?.cancel()
        screenWatchTask = nil
        screenWakeContinuation?.resume()
        screenWakeContinuation = nil
        desktopOutput = DesktopOutputState()
    }

    func requestDesktopHistoryPage(start: Int64?) {
        screenHistoryStart = start
        triggerImmediateScreenRefresh()
    }

    func triggerImmediateScreenRefresh() {
        let cont = screenWakeContinuation
        screenWakeContinuation = nil
        cont?.resume()
    }

    private func runDesktopPaneWatch(desktopId: String, windowId: Int64, paneId: Int64, target: String) async {
        var intervalMs: UInt64 = 33
        var screenUnsupported = false

        while !Task.isCancelled {
            guard let client = desktopClients[desktopId], !client.isClosed else {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            var params: [String: Any] = [
                "window_id": windowId,
                "pane_id": paneId,
                "lines": 100,
            ]
            if !screenUnsupported {
                params["screen"] = true
                if client.capabilities.terminalHistory {
                    var hist: [String: Any] = ["rows": 200]
                    if let start = screenHistoryStart { hist["start"] = start }
                    params["screen_history"] = hist
                } else if client.capabilities.terminalScroll {
                    params["screen_viewport"] = true
                }
                if client.capabilities.screenDelta && screenSync.sequence > 0 {
                    params["screen_since"] = screenSync.sequence
                }
            }

            do {
                let res = try await client.request(method: "pane.read", params: params)
                guard !Task.isCancelled, desktopOutput.target == target else { return }
                let prevFrame = desktopOutput.frame
                let prevText = desktopOutput.text

                var nextFrame = desktopOutput.frame
                if !screenUnsupported && (res["screen"] != nil || res["screen_delta"] != nil) {
                    if let applied = screenSync.apply(target: target, response: res, theme19: currentTerminalColors) {
                        nextFrame = applied
                    } else {
                        screenSync.reset()
                    }
                }
                let nextText = res["text"] as? String ?? prevText
                desktopOutput = DesktopOutputState(
                    target: target,
                    frame: nextFrame,
                    text: nextText,
                    loading: false,
                    error: nil
                )
                let changed = (nextFrame != prevFrame) || (nextText != prevText)
                intervalMs = changed ? 33 : min(intervalMs * 2, 500)
            } catch let rpc as DesktopRpcFailure {
                guard !Task.isCancelled, desktopOutput.target == target else { return }
                if rpc.code == "invalid_params" && !client.capabilities.terminalHistory && !client.capabilities.terminalScroll {
                    screenUnsupported = true
                    intervalMs = 33
                    continue
                }
                desktopOutput.loading = false
                desktopOutput.error = rpc.code
                intervalMs = 500
            } catch {
                guard !Task.isCancelled, desktopOutput.target == target else { return }
                desktopOutput.loading = false
                intervalMs = 500
            }

            await waitWithWake(milliseconds: intervalMs)
        }
    }

    private func waitWithWake(milliseconds: UInt64) async {
        let sleeper = Task {
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            await MainActor.run { [weak self] in
                self?.triggerImmediateScreenRefresh()
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                screenWakeContinuation = cont
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.triggerImmediateScreenRefresh()
            }
        }
        sleeper.cancel()
    }

    // MARK: - Relay Connection Internals

    private func runRelayAttempt(workspaceId: String, routes: [RelayProfile], generation: Int64) async {
        var lastError: DesktopFailureKind = .unknown

        for (index, route) in routes.enumerated() {
            if Task.isCancelled { return }
            let hasFallback = index + 1 < routes.count
            let lanFallback = route.isLan && hasFallback

            let transport = RelayTransport(profile: route)
            let client = DesktopRuntimeClient(transport: transport, allowInput: true)
            bindDesktopClient(client, workspaceId: workspaceId, generation: generation, relayTransport: transport)

            do {
                if lanFallback {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await client.connect() }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 5_000_000_000)
                            client.close()
                            throw DesktopFailure(.timeout)
                        }
                        try await group.next()
                        group.cancelAll()
                    }
                } else {
                    try await client.connect()
                }
                return // Connected successfully!
            } catch {
                client.close()
                let kind = DesktopFailureClassifier.classify(error)
                lastError = kind
                if !kind.isRetryable { break }
            }
        }

        desktopFailed(id: workspaceId, kind: lastError, immediate: false)
    }

    private func bindDesktopClient(
        _ client: DesktopRuntimeClient,
        workspaceId: String,
        generation: Int64,
        relayTransport: RelayTransport?
    ) {
        desktopClients[workspaceId] = client

        client.onApproval = { [weak self] approval in
            Task { @MainActor [weak self] in
                guard let self, let idx = self.desktops.firstIndex(where: { $0.id == workspaceId && $0.connectionGeneration == generation }) else { return }
                self.desktops[idx].approval = approval
            }
        }

        client.onSnapshot = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, let idx = self.desktops.firstIndex(where: { $0.id == workspaceId && $0.connectionGeneration == generation }) else { return }
                self.desktopReconnect.reset(workspaceId)
                self.desktops[idx].status = "ready"
                self.desktops[idx].hasConnected = true
                self.desktops[idx].failure = nil
                self.desktops[idx].approval = nil
                self.desktops[idx].allowInput = snapshot.allowInput
                self.desktops[idx].runtimeProcess = snapshot.processId
                self.desktops[idx].tabs = snapshot.tabs
                self.desktops[idx].panes = snapshot.panes

                if let hostOs = client.hostOs {
                    self.desktops[idx].hostIcon = HostIconCatalog.desktopOsIcon(hostOs)
                }

                // Persist newly enrolled or updated RelayProfile ONLY after first snapshot arrives.
                if let active = relayTransport?.activeProfile {
                    let withOs = active.withHostOs(client.hostOs)
                    let prev = self.relays.first { $0.id == withOs.id }
                    let merged = withOs.retainRoutes(from: prev)
                    if let rIdx = self.relays.firstIndex(where: { $0.id == merged.id }) {
                        self.relays[rIdx] = merged
                    } else {
                        self.relays.append(merged)
                    }
                    self.desktops[idx].relayProfile = merged
                    self.relayStore.save(self.relays)
                }

                // Deduplicated task transition notifications
                let tracker = self.desktopTransitions[workspaceId] ?? DesktopTransitions(workspaceId: workspaceId)
                self.desktopTransitions[workspaceId] = tracker
                let triggered = tracker.advance(snapshot: snapshot)
                let computerName = self.desktops[idx].name
                for pane in triggered {
                    DesktopNotificationCenter.notify(
                        desktopId: workspaceId,
                        desktopName: computerName,
                        processId: snapshot.processId,
                        pane: pane
                    )
                }
                self.refreshLanRecovery()
            }
        }

        client.onDisconnect = { [weak self] kind in
            Task { @MainActor [weak self] in
                guard let self, let desk = self.desktops.first(where: { $0.id == workspaceId && $0.connectionGeneration == generation }) else { return }
                _ = desk
                self.desktopFailed(id: workspaceId, kind: kind, immediate: false)
            }
        }
    }

    private func desktopFailed(id: String, kind: DesktopFailureKind, immediate: Bool) {
        guard let idx = desktops.firstIndex(where: { $0.id == id }) else { return }
        desktops[idx].status = "failed"
        desktops[idx].failure = kind
        desktops[idx].approval = nil
        let canAutoRetry = kind.isRetryable && desktops[idx].hasConnected
        if canAutoRetry, let profile = desktops[idx].relayProfile {
            desktopReconnect.schedule(id, immediate: immediate) { [weak self] in
                _ = self?.connectRelay(profile)
            }
        }
        refreshLanRecovery()
    }
}
