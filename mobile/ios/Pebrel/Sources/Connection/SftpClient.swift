import CryptoKit
import Foundation

struct SftpEntry: Identifiable, Equatable, Hashable {
    let path: String
    let name: String
    let kind: String
    let size: Int64?
    let modified: Int64?
    let permissions: Int?
    let revision: String

    var id: String { path }
    var isDirectory: Bool { kind == "directory" }

    static func parse(_ dict: [String: Any]) -> SftpEntry? {
        guard let path = dict["path"] as? String,
              let name = dict["name"] as? String,
              let kind = dict["kind"] as? String,
              let revision = dict["revision"] as? String else {
            return nil
        }
        return SftpEntry(
            path: path,
            name: name,
            kind: kind,
            size: (dict["size"] as? NSNumber)?.int64Value,
            modified: (dict["modified"] as? NSNumber)?.int64Value,
            permissions: (dict["permissions"] as? NSNumber)?.intValue,
            revision: revision
        )
    }
}

struct SftpListing: Equatable {
    let path: String
    let entries: [SftpEntry]
    let cursor: UInt64?
    let skipped: Int
}

struct SftpTab: Identifiable, Equatable, Hashable {
    let id: String
    let sessionId: String
    let file: SftpEntry
}

enum SftpPaths {
    static func child(parent: String, name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !CryptoHelpers.containsControlChar(name) else {
            throw NativeSshError(code: "INVALID_INPUT")
        }
        let trimmed = parent == "/" ? "" : parent.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return "\(trimmed)/\(name)"
    }

    static func parent(of path: String) -> String {
        let trimmed = path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let prefix = String(trimmed[..<slash])
        return prefix.isEmpty ? "/" : prefix
    }
}

/// Resumable SFTP v3 client sharing the parent SSH session with adaptive 32 KiB..2 MiB windowing
/// and SHA-256 `resolve_upload` commit reconciliation.
final class SftpClient {
    static let chunkSize = 32 * 1024
    static let batchSize = chunkSize * 64 // 2 MiB
    static let maxPreviewBytes: Int64 = 16 * 1024 * 1024

    private let execute: ([String: Any]) throws -> [String: Any]
    private let recover: (() async throws -> Void)?
    private let isActive: () -> Bool

    init(
        execute: @escaping ([String: Any]) throws -> [String: Any],
        recover: (() async throws -> Void)? = nil,
        isActive: @escaping () -> Bool = { true }
    ) {
        self.execute = execute
        self.recover = recover
        self.isActive = isActive
    }

    private func request(_ op: String, fields: [String: Any] = [:]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard isActive() else { throw NativeSshError(code: "SFTP_CLOSED") }
        var body = fields
        body["op"] = op
        let requestBody = body
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let res = try self.execute(requestBody)
                    cont.resume(returning: res)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func list(path: String, cursor: UInt64? = nil) async throws -> SftpListing {
        var fields: [String: Any] = ["path": path]
        if let cursor { fields["cursor"] = cursor }
        let res = try await request("list", fields: fields)
        let next = (res["cursor"] as? NSNumber)?.uint64Value
        if Task.isCancelled {
            if let next { _ = try? await closeList(cursor: next) }
            throw CancellationError()
        }
        let rawEntries = res["entries"] as? [[String: Any]] ?? []
        let entries = rawEntries.prefix(256).compactMap(SftpEntry.parse)
        return SftpListing(
            path: res["path"] as? String ?? path,
            entries: entries,
            cursor: next,
            skipped: res["skipped"] as? Int ?? 0
        )
    }

    func closeList(cursor: UInt64) async throws {
        _ = try await request("close_list", fields: ["cursor": cursor])
    }

    func stat(path: String) async throws -> SftpEntry {
        let res = try await request("stat", fields: ["path": path])
        guard let entry = SftpEntry.parse(res) else { throw NativeSshError(code: "SFTP_OPERATION") }
        return entry
    }

    func mkdir(path: String) async throws {
        _ = try await request("mkdir", fields: ["path": path])
    }

    func rename(entry: SftpEntry, destination: String) async throws {
        _ = try await request("rename", fields: [
            "path": entry.path,
            "destination": destination,
            "revision": entry.revision,
        ])
    }

    func remove(entry: SftpEntry) async throws {
        _ = try await request("remove", fields: [
            "path": entry.path,
            "revision": entry.revision,
        ])
    }

    func preview(path: String, progress: @escaping @MainActor (Int64, Int64) -> Void = { _, _ in }) async throws -> (file: SftpEntry, data: Data) {
        var data = Data()
        let file = try await download(path: path, maximum: Self.maxPreviewBytes, writeChunk: { chunk in
            data.append(chunk)
        }, progress: progress)
        return (file, data)
    }

    func downloadToFile(
        path: String,
        destinationURL: URL,
        waiting: @escaping @MainActor (Bool) -> Void = { _ in },
        progress: @escaping @MainActor (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> SftpEntry {
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: destinationURL)
        defer { try? fh.close() }
        do {
            return try await download(path: path, maximum: Int64.max, waiting: waiting, writeChunk: { chunk in
                try fh.write(contentsOf: chunk)
            }, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    func download(
        path: String,
        maximum: Int64,
        waiting: @escaping @MainActor (Bool) -> Void = { _ in },
        writeChunk: (Data) throws -> Void,
        progress: @escaping @MainActor (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> SftpEntry {
        var transfer: UInt64?
        var file: SftpEntry?
        var offset: Int64 = 0
        var batch = Self.batchSize

        defer {
            let t = transfer
            Task {
                if let t, self.isActive() {
                    _ = try? await self.request("close", fields: ["transfer": t])
                }
                await waiting(false)
            }
        }

        while true {
            try Task.checkCancellation()
            do {
                if transfer == nil {
                    var fields: [String: Any] = ["path": file?.path ?? path, "offset": offset]
                    if let rev = file?.revision { fields["revision"] = rev }
                    let opened = try await request("open_read", fields: fields)
                    guard let tid = (opened["transfer"] as? NSNumber)?.uint64Value,
                          let fDict = opened["file"] as? [String: Any],
                          let current = SftpEntry.parse(fDict) else {
                        throw NativeSshError(code: "SFTP_OPERATION")
                    }
                    if let prev = file, prev.revision != current.revision || prev.path != current.path {
                        throw NativeSshError(code: "SFTP_CHANGED")
                    }
                    transfer = tid
                    file = current
                }
                guard let currentFile = file, let size = currentFile.size else {
                    throw NativeSshError(code: "SFTP_FILE_TYPE")
                }
                if size > maximum { throw NativeSshError(code: "SFTP_TOO_LARGE") }

                let started = Date()
                let chunkRes = try await request("read", fields: [
                    "transfer": transfer!,
                    "offset": offset,
                    "length": batch,
                ])
                guard let encoded = chunkRes["data"] as? String,
                      let bytes = Data(base64Encoded: encoded),
                      bytes.count <= Self.batchSize,
                      (chunkRes["offset"] as? NSNumber)?.int64Value == offset,
                      (chunkRes["next_offset"] as? NSNumber)?.int64Value == offset + Int64(bytes.count),
                      let eof = chunkRes["eof"] as? Bool else {
                    throw NativeSshError(code: "SFTP_OPERATION")
                }
                try writeChunk(bytes)
                offset += Int64(bytes.count)
                await waiting(false)
                await progress(offset, size)
                if bytes.count == batch && Date().timeIntervalSince(started) < 5.0 {
                    batch = min(batch * 2, Self.batchSize)
                }
                if eof {
                    guard offset == size else { throw NativeSshError(code: "SFTP_CHANGED") }
                    return currentFile
                }
                guard !bytes.isEmpty else { throw NativeSshError(code: "SFTP_OPERATION") }
            } catch let sshErr as NativeSshError {
                if sshErr.code == "TIMEOUT" || sshErr.code == "SFTP_TIMEOUT" {
                    batch = max(batch / 2, Self.chunkSize)
                }
                try await awaitRecovery(sshErr, waiting: waiting)
                transfer = nil
            }
        }
    }

    func upload(
        remotePath: String,
        sourceURL: URL,
        expectedSize: Int64?,
        waiting: @escaping @MainActor (Bool) -> Void = { _ in },
        progress: @escaping @MainActor (Int64, Int64?) -> Void = { _, _ in }
    ) async throws -> String {
        let fh = try FileHandle(forReadingFrom: sourceURL)
        defer { try? fh.close() }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var transfer: UInt64?
        var offset: Int64 = 0
        var attempted = false
        var completed = false
        var batch = Self.batchSize
        var hasher = SHA256()

        func openTransfer() async throws {
            while transfer == nil {
                try Task.checkCancellation()
                let resume = attempted
                attempted = true
                do {
                    let res = try await request("begin_upload", fields: [
                        "path": remotePath,
                        "token": token,
                        "offset": offset,
                        "resume": resume,
                    ])
                    guard let tid = (res["transfer"] as? NSNumber)?.uint64Value else {
                        throw NativeSshError(code: "SFTP_OPERATION")
                    }
                    transfer = tid
                } catch let sshErr as NativeSshError {
                    try await awaitRecovery(sshErr, waiting: waiting)
                }
            }
        }

        defer {
            let t = transfer
            let shouldAbort = attempted && !completed
            Task {
                if let t, self.isActive() {
                    _ = try? await self.request("close", fields: ["transfer": t])
                }
                if shouldAbort && self.isActive() {
                    _ = try? await self.request("abort_upload", fields: ["path": remotePath, "token": token])
                }
                await waiting(false)
            }
        }

        try await openTransfer()

        while true {
            try Task.checkCancellation()
            let readData = try fh.read(upToCount: Self.batchSize) ?? Data()
            if readData.isEmpty { break }
            var pos = 0
            while pos < readData.count {
                let len = min(batch, readData.count - pos)
                let slice = readData.subdata(in: pos..<(pos + len))
                do {
                    try await openTransfer()
                    let started = Date()
                    let res = try await request("write_batch", fields: [
                        "transfer": transfer!,
                        "offset": offset,
                        "data": slice.base64EncodedString(),
                    ])
                    guard (res["next_offset"] as? NSNumber)?.int64Value == offset + Int64(len) else {
                        throw NativeSshError(code: "SFTP_OPERATION")
                    }
                    hasher.update(data: slice)
                    pos += len
                    offset += Int64(len)
                    await waiting(false)
                    await progress(offset, expectedSize)
                    if len == batch && Date().timeIntervalSince(started) < 5.0 {
                        batch = min(batch * 2, Self.batchSize)
                    }
                } catch let sshErr as NativeSshError {
                    if sshErr.code == "TIMEOUT" || sshErr.code == "SFTP_TIMEOUT" {
                        batch = max(batch / 2, Self.chunkSize)
                    }
                    try await awaitRecovery(sshErr, waiting: waiting)
                    transfer = nil
                }
            }
        }

        if let expectedSize, expectedSize != offset {
            throw NativeSshError(code: "SFTP_CHANGED")
        }

        let digestHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        var reconcile = false
        while true {
            try Task.checkCancellation()
            do {
                if reconcile {
                    let state = try await request("resolve_upload", fields: [
                        "path": remotePath,
                        "token": token,
                        "size": offset,
                        "digest": digestHex,
                    ])
                    if (state["committed"] as? Bool) == true, let committedPath = state["path"] as? String {
                        completed = true
                        return committedPath
                    }
                    try await openTransfer()
                }
                let res = try await request("commit", fields: ["transfer": transfer!])
                guard let committedPath = res["path"] as? String else {
                    throw NativeSshError(code: "SFTP_OPERATION")
                }
                completed = true
                return committedPath
            } catch let sshErr as NativeSshError {
                try await awaitRecovery(sshErr, waiting: waiting)
                transfer = nil
                reconcile = true
            }
        }
    }

    private func awaitRecovery(_ error: NativeSshError, waiting: @escaping @MainActor (Bool) -> Void) async throws {
        let retryable: Set<String> = ["NETWORK", "TIMEOUT", "CLOSED", "SFTP_CLOSED", "SFTP_TIMEOUT", "SFTP_STALE"]
        guard let recover, retryable.contains(error.code) else { throw error }
        try Task.checkCancellation()
        await waiting(true)
        try await Task.sleep(nanoseconds: 500_000_000)
        try await recover()
        try Task.checkCancellation()
    }
}
