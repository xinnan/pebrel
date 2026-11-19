import Compression
import CryptoKit
import Foundation

/// Zeroizes mutable secret byte storage when cleared or deallocated.
final class ZeroizedBytes {
    private(set) var bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    init(utf8 string: String) {
        self.bytes = Array(string.utf8)
    }

    var isEmpty: Bool { bytes.isEmpty }
    var count: Int { bytes.count }

    func copyBytes() -> [UInt8] {
        bytes
    }

    func wipe() {
        for index in bytes.indices {
            bytes[index] = 0
        }
        bytes.removeAll(keepingCapacity: false)
    }

    deinit {
        wipe()
    }
}

enum CryptoHelpers {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    static func sha256Base64(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            diff |= (a ^ b)
        }
        return diff == 0
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        constantTimeEquals(Data(lhs.utf8), Data(rhs.utf8))
    }

    /// Canonical unpadded Base64URL decode enforcing exact 32-byte round-trip equality.
    static func decodeBase64Url32(_ encoded: String) -> Data? {
        guard encoded.count == 43 else { return nil }
        let standard = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let decoded = Data(base64Encoded: standard), decoded.count == 32 else {
            return nil
        }
        guard encodeBase64UrlNoPad(decoded) == encoded else {
            return nil
        }
        return decoded
    }

    static func encodeBase64UrlNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Extracts the exact DER-encoded SubjectPublicKeyInfo (SPKI) TLV from an X.509 certificate.
    /// Works identically for RSA, ECDSA (P-256/P-384), and Ed25519 certificates.
    static func extractX509SubjectPublicKeyInfo(from certDER: Data) -> Data? {
        let bytes = [UInt8](certDER)
        var cursor = 0
        // Certificate ::= SEQUENCE
        guard let certBody = readDerTLV(bytes, at: &cursor, expectedTag: 0x30) else { return nil }
        // tbsCertificate ::= SEQUENCE
        var tbsCursor = certBody.valueStart
        guard let tbsBody = readDerTLV(bytes, at: &tbsCursor, expectedTag: 0x30) else { return nil }
        var fieldCursor = tbsBody.valueStart
        let tbsEnd = tbsBody.end

        // Optional [0] EXPLICIT version
        if fieldCursor < tbsEnd, bytes[fieldCursor] == 0xA0 {
            guard readDerTLV(bytes, at: &fieldCursor, expectedTag: 0xA0) != nil else { return nil }
        }
        // Skip: serialNumber, signature, issuer, validity, subject (5 elements)
        for _ in 0..<5 {
            guard fieldCursor < tbsEnd, readDerTLV(bytes, at: &fieldCursor, expectedTag: nil) != nil else {
                return nil
            }
        }
        // Next element is subjectPublicKeyInfo SEQUENCE
        guard fieldCursor < tbsEnd,
              let spki = readDerTLV(bytes, at: &fieldCursor, expectedTag: 0x30),
              spki.end <= tbsEnd else {
            return nil
        }
        return Data(bytes[spki.tlvStart..<spki.end])
    }

    private struct DerTLV {
        let tlvStart: Int
        let valueStart: Int
        let end: Int
    }

    private static func readDerTLV(_ bytes: [UInt8], at cursor: inout Int, expectedTag: UInt8?) -> DerTLV? {
        guard cursor + 2 <= bytes.count else { return nil }
        let tlvStart = cursor
        let tag = bytes[cursor]
        if let expectedTag, tag != expectedTag { return nil }
        cursor += 1
        let lengthByte = bytes[cursor]
        cursor += 1
        let length: Int
        if (lengthByte & 0x80) == 0 {
            length = Int(lengthByte)
        } else {
            let count = Int(lengthByte & 0x7F)
            guard count >= 1, count <= 4, cursor + count <= bytes.count else { return nil }
            var acc = 0
            for _ in 0..<count {
                acc = (acc << 8) | Int(bytes[cursor])
                cursor += 1
            }
            length = acc
        }
        let valueStart = cursor
        let end = valueStart + length
        guard length >= 0, end <= bytes.count else { return nil }
        cursor = end
        return DerTLV(tlvStart: tlvStart, valueStart: valueStart, end: end)
    }

    /// Produces an RFC 1950 zlib stream compatible with Python `zlib.decompress(...)`.
    static func zlibCompress(_ input: Data) -> Data? {
        let adler = adler32(input)
        var rawDeflate = Data()
        if !input.isEmpty {
            let dstCapacity = max(input.count + 512, 1024)
            var dst = [UInt8](repeating: 0, count: dstCapacity)
            let written: Int = input.withUnsafeBytes { srcBuf in
                guard let base = srcBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    &dst,
                    dstCapacity,
                    base,
                    input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            guard written > 0 else { return nil }
            rawDeflate = Data(dst[0..<written])
        } else {
            rawDeflate = Data([0x03, 0x00])
        }
        var out = Data(capacity: 2 + rawDeflate.count + 4)
        out.append(0x78)
        out.append(0x9C)
        out.append(rawDeflate)
        var beAdler = adler.bigEndian
        withUnsafeBytes(of: &beAdler) { out.append(contentsOf: $0) }
        return out
    }

    private static func adler32(_ data: Data) -> UInt32 {
        let mod: UInt32 = 65521
        var s1: UInt32 = 1
        var s2: UInt32 = 0
        for byte in data {
            s1 = (s1 + UInt32(byte)) % mod
            s2 = (s2 + s1) % mod
        }
        return (s2 << 16) | s1
    }

    static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func formatByteCount(_ bytes: Int64) -> String {
        let absBytes = max(0, bytes)
        if absBytes < 1024 { return "\(absBytes) B" }
        let kib = Double(absBytes) / 1024.0
        if kib < 1024.0 { return String(format: "%.1f KB", kib) }
        let mib = kib / 1024.0
        if mib < 1024.0 { return String(format: "%.1f MB", mib) }
        return String(format: "%.2f GB", mib / 1024.0)
    }

    static func isControlScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F)
    }

    static func containsControlChar(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: isControlScalar)
    }
}
