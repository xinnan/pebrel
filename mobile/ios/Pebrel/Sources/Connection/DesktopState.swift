import Foundation
import UserNotifications

struct DesktopAgentInfo: Equatable, Hashable {
    let kind: String
    let displayName: String
    let sessionId: String?
}

struct DesktopPane: Identifiable, Equatable, Hashable {
    let id: Int64
    let window: Int64
    let title: String
    let cwd: String
    let runningProgram: String
    let taskState: String
    let stateChangeSeq: Int64
    let sshDestination: String?
    let agent: DesktopAgentInfo?

    var displayTitle: String {
        if !runningProgram.isEmpty { return runningProgram }
        if !title.isEmpty { return title }
        return L10n.tr("raw_terminal")
    }
}

struct DesktopTabFile: Equatable, Hashable {
    let path: String
    let remote: Bool
    let dirty: Bool
    let saving: Bool
    let ready: Bool
    let revision: Int64
}

struct DesktopTab: Identifiable, Equatable, Hashable {
    let tabId: String?
    let window: Int64
    let index: Int
    let label: String
    let kind: String
    let active: Bool
    let focusedPaneId: Int64?
    let file: DesktopTabFile?
    let panes: [DesktopPane]

    var id: String { key }
    var key: String { "\(window):\(tabId ?? "legacy:\(index)")" }

    var readable: Bool {
        file != nil && ["document", "code", "image"].contains(kind)
    }

    var primaryPane: DesktopPane? {
        if let focusedPaneId, let found = panes.first(where: { $0.id == focusedPaneId }) {
            return found
        }
        return panes.first
    }

    var displayTitle: String {
        if !label.isEmpty { return label }
        if let path = file?.path, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        return primaryPane?.displayTitle ?? L10n.tr("raw_terminal")
    }
}

struct DesktopPairingApproval: Equatable {
    let code: String
    let expiresAt: Int64

    var formattedCode: String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

struct DesktopSnapshot: Equatable {
    let processId: Int64
    let revision: Int64
    let allowInput: Bool
    let notificationsEnabled: Bool
    let tabs: [DesktopTab]
    let panes: [DesktopPane]

    static func parse(_ dict: [String: Any]) -> DesktopSnapshot? {
        guard let processId = (dict["process_id"] as? NSNumber)?.int64Value,
              let revision = (dict["revision"] as? NSNumber)?.int64Value else {
            return nil
        }
        let policy = dict["mobile_policy"] as? [String: Any]
        let allowInput = policy?["allow_input"] as? Bool ?? false
        let notifications = policy?["notifications"] as? Bool ?? true

        var tabs: [DesktopTab] = []
        var panes: [DesktopPane] = []

        if let windows = dict["windows"] as? [[String: Any]] {
            for win in windows {
                guard let winId = (win["id"] as? NSNumber)?.int64Value else { continue }
                let rawTabs = win["tabs"] as? [[String: Any]] ?? []
                for tabDict in rawTabs {
                    let tabId = tabDict["tab_id"] as? String
                    let index = tabDict["index"] as? Int ?? tabs.count
                    let label = tabDict["label"] as? String ?? ""
                    let kind = tabDict["kind"] as? String ?? "shell"
                    let active = tabDict["active"] as? Bool ?? false
                    let focusedPane = (tabDict["focused_pane_id"] as? NSNumber)?.int64Value

                    var tabFile: DesktopTabFile?
                    if let f = tabDict["file"] as? [String: Any], let path = f["path"] as? String {
                        tabFile = DesktopTabFile(
                            path: path,
                            remote: f["remote"] as? Bool ?? false,
                            dirty: f["dirty"] as? Bool ?? false,
                            saving: f["saving"] as? Bool ?? false,
                            ready: f["ready"] as? Bool ?? true,
                            revision: (f["revision"] as? NSNumber)?.int64Value ?? 0
                        )
                    }

                    var tabPanes: [DesktopPane] = []
                    for p in (tabDict["panes"] as? [[String: Any]] ?? []) {
                        guard let pid = (p["id"] as? NSNumber)?.int64Value else { continue }
                        var agentInfo: DesktopAgentInfo?
                        if let ag = p["agent"] as? [String: Any], let agKind = ag["kind"] as? String, !agKind.isEmpty {
                            agentInfo = DesktopAgentInfo(
                                kind: agKind,
                                displayName: ag["display_name"] as? String ?? agKind,
                                sessionId: ag["session_id"] as? String
                            )
                        }
                        let pane = DesktopPane(
                            id: pid,
                            window: winId,
                            title: p["title"] as? String ?? "",
                            cwd: p["cwd"] as? String ?? "",
                            runningProgram: p["running_program"] as? String ?? "",
                            taskState: p["task_state"] as? String ?? "unknown",
                            stateChangeSeq: (p["state_change_seq"] as? NSNumber)?.int64Value ?? 0,
                            sshDestination: p["ssh_destination"] as? String,
                            agent: agentInfo
                        )
                        tabPanes.append(pane)
                        panes.append(pane)
                    }

                    tabs.append(DesktopTab(
                        tabId: tabId,
                        window: winId,
                        index: index,
                        label: label,
                        kind: kind,
                        active: active,
                        focusedPaneId: focusedPane,
                        file: tabFile,
                        panes: tabPanes
                    ))
                }
            }
        }

        return DesktopSnapshot(
            processId: processId,
            revision: revision,
            allowInput: allowInput,
            notificationsEnabled: notifications,
            tabs: tabs,
            panes: panes
        )
    }
}

/// Deduplicating desktop pane task-transition tracker matching Android's `DesktopTransitions`.
final class DesktopTransitions {
    private let defaultsKey: String
    private var processId: Int64 = -1
    private var sequences: [String: Int64] = [:]
    private let alertStates: Set<String> = ["finished", "failed", "waiting_input", "attention"]

    init(workspaceId: String) {
        self.defaultsKey = "desktop_transitions_\(workspaceId)"
        load()
    }

    func advance(snapshot: DesktopSnapshot) -> [DesktopPane] {
        let isFirstForProcess = (snapshot.processId != processId)
        if isFirstForProcess {
            processId = snapshot.processId
            sequences.removeAll()
        }

        var triggered: [DesktopPane] = []
        var liveKeys = Set<String>()

        for pane in snapshot.panes {
            let key = "\(pane.window):\(pane.id)"
            liveKeys.insert(key)
            let prev = sequences[key]
            if !isFirstForProcess, let prev, pane.stateChangeSeq > prev, alertStates.contains(pane.taskState) {
                triggered.append(pane)
            }
            sequences[key] = pane.stateChangeSeq
        }

        sequences = sequences.filter { liveKeys.contains($0.key) }
        if sequences.count > 512 {
            let keep = Set(sequences.keys.sorted().suffix(512))
            sequences = sequences.filter { keep.contains($0.key) }
        }
        save()
        return snapshot.notificationsEnabled ? triggered : []
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proc = (obj["process"] as? NSNumber)?.int64Value,
              let rows = obj["panes"] as? [[NSNumber]] else {
            return
        }
        processId = proc
        for row in rows where row.count == 3 {
            sequences["\(row[0].int64Value):\(row[1].int64Value)"] = row[2].int64Value
        }
    }

    private func save() {
        var rows: [[Int64]] = []
        for (key, seq) in sequences {
            let parts = key.split(separator: ":")
            if parts.count == 2, let w = Int64(parts[0]), let p = Int64(parts[1]) {
                rows.append([w, p, seq])
            }
        }
        let obj: [String: Any] = ["process": processId, "panes": rows]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

enum DesktopNotificationCenter {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func notify(desktopId: String, desktopName: String, processId: Int64, pane: DesktopPane) {
        let content = UNMutableNotificationContent()
        content.title = "\(desktopName) · \(pane.displayTitle)"
        content.body = L10n.tr("task_\(pane.taskState)")
        content.sound = .default
        content.userInfo = [
            "action": "OPEN_TASK",
            "desktop": desktopId,
            "window": pane.window,
            "pane": pane.id,
            "process": processId,
        ]
        let req = UNNotificationRequest(
            identifier: "pebrel-task-\(desktopId)-\(pane.window)-\(pane.id)-\(pane.stateChangeSeq)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
