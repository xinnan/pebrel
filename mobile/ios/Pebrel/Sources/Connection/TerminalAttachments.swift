import Foundation

enum TerminalAttachmentError: Error, LocalizedError {
    case tooLarge
    case unreadable
    case storage
    case transfer
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .tooLarge: return L10n.tr("attachment_too_large")
        case .unreadable: return L10n.tr("attachment_unreadable")
        case .storage: return L10n.tr("attachment_storage")
        case .transfer: return L10n.tr("attachment_transfer_failed")
        case .invalidResult: return L10n.tr("attachment_failed")
        }
    }
}

/// Uploads a user-picked file over the session's SFTP channel to `~/.cache/pebrel/attachments/<uuid>/<name>`.
enum TerminalAttachments {
    static let maxBytes: Int64 = 16 * 1024 * 1024

    static func uploadToSsh(sourceURL: URL, files: SftpClient) async throws -> String {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("pebrel-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedURL = stagingDir.appendingPathComponent(".attachment-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        if let size = (attrs?[.size] as? NSNumber)?.int64Value, size > maxBytes {
            throw TerminalAttachmentError.tooLarge
        }

        let copiedSize: Int64
        do {
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            FileManager.default.createFile(atPath: stagedURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: stagedURL)
            defer { try? output.close() }
            var total: Int64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 16384) ?? Data()
                if chunk.isEmpty { break }
                total += Int64(chunk.count)
                if total > maxBytes { throw TerminalAttachmentError.tooLarge }
                try output.write(contentsOf: chunk)
            }
            copiedSize = total
        } catch let err as TerminalAttachmentError {
            throw err
        } catch {
            throw TerminalAttachmentError.unreadable
        }

        let safeName = sanitizeFilename(sourceURL.lastPathComponent)
        do {
            var root = try await files.stat(path: ".").path
            for part in [".cache", "pebrel", "attachments"] {
                let next = try SftpPaths.child(parent: root, name: part)
                do {
                    let existing = try await files.stat(path: next)
                    guard existing.isDirectory else { throw TerminalAttachmentError.transfer }
                    root = existing.path
                } catch let sshErr as NativeSshError where sshErr.code == "SFTP_NOT_FOUND" {
                    _ = try? await files.mkdir(path: next)
                    let created = try await files.stat(path: next)
                    guard created.isDirectory else { throw TerminalAttachmentError.transfer }
                    root = created.path
                }
            }
            let targetDir = try SftpPaths.child(parent: root, name: UUID().uuidString)
            try await files.mkdir(path: targetDir)
            let targetPath = try SftpPaths.child(parent: targetDir, name: safeName)
            let committed = try await files.upload(remotePath: targetPath, sourceURL: stagedURL, expectedSize: copiedSize)
            guard committed == targetPath, committed.hasPrefix("/"),
                  committed.count <= 4096, !CryptoHelpers.containsControlChar(committed) else {
                throw TerminalAttachmentError.invalidResult
            }
            return committed
        } catch let err as TerminalAttachmentError {
            throw err
        } catch {
            throw TerminalAttachmentError.transfer
        }
    }

    static func sanitizeFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return "attachment" }
        var cleaned = ""
        for scalar in trimmed.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == "\\" || scalar == ":" {
                cleaned.append("_")
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        let limited = String(cleaned.prefix(200)).trimmingCharacters(in: .whitespaces)
        return (limited.isEmpty || limited == "." || limited == "..") ? "attachment" : limited
    }
}
