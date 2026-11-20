import Foundation
import Network
import Security
import os

private let tlsLogger = Logger(subsystem: "io.github.kuddev.pebrel.mobile", category: "TLS")

/// Strict SPKI SHA-256 TLS pinning with X.509 validity-window and SAN hostname/IP verification.
/// Matches `mobile/link/src/endpoint/tls.rs` and Android `PinnedDesktopTls.kt` without tripping
/// Apple's public-PKI 825-day / EKU policy on `rcgen` self-signed LAN/relay certificates.
final class PinnedTlsSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
    private let expectedPin: String?
    private let expectedHost: String
    private let stateLock = NSLock()
    private var _pinFailure: DesktopFailureKind?

    var onWebSocketOpen: (() -> Void)?
    var onWebSocketClose: ((URLSessionWebSocketTask.CloseCode) -> Void)?
    var onTaskComplete: ((Error?, HTTPURLResponse?) -> Void)?

    var pinFailure: DesktopFailureKind? {
        stateLock.lock()
        let value = _pinFailure
        stateLock.unlock()
        return value
    }

    private func recordFailure(_ failure: DesktopFailureKind) {
        stateLock.lock()
        _pinFailure = failure
        stateLock.unlock()
    }

    init(expectedPin: String?, expectedHost: String) {
        self.expectedPin = expectedPin
        self.expectedHost = expectedHost
    }

    static func isValidPin(_ pin: String) -> Bool {
        guard pin.hasPrefix("sha256/") else { return false }
        let b64 = String(pin.dropFirst(7))
        guard b64.count == 44, b64.hasSuffix("="),
              let data = Data(base64Encoded: b64), data.count == 32 else {
            return false
        }
        return true
    }

    /// Extracts leaf DER directly from BoringSSL peer certificate chain metadata, falling back to SecTrust.
    static func copyLeafDER(metadata: sec_protocol_metadata_t, secTrust: sec_trust_t) -> Data? {
        var leafDER: Data?
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata) { secCert in
            if leafDER == nil {
                let cert = sec_certificate_copy_ref(secCert).takeRetainedValue()
                leafDER = SecCertificateCopyData(cert) as Data
            }
        }
        if let leafDER {
            return leafDER
        }
        let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
        return copyLeafDER(from: trust)
    }

    /// Extracts leaf DER from a SecTrust, evaluating once if Apple's chain cache has not been populated yet.
    static func copyLeafDER(from trust: SecTrust) -> Data? {
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
           let leaf = chain.first {
            return SecCertificateCopyData(leaf) as Data
        }
        var evalError: CFError?
        _ = SecTrustEvaluateWithError(trust, &evalError)
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
           let leaf = chain.first {
            return SecCertificateCopyData(leaf) as Data
        }
        return nil
    }

    /// Evaluates a pinned leaf X.509 DER certificate. Returns `nil` when valid, or the exact failure kind.
    static func evaluatePinnedLeafDER(
        _ leafDER: Data,
        expectedPin: String,
        expectedHost: String,
        nowUnix: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> DesktopFailureKind? {
        guard let cert = CryptoHelpers.inspectX509Certificate(from: leafDER) else {
            tlsLogger.error("Pinned TLS failed: X.509 DER parse failed (len=\(leafDER.count, privacy: .public))")
            return .tls
        }
        let actualPin = "sha256/" + CryptoHelpers.sha256Base64(cert.spkiDER)
        guard CryptoHelpers.constantTimeEquals(actualPin, expectedPin) else {
            tlsLogger.error("Pinned TLS failed: SPKI pin mismatch for host \(expectedHost, privacy: .public)")
            return .certificateChanged
        }
        guard cert.isValid(at: nowUnix) else {
            tlsLogger.error("Pinned TLS failed: cert outside validity [\(cert.notBeforeUnix, privacy: .public)..\(cert.notAfterUnix, privacy: .public)] at \(nowUnix, privacy: .public)")
            return .certificateDate
        }
        guard cert.matchesHost(expectedHost) else {
            tlsLogger.error("Pinned TLS failed: host \(expectedHost, privacy: .public) not in cert SANs (dns=\(cert.dnsNames.count, privacy: .public), ip=\(cert.ipAddresses.count, privacy: .public))")
            return .tls
        }
        return nil
    }

    private func handleServerTrustChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.rejectProtectionSpace, nil)
            return
        }

        // Standard CA trust path when no SPKI pin is configured (e.g. ACME/Caddy public relay)
        guard let expectedPin else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let leafDER = Self.copyLeafDER(from: trust) else {
            tlsLogger.error("Pinned TLS URLSession challenge failed: empty certificate chain")
            recordFailure(.tls)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if let failure = Self.evaluatePinnedLeafDER(
            leafDER,
            expectedPin: expectedPin,
            expectedHost: expectedHost
        ) {
            recordFailure(failure)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // SPKI pin, validity period, and SAN host/IP all match; let TLS verify the handshake signature.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleServerTrustChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleServerTrustChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol proto: String?
    ) {
        onWebSocketOpen?()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onWebSocketClose?(closeCode)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        onTaskComplete?(error, task.response as? HTTPURLResponse)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never follow HTTP redirects for pairing or relay WebSockets.
        completionHandler(nil)
    }
}

enum PinnedWebSocketMessage {
    case text(String)
    case data(Data)
}

private final class PinnedWsOpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled = false
    private var earlyResult: Result<Void, Error>?

    func setContinuation(_ cont: CheckedContinuation<Void, Error>) {
        lock.lock()
        if settled, let earlyResult {
            self.earlyResult = nil
            lock.unlock()
            cont.resume(with: earlyResult)
            return
        }
        continuation = cont
        lock.unlock()
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        let cont = continuation
        continuation = nil
        if cont == nil {
            earlyResult = result
        }
        lock.unlock()
        cont?.resume(with: result)
    }
}

private final class PinnedWsBoolGate: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var continuation: CheckedContinuation<Bool, Never>?
    private var earlyValue: Bool?

    func setContinuation(_ cont: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if settled, let earlyValue {
            self.earlyValue = nil
            lock.unlock()
            cont.resume(returning: earlyValue)
            return
        }
        continuation = cont
        lock.unlock()
    }

    func resolve(_ value: Bool) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        let cont = continuation
        continuation = nil
        if cont == nil {
            earlyValue = value
        }
        lock.unlock()
        cont?.resume(returning: value)
    }
}

/// Network.framework WebSocket client with BoringSSL SPKI-pinned TLS verification.
///
/// Used for all endpoints carrying an explicit `tlsPin` (LAN RFC1918, Tailscale/CGNAT `100.64.0.0/10`,
/// IPv6, and self-hosted relays using `rcgen` self-signed certificates). Because `Network.framework`
/// operates below `CFNetwork` / App Transport Security (ATS) and invokes our `sec_protocol_options_set_verify_block`
/// directly during BoringSSL's TLS 1.2/1.3 handshake, it enforces strict SPKI pinning + validity + SAN
/// without tripping ATS or Apple's public-PKI 825-day / EKU rejection rules.
final class PinnedWebSocketClient: @unchecked Sendable {
    private let url: URL
    private let expectedPin: String
    private let expectedHost: String
    private let headers: [(String, String)]
    private let maxFrameBytes: Int
    private let queue = DispatchQueue(label: "io.github.kuddev.pebrel.pinned-ws")

    private let lock = NSLock()
    private var connection: NWConnection?
    private var openGate: PinnedWsOpenGate?
    private var openTimeoutWork: DispatchWorkItem?
    private var _pinFailure: DesktopFailureKind?
    private var opened = false
    private var closed = false

    init(
        url: URL,
        expectedPin: String,
        expectedHost: String,
        headers: [(String, String)],
        maxFrameBytes: Int
    ) {
        self.url = url
        self.expectedPin = expectedPin
        self.expectedHost = expectedHost
        self.headers = headers
        self.maxFrameBytes = maxFrameBytes
    }

    private var pinFailure: DesktopFailureKind? {
        lock.lock()
        let val = _pinFailure
        lock.unlock()
        return val
    }

    private func recordPinFailure(_ failure: DesktopFailureKind) {
        lock.lock()
        _pinFailure = failure
        lock.unlock()
    }

    private func isOpened() -> Bool {
        lock.lock()
        let val = opened
        lock.unlock()
        return val
    }

    func open(timeoutSeconds: Double = 15) async throws {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { [weak self] metadata, secTrust, verifyComplete in
                guard let self else {
                    verifyComplete(false)
                    return
                }
                guard let leafDER = PinnedTlsSessionDelegate.copyLeafDER(metadata: metadata, secTrust: secTrust) else {
                    tlsLogger.error("Pinned NW TLS failed: empty peer certificate chain for host \(self.expectedHost, privacy: .public)")
                    self.recordPinFailure(.tls)
                    verifyComplete(false)
                    return
                }
                if let failure = PinnedTlsSessionDelegate.evaluatePinnedLeafDER(
                    leafDER,
                    expectedPin: self.expectedPin,
                    expectedHost: self.expectedHost
                ) {
                    self.recordPinFailure(failure)
                    verifyComplete(false)
                    return
                }
                verifyComplete(true)
            },
            queue
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = max(1, Int(timeoutSeconds.rounded(.up)))

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.maximumMessageSize = maxFrameBytes
        wsOptions.autoReplyPing = true
        if !headers.isEmpty {
            wsOptions.setAdditionalHeaders(headers)
        }

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let conn = NWConnection(to: .url(url), using: parameters)
        let gate = PinnedWsOpenGate()

        lock.lock()
        if closed {
            lock.unlock()
            throw DesktopFailure(.disconnected)
        }
        self.connection = conn
        self.openGate = gate
        lock.unlock()

        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isOpened() {
                let kind = self.pinFailure ?? .timeout
                gate.resolve(.failure(DesktopFailure(kind)))
                self.close()
            }
        }
        lock.lock()
        self.openTimeoutWork = timeoutWork
        lock.unlock()
        queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.opened = true
                let timer = self.openTimeoutWork
                self.openTimeoutWork = nil
                self.lock.unlock()
                timer?.cancel()
                gate.resolve(.success(()))
            case .failed(let error):
                let wasOpened = self.isOpened()
                let kind = self.pinFailure ?? DesktopFailureClassifier.classify(error, relayReached: wasOpened)
                tlsLogger.error("Pinned NW connection failed (opened=\(wasOpened, privacy: .public)): \(String(describing: error), privacy: .public) -> \(kind.rawValue, privacy: .public)")
                self.cancelOpenTimer()
                gate.resolve(.failure(DesktopFailure(kind)))
            case .waiting(let error):
                guard !self.isOpened() else { return }
                let immediateFailure: Bool
                if self.pinFailure != nil {
                    immediateFailure = true
                } else {
                    switch error {
                    case .tls, .dns:
                        immediateFailure = true
                    case .posix(let code):
                        immediateFailure = (code == .ECONNREFUSED || code == .EHOSTUNREACH || code == .ENETUNREACH)
                    @unknown default:
                        immediateFailure = false
                    }
                }
                if immediateFailure {
                    let kind = self.pinFailure ?? DesktopFailureClassifier.classify(error, relayReached: false)
                    tlsLogger.error("Pinned NW connection waiting with terminal error: \(String(describing: error), privacy: .public) -> \(kind.rawValue, privacy: .public)")
                    gate.resolve(.failure(DesktopFailure(kind)))
                    self.close()
                }
            case .cancelled:
                self.cancelOpenTimer()
                gate.resolve(.failure(DesktopFailure(self.pinFailure ?? .disconnected)))
            default:
                break
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.setContinuation(continuation)
                conn.start(queue: queue)
            }
        } onCancel: { [weak self] in
            self?.close()
            gate.resolve(.failure(DesktopFailure(.disconnected)))
        }
    }

    func sendText(_ text: String) async throws {
        try await sendPayload(Data(text.utf8), opcode: .text)
    }

    func sendBinary(_ data: Data) async throws {
        try await sendPayload(data, opcode: .binary)
    }

    private func sendPayload(_ data: Data, opcode: NWProtocolWebSocket.Opcode) async throws {
        guard let conn = activeConnection() else {
            throw DesktopFailure(.disconnected)
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "pebrel-ws-send", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: DesktopFailure(DesktopFailureClassifier.classify(error, relayReached: true)))
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    func sendPing(timeoutSeconds: Double = 10) async -> Bool {
        guard let conn = activeConnection() else { return false }
        let gate = PinnedWsBoolGate()
        let timeoutWork = DispatchWorkItem {
            gate.resolve(false)
        }
        queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { error in
            timeoutWork.cancel()
            gate.resolve(error == nil)
        }
        let context = NWConnection.ContentContext(identifier: "pebrel-ws-ping", metadata: [metadata])

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            gate.setContinuation(continuation)
            conn.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if error != nil {
                    timeoutWork.cancel()
                    gate.resolve(false)
                }
            })
        }
    }

    private enum ReceiveStep {
        case message(PinnedWebSocketMessage)
        case ignore
        case failed(DesktopFailureKind)
    }

    func receive() async throws -> PinnedWebSocketMessage {
        while true {
            guard let conn = activeConnection() else {
                throw DesktopFailure(.disconnected)
            }
            let step: ReceiveStep = await withCheckedContinuation { continuation in
                conn.receiveMessage { [weak self] content, context, isComplete, error in
                    if let error {
                        let kind = self?.pinFailure ?? DesktopFailureClassifier.classify(error, relayReached: true)
                        continuation.resume(returning: .failed(kind))
                        return
                    }
                    let wsMeta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                    if let wsMeta {
                        switch wsMeta.opcode {
                        case .text:
                            let text = String(decoding: content ?? Data(), as: UTF8.self)
                            continuation.resume(returning: .message(.text(text)))
                        case .binary:
                            continuation.resume(returning: .message(.data(content ?? Data())))
                        case .close:
                            continuation.resume(returning: .failed(DesktopFailureClassifier.fromNWWebSocketClose(wsMeta.closeCode)))
                        case .ping, .pong, .cont:
                            continuation.resume(returning: .ignore)
                        @unknown default:
                            continuation.resume(returning: .failed(.protocol))
                        }
                    } else if isComplete && (content == nil || content?.isEmpty == true) {
                        continuation.resume(returning: .failed(.disconnected))
                    } else {
                        continuation.resume(returning: .ignore)
                    }
                }
            }
            switch step {
            case .message(let msg):
                return msg
            case .ignore:
                continue
            case .failed(let kind):
                throw DesktopFailure(kind)
            }
        }
    }

    func close() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        let conn = connection
        connection = nil
        let timer = openTimeoutWork
        openTimeoutWork = nil
        let gate = openGate
        openGate = nil
        let failure = _pinFailure
        lock.unlock()

        timer?.cancel()
        if !alreadyClosed {
            conn?.stateUpdateHandler = nil
            conn?.cancel()
        }
        gate?.resolve(.failure(DesktopFailure(failure ?? .disconnected)))
    }

    private func activeConnection() -> NWConnection? {
        lock.lock()
        let conn = closed ? nil : connection
        lock.unlock()
        return conn
    }

    private func cancelOpenTimer() {
        lock.lock()
        let timer = openTimeoutWork
        openTimeoutWork = nil
        lock.unlock()
        timer?.cancel()
    }

    deinit {
        close()
    }
}
