import Foundation

struct SecureRelayProfile: Codable, Equatable, Hashable {
    let host: String
    let grant: String
    let secret: String
    let invitation: Bool
    let expiresAt: Int64

    func isValid() -> Bool {
        CryptoHelpers.decodeBase64Url32(host) != nil &&
        CryptoHelpers.decodeBase64Url32(secret) != nil &&
        RelayProfile.isValidIdentifier(grant) &&
        (!invitation || expiresAt > 0)
    }
}

final class RelayProfile: Equatable, Hashable, Identifiable {
    let version: Int
    let url: String
    let device: String
    let token: String
    let name: String
    let mode: String
    let tlsPin: String?
    let hostOs: String
    let secure: SecureRelayProfile?
    let alternate: RelayProfile?

    init(
        version: Int,
        url: String,
        device: String,
        token: String,
        name: String,
        mode: String,
        tlsPin: String?,
        hostOs: String = "term",
        secure: SecureRelayProfile? = nil,
        alternate: RelayProfile? = nil
    ) {
        self.version = version
        self.url = url
        self.device = device
        self.token = token
        self.name = name
        self.mode = mode
        self.tlsPin = tlsPin
        self.hostOs = HostIconCatalog.desktopOsIcon(hostOs)
        self.secure = secure
        self.alternate = alternate
    }

    var id: String {
        if let secure {
            return CryptoHelpers.sha256Hex("pebrel.mobile.host.v2\n\(secure.host)")
        }
        return legacyId
    }

    var legacyId: String {
        var raw = "\(url)/\(device)"
        if let tlsPin { raw += "/\(tlsPin)" }
        if let secure { raw += "/\(secure.host)" }
        return CryptoHelpers.sha256Hex(raw)
    }

    var workspaceId: String { "relay:\(id)" }

    var isLan: Bool { mode == "lan" }

    var canRediscover: Bool {
        mode == "lan" && tlsPin != nil && secure?.invitation == false
    }

    var hasAlternateRoute: Bool { alternate != nil }

    func sameConnection(as other: RelayProfile) -> Bool {
        version == other.version &&
        url == other.url &&
        device == other.device &&
        mode == other.mode &&
        tlsPin == other.tlsPin &&
        secure?.host == other.secure?.host &&
        secure?.grant == other.secure?.grant &&
        secure?.invitation == other.secure?.invitation
    }

    func connectionRoutes() -> [RelayProfile] {
        var list = [withoutAlternate()]
        if let alt = alternate {
            list.append(alt.withoutAlternate())
        }
        return list.sorted { lhs, rhs in
            if lhs.mode != rhs.mode { return lhs.mode == "lan" }
            return false
        }
    }

    func withoutAlternate() -> RelayProfile {
        RelayProfile(
            version: version, url: url, device: device, token: token, name: name,
            mode: mode, tlsPin: tlsPin, hostOs: hostOs, secure: secure, alternate: nil
        )
    }

    func withEnrolled(grant: String, secret: String) -> RelayProfile {
        guard let secure else { return self }
        let updated = SecureRelayProfile(
            host: secure.host, grant: grant, secret: secret, invitation: false, expiresAt: 0
        )
        return RelayProfile(
            version: version, url: url, device: device, token: token, name: name,
            mode: mode, tlsPin: tlsPin, hostOs: hostOs, secure: updated, alternate: alternate
        )
    }

    func withHostOs(_ os: String?) -> RelayProfile {
        RelayProfile(
            version: version, url: url, device: device, token: token, name: name,
            mode: mode, tlsPin: tlsPin, hostOs: HostIconCatalog.desktopOsIcon(os), secure: secure, alternate: alternate
        )
    }

    func retainRoutes(from previous: RelayProfile?) -> RelayProfile {
        guard let previous,
              id == previous.id,
              secure?.invitation == false,
              previous.secure?.invitation == false else {
            return self
        }
        let retainedAlt: RelayProfile?
        if mode != previous.mode {
            retainedAlt = previous.withoutAlternate()
        } else {
            retainedAlt = alternate ?? previous.alternate?.withoutAlternate()
        }
        return RelayProfile(
            version: version, url: url, device: device, token: token, name: name,
            mode: mode, tlsPin: tlsPin, hostOs: hostOs == "term" ? previous.hostOs : hostOs,
            secure: secure, alternate: retainedAlt
        )
    }

    func discoveredAt(address: String, pin: String) -> RelayProfile? {
        guard canRediscover, tlsPin == pin else { return nil }
        guard let normalized = Self.normalizeWssURL(address.replacingOccurrences(of: "https://", with: "wss://")) else {
            return nil
        }
        return RelayProfile(
            version: version, url: normalized, device: device, token: token, name: name,
            mode: mode, tlsPin: tlsPin, hostOs: hostOs, secure: secure, alternate: alternate
        )
    }

    func atLanAddress(_ rawAddress: String) -> RelayProfile? {
        guard canRediscover else { return nil }
        let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512, !trimmed.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        let candidate: String
        if trimmed.hasPrefix("wss://") {
            candidate = trimmed
        } else if trimmed.hasPrefix("https://") {
            candidate = "wss://" + trimmed.dropFirst("https://".count)
        } else if !trimmed.contains("://") {
            candidate = "wss://" + trimmed
        } else {
            return nil
        }
        guard let normalized = Self.normalizeWssURL(candidate) else { return nil }
        return RelayProfile(
            version: version, url: normalized, device: device, token: token, name: name,
            mode: mode, tlsPin: tlsPin, hostOs: hostOs, secure: secure, alternate: alternate
        )
    }

    func toJSONDictionary(includeAlternate: Bool = true) -> [String: Any] {
        var dict: [String: Any] = [
            "version": version,
            "url": url,
            "device": device,
            "token": token,
            "name": name,
            "mode": mode,
            "hostOs": hostOs,
        ]
        if let tlsPin { dict["tlsPin"] = tlsPin }
        if let secure {
            dict["secure"] = [
                "host": secure.host,
                "grant": secure.grant,
                "secret": secure.secret,
                "invitation": secure.invitation,
                "expiresAt": secure.expiresAt,
            ]
        }
        if includeAlternate, let alternate {
            dict["alternate"] = alternate.toJSONDictionary(includeAlternate: false)
        }
        return dict
    }

    func toJSONString(includeAlternate: Bool = false) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: toJSONDictionary(includeAlternate: includeAlternate)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func parse(_ raw: String) -> RelayProfile? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 8192,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseDictionary(obj, allowAlternate: false)
    }

    static func parseStored(_ raw: String) -> RelayProfile? {
        guard raw.count <= 16384,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseDictionary(obj, allowAlternate: true)
    }

    static func parseDictionary(_ obj: [String: Any], allowAlternate: Bool) -> RelayProfile? {
        guard let version = obj["version"] as? Int, version == 1 || version == 2 else { return nil }
        guard let rawUrl = obj["url"] as? String, let normalizedUrl = normalizeWssURL(rawUrl) else { return nil }
        guard let device = obj["device"] as? String, isValidIdentifier(device) else { return nil }
        guard let token = obj["token"] as? String, isValidToken(token) else { return nil }

        let trimmedName = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? device
        let rawName = String(trimmedName.prefix(80))
        guard !rawName.isEmpty, !CryptoHelpers.containsControlChar(rawName) else { return nil }

        let mode = (obj["mode"] as? String) ?? "relay"
        guard mode == "lan" || mode == "relay" else { return nil }

        let tlsPin = obj["tlsPin"] as? String
        if let tlsPin, !PinnedTlsSessionDelegate.isValidPin(tlsPin) { return nil }
        if mode == "lan" && tlsPin == nil { return nil }

        let hostOs = HostIconCatalog.desktopOsIcon(obj["hostOs"] as? String)

        var secure: SecureRelayProfile?
        if let secObj = obj["secure"] as? [String: Any] {
            guard version == 2,
                  let host = secObj["host"] as? String,
                  let grant = secObj["grant"] as? String,
                  let secret = secObj["secret"] as? String,
                  let invitation = secObj["invitation"] as? Bool else { return nil }
            let expiresAt = (secObj["expiresAt"] as? NSNumber)?.int64Value ?? 0
            let parsed = SecureRelayProfile(host: host, grant: grant, secret: secret, invitation: invitation, expiresAt: expiresAt)
            guard parsed.isValid() else { return nil }
            secure = parsed
        }

        if version == 1 && secure != nil { return nil }
        if version == 2 && (secure == nil || tlsPin == nil) { return nil }

        var alternate: RelayProfile?
        if allowAlternate, let altObj = obj["alternate"] as? [String: Any] {
            guard altObj["alternate"] == nil,
                  let alt = parseDictionary(altObj, allowAlternate: false) else {
                return nil
            }
            let base = RelayProfile(version: version, url: normalizedUrl, device: device, token: token, name: rawName, mode: mode, tlsPin: tlsPin, hostOs: hostOs, secure: secure)
            guard alt.id == base.id,
                  alt.mode != base.mode,
                  secure?.invitation == false,
                  alt.secure?.invitation == false else {
                return nil
            }
            alternate = alt
        }

        return RelayProfile(
            version: version, url: normalizedUrl, device: device, token: token,
            name: rawName, mode: mode, tlsPin: tlsPin, hostOs: hostOs,
            secure: secure, alternate: alternate
        )
    }

    static func normalizeWssURL(_ raw: String) -> String? {
        guard raw.hasPrefix("wss://"),
              let comps = URLComponents(string: raw),
              comps.scheme == "wss",
              let host = comps.host, !host.isEmpty,
              comps.user == nil, comps.password == nil,
              comps.query == nil, comps.fragment == nil,
              comps.path.isEmpty || comps.path == "/" else {
            return nil
        }
        var cleaned = raw
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        return cleaned
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { s in
            (s.value >= 48 && s.value <= 57) ||
            (s.value >= 65 && s.value <= 90) ||
            (s.value >= 97 && s.value <= 122) ||
            s == "_" || s == "-"
        }
    }

    static func isValidToken(_ value: String) -> Bool {
        guard value.count == 43 else { return false }
        return isValidIdentifier(value)
    }

    static func == (lhs: RelayProfile, rhs: RelayProfile) -> Bool {
        lhs.version == rhs.version &&
        lhs.url == rhs.url &&
        lhs.device == rhs.device &&
        lhs.token == rhs.token &&
        lhs.name == rhs.name &&
        lhs.mode == rhs.mode &&
        lhs.tlsPin == rhs.tlsPin &&
        lhs.hostOs == rhs.hostOs &&
        lhs.secure == rhs.secure &&
        lhs.alternate == rhs.alternate
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(url)
        hasher.combine(mode)
    }
}

struct RelayRouteAttempt {
    let routes: [RelayProfile]

    static func forProfile(_ profile: RelayProfile, saved: RelayProfile?) -> RelayRouteAttempt {
        if let saved, saved.connectionRoutes().contains(where: { $0.sameConnection(as: profile) }) {
            return RelayRouteAttempt(routes: saved.connectionRoutes())
        }
        return RelayRouteAttempt(routes: [profile])
    }
}

/// Keychain-backed store for saved paired computer profiles.
final class RelayProfileStore {
    func load() -> [RelayProfile] {
        guard let data = KeychainStore.shared.loadRelayProfilesJSON(),
              let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rawArray.compactMap { RelayProfile.parseDictionary($0, allowAlternate: true) }
    }

    func save(_ profiles: [RelayProfile]) {
        let dicts = profiles.map { $0.toJSONDictionary(includeAlternate: true) }
        if let data = try? JSONSerialization.data(withJSONObject: dicts) {
            _ = KeychainStore.shared.saveRelayProfilesJSON(data)
        }
    }
}
