import Combine
import Foundation

struct DesktopGitTarget: Equatable, Hashable {
    let desktopId: String
    let windowId: Int64
    let paneId: Int64
    let cwd: String
    let generation: Int64
    let runtimeProcess: Int64

    var draftKey: String {
        "\(desktopId):git:\(runtimeProcess):\(windowId):\(paneId):\(cwd)"
    }
}

struct GitStatusEntry: Identifiable, Equatable, Hashable {
    let path: String
    let original: String?
    let index: String
    let worktree: String
    let conflict: Bool

    var id: String { "\(path)|\(index)|\(worktree)" }
    var staged: Bool { index != "." && index != "?" }
    var unstaged: Bool { worktree != "." }

    var displayBadge: String {
        if conflict { return "!" }
        if index == "?" || worktree == "?" { return "U" }
        return unstaged ? worktree : index
    }
}

struct GitStatusSnapshot: Equatable {
    let root: String
    let revision: String
    let branch: String
    let upstream: String?
    let ahead: Int
    let behind: Int
    let entries: [GitStatusEntry]

    var stagedEntries: [GitStatusEntry] { entries.filter(\.staged) }
    var unstagedEntries: [GitStatusEntry] { entries.filter { $0.unstaged && $0.worktree != "?" } }
    var untrackedEntries: [GitStatusEntry] { entries.filter { $0.index == "?" || $0.worktree == "?" } }
    var hasConflicts: Bool { entries.contains(where: \.conflict) }
}

struct GitCommitEntry: Identifiable, Equatable, Hashable {
    let hash: String
    let shortHash: String
    let subject: String
    let author: String
    let timestamp: Int64
    let refs: String

    var id: String { hash }
}

struct GitTreeRow: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let depth: Int
    let entry: GitStatusEntry?
    let isDirectory: Bool
    let isExpanded: Bool
}

struct GitProblem: Error, Equatable {
    let code: String
    let detail: String
}

enum GitTreeBuilder {
    static func build(entries: [GitStatusEntry], collapsedFolders: Set<String>) -> [GitTreeRow] {
        let sorted = entries.sorted { $0.path < $1.path }
        var rows: [GitTreeRow] = []
        var emittedFolders = Set<String>()

        for entry in sorted {
            let parts = entry.path.split(separator: "/").map(String.init)
            var prefix = ""
            var hidden = false
            for idx in 0..<max(0, parts.count - 1) {
                prefix = prefix.isEmpty ? parts[idx] : "\(prefix)/\(parts[idx])"
                if !emittedFolders.contains(prefix) {
                    emittedFolders.insert(prefix)
                    if !hidden {
                        let expanded = !collapsedFolders.contains(prefix)
                        rows.append(GitTreeRow(
                            id: "dir:\(prefix)",
                            name: parts[idx],
                            path: prefix,
                            depth: idx,
                            entry: nil,
                            isDirectory: true,
                            isExpanded: expanded
                        ))
                    }
                }
                if collapsedFolders.contains(prefix) {
                    hidden = true
                }
            }
            if !hidden {
                rows.append(GitTreeRow(
                    id: "file:\(entry.id)",
                    name: parts.last ?? entry.path,
                    path: entry.path,
                    depth: max(0, parts.count - 1),
                    entry: entry,
                    isDirectory: false,
                    isExpanded: false
                ))
            }
        }
        return rows
    }
}

@MainActor
final class DesktopGitController: ObservableObject {
    @Published private(set) var snapshot: GitStatusSnapshot?
    @Published private(set) var history: [GitCommitEntry] = []
    @Published private(set) var hasMoreHistory = false
    @Published private(set) var activeDiffTitle: String?
    @Published private(set) var activeDiffEntry: GitStatusEntry?
    @Published private(set) var activeDiffStaged = false
    @Published private(set) var activeDiffText: String?
    @Published private(set) var busy = false
    @Published private(set) var feedback: String?
    @Published private(set) var problem: GitProblem?
    @Published var collapsedFolders: Set<String> = []

    private let target: DesktopGitTarget
    private let resolveClient: @MainActor () -> (client: DesktopRuntimeClient, allowInput: Bool)?
    private var diffGeneration = 0

    init(
        target: DesktopGitTarget,
        resolveClient: @escaping @MainActor () -> (client: DesktopRuntimeClient, allowInput: Bool)?
    ) {
        self.target = target
        self.resolveClient = resolveClient
    }

    private func baseParams() -> [String: Any] {
        [
            "window_id": target.windowId,
            "pane_id": target.paneId,
            "expected_cwd": target.cwd,
        ]
    }

    func refreshStatus() async {
        guard let ctx = resolveClient() else {
            problem = GitProblem(code: "git_disconnected", detail: "")
            return
        }
        busy = true
        problem = nil
        defer { busy = false }
        do {
            let res = try await ctx.client.request(method: "git.status", params: baseParams())
            snapshot = parseStatus(res)
        } catch let rpc as DesktopRpcFailure {
            problem = GitProblem(code: rpc.code, detail: rpc.detail)
        } catch {
            problem = GitProblem(code: "git_disconnected", detail: "")
        }
    }

    func loadHistory(reset: Bool = false) async {
        guard let ctx = resolveClient() else {
            problem = GitProblem(code: "git_disconnected", detail: "")
            return
        }
        busy = true
        problem = nil
        defer { busy = false }
        let offset = reset ? 0 : history.count
        var params = baseParams()
        params["offset"] = offset
        do {
            let res = try await ctx.client.request(method: "git.history", params: params)
            let more = res["has_more"] as? Bool ?? false
            let raw = res["commits"] as? [[String: Any]] ?? []
            let parsed = raw.compactMap { row -> GitCommitEntry? in
                guard let hash = row["hash"] as? String else { return nil }
                return GitCommitEntry(
                    hash: hash,
                    shortHash: row["short_hash"] as? String ?? String(hash.prefix(7)),
                    subject: row["subject"] as? String ?? "",
                    author: row["author"] as? String ?? "",
                    timestamp: (row["timestamp"] as? NSNumber)?.int64Value ?? 0,
                    refs: row["refs"] as? String ?? ""
                )
            }
            if reset {
                history = parsed
            } else {
                var seen = Set(history.map(\.hash))
                for item in parsed where seen.insert(item.hash).inserted {
                    history.append(item)
                }
            }
            hasMoreHistory = more
        } catch let rpc as DesktopRpcFailure {
            problem = GitProblem(code: rpc.code, detail: rpc.detail)
        } catch {
            problem = GitProblem(code: "git_disconnected", detail: "")
        }
    }

    func openDiff(entry: GitStatusEntry, staged: Bool) async {
        await loadDiff(title: entry.path, path: entry.path, staged: staged, commit: "", entry: entry)
    }

    func openCommitDiff(_ commit: GitCommitEntry) async {
        await loadDiff(title: "\(commit.shortHash) · \(commit.subject)", path: "", staged: false, commit: commit.hash, entry: nil)
    }

    func closeDiff() {
        diffGeneration += 1
        activeDiffTitle = nil
        activeDiffEntry = nil
        activeDiffText = nil
    }

    private func loadDiff(title: String, path: String, staged: Bool, commit: String, entry: GitStatusEntry?) async {
        guard let ctx = resolveClient() else {
            problem = GitProblem(code: "git_disconnected", detail: "")
            return
        }
        diffGeneration += 1
        let gen = diffGeneration
        busy = true
        problem = nil
        defer { busy = false }
        var params = baseParams()
        params["path"] = path
        params["staged"] = staged
        params["commit"] = commit
        do {
            let res = try await ctx.client.request(method: "git.diff", params: params)
            guard gen == diffGeneration else { return }
            activeDiffTitle = title
            activeDiffEntry = entry
            activeDiffStaged = staged
            activeDiffText = res["text"] as? String ?? ""
        } catch let rpc as DesktopRpcFailure {
            problem = GitProblem(code: rpc.code, detail: rpc.detail)
        } catch {
            problem = GitProblem(code: "git_disconnected", detail: "")
        }
    }

    func stage(path: String? = nil, all: Bool = false) async {
        await mutate(method: "git.stage", extra: ["path": path ?? "", "all": all], label: L10n.tr("git_stage"))
    }

    func unstage(path: String? = nil, all: Bool = false) async {
        await mutate(method: "git.unstage", extra: ["path": path ?? "", "all": all], label: L10n.tr("git_unstage"))
    }

    func commit(message: String) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 16384 else { return false }
        return await mutate(method: "git.commit", extra: ["message": trimmed], label: L10n.tr("git_commit"))
    }

    func fetch() async {
        _ = await mutate(method: "git.fetch", extra: [:], label: L10n.tr("git_fetch"))
    }

    func pull() async {
        _ = await mutate(method: "git.pull", extra: [:], label: L10n.tr("git_pull"))
    }

    func push() async {
        _ = await mutate(method: "git.push", extra: [:], label: L10n.tr("git_push"))
    }

    func sync() async {
        guard await mutate(method: "git.fetch", extra: [:], label: L10n.tr("git_fetch")) else { return }
        guard await mutate(method: "git.pull", extra: [:], label: L10n.tr("git_pull")) else { return }
        _ = await mutate(method: "git.push", extra: [:], label: L10n.tr("git_push"))
    }

    @discardableResult
    private func mutate(method: String, extra: [String: Any], label: String) async -> Bool {
        guard !busy else { return false }
        guard let ctx = resolveClient() else {
            problem = GitProblem(code: "git_disconnected", detail: "")
            return false
        }
        guard ctx.allowInput else {
            problem = GitProblem(code: "input_not_authorized", detail: "")
            return false
        }
        guard let rev = snapshot?.revision else {
            problem = GitProblem(code: "git_stale", detail: "")
            return false
        }
        busy = true
        problem = nil
        feedback = nil
        defer { busy = false }

        var params = baseParams()
        params["revision"] = rev
        for (k, v) in extra { params[k] = v }

        do {
            let res = try await ctx.client.request(method: method, params: params)
            guard (res["success"] as? Bool) == true else {
                problem = GitProblem(code: "git_outcome_unknown", detail: "")
                return false
            }
            diffGeneration += 1
            activeDiffTitle = nil
            activeDiffEntry = nil
            activeDiffText = nil
            history = []
            hasMoreHistory = false
            feedback = label
            let statusRes = try await ctx.client.request(method: "git.status", params: baseParams())
            snapshot = parseStatus(statusRes)
            return true
        } catch let rpc as DesktopRpcFailure {
            problem = GitProblem(code: rpc.code, detail: rpc.detail)
            return false
        } catch {
            problem = GitProblem(code: "git_outcome_unknown", detail: "")
            return false
        }
    }

    private func parseStatus(_ dict: [String: Any]) -> GitStatusSnapshot? {
        guard let root = dict["root"] as? String,
              let revision = dict["revision"] as? String,
              let status = dict["status"] as? [String: Any] else {
            return nil
        }
        let branch = status["branch"] as? String ?? ""
        let upstream = status["upstream"] as? String
        let ahead = status["ahead"] as? Int ?? 0
        let behind = status["behind"] as? Int ?? 0
        let rawEntries = status["entries"] as? [[String: Any]] ?? []
        let entries = rawEntries.compactMap { row -> GitStatusEntry? in
            guard let path = row["path"] as? String else { return nil }
            return GitStatusEntry(
                path: path,
                original: row["original"] as? String,
                index: row["index"] as? String ?? ".",
                worktree: row["worktree"] as? String ?? ".",
                conflict: row["conflict"] as? Bool ?? false
            )
        }
        return GitStatusSnapshot(
            root: root,
            revision: revision,
            branch: branch,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            entries: entries
        )
    }
}
