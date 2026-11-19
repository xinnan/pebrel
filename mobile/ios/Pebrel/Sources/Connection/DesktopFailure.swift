import Darwin
import Foundation

enum DesktopFailureKind: String, Equatable {
    case dns = "desktop_dns"
    case timeout = "desktop_timeout"
    case refused = "desktop_refused"
    case network = "desktop_network"
    case alreadyConnected = "desktop_already_connected"
    case server = "desktop_server"
    case peerOffline = "desktop_peer_offline"
    case runtimeUnavailable = "desktop_runtime_unavailable"
    case disconnected = "desktop_disconnected"
    case unknown = "desktop_connection_failed"
    case authentication = "desktop_authentication"
    case certificateChanged = "desktop_certificate_changed"
    case certificateDate = "desktop_certificate_date"
    case tls = "desktop_tls"
    case `protocol` = "desktop_protocol"

    var isRetryable: Bool {
        switch self {
        case .authentication, .certificateChanged, .certificateDate, .tls, .protocol:
            return false
        default:
            return true
        }
    }

    var localizedMessage: String {
        L10n.tr(rawValue)
    }
}

struct DesktopFailure: Error, LocalizedError, Equatable {
    let kind: DesktopFailureKind
    let detail: String

    init(_ kind: DesktopFailureKind, detail: String = "") {
        self.kind = kind
        self.detail = detail
    }

    var errorDescription: String? {
        detail.isEmpty ? kind.localizedMessage : detail
    }
}

struct DesktopRpcFailure: Error, LocalizedError, Equatable {
    let code: String
    let detail: String

    init(_ code: String, detail: String = "") {
        self.code = String(code.prefix(80))
        self.detail = String(detail.prefix(4096))
    }

    var errorDescription: String? { code }
}

enum DesktopFailureClassifier {
    static func fromHttpStatus(_ statusCode: Int) -> DesktopFailureKind {
        switch statusCode {
        case 401, 403: return .authentication
        case 409: return .alreadyConnected
        default: return .server
        }
    }

    static func fromWebSocketClose(_ closeCode: URLSessionWebSocketTask.CloseCode) -> DesktopFailureKind {
        switch closeCode {
        case .policyViolation, .messageTooBig:
            return .protocol
        default:
            return .disconnected
        }
    }

    static func classify(_ error: Error, relayReached: Bool = false) -> DesktopFailureKind {
        if let f = error as? DesktopFailure { return f.kind }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed: return .dns
            case .timedOut: return .timeout
            case .cannotConnectToHost: return .refused
            case .serverCertificateHasBadDate: return .certificateDate
            case .serverCertificateUntrusted, .secureConnectionFailed, .serverCertificateNotYetValid:
                return relayReached ? .network : .tls
            case .userAuthenticationRequired: return .authentication
            default: return .network
            }
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case ETIMEDOUT: return .timeout
            case ECONNREFUSED: return .refused
            case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN: return .network
            case ECONNRESET, ENOTCONN, EPIPE: return relayReached ? .disconnected : .network
            default: return .network
            }
        }
        return relayReached ? .network : .unknown
    }
}

/// Foreground-only exponential reconnect backoff (500ms -> 1s -> 2s -> 4s -> 8s -> 15s).
@MainActor
final class DesktopReconnectScheduler {
    private var attempts: [String: Int] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private(set) var isForeground = true

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if !foreground {
            cancelAll()
        }
    }

    func reset(_ id: String) {
        attempts[id] = 0
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    func schedule(_ id: String, immediate: Bool = false, action: @escaping @MainActor () -> Void) {
        guard isForeground else { return }
        tasks[id]?.cancel()
        let attempt = immediate ? 0 : (attempts[id] ?? 0)
        attempts[id] = min(attempt + 1, 6)
        let delayMs: UInt64 = immediate ? 1 : min(500 << attempt, 15_000)
        tasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard !Task.isCancelled, self?.isForeground == true else { return }
            action()
        }
    }
}
