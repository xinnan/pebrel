import SwiftUI
import UniformTypeIdentifiers

struct HostRowCard: View {
    @Environment(\.pebrelPalette) private var palette
    let host: HostProfile
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    HostGlyphView(iconId: host.icon, size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.foreground)
                        Text(host.endpointLabel)
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button(L10n.tr("edit_host"), action: onEdit)
                Button(L10n.tr("delete_host"), role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(palette.muted)
                    .frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .pebrelGlass(tier: .heavy, cornerRadius: 14)
    }
}

struct HostsScreen: View {
    @Environment(\.pebrelPalette) private var palette
    let hosts: [HostProfile]
    let onBack: () -> Void
    let onAdd: () -> Void
    let onConnect: (HostProfile) -> Void
    let onEdit: (HostProfile) -> Void
    let onDelete: (HostProfile) -> Void

    @State private var search = ""
    @State private var groupFilter = "all"

    private var filtered: [HostProfile] {
        hosts.filter { h in
            let matchesGroup = groupFilter == "all" || h.group == groupFilter
            let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesQuery = q.isEmpty ||
                h.name.lowercased().contains(q) ||
                h.address.lowercased().contains(q) ||
                h.user.lowercased().contains(q)
            return matchesGroup && matchesQuery
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PebrelPageHeader(L10n.tr("ssh_hosts"), onBack: onBack) {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(palette.primary)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel(L10n.tr("add_ssh"))
            }

            VStack(spacing: 12) {
                TextField(L10n.tr("search_hosts"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Picker("", selection: $groupFilter) {
                    Text(L10n.tr("all")).tag("all")
                    Text(L10n.tr("group_production")).tag("production")
                    Text(L10n.tr("group_development")).tag("development")
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if filtered.isEmpty {
                        Text(L10n.tr("ios_no_saved_hosts"))
                            .font(.subheadline)
                            .foregroundStyle(palette.muted)
                            .padding(.top, 32)
                    } else {
                        ForEach(filtered) { host in
                            HostRowCard(
                                host: host,
                                onTap: { onConnect(host) },
                                onEdit: { onEdit(host) },
                                onDelete: { onDelete(host) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }
}

struct HostFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pebrelPalette) private var palette

    let initial: HostProfile?
    @ObservedObject var repository: SessionRepository
    let allowConnect: Bool
    let onSaved: (HostProfile, ZeroizedBytes?, Bool) -> Void

    @State private var name: String
    @State private var address: String
    @State private var portText: String
    @State private var user: String
    @State private var icon: String
    @State private var group: String
    @State private var sessionMode: SshSessionMode
    @State private var sessionName: String
    @State private var authMode: String
    @State private var keyId: String
    @State private var keyName: String
    @State private var passwordText = ""
    @State private var rememberPassword = true
    @State private var showKeyImporter = false
    @State private var validationError: String?

    init(
        initial: HostProfile?,
        repository: SessionRepository,
        allowConnect: Bool,
        onSaved: @escaping (HostProfile, ZeroizedBytes?, Bool) -> Void
    ) {
        self.initial = initial
        self.repository = repository
        self.allowConnect = allowConnect
        self.onSaved = onSaved
        _name = State(initialValue: initial?.name ?? "")
        _address = State(initialValue: initial?.address ?? "")
        _portText = State(initialValue: String(initial?.port ?? 22))
        _user = State(initialValue: initial?.user ?? "root")
        _icon = State(initialValue: initial?.icon ?? "term")
        _group = State(initialValue: initial?.group ?? "development")
        _sessionMode = State(initialValue: initial?.sessionMode ?? .shell)
        _sessionName = State(initialValue: initial?.sessionName ?? "")
        _authMode = State(initialValue: (initial?.hasPrivateKey == true) ? "key" : "auto")
        _keyId = State(initialValue: initial?.keyId ?? "")
        _keyName = State(initialValue: initial?.keyName ?? "")
    }

    private var hasSavedPwd: Bool {
        if let initial { return repository.hasSavedPassword(for: initial) }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("host_actions")) {
                    HStack {
                        Menu {
                            ForEach(HostIconCatalog.shared.entries) { entry in
                                Button {
                                    icon = entry.id
                                } label: {
                                    Text("\(entry.glyph)  \(entry.localizedLabel)")
                                }
                            }
                        } label: {
                            HostGlyphView(iconId: icon, size: 22)
                                .padding(6)
                                .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 8))
                        }
                        TextField(L10n.tr("host_name"), text: $name)
                    }

                    TextField(L10n.tr("host_address"), text: $address)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: address) { newValue in
                            if newValue.contains("@"), let parsed = SshEndpointParser.parse(newValue), let u = parsed.user {
                                user = u
                                address = parsed.host
                            }
                        }

                    HStack {
                        TextField(L10n.tr("username"), text: $user)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Divider()
                        TextField(L10n.tr("port"), text: $portText)
                            .keyboardType(.numberPad)
                            .frame(width: 72)
                    }
                }

                Section(L10n.tr("ssh_terminal_mode")) {
                    Picker(L10n.tr("ssh_terminal_mode"), selection: $sessionMode) {
                        Text("Shell").tag(SshSessionMode.shell)
                        Text("tmux").tag(SshSessionMode.tmux)
                        Text("herdr").tag(SshSessionMode.herdr)
                    }
                    .pickerStyle(.segmented)

                    if sessionMode != .shell {
                        TextField(L10n.tr("ssh_session_name"), text: $sessionName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }

                Section(L10n.tr("authentication")) {
                    Picker(L10n.tr("authentication"), selection: $authMode) {
                        Text(L10n.tr("auth_auto")).tag("auto")
                        Text(L10n.tr("auth_key")).tag("key")
                    }
                    .pickerStyle(.segmented)

                    if authMode == "key" {
                        HStack {
                            Text(keyName.isEmpty ? L10n.tr("ios_key_import_hint") : keyName)
                                .foregroundStyle(keyName.isEmpty ? palette.muted : palette.foreground)
                            Spacer()
                            Button(L10n.tr("ssh_choose_key")) { showKeyImporter = true }
                        }
                    }

                    SecureField(
                        authMode == "key" ? L10n.tr("ssh_key_passphrase") : L10n.tr("password"),
                        text: $passwordText
                    )
                    Toggle(L10n.tr("save_password"), isOn: $rememberPassword)

                    if hasSavedPwd, let initial {
                        Button(L10n.tr("clear_saved_password"), role: .destructive) {
                            repository.clearHostPassword(initial)
                        }
                    }
                }

                Section(L10n.tr("host_group")) {
                    Picker(L10n.tr("host_group"), selection: $group) {
                        Text(L10n.tr("group_development")).tag("development")
                        Text(L10n.tr("group_production")).tag("production")
                    }
                    .pickerStyle(.segmented)
                }

                if let validationError {
                    Section {
                        Text(validationError).foregroundStyle(palette.error).font(.footnote)
                    }
                }
            }
            .navigationTitle(initial == nil ? L10n.tr("add_ssh") : L10n.tr("edit_host"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("cancel")) { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button(L10n.tr("save")) { submit(connect: false) }
                    if allowConnect {
                        Button(L10n.tr("save_connect")) { submit(connect: true) }
                            .fontWeight(.semibold)
                    }
                }
            }
            .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.data, .text, .item]) { result in
                if case .success(let url) = result {
                    importPrivateKey(from: url)
                }
            }
        }
    }

    private func importPrivateKey(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= 65536 else {
            validationError = L10n.tr("ssh_key_access_failed")
            return
        }
        let newKeyId = keyId.isEmpty ? UUID().uuidString : keyId
        guard KeychainStore.shared.savePrivateKey(data, for: newKeyId) else {
            validationError = L10n.tr("credential_save_failed")
            return
        }
        keyId = newKeyId
        keyName = url.lastPathComponent
        validationError = nil
    }

    private func submit(connect: Bool) {
        guard let parsed = SshEndpointParser.parse(address) else {
            validationError = L10n.tr("service_address_error")
            return
        }
        guard let port = Int(portText), (1...65535).contains(port) else {
            validationError = L10n.tr("invalid_port")
            return
        }
        let cleanUser = (parsed.user ?? user).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty, cleanUser.count <= 40 else {
            validationError = L10n.tr("invalid_username")
            return
        }
        guard SshEndpointParser.isValidRemoteSessionName(sessionName, mode: sessionMode) else {
            validationError = L10n.tr("ssh_session_name_invalid")
            return
        }
        if authMode == "key" && keyId.isEmpty {
            validationError = L10n.tr("ios_key_import_hint")
            return
        }

        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? parsed.host
            : String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))

        let host = HostProfile(
            id: initial?.id ?? UUID().uuidString,
            name: finalName,
            address: parsed.host,
            port: port,
            user: cleanUser,
            fingerprint: initial?.fingerprint ?? "",
            icon: icon,
            group: group,
            sessionMode: sessionMode,
            sessionName: sessionMode == .shell ? "" : sessionName,
            keyId: authMode == "key" ? keyId : "",
            keyName: authMode == "key" ? keyName : ""
        )

        let explicitSecret = passwordText.isEmpty ? nil : ZeroizedBytes(utf8: passwordText)
        let connectSecret = connect ? repository.passwordForConnection(host, explicit: explicitSecret) : nil
        if connect && connectSecret == nil {
            validationError = L10n.tr("credential_missing")
            return
        }
        guard repository.saveHost(host, password: explicitSecret, rememberPassword: rememberPassword) else {
            return
        }
        onSaved(host, connectSecret, connect)
    }
}

struct LoginFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pebrelPalette) private var palette

    let host: HostProfile
    @ObservedObject var repository: SessionRepository
    let attachmentLabel: String?
    let onConnect: (ZeroizedBytes, Bool, Bool) -> Void

    @State private var password = ""
    @State private var rememberPassword = false
    @State private var connectDesktop = false
    @State private var allowDesktopInput = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        HostGlyphView(iconId: host.icon, size: 24)
                        VStack(alignment: .leading) {
                            Text(host.name).font(.headline)
                            Text(host.endpointLabel).font(.caption).foregroundStyle(palette.muted)
                        }
                    }
                    if host.hasPrivateKey {
                        Label(host.keyName, systemImage: "key").font(.caption).foregroundStyle(palette.muted)
                    }
                }

                Section(L10n.tr("authentication")) {
                    SecureField(
                        host.hasPrivateKey ? L10n.tr("ssh_key_passphrase") : L10n.tr("password"),
                        text: $password
                    )
                    Toggle(L10n.tr("save_password"), isOn: $rememberPassword)
                }

                if attachmentLabel == nil {
                    Section(L10n.tr("computers")) {
                        Toggle(L10n.tr("connect_pebrel"), isOn: $connectDesktop)
                        if connectDesktop {
                            Toggle(L10n.tr("allow_input"), isOn: $allowDesktopInput)
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("connect"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("connect")) {
                        let secret = ZeroizedBytes(utf8: password)
                        _ = repository.saveHost(host, password: secret, rememberPassword: rememberPassword)
                        onConnect(secret, connectDesktop, allowDesktopInput)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
