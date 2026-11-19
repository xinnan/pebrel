import Foundation

enum SshSessionMode: String, Codable, CaseIterable, Identifiable {
    case shell = "shell"
    case tmux = "tmux"
    case herdr = "herdr"

    var id: String { rawValue }
}

struct HostProfile: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var address: String
    var port: Int
    var user: String
    var fingerprint: String
    var icon: String
    var group: String
    var sessionMode: SshSessionMode
    var sessionName: String
    var keyId: String
    var keyName: String

    init(
        id: String = UUID().uuidString,
        name: String,
        address: String,
        port: Int = 22,
        user: String = "root",
        fingerprint: String = "",
        icon: String = "term",
        group: String = "development",
        sessionMode: SshSessionMode = .shell,
        sessionName: String = "",
        keyId: String = "",
        keyName: String = ""
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.user = user
        self.fingerprint = fingerprint
        self.icon = icon
        self.group = group
        self.sessionMode = sessionMode
        self.sessionName = sessionName
        self.keyId = keyId
        self.keyName = keyName
    }

    var hasPrivateKey: Bool { !keyId.isEmpty }

    var endpointLabel: String {
        let formattedHost = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        let suffix = port == 22 ? "" : ":\(port)"
        return "\(user)@\(formattedHost)\(suffix)"
    }

    func attachCommand() -> String? {
        switch sessionMode {
        case .shell:
            return nil
        case .tmux:
            let name = sessionName.isEmpty ? "pebrel" : sessionName
            return "exec tmux new-session -A -s \(CryptoHelpers.shellSingleQuote(name))"
        case .herdr:
            if sessionName.isEmpty {
                return "exec herdr"
            }
            return "exec herdr session attach \(CryptoHelpers.shellSingleQuote(sessionName))"
        }
    }

    func reconnectCommand() -> String? {
        let pathPrefix = "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin\"; export PATH"
        switch sessionMode {
        case .shell:
            return nil
        case .tmux:
            let name = sessionName.isEmpty ? "pebrel" : sessionName
            let target = "=\(name)"
            let q = CryptoHelpers.shellSingleQuote(target)
            let inner = "\(pathPrefix); if tmux has-session -t \(q) 2>/dev/null; then tmux attach-session -t \(q); fi; exec \"${SHELL:-/bin/sh}\" -l"
            return "sh -c \(CryptoHelpers.shellSingleQuote(inner))"
        case .herdr:
            let flag = sessionName.isEmpty ? "" : "--session \(CryptoHelpers.shellSingleQuote(sessionName)) "
            let inner = "\(pathPrefix); HERDR_REMOTE_KEYBINDINGS=server exec herdr \(flag)client"
            return "sh -c \(CryptoHelpers.shellSingleQuote(inner))"
        }
    }
}

struct ParsedSshEndpoint: Equatable {
    let host: String
    let user: String?
}

enum SshEndpointParser {
    static func parse(_ raw: String) -> ParsedSshEndpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("://"),
              !CryptoHelpers.containsControlChar(trimmed),
              !trimmed.contains(where: { $0.isWhitespace }) else {
            return nil
        }

        let atParts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard atParts.count <= 2 else { return nil }

        let user: String?
        var hostPart: String
        if atParts.count == 2 {
            let u = String(atParts[0])
            guard !u.isEmpty, u.count <= 1024 else { return nil }
            user = u
            hostPart = String(atParts[1])
        } else {
            user = nil
            hostPart = trimmed
        }

        if hostPart.hasPrefix("[") && hostPart.hasSuffix("]") {
            hostPart = String(hostPart.dropFirst().dropLast())
        }
        guard !hostPart.isEmpty,
              hostPart.count <= 1024,
              !hostPart.contains("/"),
              !hostPart.contains("?"),
              !hostPart.contains("#") else {
            return nil
        }
        return ParsedSshEndpoint(host: hostPart, user: user)
    }

    static func isValidRemoteSessionName(_ name: String, mode: SshSessionMode) -> Bool {
        if name.isEmpty { return true }
        guard name.count <= 64, name != ".", name != "..", !name.hasPrefix("-") else {
            return false
        }
        return name.unicodeScalars.allSatisfy { s in
            (s.value >= 48 && s.value <= 57) ||
            (s.value >= 65 && s.value <= 90) ||
            (s.value >= 97 && s.value <= 122) ||
            s == "_" || s == "-" || (mode == .herdr && s == ".")
        }
    }
}

final class HostStore {
    private let defaultsKey = "pebrel_saved_hosts_v1"

    func load() -> [HostProfile] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let hosts = try? JSONDecoder().decode([HostProfile].self, from: data) else {
            return []
        }
        return hosts
    }

    func save(_ hosts: [HostProfile]) {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
