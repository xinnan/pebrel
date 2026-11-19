import Foundation
import Security

/// Strict SPKI SHA-256 TLS pinning with preserved leaf validity-date and hostname/IP SAN verification.
final class PinnedTlsSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let expectedPin: String?
    private let expectedHost: String
    private(set) var pinFailure: DesktopFailureKind?

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
            pinFailure = .tls
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Verify leaf SPKI SHA-256 pin first using exact X.509 DER SPKI extraction
        let leafDER = SecCertificateCopyData(leaf) as Data
        guard let spkiDER = CryptoHelpers.extractX509SubjectPublicKeyInfo(from: leafDER) else {
            pinFailure = .tls
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let actualPin = "sha256/" + CryptoHelpers.sha256Base64(spkiDER)
        guard CryptoHelpers.constantTimeEquals(actualPin, expectedPin) else {
            pinFailure = .certificateChanged
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Anchor to the verified leaf certificate and enforce SSL hostname/IP SAN + validity dates.
        let sslPolicy = SecPolicyCreateSSL(true, expectedHost as CFString)
        SecTrustSetPolicies(trust, sslPolicy)
        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var cfError: CFError?
        if SecTrustEvaluateWithError(trust, &cfError) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        if let cfError {
            let desc = (cfError as Error).localizedDescription.lowercased()
            if desc.contains("expired") || desc.contains("not yet valid") || desc.contains("date") {
                pinFailure = .certificateDate
            } else {
                pinFailure = .tls
            }
        } else {
            pinFailure = .tls
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
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
