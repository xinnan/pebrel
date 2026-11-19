import CryptoKit
import Foundation

/// Manages the pinned Whisper Base model (`ggml-base.bin`) matching Android's exact size & SHA-256.
actor VoiceModelStore {
    static let shared = VoiceModelStore()

    static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!
    static let modelBytes: Int64 = 147_951_465
    static let modelSha256 = "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"

    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDir = dir
        try? mutableDir.setResourceValues(resourceValues)
        self.fileURL = dir.appendingPathComponent("ggml-base.bin")
    }

    func isInstalled() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return false
        }
        return size == Self.modelBytes
    }

    func removeModel() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func download(onProgress: @escaping @MainActor (Float) -> Void) async throws {
        let tempURL = fileURL.deletingLastPathComponent().appendingPathComponent("base-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (bytesStream, response) = try await session.bytes(from: Self.modelURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LocalWhisperError.failed("model_download_failed")
        }
        if http.expectedContentLength > 0 && http.expectedContentLength != Self.modelBytes {
            throw LocalWhisperError.failed("model_size_mismatch")
        }

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tempURL)
        defer { try? fh.close() }

        var hasher = SHA256()
        var received: Int64 = 0
        var chunk = Data()
        chunk.reserveCapacity(65536)

        for try await byte in bytesStream {
            try Task.checkCancellation()
            chunk.append(byte)
            if chunk.count >= 65536 {
                hasher.update(data: chunk)
                try fh.write(contentsOf: chunk)
                received += Int64(chunk.count)
                chunk.removeAll(keepingCapacity: true)
                if received > Self.modelBytes { throw LocalWhisperError.failed("model_size_mismatch") }
                await onProgress(Float(received) / Float(Self.modelBytes))
            }
        }
        if !chunk.isEmpty {
            hasher.update(data: chunk)
            try fh.write(contentsOf: chunk)
            received += Int64(chunk.count)
        }
        try fh.synchronize()
        try fh.close()

        guard received == Self.modelBytes else {
            throw LocalWhisperError.failed("model_size_mismatch")
        }
        let actualSha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualSha == Self.modelSha256 else {
            throw LocalWhisperError.failed("model_checksum_mismatch")
        }

        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
        await onProgress(1.0)
    }

    /// Re-verifies full SHA-256 of the model file before every on-device inference pass.
    func transcribe(samples: [Float]) async throws -> String {
        guard verifyModelIntegrity() else {
            throw LocalWhisperError.failed("model_integrity_failed")
        }
        return try await LocalWhisper.shared.transcribe(modelURL: fileURL, samples: samples)
    }

    private func verifyModelIntegrity() -> Bool {
        guard isInstalled(), let fh = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? fh.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let data = try? fh.read(upToCount: 256 * 1024), !data.isEmpty {
            hasher.update(data: data)
            total += Int64(data.count)
        }
        guard total == Self.modelBytes else { return false }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == Self.modelSha256
    }
}
