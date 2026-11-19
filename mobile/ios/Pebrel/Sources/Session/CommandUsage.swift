import Combine
import Foundation

/// Per-session bounded command history powering composer autocomplete suggestions.
@MainActor
final class CommandUsageStore: ObservableObject {
    private let maxEntriesPerScope = 64
    private let maxScopes = 24
    private let defaultsKey = "pebrel_command_usage_v1"

    private var scopes: [String: [String]] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.scopes = decoded
        }
    }

    func record(_ command: String, scope: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512, !trimmed.contains("\n") else { return }
        var list = scopes[scope] ?? []
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        if list.count > maxEntriesPerScope {
            list = Array(list.prefix(maxEntriesPerScope))
        }
        scopes[scope] = list
        if scopes.count > maxScopes, let dropKey = scopes.keys.first(where: { $0 != scope }) {
            scopes.removeValue(forKey: dropKey)
        }
        persist()
    }

    func suggestions(for draft: String, scope: String, limit: Int = 6) -> [String] {
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let list = scopes[scope] ?? []
        var prefixMatches: [String] = []
        var containsMatches: [String] = []
        for entry in list {
            let lower = entry.lowercased()
            if lower == query { continue }
            if lower.hasPrefix(query) {
                prefixMatches.append(entry)
            } else if lower.contains(query) {
                containsMatches.append(entry)
            }
        }
        return Array((prefixMatches + containsMatches).prefix(limit))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(scopes) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
