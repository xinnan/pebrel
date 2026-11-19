import Foundation
import PebrelVoice

enum LocalWhisperError: Error, LocalizedError {
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .failed(let code): return code
        case .cancelled: return "cancelled"
        }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let v = cancelled
        lock.unlock()
        return v
    }
}

/// Serialized on-device Whisper transcription backed by pinned whisper.cpp v1.7.6.
actor LocalWhisper {
    static let shared = LocalWhisper()

    private init() {}

    func transcribe(modelURL: URL, samples: [Float]) async throws -> String {
        var errPtr: UnsafePointer<CChar>?
        let handle = pebrel_voice_create(&errPtr)
        guard handle > 0 else {
            throw LocalWhisperError.failed(errPtr.map { String(cString: $0) } ?? "local_transcription_failed")
        }

        let cancelFlag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { pebrel_voice_destroy(handle) }
                    if cancelFlag.isCancelled {
                        continuation.resume(throwing: LocalWhisperError.cancelled)
                        return
                    }
                    var outText: UnsafeMutablePointer<CChar>?
                    var runErr: UnsafePointer<CChar>?
                    let ok: Bool = samples.withUnsafeBufferPointer { buf in
                        pebrel_voice_transcribe(
                            handle,
                            modelURL.path,
                            buf.baseAddress,
                            buf.count,
                            &outText,
                            &runErr
                        )
                    }
                    if cancelFlag.isCancelled {
                        if let outText { pebrel_voice_free_string(outText) }
                        continuation.resume(throwing: LocalWhisperError.cancelled)
                        return
                    }
                    if !ok {
                        if let outText { pebrel_voice_free_string(outText) }
                        let code = runErr.map { String(cString: $0) } ?? "local_transcription_failed"
                        continuation.resume(throwing: LocalWhisperError.failed(code))
                        return
                    }
                    defer {
                        if let outText { pebrel_voice_free_string(outText) }
                    }
                    let result = outText.map { String(cString: $0) } ?? ""
                    continuation.resume(returning: result.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        } onCancel: {
            cancelFlag.cancel()
            pebrel_voice_cancel(handle)
        }
    }
}
