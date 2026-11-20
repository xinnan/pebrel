import Foundation

enum PairingCodeError: Error, LocalizedError {
    case invalidCode
    case rejected(String)
    case invalidInvitation
    case failed(DesktopFailureKind)

    var errorDescription: String? {
        switch self {
        case .invalidCode: return L10n.tr("pair_code_rejected")
        case .rejected: return L10n.tr("pair_code_rejected")
        case .invalidInvitation: return L10n.tr("desktop_protocol")
        case .failed(let kind): return kind.localizedMessage
        }
    }
}

/// Redeems an 8-digit LAN pairing code over a pinned TLS WebSocket at `/v2/pair` without an Origin header.
enum PairingCodeLookup {
    static func isValidCode(_ code: String) -> Bool {
        code.count == 8 && code.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    static func redeem(computer: DiscoveredComputer, code: String) async throws -> RelayProfile {
        guard isValidCode(code) else { throw PairingCodeError.invalidCode }
        guard let baseWss = RelayProfile.normalizeWssURL(computer.address.replacingOccurrences(of: "https://", with: "wss://")),
              let url = URL(string: "\(baseWss)/v2/pair"),
              let host = url.host else {
            throw PairingCodeError.invalidInvitation
        }

        let client = PinnedWebSocketClient(
            url: url,
            expectedPin: computer.pin,
            expectedHost: host,
            headers: [],
            maxFrameBytes: 16384
        )
        defer { client.close() }

        do {
            try await client.open(timeoutSeconds: 5)
            let payload = try JSONSerialization.data(withJSONObject: ["code": code])
            let text = String(decoding: payload, as: UTF8.self)
            try await client.sendText(text)

            let received = try await client.receive()
            guard case .text(let replyText) = received,
                  replyText.utf8.count <= 16384,
                  let replyData = replyText.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
                throw PairingCodeError.invalidInvitation
            }

            if let errCode = obj["error"] as? String {
                throw PairingCodeError.rejected(errCode)
            }

            guard let inviteStr = obj["invitation"] as? String,
                  let profile = RelayProfile.parse(inviteStr),
                  profile.version == 2,
                  profile.mode == "lan",
                  profile.tlsPin == computer.pin,
                  profile.url == baseWss,
                  let secure = profile.secure,
                  secure.invitation,
                  secure.expiresAt > Int64(Date().timeIntervalSince1970) else {
                throw PairingCodeError.invalidInvitation
            }
            return profile
        } catch let err as PairingCodeError {
            throw err
        } catch let failure as DesktopFailure {
            throw PairingCodeError.failed(failure.kind)
        } catch {
            throw PairingCodeError.failed(DesktopFailureClassifier.classify(error))
        }
    }
}
