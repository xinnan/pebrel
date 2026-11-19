import Foundation

struct DesktopFilePayload {
    let revision: String
    let kind: String
    let bytes: Data
}

/// Operations on Desktop tabs: focus, close, create terminal, open file, and chunked file read.
final class DesktopTabsClient {
    private let client: DesktopRuntimeClient
    private let allowInput: @MainActor () -> Bool

    init(client: DesktopRuntimeClient, allowInput: @escaping @MainActor () -> Bool) {
        self.client = client
        self.allowInput = allowInput
    }

    func focus(_ tab: DesktopTab) async throws {
        guard await allowInput() else { throw DesktopRpcFailure("input_not_authorized") }
        guard let tabId = tab.tabId else { throw DesktopRpcFailure("tabs_unsupported") }
        _ = try await client.request(method: "tab.focus", params: [
            "window_id": tab.window,
            "tab_id": tabId,
        ])
    }

    func close(_ tab: DesktopTab) async throws {
        guard await allowInput() else { throw DesktopRpcFailure("input_not_authorized") }
        guard let tabId = tab.tabId else { throw DesktopRpcFailure("tabs_unsupported") }
        _ = try await client.request(method: "tab.close", params: [
            "window_id": tab.window,
            "tab_id": tabId,
        ])
    }

    func newTerminal(windowId: Int64?, cwd: String?) async throws -> (windowId: Int64, paneId: Int64)? {
        guard await allowInput() else { throw DesktopRpcFailure("input_not_authorized") }
        var params: [String: Any] = [:]
        if let windowId { params["window_id"] = windowId }
        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["cwd"] = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let result = try await client.request(method: "tab.new", params: params)
        if let action = result["action"] as? [String: Any],
           let win = (action["window_id"] as? NSNumber)?.int64Value,
           let pane = (action["pane_id"] as? NSNumber)?.int64Value {
            return (win, pane)
        }
        return nil
    }

    func openFile(windowId: Int64, path: String) async throws -> String? {
        guard await allowInput() else { throw DesktopRpcFailure("input_not_authorized") }
        let result = try await client.request(method: "tab.open", params: [
            "window_id": windowId,
            "path": path,
        ])
        if let action = result["action"] as? [String: Any] {
            return action["tab_id"] as? String
        }
        return nil
    }

    func readFile(
        tab: DesktopTab,
        onProgress: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> DesktopFilePayload {
        guard let tabId = tab.tabId else { throw DesktopRpcFailure("tabs_unsupported") }
        let maxTotal = 16 * 1024 * 1024
        let limit = 65536

        var offset = 0
        var revision: String?
        var expectedTotal: Int?
        var kind = tab.kind
        var output = Data()

        while true {
            try Task.checkCancellation()
            var params: [String: Any] = [
                "window_id": tab.window,
                "tab_id": tabId,
                "offset": offset,
                "limit": limit,
            ]
            if let revision { params["revision"] = revision }

            let result = try await client.request(method: "tab.read", params: params)
            guard (result["window_id"] as? NSNumber)?.int64Value == tab.window,
                  (result["tab_id"] as? String) == tabId,
                  let rev = result["revision"] as? String,
                  let total = result["total_bytes"] as? Int, total >= 0, total <= maxTotal,
                  let chunkKind = result["kind"] as? String,
                  let respOffset = result["offset"] as? Int, respOffset == offset,
                  let nextOffset = result["next_offset"] as? Int,
                  let eof = result["eof"] as? Bool,
                  let encoded = result["data"] as? String,
                  let chunk = Data(base64Encoded: encoded),
                  chunk.count <= limit,
                  nextOffset == offset + chunk.count else {
                throw DesktopRpcFailure("invalid_file_response")
            }

            if let existingRev = revision, existingRev != rev { throw DesktopRpcFailure("file_changed") }
            if let existingTotal = expectedTotal, existingTotal != total { throw DesktopRpcFailure("file_changed") }
            revision = rev
            expectedTotal = total
            kind = chunkKind

            output.append(chunk)
            offset = nextOffset
            await onProgress(offset, total)

            if eof {
                guard output.count == total else { throw DesktopRpcFailure("file_changed") }
                break
            }
            guard !chunk.isEmpty else { throw DesktopRpcFailure("invalid_file_response") }
        }

        return DesktopFilePayload(revision: revision ?? "", kind: kind, bytes: output)
    }
}
