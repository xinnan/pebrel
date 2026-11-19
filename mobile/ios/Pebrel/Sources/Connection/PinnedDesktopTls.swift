import Foundation
import Security

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

    /// Evaluates a pinned leaf X.509 DER certificate. Returns `nil` when valid, or the exact failure kind.
    static func evaluatePinnedLeafDER(
        _ leafDER: Data,
        expectedPin: String,
        expectedHost: String,
        nowUnix: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> DesktopFailureKind? {
        guard let cert = CryptoHelpers.inspectX509Certificate(from: leafDER) else {
            return .tls
        }
        let actualPin = "sha256/" + CryptoHelpers.sha256Base64(cert.spkiDER)
        guard CryptoHelpers.constantTimeEquals(actualPin, expectedPin) else {
            return .certificateChanged
        }
        guard cert.isValid(at: nowUnix) else {
            return .certificateDate
        }
        guard cert.matchesHost(expectedHost) else {
            return .tls
        }
        return nil
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
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

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            recordFailure(.tls)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let leafDER = SecCertificateCopyData(leaf) as Data
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
