import Foundation

enum RelayServiceAction {
    case status
    case install
    case start
    case stop
    case uninstall
}

struct RelayServiceState: Equatable {
    let installed: Bool
    let running: Bool
    let ready: Bool
    let retained: Bool
}

struct RelayServiceProgress: Equatable {
    let stage: String
    let sentBytes: Int
    let totalBytes: Int

    init(_ stage: String, sentBytes: Int = 0, totalBytes: Int = 0) {
        self.stage = stage
        self.sentBytes = sentBytes
        self.totalBytes = totalBytes
    }
}

struct RelayServiceResult: Equatable {
    let state: RelayServiceState
    let accessJSON: String?
}

struct RelayServiceFailure: Error, LocalizedError {
    let code: String
    var errorDescription: String? { code }
}

/// Manages self-hosted Linux `pebrel-relay` installation and lifecycle over SSH.
enum NativeRelayDeployment {
    private static let remoteBinary = "/opt/pebrel-relay/pebrel-relay"
    private static let allowedStages: Set<String> = [
        "checking", "uploaded", "initializing", "installing", "starting",
        "verifying", "ready", "stopping", "stopped", "removing", "uninstalled"
    ]
    private static let knownFailures: Set<String> = [
        "systemd_247_required", "systemd_239_required", "linux_systemd_required", "root_required",
        "installation_conflict", "managed_file_changed", "explicit_update_required", "service_not_ready",
        "port_in_use", "permission_denied", "file_or_service_not_found", "binary_integrity_failed",
        "supported_init_required", "openrc_supervisor_required", "service_manager_changed",
        "configuration_directory_not_empty", "symlink_installation_path", "invalid_ownership_manifest",
        "service_command_failed", "service_command_timeout", "service_command_output_limit",
        "unprivileged_account_required", "privilege_drop_failed", "remote_tools_missing",
        "operation_timeout", "relay_operation_failed"
    ]

    static func execute(
        host: HostProfile,
        password: ZeroizedBytes,
        privateKey: ZeroizedBytes,
        verifyHostKey: @escaping (HostProfile, String) async -> Bool,
        action: RelayServiceAction,
        advertisedAddress: String,
        relayPort: Int = 443,
        purge: Bool = false,
        progress: @escaping @MainActor (RelayServiceProgress) -> Void
    ) async throws -> RelayServiceResult {
        guard (1...65535).contains(relayPort) else { throw RelayServiceFailure(code: "invalid_address") }
        let endpoint = try validatedAddress(advertisedAddress)

        await progress(RelayServiceProgress("connecting"))
        let preflight = try await runExec(
            host: host, password: password, privateKey: privateKey,
            verifyHostKey: verifyHostKey, command: preflightCommand(),
            input: nil, onConnected: { await progress(RelayServiceProgress("checking")) },
            onStage: { st in await progress(RelayServiceProgress(st)) }
        )
        guard let arch = preflight.last?["arch"] as? String else {
            throw RelayServiceFailure(code: "invalid_response")
        }

        let statusCmd = """
        set -eu
        if [ -L \(remoteBinary) ]; then printf '{"error":"managed_file_changed"}\\n'; exit 1; fi
        if [ -x \(remoteBinary) ]; then \(remoteBinary) service-status
        else printf '{"installed":false,"running":false,"ready":false,"configuration_retained":false}\\n'; fi
        """
        let stateList = try await runExec(
            host: host, password: password, privateKey: privateKey,
            verifyHostKey: verifyHostKey, command: statusCmd,
            input: nil, onConnected: {}, onStage: { st in await progress(RelayServiceProgress(st)) }
        )
        guard let stateDict = stateList.last, let parsedState = parseState(stateDict) else {
            throw RelayServiceFailure(code: "invalid_response")
        }
        if action == .status {
            return RelayServiceResult(state: parsedState, accessJSON: nil)
        }

        if action == .install {
            let binary = try loadBundledRelay(arch: arch)
            let sha = CryptoHelpers.sha256Hex(binary)
            let encoded = Data(binary.base64EncodedString().utf8)
            let qEndpoint = CryptoHelpers.shellSingleQuote(endpoint)
            let installCmd = """
            set -eu
            umask 077
            [ ! -L /opt ] || { printf '{"error":"symlink_installation_path"}\\n'; exit 1; }
            mkdir -p /opt
            stage=$(mktemp -d /opt/.pebrel-relay.XXXXXXXX)
            trap 'rm -f "$stage/pebrel-relay"; rmdir "$stage"' EXIT
            head -c \(encoded.count) | base64 -d > "$stage/pebrel-relay"
            printf '%s  %s\\n' '\(sha)' "$stage/pebrel-relay" | sha256sum -c - >/dev/null || { printf '{"error":"binary_integrity_failed"}\\n'; exit 1; }
            printf '{"event":"progress","stage":"uploaded"}\\n'
            chmod 700 "$stage/pebrel-relay"
            "$stage/pebrel-relay" service-install --source "$stage/pebrel-relay" --sha256 '\(sha)' --address \(qEndpoint) --port \(relayPort)
            \(remoteBinary) export-access --directory /etc/pebrel-relay
            printf '\\n'
            \(remoteBinary) service-status
            """
            await progress(RelayServiceProgress("uploading", sentBytes: 0, totalBytes: encoded.count))
            let result = try await runExec(
                host: host, password: password, privateKey: privateKey,
                verifyHostKey: verifyHostKey, command: installCmd,
                input: encoded, onConnected: {},
                onStage: { st in await progress(RelayServiceProgress(st)) },
                onUpload: { sent, total in await progress(RelayServiceProgress("uploading", sentBytes: sent, totalBytes: total)) }
            )
            guard let accessDict = result.first(where: { ($0["version"] as? Int) == 2 && $0["desktopToken"] != nil }),
                  isValidAccess(accessDict),
                  let accessData = try? JSONSerialization.data(withJSONObject: accessDict, options: [.prettyPrinted]),
                  let accessStr = String(data: accessData, encoding: .utf8),
                  let lastDict = result.last,
                  let finalState = parseState(lastDict) else {
                throw RelayServiceFailure(code: "invalid_access")
            }
            guard finalState.ready else { throw RelayServiceFailure(code: "service_not_ready") }
            return RelayServiceResult(state: finalState, accessJSON: accessStr)
        }

        guard parsedState.installed else { throw RelayServiceFailure(code: "file_or_service_not_found") }
        let op: String
        switch action {
        case .start: op = "service-start"
        case .stop: op = "service-stop"
        case .uninstall: op = purge ? "service-uninstall --purge" : "service-uninstall"
        default: op = "service-status"
        }
        let cmd = action == .uninstall ? "\(remoteBinary) \(op)" : "\(remoteBinary) \(op)\n\(remoteBinary) service-status"
        let res = try await runExec(
            host: host, password: password, privateKey: privateKey,
            verifyHostKey: verifyHostKey, command: cmd,
            input: nil, onConnected: {}, onStage: { st in await progress(RelayServiceProgress(st)) }
        )
        if action == .uninstall {
            guard (res.last?["ok"] as? Bool) == true else { throw RelayServiceFailure(code: "service_failed") }
            return RelayServiceResult(state: RelayServiceState(installed: false, running: false, ready: false, retained: !purge), accessJSON: nil)
        }
        guard let lastDict = res.last, let finalState = parseState(lastDict) else {
            throw RelayServiceFailure(code: "invalid_response")
        }
        return RelayServiceResult(state: finalState, accessJSON: nil)
    }

    static func preflightCommand() -> String {
        """
        set -eu
        fail() { printf '{"error":"%s"}\\n' "$1"; exit 1; }
        [ "$(uname -s)" = Linux ] || fail linux_systemd_required
        [ "$(id -u)" = 0 ] || fail root_required
        for tool in head base64 sha256sum mktemp chmod; do
            command -v "$tool" >/dev/null 2>&1 || fail remote_tools_missing
        done
        if [ -d /run/systemd/system ]; then
            command -v systemctl >/dev/null 2>&1 || fail supported_init_required
        elif [ -d /run/openrc ] && [ -x /sbin/rc-service ] && [ -x /sbin/openrc-run ]; then
            [ -x /sbin/supervise-daemon ] && [ -x /sbin/rc-update ] || fail openrc_supervisor_required
        else
            fail supported_init_required
        fi
        printf '{"arch":"%s"}\\n' "$(uname -m)"
        """
    }

    static func validatedAddress(_ raw: String) throws -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy({ s in
                  (s.value >= 48 && s.value <= 57) ||
                  (s.value >= 65 && s.value <= 90) ||
                  (s.value >= 97 && s.value <= 122) ||
                  s == "." || s == ":" || s == "-"
              }) else {
            throw RelayServiceFailure(code: "invalid_address")
        }
        return host
    }

    private static func loadBundledRelay(arch: String) throws -> Data {
        guard arch == "x86_64" || arch == "aarch64" else {
            throw RelayServiceFailure(code: "unsupported_arch")
        }
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("native-relay/\(arch)"),
              let manifestData = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let binary = try? Data(contentsOf: root.appendingPathComponent("pebrel-relay")) else {
            throw RelayServiceFailure(code: "asset_missing")
        }
        guard binary.count >= 64, binary.count <= 64 * 1024 * 1024,
              (manifest["sha256"] as? String) == CryptoHelpers.sha256Hex(binary),
              (manifest["arch"] as? String) == arch,
              (manifest["protocol"] as? Int) == 2 else {
            throw RelayServiceFailure(code: "binary_integrity_failed")
        }
        return binary
    }

    private static func parseState(_ dict: [String: Any]) -> RelayServiceState? {
        guard let installed = dict["installed"] as? Bool,
              let running = dict["running"] as? Bool,
              let ready = dict["ready"] as? Bool,
              let retained = dict["configuration_retained"] as? Bool else {
            return nil
        }
        return RelayServiceState(installed: installed, running: running, ready: ready, retained: retained)
    }

    private static func isValidAccess(_ dict: [String: Any]) -> Bool {
        guard (dict["version"] as? Int) == 2,
              let url = dict["url"] as? String, RelayProfile.normalizeWssURL(url) != nil,
              let room = dict["room"] as? String, RelayProfile.isValidIdentifier(room),
              let pin = dict["tlsPin"] as? String, PinnedTlsSessionDelegate.isValidPin(pin),
              let dt = dict["desktopToken"] as? String, RelayProfile.isValidToken(dt),
              let mt = dict["mobileToken"] as? String, RelayProfile.isValidToken(mt),
              dt != mt else {
            return false
        }
        return true
    }

    private static func runExec(
        host: HostProfile,
        password: ZeroizedBytes,
        privateKey: ZeroizedBytes,
        verifyHostKey: @escaping (HostProfile, String) async -> Bool,
        command: String,
        input: Data?,
        onConnected: @escaping () async -> Void,
        onStage: @escaping (String) async -> Void,
        onUpload: @escaping (Int, Int) async -> Void = { _, _ in }
    ) async throws -> [[String: Any]] {
        let ssh = try NativeSshHandle(
            host: host.address,
            port: host.port,
            user: host.user,
            password: password.copyBytes(),
            fingerprint: host.fingerprint,
            privateKey: privateKey.copyBytes()
        )
        defer { ssh.close() }

        while true {
            let ev = try await runBlocking { try ssh.nextEvent() }
            if ev == "connected" { break }
            if ev.hasPrefix("verify:") {
                let fp = String(ev.dropFirst("verify:".count))
                let ok = await verifyHostKey(host, fp)
                try ssh.answerHostKey(accepted: ok)
            } else if ev.hasPrefix("error:") {
                throw RelayServiceFailure(code: String(ev.dropFirst("error:".count)))
            }
        }
        await onConnected()
        try await runBlocking { try ssh.openExec(command: command) }

        async let outLines = readJsonStream(ssh: ssh, stderr: false, onStage: onStage)
        async let errLines = readJsonStream(ssh: ssh, stderr: true, onStage: { _ in })
        async let writeResult: Void = writeUpload(ssh: ssh, input: input, onUpload: onUpload)
        let exitCode = try await runBlocking { try ssh.awaitExit() }
        try await writeResult
        let messages = try await outLines
        let errors = try await errLines

        let failure = (messages + errors).compactMap { $0["error"] as? String }.first
        if exitCode != 0 || failure != nil {
            let code = failure.flatMap { knownFailures.contains($0) ? $0 : nil } ?? "service_failed"
            throw RelayServiceFailure(code: code)
        }
        guard !messages.isEmpty else { throw RelayServiceFailure(code: "invalid_response") }
        return messages
    }

    private static func writeUpload(
        ssh: NativeSshHandle,
        input: Data?,
        onUpload: @escaping (Int, Int) async -> Void
    ) async throws {
        guard let input else { return }
        var sent = 0
        while sent < input.count {
            let count = min(32 * 1024, input.count - sent)
            let chunk = input.subdata(in: sent..<(sent + count))
            try await runBlocking { try ssh.write(chunk) }
            sent += count
            await onUpload(sent, input.count)
        }
    }

    private static func readJsonStream(
        ssh: NativeSshHandle,
        stderr: Bool,
        onStage: @escaping (String) async -> Void
    ) async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var buffer = Data()
        var acc = ""
        var total = 0
        while true {
            guard let chunk = try await runBlocking({ try ssh.read(maxBytes: 8192, stderr: stderr) }) else { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .newlines)
                total += line.count
                if total > 32 * 1024 || line.count > 8192 {
                    throw RelayServiceFailure(code: "output_limit")
                }
                if !acc.isEmpty || line.hasPrefix("{") {
                    acc += line
                    if let d = acc.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        acc = ""
                        if (obj["event"] as? String) == "progress",
                           let stage = obj["stage"] as? String, allowedStages.contains(stage) {
                            await onStage(stage)
                        } else {
                            result.append(obj)
                        }
                    }
                }
            }
        }
        return result
    }

    private static func runBlocking<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}
