import Foundation
import UIKit

/// v2 Noise NKpsk0 E2EE session state machine shared with desktop (`mobile/link/src/crypto.rs`).
final class SecureRelaySession {
    enum Phase {
        case new
        case handshake
        case enrollment
        case ready
        case closed
    }

    private(set) var profile: RelayProfile
    private(set) var phase: Phase = .new
    private var link: NativeLinkHandle?
    private var expectedVerificationCode: String?
    private var approvalReceived = false
    private let sendBinary: (Data) async throws -> Void
    private let deliverFrame: ([String: Any]) -> Void
    private let onEnrolled: (RelayProfile) -> Void

    init(
        profile: RelayProfile,
        sendBinary: @escaping (Data) async throws -> Void,
        deliverFrame: @escaping ([String: Any]) -> Void,
        onEnrolled: @escaping (RelayProfile) -> Void
    ) {
        self.profile = profile
        self.sendBinary = sendBinary
        self.deliverFrame = deliverFrame
        self.onEnrolled = onEnrolled
    }

    func paired(epoch: String) async throws {
        guard phase == .new,
              let secure = profile.secure,
              let hostPub = CryptoHelpers.decodeBase64Url32(secure.host),
              let secret = CryptoHelpers.decodeBase64Url32(secure.secret) else {
            close()
            throw DesktopFailure(.protocol)
        }
        if secure.invitation {
            let now = Int64(Date().timeIntervalSince1970)
            guard now < secure.expiresAt else {
                close()
                throw DesktopFailure(.authentication)
            }
        }

        let role = secure.invitation ? "invite" : "device"
        let contextStr = "pebrel.mobile.v2\n\(secure.host)\n\(secure.grant)\n\(role)\n\(epoch)"
        let contextData = Data(contextStr.utf8)
        guard contextData.count <= 512 else {
            close()
            throw DesktopFailure(.protocol)
        }

        let handle: NativeLinkHandle
        do {
            handle = try NativeLinkHandle(hostPublicKey: hostPub, secret: secret, context: contextData)
        } catch {
            close()
            throw DesktopFailure(.authentication)
        }
        self.link = handle
        self.phase = .handshake

        // Binary WS frame 1: [0x01] || JSON({"host","grant","invitation"})
        let headerObj: [String: Any] = [
            "host": secure.host,
            "grant": secure.grant,
            "invitation": secure.invitation,
        ]
        guard let headerJSON = try? JSONSerialization.data(withJSONObject: headerObj),
              headerJSON.count + 1 <= 512 else {
            close()
            throw DesktopFailure(.protocol)
        }
        var helloHeader = Data([0x01])
        helloHeader.append(headerJSON)
        try await sendBinary(helloHeader)

        // Binary WS frame 2: Noise NKpsk0 handshake message 1
        let noiseMsg1: Data
        do {
            noiseMsg1 = try handle.hello()
        } catch {
            close()
            throw DesktopFailure(.authentication)
        }
        try await sendBinary(noiseMsg1)
    }

    func receiveBinary(_ data: Data) async throws {
        guard let link else {
            close()
            throw DesktopFailure(.protocol)
        }

        switch phase {
        case .handshake:
            guard data.count >= 1, data.count <= 128 else {
                close()
                throw DesktopFailure(.protocol)
            }
            let established: Bool
            do {
                established = try link.finish(response: data)
                expectedVerificationCode = try link.verificationCode()
            } catch {
                close()
                throw DesktopFailure(.authentication)
            }
            guard established else {
                close()
                throw DesktopFailure(.authentication)
            }
            phase = .enrollment
            let rawDeviceName = await MainActor.run { UIDevice.current.name }
            let sanitizedName = String(rawDeviceName.unicodeScalars.filter { !CryptoHelpers.isControlScalar($0) })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceName = sanitizedName.isEmpty ? "Pebrel iOS" : String(sanitizedName.prefix(80))
            try await sendEncryptedJSON([
                "type": "secure.connect",
                "name": deviceName,
                "approval": true,
            ])

        case .enrollment:
            let plain: Data?
            do {
                plain = try link.open(data)
            } catch {
                close()
                throw DesktopFailure(.authentication)
            }
            guard let plain else { return }
            guard plain.count <= 1024,
                  let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
                  let type = obj["type"] as? String else {
                close()
                throw DesktopFailure(.protocol)
            }
            try await handleEnrollmentMessage(type: type, obj: obj)

        case .ready:
            let plain: Data?
            do {
                plain = try link.open(data)
            } catch {
                close()
                throw DesktopFailure(.protocol)
            }
            guard let plain else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
                close()
                throw DesktopFailure(.protocol)
            }
            deliverFrame(obj)

        case .new, .closed:
            close()
            throw DesktopFailure(.protocol)
        }
    }

    func sendRuntimeFrame(_ frame: [String: Any]) async throws {
        guard phase == .ready else {
            throw DesktopFailure(.disconnected)
        }
        try await sendEncryptedJSON(frame, maxBytes: 40 * 1024)
    }

    func close() {
        phase = .closed
        link?.close()
        link = nil
    }

    private func handleEnrollmentMessage(type: String, obj: [String: Any]) async throws {
        guard let secure = profile.secure else {
            close()
            throw DesktopFailure(.protocol)
        }
        if secure.invitation {
            if type == "secure.approval" {
                guard !approvalReceived,
                      let code = obj["code"] as? String,
                      code.count == 6,
                      code.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
                      let expected = expectedVerificationCode,
                      CryptoHelpers.constantTimeEquals(code, expected),
                      let expiresAt = (obj["expiresAt"] as? NSNumber)?.int64Value,
                      expiresAt > 0 else {
                    close()
                    throw DesktopFailure(.authentication)
                }
                approvalReceived = true
                let localDeadline = Int64(Date().timeIntervalSince1970) + 120
                deliverFrame([
                    "type": "mobile.approval",
                    "code": code,
                    "expiresAt": localDeadline,
                ])
                return
            }
            guard type == "secure.enrolled",
                  let newGrant = obj["grant"] as? String,
                  let newSecret = obj["secret"] as? String,
                  RelayProfile.isValidIdentifier(newGrant),
                  CryptoHelpers.decodeBase64Url32(newSecret) != nil,
                  newGrant != secure.grant,
                  newSecret != secure.secret else {
                close()
                throw DesktopFailure(.authentication)
            }
            let updated = profile.withEnrolled(grant: newGrant, secret: newSecret)
            profile = updated
            onEnrolled(updated)
            try await sendEncryptedJSON(["type": "secure.ack", "grant": newGrant])
            phase = .ready
        } else {
            guard type == "secure.accepted",
                  let grant = obj["grant"] as? String,
                  grant == secure.grant else {
                close()
                throw DesktopFailure(.authentication)
            }
            try await sendEncryptedJSON(["type": "secure.ack", "grant": grant])
            phase = .ready
        }
    }

    private func sendEncryptedJSON(_ obj: [String: Any], maxBytes: Int = 2 * 1024 * 1024) async throws {
        guard let link,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              !data.isEmpty,
              data.count <= maxBytes else {
            close()
            throw DesktopFailure(.protocol)
        }
        let packets: [Data]
        do {
            packets = try link.seal(data)
        } catch {
            close()
            throw DesktopFailure(.protocol)
        }
        for packet in packets {
            try await sendBinary(packet)
        }
    }
}
