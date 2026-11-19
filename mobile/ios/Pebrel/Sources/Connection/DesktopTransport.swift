import Foundation

protocol DesktopTransport: AnyObject {
    var transportLabel: String { get }
    var onFrame: (([String: Any]) -> Void)? { get set }
    var onFailure: ((DesktopFailureKind) -> Void)? { get set }
    func open() async throws
    func send(_ frame: [String: Any]) async throws
    func readyTimeoutFailure() -> DesktopFailureKind
    func close()
}

/// NDJSON Desktop Runtime transport over an authenticated SSH exec channel (`pebrel mobile-bridge`).
final class SshDesktopTransport: DesktopTransport {
    let host: HostProfile
    let allowInput: Bool
    private let password: ZeroizedBytes
    private let privateKey: ZeroizedBytes
    private let verifyHostKey: (HostProfile, String) async -> Bool

    private var ssh: NativeSshHandle?
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private let writeLock = NSLock()
    private var closed = false
    private let maxLineBytes = 2 * 1024 * 1024

    var onFrame: (([String: Any]) -> Void)?
    var onFailure: ((DesktopFailureKind) -> Void)?
    var transportLabel: String { "SSH" }

    init(
        host: HostProfile,
        password: ZeroizedBytes,
        privateKey: ZeroizedBytes,
        allowInput: Bool,
        verifyHostKey: @escaping (HostProfile, String) async -> Bool
    ) {
        self.host = host
        self.password = ZeroizedBytes(password.copyBytes())
        self.privateKey = ZeroizedBytes(privateKey.copyBytes())
        self.allowInput = allowInput
        self.verifyHostKey = verifyHostKey
    }

    func readyTimeoutFailure() -> DesktopFailureKind {
        .runtimeUnavailable
    }

    func open() async throws {
        defer {
            password.wipe()
            privateKey.wipe()
        }
        let handle = try NativeSshHandle(
            host: host.address,
            port: host.port,
            user: host.user,
            password: password.copyBytes(),
            fingerprint: host.fingerprint,
            privateKey: privateKey.copyBytes()
        )
        self.ssh = handle

        // Drive SSH connection events until "connected"
        while true {
            let event = try await runBlocking { try handle.nextEvent() }
            if event == "connected" { break }
            if event.hasPrefix("verify:") {
                let fp = String(event.dropFirst("verify:".count))
                let accepted = await verifyHostKey(host, fp)
                try handle.answerHostKey(accepted: accepted)
            } else if event.hasPrefix("error:") {
                let code = String(event.dropFirst("error:".count))
                handle.close()
                throw DesktopFailure(mapSshCode(code))
            }
        }

        let cmd = allowInput ? "pebrel mobile-bridge --allow-input" : "pebrel mobile-bridge"
        try await runBlocking { try handle.openExec(command: cmd) }

        stderrTask = Task.detached(priority: .utility) { [weak handle] in
            while let handle, !Task.isCancelled {
                guard let chunk = try? handle.read(maxBytes: 8192, stderr: true), chunk != nil else { break }
            }
        }

        readerTask = Task.detached(priority: .userInitiated) { [weak self, weak handle] in
            guard let self, let handle else { return }
            var buffer = Data()
            while !Task.isCancelled {
                do {
                    guard let chunk = try handle.read(maxBytes: 16384, stderr: false) else {
                        if !buffer.isEmpty {
                            self.fail(.protocol)
                        } else {
                            self.fail(.disconnected)
                        }
                        return
                    }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<nl]
                        buffer.removeSubrange(buffer.startIndex...nl)
                        if lineData.count > self.maxLineBytes {
                            self.fail(.protocol)
                            return
                        }
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else {
                            self.fail(.protocol)
                            return
                        }
                        self.onFrame?(obj)
                    }
                    if buffer.count > self.maxLineBytes {
                        self.fail(.protocol)
                        return
                    }
                } catch {
                    self.fail(.network)
                    return
                }
            }
        }
    }

    func send(_ frame: [String: Any]) async throws {
        guard let ssh,
              var data = try? JSONSerialization.data(withJSONObject: frame) else {
            throw DesktopFailure(.protocol)
        }
        data.append(0x0A)
        try await runBlocking {
            self.writeLock.lock()
            defer { self.writeLock.unlock() }
            try ssh.write(data)
        }
    }

    func close() {
        writeLock.lock()
        let already = closed
        closed = true
        writeLock.unlock()
        if already { return }
        readerTask?.cancel()
        stderrTask?.cancel()
        ssh?.close()
        ssh = nil
    }

    private func fail(_ kind: DesktopFailureKind) {
        writeLock.lock()
        let already = closed
        writeLock.unlock()
        if already { return }
        close()
        onFailure?(kind)
    }

    private func mapSshCode(_ code: String) -> DesktopFailureKind {
        switch code {
        case "UNKNOWN_HOST": return .dns
        case "REFUSED": return .refused
        case "TIMEOUT": return .timeout
        case "AUTH", "KEY", "TRUST_REJECTED": return .authentication
        case "HOST_KEY_CHANGED": return .certificateChanged
        default: return .network
        }
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
