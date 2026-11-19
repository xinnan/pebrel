import Combine
import Foundation

struct ConversationIdentity: Equatable, Hashable {
    let kind: String
    let session: String
    let epoch: Int64?
}

struct ConversationMessage: Identifiable, Equatable {
    let id: String
    let role: String // "user" | "assistant" | "tool"
    let text: String
    let name: String?
    let detail: String?
    let complete: Bool
    let truncated: Bool
    let isError: Bool
}

struct ConversationPrompt: Identifiable, Equatable {
    let id: String
    let text: String
    let options: [String]
    let selected: Int
    let binary: Bool
}

struct ConversationPage: Equatable {
    var identity: ConversationIdentity
    var messages: [ConversationMessage] = []
    var revision: String?
    var before: Int64?
    var cwd: String = ""
    var loaded: Bool = false
    var canSend: Bool = false
    var state: String = "idle"
    var activity: String = ""
    var truncated: Bool = false
    var prompt: ConversationPrompt?
}

@MainActor
protocol ConversationSource: AnyObject {
    var page: ConversationPage { get }
    var pagePublisher: AnyPublisher<ConversationPage, Never> { get }
    func refresh(older: Bool) async throws -> Bool
    func send(_ text: String) async throws
    func choose(prompt: ConversationPrompt, index: Int) async throws
    func key(_ keyName: String) async throws
}

func sshAgentDisplayName(_ kind: String) -> String {
    switch kind {
    case "claude": return "Claude Code"
    case "codex": return "Codex"
    case "pi": return "Pi"
    case "antigravity": return "Antigravity"
    default: return kind
    }
}

struct SshForeground: Equatable {
    let program: String
    let cwd: String
    let agent: String?
    let multiplexer: String?

    var label: String {
        let first = agent.map(sshAgentDisplayName) ?? program
        return [first, cwd].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func parse(_ dict: [String: Any]) -> SshForeground {
        let home = (dict["home"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rawCwd = dict["cwd"] as? String ?? ""
        let cwd: String
        if !home.isEmpty && (rawCwd == "/\(home)" || rawCwd.hasPrefix("/\(home)/")) {
            cwd = "~" + rawCwd.dropFirst(home.count + 1)
        } else if !home.isEmpty && (rawCwd == home || rawCwd.hasPrefix("\(home)/")) {
            cwd = "~" + rawCwd.dropFirst(home.count)
        } else {
            cwd = rawCwd
        }
        let agentStr = dict["agent"] as? String ?? ""
        let muxStr = dict["multiplexer"] as? String ?? ""
        return SshForeground(
            program: dict["program"] as? String ?? "",
            cwd: cwd,
            agent: agentStr.isEmpty ? nil : agentStr,
            multiplexer: muxStr.isEmpty ? nil : muxStr
        )
    }
}

/// Parses agent selection menus and running indicators drawn on an interactive SSH terminal.
enum TerminalPromptParser {
    private static let borderChars = CharacterSet(charactersIn: " \t│┃|╭╮╰╯─")
    private static let optionRegex = try! NSRegularExpression(pattern: "^([❯›>▶]\\s*)?(\\d{1,2})[.)]\\s+(.+)$")
    private static let runningRegex = try! NSRegularExpression(pattern: "\\b(?:esc|ctrl\\+c) to interrupt\\b", options: [.caseInsensitive])
    private static let hintRegex = try! NSRegularExpression(
        pattern: "\\s*(?:\\(\\s*(?:esc|ctrl\\+c) to interrupt\\s*\\)|[·•]\\s*(?:esc|ctrl\\+c) to interrupt\\b|\\b(?:esc|ctrl\\+c) to interrupt\\b.*$)",
        options: [.caseInsensitive]
    )

    static func isRunning(_ screen: String) -> Bool {
        let tail = screen.components(separatedBy: "\n").suffix(12)
        return tail.contains { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            return runningRegex.firstMatch(in: line, range: range) != nil
        }
    }

    static func activity(_ screen: String) -> String {
        let tail = screen.components(separatedBy: "\n").suffix(12)
        guard let matched = tail.last(where: { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            return runningRegex.firstMatch(in: line, range: range) != nil
        }) else {
            return ""
        }
        let stripped = matched.trimmingCharacters(in: borderChars)
        let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        return hintRegex.stringByReplacingMatches(in: stripped, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ screen: String) -> ConversationPrompt? {
        let rawLines = screen.components(separatedBy: "\n")
        let lines = rawLines.suffix(30).map { $0.trimmingCharacters(in: borderChars) }
        guard let lastIdx = lines.lastIndex(where: { matchOption($0) != nil }) else { return nil }

        var found: [(index: Int, marked: Bool, number: Int, label: String)] = []
        var idx = lastIdx
        var gap = 0
        while idx >= 0 && gap <= 2 {
            if let m = matchOption(lines[idx]) {
                found.insert((idx, m.marked, m.number, m.label), at: 0)
                gap = 0
                if m.number == 1 { break }
            } else {
                gap += 1
            }
            idx -= 1
        }
        guard found.count >= 2 else { return nil }
        for (i, entry) in found.enumerated() where entry.number != i + 1 { return nil }
        guard let selectedIdx = found.firstIndex(where: \.marked) else { return nil }

        let maxWidth = rawLines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression).count }.max() ?? 0
        var above = Array(lines[0..<found[0].index])
        while above.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { above.removeLast() }
        var questionRows: [String] = []
        for row in above.reversed() {
            if row.trimmingCharacters(in: .whitespaces).isEmpty { break }
            questionRows.insert(row, at: 0)
            if questionRows.count >= 4 { break }
        }
        var question = ""
        for (i, row) in questionRows.enumerated() {
            let joiner = (i == 0 || questionRows[i - 1].count >= maxWidth - 1) ? "" : " "
            question += joiner + row.trimmingCharacters(in: .whitespaces)
        }
        let options = found.map(\.label)
        let id = CryptoHelpers.sha256Hex(question + "\u{0000}" + options.joined(separator: "\u{0000}"))
        return ConversationPrompt(id: id, text: question, options: options, selected: selectedIdx, binary: false)
    }

    private static func matchOption(_ line: String) -> (marked: Bool, number: Int, label: String)? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let m = optionRegex.firstMatch(in: line, range: range),
              let numRange = Range(m.range(at: 2), in: line),
              let num = Int(line[numRange]),
              let lblRange = Range(m.range(at: 3), in: line) else {
            return nil
        }
        let marked = m.range(at: 1).location != NSNotFound
        return (marked, num, String(line[lblRange]).trimmingCharacters(in: .whitespaces))
    }
}

/// Runs bundled `ssh_agent_chat.py` over an SSH exec channel (auto-installed once into `~/.cache/pebrel/`).
final class SshAgentChatClient {
    private let scriptData: Data
    private let remotePath: String
    private let queryFn: (String) async throws -> (status: Int, stdout: String)

    init(scriptData: Data, query: @escaping (String) async throws -> (status: Int, stdout: String)) {
        self.scriptData = scriptData
        let shortHash = String(CryptoHelpers.sha256Hex(scriptData).prefix(12))
        self.remotePath = "$HOME/.cache/pebrel/ssh-agent-chat-\(shortHash).py"
        self.queryFn = query
    }

    func foreground() async throws -> SshForeground {
        let res = try await call(["mode": "detect"])
        return SshForeground.parse(res)
    }

    func call(_ request: [String: Any]) async throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: request)
        let argument = payload.base64EncodedString()
        let cmd = RemoteSessions.posixWithPath(
            "f=\"\(remotePath)\"; [ -f \"$f\" ] || exit 86; command -v python3 >/dev/null 2>&1 || exit 87; exec python3 \"$f\" '\(argument)'"
        )
        var reply = try await queryFn(cmd)
        if reply.status == 86 {
            try await install()
            reply = try await queryFn(cmd)
        }
        if reply.status == 87 { throw DesktopRpcFailure("python_missing") }
        guard reply.status == 0 else { throw DesktopRpcFailure("conversation_unavailable") }

        let prefix = "PEBREL_SSH_CHAT="
        guard let line = reply.stdout.components(separatedBy: "\n").last(where: { $0.hasPrefix(prefix) }),
              let data = String(line.dropFirst(prefix.count)).data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (result["version"] as? Int) == 1 else {
            throw DesktopRpcFailure("conversation_unavailable")
        }
        if let err = result["error"] as? String, !err.isEmpty {
            throw DesktopRpcFailure(err)
        }
        return result
    }

    private func install() async throws {
        guard let compressed = CryptoHelpers.zlibCompress(scriptData) else {
            throw DesktopRpcFailure("conversation_unavailable")
        }
        let encoded = compressed.base64EncodedString()
        let staged = "\(remotePath).b64"
        let initReply = try await queryFn(RemoteSessions.posixWithPath("umask 077; mkdir -p \"$HOME/.cache/pebrel\" && : > \"\(staged)\""))
        guard initReply.status == 0 else { throw DesktopRpcFailure("conversation_unavailable") }

        var idx = encoded.startIndex
        while idx < encoded.endIndex {
            let nextIdx = encoded.index(idx, offsetBy: 6000, limitedBy: encoded.endIndex) ?? encoded.endIndex
            let chunk = String(encoded[idx..<nextIdx])
            let step = try await queryFn(RemoteSessions.posixWithPath("printf %s '\(chunk)' >> \"\(staged)\""))
            guard step.status == 0 else { throw DesktopRpcFailure("conversation_unavailable") }
            idx = nextIdx
        }

        let unpack = "import base64,sys,zlib;open(sys.argv[2],'wb').write(zlib.decompress(base64.b64decode(open(sys.argv[1]).read())))"
        let finish = try await queryFn(RemoteSessions.posixWithPath(
            "command -v python3 >/dev/null 2>&1 || exit 87; python3 -c \"\(unpack)\" \"\(staged)\" \"\(remotePath).tmp\" && mv \"\(remotePath).tmp\" \"\(remotePath)\"; s=$?; rm -f \"\(staged)\" \"\(remotePath).tmp\"; exit $s"
        ))
        if finish.status == 87 { throw DesktopRpcFailure("python_missing") }
        guard finish.status == 0 else { throw DesktopRpcFailure("conversation_unavailable") }
    }
}

/// Desktop Runtime conversation client (`conversation.read/send/choose/key`).
@MainActor
final class DesktopConversation: ObservableObject, ConversationSource {
    @Published private(set) var page: ConversationPage
    var pagePublisher: AnyPublisher<ConversationPage, Never> { $page.eraseToAnyPublisher() }

    private let windowId: Int64
    private let paneId: Int64
    private let resolveClient: @MainActor () -> (client: DesktopRuntimeClient, allowInput: Bool)?
    private var mutationVersion = 0

    init(
        windowId: Int64,
        paneId: Int64,
        identity: ConversationIdentity,
        resolveClient: @escaping @MainActor () -> (client: DesktopRuntimeClient, allowInput: Bool)?
    ) {
        self.windowId = windowId
        self.paneId = paneId
        self.page = ConversationPage(identity: identity)
        self.resolveClient = resolveClient
    }

    func refresh(older: Bool) async throws -> Bool {
        guard (mutationVersion % 2) == 0 else { return false }
        let startVersion = mutationVersion
        guard let ctx = resolveClient() else { throw DesktopRpcFailure("desktop_disconnected") }

        let old = page
        if older && old.before == nil { return false }

        var idDict: [String: Any] = ["kind": old.identity.kind, "session_id": old.identity.session]
        if let epoch = old.identity.epoch { idDict["epoch"] = epoch }
        var params: [String: Any] = [
            "window_id": windowId,
            "pane_id": paneId,
            "identity": idDict,
        ]
        if older, let before = old.before {
            params["before"] = before
        } else if !older, let rev = old.revision {
            params["revision"] = rev
        }

        let res = try await ctx.client.request(method: "conversation.read", params: params)
        guard mutationVersion == startVersion else { return false }

        let respId = res["identity"] as? [String: Any]
        let kind = respId?["kind"] as? String ?? old.identity.kind
        let session = respId?["session_id"] as? String ?? old.identity.session
        let epoch = (respId?["epoch"] as? NSNumber)?.int64Value ?? old.identity.epoch
        guard kind == old.identity.kind && session == old.identity.session else {
            throw DesktopRpcFailure("conversation_identity_changed")
        }
        if let oldEpoch = old.identity.epoch, let epoch, oldEpoch != epoch {
            throw DesktopRpcFailure("conversation_identity_changed")
        }

        let unchanged = res["unchanged"] as? Bool ?? false
        let received = unchanged ? [] : parseMessages(res["messages"])
        let merged = mergeMessages(old: old.messages, received: received, older: older, unchanged: unchanged)
        guard merged.count <= 640 else { throw DesktopRpcFailure("conversation_history_limit") }
        let totalBytes = merged.reduce(0) { $0 + $1.text.utf8.count + ($1.detail?.utf8.count ?? 0) }
        guard totalBytes <= 1024 * 1024 else { throw DesktopRpcFailure("conversation_history_limit") }

        let next = ConversationPage(
            identity: ConversationIdentity(kind: kind, session: session, epoch: epoch),
            messages: merged,
            revision: older ? old.revision : (res["revision"] as? String ?? old.revision),
            before: unchanged ? old.before : ((older || !old.loaded) ? (res["before"] as? NSNumber)?.int64Value : old.before),
            cwd: res["cwd"] as? String ?? old.cwd,
            loaded: true,
            canSend: (res["can_send"] as? Bool ?? false) && ctx.allowInput,
            state: res["state"] as? String ?? "idle",
            activity: "",
            truncated: old.truncated || (res["truncated"] as? Bool ?? false),
            prompt: parsePrompt(res["prompt"])
        )
        let changed = next != page
        page = next
        return changed
    }

    func send(_ text: String) async throws {
        guard let ctx = resolveClient() else { throw DesktopRpcFailure("desktop_disconnected") }
        guard ctx.allowInput else { throw DesktopRpcFailure("input_not_authorized") }
        guard page.canSend, let epoch = page.identity.epoch else { throw DesktopRpcFailure("agent_busy") }

        mutationVersion += 1
        page.canSend = false
        page.prompt = nil
        defer { mutationVersion += 1 }

        let res = try await ctx.client.request(method: "conversation.send", params: [
            "window_id": windowId,
            "pane_id": paneId,
            "identity": ["kind": page.identity.kind, "session_id": page.identity.session, "epoch": epoch],
            "text": text,
        ])
        guard (res["accepted"] as? Bool) == true else { throw DesktopRpcFailure("delivery_unknown") }
    }

    func choose(prompt: ConversationPrompt, index: Int) async throws {
        guard let ctx = resolveClient() else { throw DesktopRpcFailure("desktop_disconnected") }
        guard ctx.allowInput else { throw DesktopRpcFailure("input_not_authorized") }
        guard page.prompt?.id == prompt.id, let epoch = page.identity.epoch else { throw DesktopRpcFailure("prompt_changed") }

        mutationVersion += 1
        page.canSend = false
        page.prompt = nil
        defer { mutationVersion += 1 }

        let res = try await ctx.client.request(method: "conversation.choose", params: [
            "window_id": windowId,
            "pane_id": paneId,
            "identity": ["kind": page.identity.kind, "session_id": page.identity.session, "epoch": epoch],
            "prompt_id": prompt.id,
            "option": index,
        ])
        guard (res["accepted"] as? Bool) == true else { throw DesktopRpcFailure("delivery_unknown") }
    }

    func key(_ keyName: String) async throws {
        guard let ctx = resolveClient() else { throw DesktopRpcFailure("desktop_disconnected") }
        guard ctx.allowInput else { throw DesktopRpcFailure("input_not_authorized") }
        guard let epoch = page.identity.epoch else { throw DesktopRpcFailure("conversation_unavailable") }

        mutationVersion += 1
        defer { mutationVersion += 1 }

        let res = try await ctx.client.request(method: "conversation.key", params: [
            "window_id": windowId,
            "pane_id": paneId,
            "identity": ["kind": page.identity.kind, "session_id": page.identity.session, "epoch": epoch],
            "key": keyName,
        ])
        guard (res["accepted"] as? Bool) == true else { throw DesktopRpcFailure("delivery_unknown") }
    }

    private func parseMessages(_ raw: Any?) -> [ConversationMessage] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let role = row["role"] as? String else { return nil }
            return ConversationMessage(
                id: id,
                role: role,
                text: row["text"] as? String ?? "",
                name: row["name"] as? String,
                detail: row["detail"] as? String,
                complete: row["complete"] as? Bool ?? true,
                truncated: row["truncated"] as? Bool ?? false,
                isError: row["error"] as? Bool ?? false
            )
        }
    }

    private func parsePrompt(_ raw: Any?) -> ConversationPrompt? {
        guard let obj = raw as? [String: Any],
              let id = obj["id"] as? String,
              let text = obj["text"] as? String,
              let options = obj["options"] as? [String] else {
            return nil
        }
        return ConversationPrompt(
            id: id,
            text: text,
            options: options,
            selected: obj["selected"] as? Int ?? 0,
            binary: obj["binary"] as? Bool ?? false
        )
    }

    private func mergeMessages(
        old: [ConversationMessage],
        received: [ConversationMessage],
        older: Bool,
        unchanged: Bool
    ) -> [ConversationMessage] {
        if unchanged { return old }
        if older {
            var seen = Set<String>()
            return (received + old).filter { seen.insert($0.id).inserted }
        }
        guard let firstNew = received.first else { return old }
        let firstOffset = messageOffset(firstNew.id)
        let prefix = old.prefix { messageOffset($0.id) < firstOffset }
        return Array(prefix) + received
    }

    private func messageOffset(_ id: String) -> Int64 {
        Int64(id.split(separator: ":").first ?? "0") ?? 0
    }
}

/// Conversation source for an AI agent running inside an interactive SSH terminal session.
@MainActor
final class SshConversation: ObservableObject, ConversationSource {
    @Published private(set) var page: ConversationPage
    var pagePublisher: AnyPublisher<ConversationPage, Never> { $page.eraseToAnyPublisher() }

    private let kind: String
    private let chat: SshAgentChatClient
    private let terminal: @MainActor () -> TerminalSession?
    private let isReady: @MainActor () -> Bool
    private var pending: [(message: ConversationMessage, timestamp: Date)] = []
    private var sentCounter = 0

    init(
        kind: String,
        chat: SshAgentChatClient,
        terminal: @escaping @MainActor () -> TerminalSession?,
        isReady: @escaping @MainActor () -> Bool
    ) {
        self.kind = kind
        self.chat = chat
        self.terminal = terminal
        self.isReady = isReady
        self.page = ConversationPage(identity: ConversationIdentity(kind: kind, session: "", epoch: 1))
    }

    func refresh(older: Bool) async throws -> Bool {
        let previous = page
        let cleanOldMessages = previous.messages.filter { !$0.id.hasPrefix("pending:") }
        var old = previous
        old.messages = cleanOldMessages
        if older && old.before == nil { return false }

        var req: [String: Any] = ["mode": "read"]
        if older, let before = old.before {
            req["before"] = before
        } else if let rev = old.revision {
            req["revision"] = rev
        }

        let res = try await chat.call(req)
        guard (res["agent"] as? String) == kind else { throw DesktopRpcFailure("conversation_ended") }
        let sessionId = res["session"] as? String ?? ""
        let sameSession = (sessionId == old.identity.session)
        let base = sameSession ? old : ConversationPage(identity: ConversationIdentity(kind: kind, session: sessionId, epoch: 1))
        let unchanged = (res["unchanged"] as? Bool ?? false) && sameSession

        let received: [ConversationMessage]
        if unchanged {
            received = []
        } else {
            let rows = res["messages"] as? [[String: Any]] ?? []
            received = rows.compactMap { row in
                guard let id = row["id"] as? String, let role = row["role"] as? String else { return nil }
                return ConversationMessage(
                    id: id,
                    role: role,
                    text: row["text"] as? String ?? "",
                    name: row["name"] as? String,
                    detail: row["detail"] as? String,
                    complete: row["complete"] as? Bool ?? true,
                    truncated: row["truncated"] as? Bool ?? false,
                    isError: row["error"] as? Bool ?? false
                )
            }
        }

        let merged: [ConversationMessage]
        if unchanged {
            merged = base.messages
        } else if older {
            var seen = Set<String>()
            merged = (received + base.messages).filter { seen.insert($0.id).inserted }
        } else if received.isEmpty {
            merged = sameSession ? base.messages : []
        } else {
            let firstOffset = Int64(received[0].id.split(separator: ":").first ?? "0") ?? 0
            let prefix = base.messages.prefix { (Int64($0.id.split(separator: ":").first ?? "0") ?? 0) < firstOffset }
            merged = Array(prefix) + received
        }

        let screen = terminal()?.screenText() ?? ""
        let prompt = TerminalPromptParser.parse(screen)
        let recentUserTexts = Set(merged.filter { $0.role == "user" }.suffix(pending.count + 4).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
        let cutoff = Date().addingTimeInterval(-60)
        pending.removeAll { item in
            item.timestamp <= cutoff || recentUserTexts.contains(item.message.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let running = TerminalPromptParser.isRunning(screen)
        let next = ConversationPage(
            identity: base.identity,
            messages: merged + pending.map(\.message),
            revision: older ? base.revision : ((res["revision"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? base.revision),
            before: unchanged ? base.before : ((older || !base.loaded) ? (res["before"] as? NSNumber)?.int64Value : base.before),
            cwd: res["cwd"] as? String ?? base.cwd,
            loaded: true,
            canSend: isReady() && prompt == nil,
            state: prompt != nil ? "waiting_input" : ((running || !pending.isEmpty) ? "running" : "idle"),
            activity: running ? TerminalPromptParser.activity(screen) : "",
            truncated: base.truncated || (res["truncated"] as? Bool ?? false),
            prompt: prompt
        )
        page = next
        return next != previous
    }

    func send(_ text: String) async throws {
        guard isReady(), let term = terminal() else { throw DesktopRpcFailure("desktop_disconnected") }
        if TerminalPromptParser.parse(term.screenText()) != nil { throw DesktopRpcFailure("agent_busy") }
        guard term.paste(text) else { throw DesktopRpcFailure("input_in_progress") }
        try await Task.sleep(nanoseconds: 80_000_000)
        guard term.sendText("\r") else { throw DesktopRpcFailure("delivery_unknown") }
        sentCounter += 1
        let msg = ConversationMessage(
            id: "pending:\(sentCounter)",
            role: "user",
            text: text,
            name: nil,
            detail: nil,
            complete: true,
            truncated: false,
            isError: false
        )
        pending.append((msg, Date()))
        page.messages.append(msg)
        page.canSend = false
        page.state = "running"
    }

    func choose(prompt: ConversationPrompt, index: Int) async throws {
        guard isReady(), let term = terminal() else { throw DesktopRpcFailure("desktop_disconnected") }
        guard let shown = TerminalPromptParser.parse(term.screenText()),
              shown.id == prompt.id,
              index >= 0, index < shown.options.count else {
            throw DesktopRpcFailure("prompt_changed")
        }
        let stepKey = index > shown.selected ? "↓" : "↑"
        guard let step = TerminalShortcut.parse(stepKey), let enter = TerminalShortcut.parse("Enter") else { return }
        for _ in 0..<abs(index - shown.selected) {
            guard term.sendShortcut(step) else { throw DesktopRpcFailure("delivery_unknown") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        guard term.sendShortcut(enter) else { throw DesktopRpcFailure("delivery_unknown") }
        page.prompt = nil
    }

    func key(_ keyName: String) async throws {
        guard isReady(), let term = terminal() else { throw DesktopRpcFailure("desktop_disconnected") }
        guard let shortcut = TerminalShortcut.parse(keyName) else { throw DesktopRpcFailure("conversation_unavailable") }
        guard term.sendShortcut(shortcut) else { throw DesktopRpcFailure("delivery_unknown") }
    }
}
