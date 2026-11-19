import Foundation

enum SshStage: String, Equatable {
    case network = "NETWORK"
    case verifying = "VERIFYING"
    case authenticating = "AUTHENTICATING"
    case openingShell = "OPENING_SHELL"
}

enum SshFailureKind: String, Equatable {
    case unknownHost = "UNKNOWN_HOST"
    case timeout = "TIMEOUT"
    case refused = "REFUSED"
    case auth = "AUTH"
    case hostKeyChanged = "HOST_KEY_CHANGED"
    case trustRejected = "TRUST_REJECTED"
    case channel = "CHANNEL"
    case network = "NETWORK"
    case crypto = "CRYPTO"
    case negotiation = "NEGOTIATION"
    case key = "KEY"
    case unknown = "UNKNOWN"

    var isRetryable: Bool {
        switch self {
        case .network, .timeout, .unknownHost, .refused: return true
        default: return false
        }
    }

    static func fromCode(_ code: String) -> SshFailureKind {
        SshFailureKind(rawValue: code) ?? .unknown
    }
}

struct RemoteWindow: Identifiable, Equatable, Hashable {
    let id: String
    let index: Int
    let name: String
    let active: Bool
    let paneId: String
}

struct RemoteSessionEntry: Identifiable, Equatable, Hashable {
    let kind: String // "tmux" | "herdr"
    let id: String
    let name: String
    let attached: Bool
    let identity: String
    var windows: [RemoteWindow]

    var uniqueId: String { "\(kind):\(id)" }
}

struct RemoteAttachment: Equatable, Hashable {
    let kind: String
    let sessionId: String
    let sessionName: String
    let identity: String
    let windowId: String?
    let paneId: String?

    var title: String {
        if let windowId, !windowId.isEmpty {
            return "\(sessionName) · \(windowId)"
        }
        return sessionName
    }
}

enum RemoteSessions {
    static let pathSetup = "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin\"; export PATH;"

    static func posixWithPath(_ body: String) -> String {
        "sh -c \(CryptoHelpers.shellSingleQuote("\(pathSetup) \(body)"))"
    }

    static func discover(query: (String) async throws -> (status: Int, stdout: String)) async -> (os: String, sessions: [RemoteSessionEntry]) {
        let script = """
        printf '\\036os\\n'; uname -s 2>/dev/null || true
        printf '\\036distro\\n'; [ -r /etc/os-release ] && grep '^ID=' /etc/os-release | head -n 1 || true
        printf '\\036tmux\\n'; command -v tmux >/dev/null 2>&1 && tmux -u list-sessions -F '#{session_id}\t#{session_name}\t#{session_attached}\t#{session_created}:#{pid}' 2>/dev/null || true
        printf '\\036windows\\n'; command -v tmux >/dev/null 2>&1 && tmux -u list-windows -a -F '#{session_id}\t#{window_id}\t#{window_index}\t#{window_name}\t#{window_active}\t#{pane_id}' 2>/dev/null || true
        printf '\\036herdr\\n'; command -v herdr >/dev/null 2>&1 && herdr session list --json 2>/dev/null || true
        printf '\\036end\\n'
        """
        if let reply = try? await query(posixWithPath(script)), reply.stdout.contains("\u{001E}os\n") {
            return parsePosix(reply.stdout)
        }
        // Windows PowerShell fallback
        let ps = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Write-Output \"`e[0m\"; Write-Output \"$([char]30)os\"; Write-Output 'windows'; Write-Output \"$([char]30)herdr\"; if (Get-Command herdr -ErrorAction SilentlyContinue) { herdr session list --json }; Write-Output \"$([char]30)end\""
        if let utf16 = ps.data(using: .utf16LittleEndian) {
            let cmd = "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand \(utf16.base64EncodedString())"
            if let reply = try? await query(cmd) {
                return parsePosix(reply.stdout)
            }
        }
        return ("term", [])
    }

    static func attachCommand(for attachment: RemoteAttachment) -> String {
        if attachment.kind == "tmux" {
            let sid = CryptoHelpers.shellSingleQuote(attachment.sessionId)
            let ident = CryptoHelpers.shellSingleQuote(attachment.identity)
            var selectCmd = ""
            if let wid = attachment.windowId, !wid.isEmpty {
                selectCmd += " tmux -u select-window -t \(CryptoHelpers.shellSingleQuote(wid)) 2>/dev/null || true;"
            }
            if let pid = attachment.paneId, !pid.isEmpty {
                selectCmd += " tmux -u select-pane -t \(CryptoHelpers.shellSingleQuote(pid)) 2>/dev/null || true;"
            }
            let body = """
            if [ "$(tmux -u display-message -p -t \(sid) '#{session_created}:#{pid}' 2>/dev/null)" = \(ident) ]; then
              \(selectCmd)
              exec tmux -u attach-session -t \(sid)
            fi
            exec "${SHELL:-/bin/sh}" -l
            """
            return posixWithPath(body)
        } else {
            let sid = CryptoHelpers.shellSingleQuote(attachment.sessionId)
            var focus = ""
            if let wid = attachment.windowId, !wid.isEmpty {
                focus = "herdr --session \(sid) tab focus \(CryptoHelpers.shellSingleQuote(wid)) 2>/dev/null || true; "
            }
            return posixWithPath("\(focus)HERDR_REMOTE_KEYBINDINGS=server exec herdr --session \(sid) client")
        }
    }

    private static func parsePosix(_ output: String) -> (os: String, sessions: [RemoteSessionEntry]) {
        var sections: [String: String] = [:]
        for chunk in output.components(separatedBy: "\u{001E}") {
            guard let nl = chunk.firstIndex(of: "\n") else { continue }
            let header = String(chunk[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(chunk[chunk.index(after: nl)...])
            sections[header] = body
        }

        let rawOs = (sections["os"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawDistro = (sections["distro"] ?? "")
            .replacingOccurrences(of: "ID=", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let osIcon = HostIconCatalog.desktopOsIcon(rawDistro.isEmpty ? rawOs : rawDistro)

        var windowsBySession: [String: [RemoteWindow]] = [:]
        for line in (sections["windows"] ?? "").components(separatedBy: "\n").prefix(256) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 6, cols[0].hasPrefix("$"), cols[1].hasPrefix("@") else { continue }
            let win = RemoteWindow(
                id: cols[1],
                index: Int(cols[2]) ?? 0,
                name: cols[3],
                active: cols[4] == "1",
                paneId: cols[5]
            )
            windowsBySession[cols[0], default: []].append(win)
        }

        var sessions: [RemoteSessionEntry] = []
        for line in (sections["tmux"] ?? "").components(separatedBy: "\n").prefix(128) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 4, cols[0].hasPrefix("$") else { continue }
            sessions.append(RemoteSessionEntry(
                kind: "tmux",
                id: cols[0],
                name: cols[1],
                attached: (Int(cols[2]) ?? 0) > 0,
                identity: cols[3],
                windows: windowsBySession[cols[0]] ?? []
            ))
        }

        if let herdrBody = sections["herdr"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let data = herdrBody.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["sessions"] as? [[String: Any]] {
            for item in list.prefix(128) {
                guard let name = item["name"] as? String, !name.isEmpty else { continue }
                let running = item["running"] as? Bool ?? true
                sessions.append(RemoteSessionEntry(
                    kind: "herdr",
                    id: name,
                    name: name,
                    attached: running,
                    identity: name,
                    windows: []
                ))
            }
        }

        return (osIcon, sessions)
    }
}

/// Filters the nonce-scoped `\x1ePEBREL_TTY_<nonce>=<tty>\x1f` marker from the first 8 KiB of PTY output.
final class PtyIdentityFilter {
    private let prefix: [UInt8]
    private var scanned = 0
    private var finished = false
    private var carry = Data()
    private(set) var detectedTty: String?

    init(nonce: String) {
        self.prefix = Array("\u{001E}PEBREL_TTY_\(nonce)=".utf8)
    }

    func process(_ chunk: Data) -> Data {
        guard !finished else { return chunk }
        carry.append(chunk)
        if let startRange = carry.range(of: Data(prefix)) {
            if let endIdx = carry[startRange.upperBound...].firstIndex(of: 0x1F) {
                let ttyData = carry[startRange.upperBound..<endIdx]
                if let tty = String(data: ttyData, encoding: .utf8),
                   tty.hasPrefix("/dev/"), tty.count <= 133 {
                    detectedTty = tty
                }
                var out = Data()
                out.append(carry[carry.startIndex..<startRange.lowerBound])
                out.append(carry[carry.index(after: endIdx)...])
                carry.removeAll()
                finished = true
                return out
            }
            if carry.count > 8192 {
                finished = true
                let out = carry
                carry.removeAll()
                return out
            }
            return Data()
        }
        scanned += chunk.count
        if scanned >= 8192 {
            finished = true
            let out = carry
            carry.removeAll()
            return out
        }
        let keepTail = min(carry.count, prefix.count)
        let emitLen = carry.count - keepTail
        if emitLen > 0 {
            let out = carry.prefix(emitLen)
            carry.removeFirst(emitLen)
            return Data(out)
        }
        return Data()
    }
}

/// Manages one live SSH terminal connection, out-of-band queries, tmux copy-mode scrolling,
/// and SFTP subsystem access over the same authenticated `NativeSshHandle`.
final class SshConnection: TerminalTransportBridge {
    let host: HostProfile
    let attachment: RemoteAttachment?

    private let lock = NSLock()
    private var handle: NativeSshHandle?
    private var readTask: Task<Void, Never>?
    private var ttyFilter: PtyIdentityFilter?
    private var closed = false
    private(set) var isReady = false

    var onStage: ((SshStage) -> Void)?
    var onVerifyHostKey: ((String) async -> Bool)?
    var onReady: (() -> Void)?
    var onOutput: ((Data) -> Void)?
    var onFailure: ((SshFailureKind) -> Void)?
    var onEnded: ((Int) -> Void)?

    init(host: HostProfile, attachment: RemoteAttachment? = nil) {
        self.host = host
        self.attachment = attachment
    }

    func connect(
        password: ZeroizedBytes,
        privateKey: ZeroizedBytes,
        geometry: (columns: Int, rows: Int, width: Int, height: Int),
        reconnecting: Bool = false
    ) async {
        do {
            onStage?(.network)
            let ssh = try NativeSshHandle(
                host: host.address,
                port: host.port,
                user: host.user,
                password: password.copyBytes(),
                fingerprint: host.fingerprint,
                privateKey: privateKey.copyBytes()
            )
            lock.lock()
            if closed {
                lock.unlock()
                ssh.close()
                return
            }
            handle = ssh
            lock.unlock()

            while true {
                let event = try await runBlocking { try ssh.nextEvent() }
                if event == "stage:NETWORK" {
                    onStage?(.network)
                } else if event == "stage:AUTHENTICATING" {
                    onStage?(.authenticating)
                } else if event.hasPrefix("verify:") {
                    onStage?(.verifying)
                    let fp = String(event.dropFirst("verify:".count))
                    let accepted = await (onVerifyHostKey?(fp) ?? false)
                    try ssh.answerHostKey(accepted: accepted)
                } else if event == "connected" {
                    break
                } else if event.hasPrefix("error:") {
                    let code = String(event.dropFirst("error:".count))
                    throw NativeSshError(code: code)
                }
            }

            onStage?(.openingShell)
            let ptyCmd: String?
            if let attachment {
                ptyCmd = RemoteSessions.attachCommand(for: attachment)
            } else {
                ptyCmd = reconnecting ? host.reconnectCommand() : host.attachCommand()
            }

            if let ptyCmd {
                let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                ttyFilter = PtyIdentityFilter(nonce: nonce)
                let wrapped = "printf '\\036PEBREL_TTY_\(nonce)=%s\\037' \"$(tty)\"; \(ptyCmd)"
                try await runBlocking {
                    try ssh.openPtyExec(
                        command: wrapped,
                        columns: geometry.columns,
                        rows: geometry.rows,
                        width: geometry.width,
                        height: geometry.height
                    )
                }
            } else {
                try await runBlocking {
                    try ssh.openShell(
                        columns: geometry.columns,
                        rows: geometry.rows,
                        width: geometry.width,
                        height: geometry.height
                    )
                }
            }

            isReady = true
            onReady?()
            startReadLoop(ssh)
        } catch let sshErr as NativeSshError {
            isReady = false
            onFailure?(SshFailureKind.fromCode(sshErr.code))
        } catch {
            isReady = false
            onFailure?(.unknown)
        }
    }

    func sendBytes(_ data: Data) async throws {
        guard let ssh = currentHandle(), isReady else {
            throw NativeSshError(code: "CLOSED")
        }
        try await runBlocking { try ssh.write(data) }
    }

    func resize(columns: Int, rows: Int, width: Int, height: Int) async throws {
        guard let ssh = currentHandle(), isReady else { return }
        try await runBlocking {
            try ssh.resize(columns: columns, rows: rows, width: width, height: height)
        }
    }

    func query(_ command: String) async throws -> (status: Int, stdout: String) {
        guard let ssh = currentHandle(), isReady else {
            throw NativeSshError(code: "CLOSED")
        }
        let raw = try await runBlocking { try ssh.query(command: command) }
        if let nl = raw.firstIndex(of: "\n") {
            let status = Int(raw[..<nl]) ?? -1
            let body = String(raw[raw.index(after: nl)...])
            return (status, body)
        }
        return (Int(raw) ?? -1, "")
    }

    func sftpRequest(_ request: [String: Any]) throws -> [String: Any] {
        guard let ssh = currentHandle(), isReady else {
            throw NativeSshError(code: "SFTP_CLOSED")
        }
        guard let reqData = try? JSONSerialization.data(withJSONObject: request),
              let reqStr = String(data: reqData, encoding: .utf8) else {
            throw NativeSshError(code: "INVALID_INPUT")
        }
        let respStr = try ssh.sftp(requestJSON: reqStr)
        guard let respData = respStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            throw NativeSshError(code: "SFTP_OPERATION")
        }
        return obj
    }

    func scrollHistory(lines: Int) async {
        guard let tty = ttyFilter?.detectedTty, lines != 0 else { return }
        let count = abs(lines.clamped(to: -256...256))
        let dir = lines < 0 ? "scroll-up" : "scroll-down"
        let cmd = RemoteSessions.posixWithPath(
            "t=\(CryptoHelpers.shellSingleQuote(tty)); " +
            "target=$(tmux -u list-clients -F '#{client_tty}\t#{session_id}:#{window_id}.#{pane_id}\t#{pane_mode}' 2>/dev/null | awk -F'\t' -v t=\"$t\" '$1==t{print $2\"\t\"$3;exit}'); " +
            "pane=$(printf '%s' \"$target\" | cut -f1); mode=$(printf '%s' \"$target\" | cut -f2); " +
            "[ -n \"$pane\" ] || exit 0; " +
            "[ -z \"$mode\" ] && [ \"\(dir)\" = scroll-up ] && tmux -u copy-mode -t \"$pane\" 2>/dev/null || true; " +
            "tmux -u send-keys -X -N \(count) -t \"$pane\" \(dir) 2>/dev/null || true"
        )
        _ = try? await query(cmd)
    }

    func returnToLiveInput() async {
        guard let tty = ttyFilter?.detectedTty else { return }
        let cmd = RemoteSessions.posixWithPath(
            "t=\(CryptoHelpers.shellSingleQuote(tty)); " +
            "pane=$(tmux -u list-clients -F '#{client_tty}\t#{session_id}:#{window_id}.#{pane_id}\t#{pane_mode}' 2>/dev/null | awk -F'\t' -v t=\"$t\" '$1==t && $3==\"copy-mode\"{print $2;exit}'); " +
            "[ -n \"$pane\" ] && tmux -u send-keys -X -t \"$pane\" cancel 2>/dev/null || true"
        )
        _ = try? await query(cmd)
    }

    func close() {
        lock.lock()
        closed = true
        isReady = false
        let ssh = handle
        handle = nil
        lock.unlock()
        readTask?.cancel()
        readTask = nil
        ssh?.close()
    }

    private func currentHandle() -> NativeSshHandle? {
        lock.lock()
        let h = handle
        lock.unlock()
        return h
    }

    private func startReadLoop(_ ssh: NativeSshHandle) {
        readTask = Task.detached(priority: .userInitiated) { [weak self, weak ssh] in
            guard let self, let ssh else { return }
            while !Task.isCancelled {
                do {
                    guard let chunk = try ssh.read(maxBytes: 16384, stderr: false) else {
                        let code = (try? ssh.awaitExit()) ?? 0
                        self.isReady = false
                        self.onEnded?(code)
                        return
                    }
                    let filtered = self.ttyFilter?.process(chunk) ?? chunk
                    if !filtered.isEmpty {
                        self.onOutput?(filtered)
                    }
                } catch let sshErr as NativeSshError {
                    self.isReady = false
                    if !self.isClosed() {
                        self.onFailure?(SshFailureKind.fromCode(sshErr.code))
                    }
                    return
                } catch {
                    self.isReady = false
                    if !self.isClosed() {
                        self.onFailure?(.network)
                    }
                    return
                }
            }
        }
    }

    private func isClosed() -> Bool {
        lock.lock()
        let c = closed
        lock.unlock()
        return c
    }

    private func runBlocking<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    deinit {
        close()
    }
}
