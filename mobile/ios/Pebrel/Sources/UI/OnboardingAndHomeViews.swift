import SwiftUI

struct OnboardingView: View {
    @Environment(\.pebrelPalette) private var palette

    let onComputer: () -> Void
    let onSshHost: () -> Void
    let onLocalShellInfo: () -> Void
    let onLater: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 36)
                Image("PebrelLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(spacing: 8) {
                    Text(L10n.tr("onboarding_connection_title"))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(palette.foreground)
                        .multilineTextAlignment(.center)
                    Text(L10n.tr("onboarding_connection_hint"))
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    Button(action: onComputer) {
                        HStack(spacing: 14) {
                            Image(systemName: "desktopcomputer")
                                .font(.title3)
                                .foregroundStyle(palette.onPrimary)
                                .frame(width: 36, height: 36)
                                .background(palette.primary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.tr("computer_connect"))
                                    .font(.headline)
                                    .foregroundStyle(palette.foreground)
                                Text(L10n.tr("onboarding_my_computer_hint"))
                                    .font(.caption)
                                    .foregroundStyle(palette.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(palette.muted)
                        }
                        .padding(16)
                        .pebrelGlass(tier: .heavy, cornerRadius: 18)
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 0) {
                        Button(action: onSshHost) {
                            HStack(spacing: 14) {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(palette.primary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.tr("add_ssh"))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(palette.foreground)
                                    Text(L10n.tr("ssh_hosts"))
                                        .font(.caption)
                                        .foregroundStyle(palette.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(palette.muted)
                            }
                            .padding(16)
                        }
                        .buttonStyle(.plain)

                        Divider().overlay(palette.outlineVariant)

                        Button(action: onLocalShellInfo) {
                            HStack(spacing: 14) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(palette.muted)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.tr("ios_local_shell_title"))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(palette.muted)
                                    Text(L10n.tr("ios_local_shell_body"))
                                        .font(.caption)
                                        .foregroundStyle(palette.muted)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                            .padding(16)
                        }
                        .buttonStyle(.plain)
                    }
                    .pebrelGlass(tier: .heavy, cornerRadius: 18)
                }

                Button(L10n.tr("onboarding_later"), action: onLater)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.muted)
                    .padding(.top, 8)
            }
            .padding(22)
        }
    }
}

struct HomeView: View {
    @Environment(\.pebrelPalette) private var palette
    @ObservedObject var repository: SessionRepository

    let onOpenSession: (String) -> Void
    let onOpenSwitcher: () -> Void
    let onOpenHosts: () -> Void
    let onConnectHost: (HostProfile) -> Void
    let onEditHost: (HostProfile) -> Void
    let onDeleteHost: (HostProfile) -> Void
    let onAddHost: () -> Void
    let onOpenDesktop: (String) -> Void
    let onConnectRelay: (RelayProfile) -> Void
    let onOpenComputers: () -> Void
    let onAddRelay: () -> Void
    let onDeployRelay: () -> Void
    let onOpenPane: (String, DesktopPane) -> Void
    let onOpenTab: (String, DesktopTab) -> Void
    let onOpenSettings: (String) -> Void
    let onOpenNewSheet: () -> Void
    let onLocalShellInfo: () -> Void

    private var isEmpty: Bool {
        repository.sessions.isEmpty &&
        repository.hosts.isEmpty &&
        repository.relays.isEmpty &&
        repository.desktops.allSatisfy { !$0.hasConnected }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                homeHeader
                if isEmpty {
                    emptyContent
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            sessionGallerySection
                            hostsPreviewSection
                            computersPreviewSection
                            localBoundaryBanner
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 92)
                    }
                }
            }

            if !isEmpty {
                Button(action: onOpenNewSheet) {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(palette.onPrimary)
                        .frame(width: 58, height: 58)
                        .pebrelGlass(tier: .heavy, cornerRadius: 29, accent: palette.primary)
                        .shadow(color: Color.black.opacity(0.2), radius: 10, y: 4)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 22)
                .accessibilityLabel(L10n.tr("new_connection"))
            }
        }
    }

    private var homeHeader: some View {
        HStack(spacing: 10) {
            Image("PebrelLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(L10n.tr("app_name"))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(palette.foreground)
            Spacer()
            if !isEmpty {
                Button { onOpenSettings("notices") } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 17))
                        .foregroundStyle(palette.foreground)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel(L10n.tr("notifications"))
            }
            Button { onOpenSettings("") } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundStyle(palette.foreground)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel(L10n.tr("settings"))
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .pebrelGlassBar()
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.outlineVariant).frame(height: 0.5)
        }
    }

    private var emptyContent: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 60)
                Image("PebrelLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(L10n.tr("home_empty_title"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.foreground)
                Text(L10n.tr("home_empty_hint"))
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)
                    .multilineTextAlignment(.center)
                Button(L10n.tr("computer_connect"), action: onAddRelay)
                    .buttonStyle(.borderedProminent)
                    .tint(palette.primary)
                    .controlSize(.large)
                HStack(spacing: 16) {
                    Button(L10n.tr("add_ssh"), action: onAddHost)
                    Button(L10n.tr("new_deploy_relay"), action: onDeployRelay)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(palette.primary)
            }
            .padding(24)
        }
    }

    private var sessionGallerySection: some View {
        let totalCards = repository.sessions.count + desktopCardCount
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(L10n.tr("sessions")) · \(totalCards)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.muted)
                Spacer()
                Button(L10n.tr("all_sessions"), action: onOpenSwitcher)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.primary)
            }
            if totalCards == 0 {
                Text(L10n.tr("no_sessions"))
                    .font(.footnote)
                    .foregroundStyle(palette.muted)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pebrelGlass(tier: .light, cornerRadius: 14)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(repository.sessions) { session in
                            Button { onOpenSession(session.id) } label: {
                                SshSessionPreviewCard(session: session)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(repository.desktops) { desk in
                            if !desk.tabs.isEmpty {
                                ForEach(desk.tabs) { tab in
                                    Button { onOpenTab(desk.id, tab) } label: {
                                        DesktopSessionPreviewCard(desktop: desk, tab: tab, pane: tab.primaryPane)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                Button { onOpenDesktop(desk.id) } label: {
                                    DesktopSessionPreviewCard(desktop: desk, tab: nil, pane: nil)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var desktopCardCount: Int {
        repository.desktops.reduce(0) { $0 + max(1, $1.tabs.count) }
    }

    private var hostsPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("ssh_hosts"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.muted)
                Spacer()
                Button(L10n.tr("all_count", repository.hosts.count), action: onOpenHosts)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.primary)
            }
            if repository.hosts.isEmpty {
                Button(action: onAddHost) {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text(L10n.tr("add_ssh"))
                        Spacer()
                    }
                    .foregroundStyle(palette.primary)
                    .padding(14)
                    .pebrelGlass(tier: .light, cornerRadius: 14)
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 10) {
                    ForEach(repository.hosts.prefix(2)) { host in
                        HostRowCard(
                            host: host,
                            onTap: { onConnectHost(host) },
                            onEdit: { onEditHost(host) },
                            onDelete: { onDeleteHost(host) }
                        )
                    }
                }
            }
        }
    }

    private var computersPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("computers"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.muted)
                Spacer()
                Button(L10n.tr("all"), action: onOpenComputers)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.primary)
            }
            ComputerRowsList(
                desktops: repository.desktops,
                relays: repository.relays,
                onOpenDesktop: onOpenDesktop,
                onConnectRelay: onConnectRelay,
                onAddRelay: onAddRelay,
                onForget: nil
            )
        }
    }

    private var localBoundaryBanner: some View {
        Button(action: onLocalShellInfo) {
            HStack(spacing: 12) {
                Image(systemName: "iphone")
                    .foregroundStyle(palette.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("ios_local_shell_title"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(palette.foreground)
                    Text(L10n.tr("ios_local_shell_body"))
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(14)
            .pebrelGlass(tier: .light, cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }
}

private struct SshSessionPreviewCard: View {
    @Environment(\.pebrelPalette) private var palette
    let session: ManagedTerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text("SSH")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.primary)
                Spacer()
            }
            if let fg = session.foreground, !fg.label.isEmpty {
                Text(fg.label)
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            Text(session.previewText.isEmpty ? session.host.endpointLabel : session.previewText)
                .font(TerminalFontRegistry.swiftUIFont(family: "maple", size: 9.5))
                .foregroundStyle(palette.foreground.opacity(0.85))
                .lineLimit(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
                .background(palette.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))

            Text(session.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
        }
        .padding(12)
        .frame(width: 162, height: 176)
        .pebrelGlass(tier: .heavy, cornerRadius: 16)
    }

    private var statusColor: Color {
        switch session.status {
        case "ready": return palette.tertiary
        case "connecting": return palette.yellow
        default: return palette.error
        }
    }
}

private struct DesktopSessionPreviewCard: View {
    @Environment(\.pebrelPalette) private var palette
    let desktop: ManagedDesktopSession
    let tab: DesktopTab?
    let pane: DesktopPane?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: tab.map { FileSymbol.tabSystemName(kind: $0.kind) } ?? "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(palette.primary)
                Text("\(desktop.transportLabel) · \(desktop.status)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            Text(desktop.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
            if let pane, pane.taskState != "unknown" && pane.taskState != "idle" {
                Text(pane.taskState)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.primary)
            }
            Text(tab?.file?.path ?? pane?.cwd ?? "")
                .font(.caption2)
                .foregroundStyle(palette.muted)
                .lineLimit(3)
            Spacer()
            Text(tab?.displayTitle ?? pane?.displayTitle ?? desktop.name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
        }
        .padding(12)
        .frame(width: 162, height: 176)
        .pebrelGlass(tier: .heavy, cornerRadius: 16)
    }
}

struct NewConnectionSheet: View {
    @Environment(\.pebrelPalette) private var palette

    let onComputer: () -> Void
    let onSshHost: () -> Void
    let onLocalShellInfo: () -> Void
    let onDeployRelay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("new_connection"))
                .font(.headline)
                .foregroundStyle(palette.foreground)
                .padding(.top, 8)

            sheetRow(icon: "desktopcomputer", title: L10n.tr("computer_connect"), subtitle: L10n.tr("onboarding_my_computer_hint"), action: onComputer)
            sheetRow(icon: "server.rack", title: L10n.tr("add_ssh"), subtitle: L10n.tr("ssh_hosts"), action: onSshHost)
            sheetRow(icon: "cloud", title: L10n.tr("new_deploy_relay"), subtitle: L10n.tr("new_deploy_relay_hint"), action: onDeployRelay)
            sheetRow(icon: "info.circle", title: L10n.tr("ios_local_shell_title"), subtitle: L10n.tr("ios_local_shell_body"), action: onLocalShellInfo)
            Spacer()
        }
        .padding(20)
        .background(palette.background.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private func sheetRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(palette.primary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.foreground)
                    Text(subtitle).font(.caption).foregroundStyle(palette.muted).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(palette.muted)
            }
            .padding(14)
            .pebrelGlass(tier: .heavy, cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }
}

struct SessionSwitcherSheet: View {
    @Environment(\.pebrelPalette) private var palette
    @ObservedObject var repository: SessionRepository

    let currentSessionId: String?
    let currentDesktopId: String?
    let onNewSshTab: (String) -> Void
    let onOpenHosts: () -> Void
    let onOpenSession: (String) -> Void
    let onOpenSftpTab: (SftpTab) -> Void
    let onCloseSftpTab: (SftpTab) -> Void
    let onOpenDesktop: (String) -> Void
    let onOpenDesktopTab: (String, DesktopTab) -> Void
    let onOpenDesktopPane: (String, DesktopPane) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let sid = currentSessionId,
                       let current = repository.sessions.first(where: { $0.id == sid }) {
                        Button { onNewSshTab(sid) } label: {
                            Label("\(L10n.tr("tab_new_terminal")) · \(current.host.name)", systemImage: "plus")
                        }
                    }
                    Button(action: onOpenHosts) {
                        Label(L10n.tr("ssh_hosts"), systemImage: "server.rack")
                    }
                }

                Section(L10n.tr("all_sessions")) {
                    if repository.sessions.isEmpty && repository.desktops.isEmpty {
                        Text(L10n.tr("no_sessions")).foregroundStyle(palette.muted)
                    }
                    ForEach(repository.sessions) { session in
                        Button { onOpenSession(session.id) } label: {
                            HStack {
                                Image(systemName: "terminal").foregroundStyle(palette.primary)
                                VStack(alignment: .leading) {
                                    Text(session.title).foregroundStyle(palette.foreground)
                                    Text(session.status).font(.caption).foregroundStyle(palette.muted)
                                }
                            }
                        }
                        ForEach(repository.sftpTabs.filter { $0.sessionId == session.id }) { tab in
                            HStack {
                                Button { onOpenSftpTab(tab) } label: {
                                    HStack {
                                        Image(systemName: FileSymbol.systemName(name: tab.file.name, isDirectory: false))
                                            .foregroundStyle(palette.muted)
                                        Text(tab.file.name).font(.subheadline).foregroundStyle(palette.foreground)
                                    }
                                    .padding(.leading, 20)
                                }
                                Spacer()
                                Button { onCloseSftpTab(tab) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(palette.muted)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    ForEach(repository.desktops) { desk in
                        if desk.tabs.isEmpty {
                            Button { onOpenDesktop(desk.id) } label: {
                                Label("\(desk.name) · \(desk.status)", systemImage: "desktopcomputer")
                            }
                        } else {
                            ForEach(desk.tabs) { tab in
                                Button { onOpenDesktopTab(desk.id, tab) } label: {
                                    HStack {
                                        Image(systemName: FileSymbol.tabSystemName(kind: tab.kind)).foregroundStyle(palette.primary)
                                        VStack(alignment: .leading) {
                                            Text(tab.displayTitle).foregroundStyle(palette.foreground)
                                            Text("\(desk.name) · \(desk.status)").font(.caption).foregroundStyle(palette.muted)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if let did = currentDesktopId,
                   let desk = repository.desktops.first(where: { $0.id == did }) {
                    Section {
                        Button { onOpenDesktop(did) } label: {
                            Label("\(L10n.tr("tab_manage")) · \(desk.name)", systemImage: "rectangle.stack")
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("all_sessions"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
