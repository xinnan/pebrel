import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComputerRowsList: View {
    @Environment(\.pebrelPalette) private var palette
    let desktops: [ManagedDesktopSession]
    let relays: [RelayProfile]
    let onOpenDesktop: (String) -> Void
    let onConnectRelay: (RelayProfile) -> Void
    let onAddRelay: () -> Void
    let onForget: ((RelayProfile) -> Void)?

    @State private var forgettingProfile: RelayProfile?

    var body: some View {
        VStack(spacing: 10) {
            ForEach(desktops) { desk in
                Button { onOpenDesktop(desk.id) } label: {
                    HStack(spacing: 12) {
                        HostGlyphView(iconId: desk.hostIcon, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(desk.name).font(.subheadline.weight(.semibold)).foregroundStyle(palette.foreground)
                            Text("\(desk.transportLabel) · \(desk.status)")
                                .font(.caption).foregroundStyle(palette.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(palette.muted)
                    }
                    .padding(14)
                    .pebrelGlass(tier: .heavy, cornerRadius: 14)
                }
                .buttonStyle(.plain)
            }

            ForEach(relays.filter { r in !desktops.contains { $0.id == r.workspaceId } }) { profile in
                HStack(spacing: 12) {
                    Button { onConnectRelay(profile) } label: {
                        HStack(spacing: 12) {
                            HostGlyphView(iconId: profile.hostOs, size: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).font(.subheadline.weight(.semibold)).foregroundStyle(palette.foreground)
                                Text(profile.hasAlternateRoute ? "LAN + Relay" : (profile.isLan ? "LAN" : "Relay"))
                                    .font(.caption).foregroundStyle(palette.muted)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if onForget != nil {
                        Menu {
                            Button(L10n.tr("computer_remove_title"), role: .destructive) {
                                forgettingProfile = profile
                            }
                        } label: {
                            Image(systemName: "ellipsis").foregroundStyle(palette.muted).frame(width: 34, height: 34)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .pebrelGlass(tier: .heavy, cornerRadius: 14)
            }

            Button(action: onAddRelay) {
                HStack(spacing: 10) {
                    Image(systemName: "qrcode.viewfinder").foregroundStyle(palette.primary)
                    Text(L10n.tr("computer_connect")).font(.subheadline.weight(.medium)).foregroundStyle(palette.primary)
                    Spacer()
                }
                .padding(14)
                .pebrelGlass(tier: .light, cornerRadius: 14)
            }
            .buttonStyle(.plain)
        }
        .alert(L10n.tr("computer_remove_title"), isPresented: Binding(
            get: { forgettingProfile != nil },
            set: { if !$0 { forgettingProfile = nil } }
        )) {
            Button(L10n.tr("computer_remove_title"), role: .destructive) {
                if let profile = forgettingProfile {
                    onForget?(profile)
                    forgettingProfile = nil
                }
            }
            Button(L10n.tr("cancel"), role: .cancel) { forgettingProfile = nil }
        } message: {
            if let profile = forgettingProfile {
                Text(profile.name)
            }
        }
    }
}

struct ComputersScreen: View {
    @Environment(\.pebrelPalette) private var palette
    @ObservedObject var repository: SessionRepository
    let onBack: () -> Void
    let onOpenDesktop: (String) -> Void
    let onConnectRelay: (RelayProfile) -> Void
    let onAddRelay: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PebrelPageHeader(L10n.tr("computers"), onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ComputerRowsList(
                        desktops: repository.desktops,
                        relays: repository.relays,
                        onOpenDesktop: onOpenDesktop,
                        onConnectRelay: onConnectRelay,
                        onAddRelay: onAddRelay,
                        onForget: { repository.forgetRelay($0) }
                    )
                    Text(L10n.tr("connection_boundary"))
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .padding(.top, 4)
                }
                .padding(18)
            }
        }
    }
}

/// Full-screen Desktop pairing sheet: QR camera scan, 8-digit LAN short code, or invite JSON / manual setup.
struct RelayFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pebrelPalette) private var palette

    let onConnect: (String) -> Void
    let onConnectProfile: (RelayProfile) -> Void
    let onDeploy: () -> Void

    @State private var tab = "scan"
    @State private var pasteText = ""
    @State private var showManual = false
    @State private var manualMode = "relay"
    @State private var manualName = ""
    @State private var manualUrl = ""
    @State private var manualDevice = ""
    @State private var manualToken = ""
    @State private var manualPin = ""
    @State private var scanError: String?

    // Short code pairing
    @StateObject private var discovery = PairingDiscovery()
    @State private var selectedComputer: DiscoveredComputer?
    @State private var shortCode = ""
    @State private var redeeming = false
    @State private var redeemError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        stepBadge(number: "1", label: L10n.tr("pair_step_find"))
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(palette.muted)
                        stepBadge(number: "2", label: L10n.tr("pair_step_approve"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .pebrelGlass(tier: .light, cornerRadius: 14)

                    Picker("", selection: $tab) {
                        Text(L10n.tr("pair_tab_scan")).tag("scan")
                        Text(L10n.tr("pair_short_code")).tag("code")
                        Text(L10n.tr("pair_tab_paste")).tag("paste")
                    }
                    .pickerStyle(.segmented)

                    if tab == "scan" {
                        qrScannerSection
                    } else if tab == "code" {
                        shortCodeSection
                    } else {
                        pasteAndManualSection
                    }

                    Button(action: onDeploy) {
                        HStack {
                            Image(systemName: "cloud")
                            Text(L10n.tr("new_deploy_relay"))
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.primary)
                        .padding(14)
                        .pebrelGlass(tier: .light, cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
            }
            .background(palette.background.ignoresSafeArea())
            .navigationTitle(L10n.tr("computer_connect"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("cancel")) { dismiss() }
                }
            }
            .onChange(of: tab) { next in
                if next == "code" { discovery.start() } else { discovery.stop() }
            }
            .onChange(of: discovery.computers) { list in
                if list.count == 1 && selectedComputer == nil {
                    selectedComputer = list[0]
                }
            }
            .onDisappear { discovery.stop() }
        }
    }

    private func stepBadge(number: String, label: String) -> some View {
        HStack(spacing: 6) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(palette.onPrimary)
                .frame(width: 20, height: 20)
                .background(palette.primary, in: Circle())
            Text(label).font(.caption).foregroundStyle(palette.foreground)
        }
    }

    private var qrScannerSection: some View {
        VStack(spacing: 12) {
            InlineQrScannerView { payload in
                if RelayProfile.parse(payload) != nil {
                    scanError = nil
                    onConnect(payload)
                    return true
                } else {
                    scanError = L10n.tr("invalid_relay_invite")
                    return false
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(palette.primary.opacity(0.6), lineWidth: 1.5)
            }

            if let scanError {
                Text(scanError).font(.caption).foregroundStyle(palette.error)
            }
        }
    }

    private var shortCodeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.tr("pair_lan"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.foreground)
                Spacer()
                Button(L10n.tr("retry")) { discovery.start() }
                    .font(.caption.weight(.medium))
            }

            if discovery.computers.isEmpty {
                HStack(spacing: 10) {
                    if discovery.searching { ProgressView() }
                    Text(L10n.tr("pair_discovery_searching"))
                        .font(.footnote)
                        .foregroundStyle(palette.muted)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pebrelGlass(tier: .light, cornerRadius: 14)
            } else {
                ForEach(discovery.computers) { computer in
                    Button { selectedComputer = computer } label: {
                        HStack {
                            Image(systemName: selectedComputer?.id == computer.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(palette.primary)
                            VStack(alignment: .leading) {
                                Text(computer.name).font(.subheadline.weight(.semibold)).foregroundStyle(palette.foreground)
                                Text(computer.address).font(.caption2).foregroundStyle(palette.muted)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .pebrelGlass(tier: .heavy, cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                }
            }

            TextField("12345678", text: $shortCode)
                .keyboardType(.numberPad)
                .font(TerminalFontRegistry.swiftUIFont(family: "maple", size: 22))
                .multilineTextAlignment(.center)
                .padding(12)
                .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: shortCode) { val in
                    let digits = val.filter(\.isNumber)
                    if digits != val || digits.count > 8 {
                        shortCode = String(digits.prefix(8))
                    }
                }

            if let redeemError {
                Text(redeemError).font(.caption).foregroundStyle(palette.error)
            }

            Button {
                guard let computer = selectedComputer else { return }
                redeeming = true
                redeemError = nil
                Task {
                    defer { redeeming = false }
                    do {
                        let profile = try await PairingCodeLookup.redeem(computer: computer, code: shortCode)
                        onConnectProfile(profile)
                    } catch {
                        redeemError = error.localizedDescription
                    }
                }
            } label: {
                HStack {
                    if redeeming { ProgressView().tint(palette.onPrimary) }
                    Text(L10n.tr("connect"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.primary)
            .disabled(selectedComputer == nil || !PairingCodeLookup.isValidCode(shortCode) || redeeming)
        }
    }

    private var pasteAndManualSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SecureField(L10n.tr("pair_paste_hint"), text: $pasteText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Button(L10n.tr("pair_import_connect")) {
                onConnect(pasteText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.primary)
            .frame(maxWidth: .infinity)
            .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            DisclosureGroup(L10n.tr("pair_manual_setup"), isExpanded: $showManual) {
                VStack(spacing: 10) {
                    Picker("", selection: $manualMode) {
                        Text("Relay").tag("relay")
                        Text("LAN").tag("lan")
                    }
                    .pickerStyle(.segmented)
                    TextField(L10n.tr("pair_computer_name"), text: $manualName).textFieldStyle(.roundedBorder)
                    TextField("wss://...", text: $manualUrl)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.tr("pair_device_id"), text: $manualDevice)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L10n.tr("pair_access_key"), text: $manualToken).textFieldStyle(.roundedBorder)
                    if manualMode == "lan" {
                        TextField("sha256/...", text: $manualPin)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button(L10n.tr("connect")) {
                        var dict: [String: Any] = [
                            "version": 1,
                            "mode": manualMode,
                            "url": manualUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                            "device": manualDevice.trimmingCharacters(in: .whitespacesAndNewlines),
                            "token": manualToken.trimmingCharacters(in: .whitespacesAndNewlines),
                            "name": manualName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? manualDevice : manualName,
                        ]
                        if !manualPin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            dict["tlsPin"] = manualPin.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        if let data = try? JSONSerialization.data(withJSONObject: dict),
                           let str = String(data: data, encoding: .utf8) {
                            onConnect(str)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.primary)
                }
                .padding(.top, 8)
            }
        }
    }
}

/// Embedded AVFoundation on-device QR scanner with macro/near-focus support for dense pairing QR codes.
struct InlineQrScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Bool

    func makeUIViewController(context: Context) -> QrScannerViewController {
        let vc = QrScannerViewController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: QrScannerViewController, context: Context) {
        uiViewController.onCode = onCode
    }
}

final class QrScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Bool)?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "io.github.kuddev.pebrel.qr.camera")
    private var captureDevice: AVCaptureDevice?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let statusStack = UIStackView()
    private let statusLabel = UILabel()
    private let settingsButton = UIButton(type: .system)
    private var isConfigured = false
    private var didEmit = false
    private var didAccept = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        statusLabel.textColor = .white
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .footnote)

        settingsButton.setTitle(L10n.tr("settings"), for: .normal)
        settingsButton.isHidden = true
        settingsButton.addTarget(self, action: #selector(openAppSettings), for: .touchUpInside)

        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 10
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.addArrangedSubview(statusLabel)
        statusStack.addArrangedSubview(settingsButton)
        view.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleFocusTap(_:)))
        view.addGestureRecognizer(tap)

        checkAndStartCamera()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isConfigured && !didAccept {
            sessionQueue.async { [weak self] in
                guard let self, !self.session.isRunning else { return }
                self.session.startRunning()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    @objc private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @objc private func handleFocusTap(_ gesture: UITapGestureRecognizer) {
        guard let preview = previewLayer, let device = captureDevice else { return }
        let point = preview.captureDevicePointConverted(fromLayerPoint: gesture.location(in: view))
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
    }

    private func checkAndStartCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureSession()
                    } else {
                        self?.showCameraStatus(L10n.tr("pair_camera_permission"), showSettings: true)
                    }
                }
            }
        default:
            showCameraStatus(L10n.tr("pair_camera_permission"), showSettings: true)
        }
    }

    private func showCameraStatus(_ text: String, showSettings: Bool) {
        statusLabel.text = text
        settingsButton.isHidden = !showSettings
        statusStack.isHidden = false
    }

    private func preferredBackCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera,
            ],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    private func configureSession() {
        guard !isConfigured else { return }
        guard let device = preferredBackCamera(),
              let input = try? AVCaptureDeviceInput(device: device) else {
            showCameraStatus(L10n.tr("pair_camera_missing"), showSettings: false)
            return
        }

        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }

        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            showCameraStatus(L10n.tr("pair_camera_missing"), showSettings: false)
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()

        captureDevice = device
        isConfigured = true

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
        statusStack.isHidden = true

        sessionQueue.async { [weak self] in
            self?.session.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didEmit, !didAccept,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue else { return }
        didEmit = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let accepted = onCode?(value) ?? false
        if accepted {
            didAccept = true
            sessionQueue.async { [weak self] in
                self?.session.stopRunning()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.didEmit = false
            }
        }
    }
}

struct RelayAccessDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// One-click Linux `pebrel-relay` deployment and management flow over SSH.
struct RelayDeploymentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pebrelPalette) private var palette
    @ObservedObject var repository: SessionRepository

    @State private var selectedHost: HostProfile?
    @State private var address = ""
    @State private var sshPort = "22"
    @State private var user = "root"
    @State private var password = ""
    @State private var relayPort = "443"
    @State private var advertisedAddress = ""
    @State private var purgeOnRemove = false
    @State private var busy = false
    @State private var progress = RelayServiceProgress("idle")
    @State private var serviceState: RelayServiceState?
    @State private var exportedAccessJSON: String?
    @State private var showExporter = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                if !repository.hosts.isEmpty {
                    Section(L10n.tr("ssh_hosts")) {
                        Menu(selectedHost?.name ?? L10n.tr("deploy_choose_host")) {
                            ForEach(repository.hosts) { h in
                                Button(h.name) {
                                    selectedHost = h
                                    address = h.address
                                    sshPort = String(h.port)
                                    user = h.user
                                    advertisedAddress = h.address
                                }
                            }
                        }
                    }
                }

                Section(L10n.tr("host_actions")) {
                    TextField(L10n.tr("host_address"), text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(L10n.tr("username"), text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(L10n.tr("password"), text: $password)
                    DisclosureGroup(L10n.tr("service_advanced")) {
                        TextField(L10n.tr("port"), text: $sshPort).keyboardType(.numberPad)
                        TextField("Relay port (443)", text: $relayPort).keyboardType(.numberPad)
                        TextField("Advertised host/IP", text: $advertisedAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }

                Section(L10n.tr("service_title")) {
                    if busy {
                        HStack {
                            ProgressView()
                            Text(progress.stage)
                            Spacer()
                            if progress.totalBytes > 0 {
                                Text("\(progress.sentBytes / 1024) / \(progress.totalBytes / 1024) KB")
                                    .font(.caption)
                                    .foregroundStyle(palette.muted)
                            }
                        }
                    }
                    if let st = serviceState {
                        Text("Installed: \(st.installed ? "Yes" : "No") · Running: \(st.running ? "Yes" : "No") · Ready: \(st.ready ? "Yes" : "No")")
                            .font(.footnote)
                    }
                    if let errorText {
                        Text(errorText).font(.caption).foregroundStyle(palette.error)
                    }

                    HStack {
                        Button(L10n.tr("service_check")) { run(.status) }.disabled(busy || address.isEmpty)
                        Spacer()
                        Button(L10n.tr("service_install")) { run(.install) }
                            .buttonStyle(.borderedProminent)
                            .tint(palette.primary)
                            .disabled(busy || address.isEmpty)
                    }

                    if serviceState?.installed == true {
                        HStack {
                            Button(L10n.tr("service_start")) { run(.start) }.disabled(busy)
                            Spacer()
                            Button(L10n.tr("service_stop")) { run(.stop) }.disabled(busy)
                            Spacer()
                            Button(L10n.tr("service_uninstall"), role: .destructive) { run(.uninstall) }.disabled(busy)
                        }
                        Toggle(L10n.tr("service_purge"), isOn: $purgeOnRemove)
                    }

                    if exportedAccessJSON != nil {
                        Button {
                            showExporter = true
                        } label: {
                            Label(L10n.tr("ios_relay_export_ready"), systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("new_deploy_relay"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("close")) { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $showExporter,
                document: RelayAccessDocument(text: exportedAccessJSON ?? ""),
                contentType: .json,
                defaultFilename: "pebrel-relay-access.json"
            ) { _ in }
        }
    }

    private func run(_ action: RelayServiceAction) {
        let host = selectedHost ?? HostProfile(
            name: address,
            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(sshPort) ?? 22,
            user: user.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let pwd = repository.passwordForConnection(host, explicit: password.isEmpty ? nil : ZeroizedBytes(utf8: password)) ?? ZeroizedBytes([])
        let key = host.hasPrivateKey ? (KeychainStore.shared.loadPrivateKey(for: host.keyId) ?? ZeroizedBytes([])) : ZeroizedBytes([])
        let adv = advertisedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host.address : advertisedAddress

        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            do {
                let res = try await NativeRelayDeployment.execute(
                    host: host,
                    password: pwd,
                    privateKey: key,
                    verifyHostKey: { h, fp in
                        await repository.requestHostTrust(ownerId: "relay-deploy", host: h, fingerprint: fp)
                    },
                    action: action,
                    advertisedAddress: adv,
                    relayPort: Int(relayPort) ?? 443,
                    purge: purgeOnRemove,
                    progress: { p in progress = p }
                )
                serviceState = res.state
                if let access = res.accessJSON {
                    exportedAccessJSON = access
                    showExporter = true
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
