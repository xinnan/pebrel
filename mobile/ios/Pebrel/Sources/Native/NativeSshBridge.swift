import Foundation
import PebrelSshFFI

struct NativeSshError: Error, LocalizedError, Equatable {
    let code: String

    var errorDescription: String? { code }
}

private func extractErrorCode(_ errorPtr: UnsafePointer<CChar>?) -> String {
    guard let errorPtr else { return "INTERNAL" }
    return String(cString: errorPtr)
}

/// Safe Swift wrapper around `pebrel_ssh_*` monotonic Rust handles.
final class NativeSshHandle {
    private let lock = NSLock()
    private var rawId: Int64

    init(
        host: String,
        port: Int,
        user: String,
        password: [UInt8],
        fingerprint: String,
        privateKey: [UInt8]
    ) throws {
        guard port >= 1, port <= 65535 else {
            throw NativeSshError(code: "INVALID_INPUT")
        }
        var errPtr: UnsafePointer<CChar>?
        let handle: Int64 = password.withUnsafeBufferPointer { pwdBuf in
            privateKey.withUnsafeBufferPointer { keyBuf in
                pebrel_ssh_create(
                    host,
                    UInt16(port),
                    user,
                    pwdBuf.baseAddress,
                    pwdBuf.count,
                    fingerprint,
                    keyBuf.baseAddress,
                    keyBuf.count,
                    &errPtr
                )
            }
        }
        if handle <= 0 || errPtr != nil {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
        self.rawId = handle
    }

    private func currentId() throws -> Int64 {
        lock.lock()
        let id = rawId
        lock.unlock()
        guard id > 0 else { throw NativeSshError(code: "CLOSED") }
        return id
    }

    func nextEvent() throws -> String {
        let id = try currentId()
        var errPtr: UnsafePointer<CChar>?
        guard let cstr = pebrel_ssh_next_event(id, &errPtr) else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
        defer { pebrel_string_free(cstr) }
        return String(cString: cstr)
    }

    func answerHostKey(accepted: Bool) throws {
        let id = try currentId()
        var errPtr: UnsafePointer<CChar>?
        guard pebrel_ssh_answer_host_key(id, accepted, &errPtr) else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
    }

    func openShell(columns: Int, rows: Int, width: Int, height: Int) throws {
        let id = try currentId()
        var errPtr: UnsafePointer<CChar>?
        guard pebrel_ssh_open_shell(id, Int32(columns), Int32(rows), Int32(width), Int32(height), &errPtr) else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
    }

    func openExec(command: String) throws {
        let id = try currentId()
        var errPtr: UnsafePointer<CChar>?
        guard pebrel_ssh_open_exec(id, command, &errPtr) else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
    }

    func openPtyExec(command: String, columns: Int, rows: Int, width: Int, height: Int) throws {
        let id = try currentId()
        var errPtr: UnsafePointer<CChar>?
        guard pebrel_ssh_open_pty_exec(
            id,
            command,
            Int32(columns),
            Int32(rows),
            Int32(width),
            Int32(height),
            &errPtr
        ) else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
    }

    func query(command: String) throws -> String {
        let id = try currentId()
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen: Int = 0
        var errPtr: UnsafePointer<CChar>?
        guard pebrel_ssh_query(id, command, &outPtr, &outLen, &errPtr) else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
        defer {
            if let outPtr, outLen > 0 {
                pebrel_bytes_free(outPtr, outLen)
            }
        }
        guard let outPtr, outLen > 0 else { return "" }
        let data = Data(bytes: outPtr, count: outLen)
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads up to `maxBytes` (1..=16384). Returns `nil` on clean EOF.
    func read(maxBytes: Int = 16384, stderr: Bool = false) throws -> Data? {
        let id = try currentId()
        let count = min(max(1, maxBytes), 16384)
        var buffer = [UInt8](repeating: 0, count: count)
        var errPtr: UnsafePointer<CChar>?
        let n = buffer.withUnsafeMutableBufferPointer { buf in
            pebrel_ssh_read(id, buf.baseAddress, count, stderr, &errPtr)
        }
        if n == -1 { return nil }
        if n < 0 || errPtr != nil {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
        return Data(buffer[0..<Int(n)])
    }

    func write(_ data: Data) throws {
        let id = try currentId()
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let chunkLen = min(8192, bytes.count - offset)
            var errPtr: UnsafePointer<CChar>?
            let ok: Bool = bytes.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return false }
                return pebrel_ssh_write(id, base.advanced(by: offset), chunkLen, &errPtr)
            }
            if !ok || errPtr != nil {
                throw NativeSshError(code: extractErrorCode(errPtr))
            }
            offset += chunkLen
        }
    }

    func resize(columns: Int, rows: Int, width: Int, height: Int) throws {
        let id = try currentId()
        var errPtr: UnsafePointer<CChar>?
        guard pebrel_ssh_resize(id, Int32(columns), Int32(rows), Int32(width), Int32(height), &errPtr) else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
    }

    func awaitExit() throws -> Int {
        let id = try currentId()
        var code: Int32 = -1
        var errPtr: UnsafePointer<CChar>?
        guard pebrel_ssh_await_exit(id, &code, &errPtr) else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
        return Int(code)
    }

    func sftp(requestJSON: String) throws -> String {
        let id = try currentId()
        var errPtr: UnsafePointer<CChar>?
        guard let cstr = pebrel_ssh_sftp(id, requestJSON, &errPtr) else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
        defer { pebrel_string_free(cstr) }
        return String(cString: cstr)
    }

    func close() {
        lock.lock()
        let id = rawId
        rawId = 0
        lock.unlock()
        if id > 0 {
            pebrel_ssh_close(id)
        }
    }

    deinit {
        close()
    }
}

/// Safe Swift wrapper around `pebrel_link_*` Noise NKpsk0 E2EE channels.
final class NativeLinkHandle {
    private let lock = NSLock()
    private var rawId: Int64

    init(hostPublicKey: Data, secret: Data, context: Data) throws {
        var errPtr: UnsafePointer<CChar>?
        let handle: Int64 = hostPublicKey.withUnsafeBytes { hostBuf in
            secret.withUnsafeBytes { secBuf in
                context.withUnsafeBytes { ctxBuf in
                    pebrel_link_create(
                        hostBuf.bindMemory(to: UInt8.self).baseAddress,
                        hostPublicKey.count,
                        secBuf.bindMemory(to: UInt8.self).baseAddress,
                        secret.count,
                        ctxBuf.bindMemory(to: UInt8.self).baseAddress,
                        context.count,
                        &errPtr
                    )
                }
            }
        }
        if handle <= 0 || errPtr != nil {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
        self.rawId = handle
    }

    private func currentId() throws -> Int64 {
        lock.lock()
        let id = rawId
        lock.unlock()
        guard id > 0 else { throw NativeSshError(code: "invalid_link_state") }
        return id
    }

    func hello() throws -> Data {
        let id = try currentId()
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen: Int = 0
        var errPtr: UnsafePointer<CChar>?
        guard pebrel_link_hello(id, &outPtr, &outLen, &errPtr) else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
        defer {
            if let outPtr, outLen > 0 { pebrel_bytes_free(outPtr, outLen) }
        }
        guard let outPtr, outLen > 0 else { return Data() }
        return Data(bytes: outPtr, count: outLen)
    }

    func finish(response: Data) throws -> Bool {
        let id = try currentId()
        var established = false
        var errPtr: UnsafePointer<CChar>?
        let ok: Bool = response.withUnsafeBytes { buf in
            pebrel_link_finish(
                id,
                buf.bindMemory(to: UInt8.self).baseAddress,
                response.count,
                &established,
                &errPtr
            )
        }
        guard ok else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
        return established
    }

    func verificationCode() throws -> String {
        let id = try currentId()
        var errPtr: UnsafePointer<CChar>?
        guard let cstr = pebrel_link_verification_code(id, &errPtr) else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
        defer { pebrel_string_free(cstr) }
        return String(cString: cstr)
    }

    func seal(_ plaintext: Data) throws -> [Data] {
        let id = try currentId()
        var packetsPtr: UnsafeMutablePointer<PebrelByteSlice>?
        var packetCount: Int = 0
        var errPtr: UnsafePointer<CChar>?
        let ok: Bool = plaintext.withUnsafeBytes { buf in
            pebrel_link_seal(
                id,
                buf.bindMemory(to: UInt8.self).baseAddress,
                plaintext.count,
                &packetsPtr,
                &packetCount,
                &errPtr
            )
        }
        guard ok else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
        defer {
            if let packetsPtr, packetCount > 0 {
                pebrel_packet_list_free(packetsPtr, packetCount)
            }
        }
        guard let packetsPtr, packetCount > 0 else { return [] }
        var result: [Data] = []
        result.reserveCapacity(packetCount)
        for index in 0..<packetCount {
            let slice = packetsPtr[index]
            if let ptr = slice.ptr, slice.len > 0 {
                result.append(Data(bytes: ptr, count: slice.len))
            }
        }
        return result
    }

    func open(_ ciphertext: Data) throws -> Data? {
        let id = try currentId()
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen: Int = 0
        var errPtr: UnsafePointer<CChar>?
        let ok: Bool = ciphertext.withUnsafeBytes { buf in
            pebrel_link_open(
                id,
                buf.bindMemory(to: UInt8.self).baseAddress,
                ciphertext.count,
                &outPtr,
                &outLen,
                &errPtr
            )
        }
        guard ok else {
            throw NativeSshError(code: extractErrorCode(errPtr))
        }
        defer {
            if let outPtr, outLen > 0 { pebrel_bytes_free(outPtr, outLen) }
        }
        guard let outPtr, outLen > 0 else { return nil }
        return Data(bytes: outPtr, count: outLen)
    }

    func close() {
        lock.lock()
        let id = rawId
        rawId = 0
        lock.unlock()
        if id > 0 {
            pebrel_link_close(id)
        }
    }

    deinit {
        close()
    }
}
