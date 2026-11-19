import Compression
import CryptoKit
import Darwin
import Foundation

struct X509CertificateInfo: Equatable {
    let spkiDER: Data
    let notBeforeUnix: Int64
    let notAfterUnix: Int64
    let dnsNames: [String]
    let ipAddresses: [Data]

    func isValid(at unixTime: Int64) -> Bool {
        unixTime >= notBeforeUnix && unixTime <= notAfterUnix
    }

    func matchesHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if let zoneIndex = host.firstIndex(of: "%") {
            host = String(host[..<zoneIndex])
        }
        guard !host.isEmpty else { return false }

        // 1. IPv4 literal match against iPAddress SANs
        var addr4 = in_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 {
            let target = withUnsafeBytes(of: &addr4) { Data($0) }
            return ipAddresses.contains(target)
        }

        // 2. IPv6 literal match against iPAddress SANs
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, host, &addr6) == 1 {
            let target = withUnsafeBytes(of: &addr6) { Data($0) }
            return ipAddresses.contains(target)
        }

        // 3. DNS hostname match against dNSName SANs (exact or single-label RFC 6125 wildcard)
        var normalized = host.lowercased()
        while normalized.hasSuffix(".") { normalized.removeLast() }
        guard !normalized.isEmpty else { return false }

        for rawPattern in dnsNames {
            var pattern = rawPattern.lowercased()
            while pattern.hasSuffix(".") { pattern.removeLast() }
            if pattern == normalized {
                return true
            }
            if pattern.hasPrefix("*.") {
                let suffix = pattern.dropFirst(1) // ".example.com"
                let baseDomain = suffix.dropFirst(1) // "example.com"
                guard baseDomain.contains("."), normalized.hasSuffix(suffix) else { continue }
                let prefix = normalized.dropLast(suffix.count)
                if !prefix.isEmpty && !prefix.contains(".") {
                    return true
                }
            }
        }
        return false
    }
}

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
        inspectX509Certificate(from: certDER)?.spkiDER
    }

    /// Parses leaf X.509 DER SPKI, validity window (UTCTime & GeneralizedTime), and SubjectAltNames.
    static func inspectX509Certificate(from certDER: Data) -> X509CertificateInfo? {
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
        // Skip: serialNumber, signature, issuer (3 elements)
        for _ in 0..<3 {
            guard fieldCursor < tbsEnd, readDerTLV(bytes, at: &fieldCursor, expectedTag: nil) != nil else {
                return nil
            }
        }
        // Element 4: validity SEQUENCE { notBefore Time, notAfter Time }
        guard fieldCursor < tbsEnd,
              let validityTLV = readDerTLV(bytes, at: &fieldCursor, expectedTag: 0x30),
              validityTLV.end <= tbsEnd else {
            return nil
        }
        var valCursor = validityTLV.valueStart
        guard let nbTLV = readDerTLV(bytes, at: &valCursor, expectedTag: nil),
              let naTLV = readDerTLV(bytes, at: &valCursor, expectedTag: nil),
              let notBefore = parseAsn1Time(bytes, tlv: nbTLV),
              let notAfter = parseAsn1Time(bytes, tlv: naTLV) else {
            return nil
        }
        // Element 5: subject
        guard fieldCursor < tbsEnd, readDerTLV(bytes, at: &fieldCursor, expectedTag: nil) != nil else {
            return nil
        }
        // Element 6: subjectPublicKeyInfo SEQUENCE
        guard fieldCursor < tbsEnd,
              let spki = readDerTLV(bytes, at: &fieldCursor, expectedTag: 0x30),
              spki.end <= tbsEnd else {
            return nil
        }
        let spkiDER = Data(bytes[spki.tlvStart..<spki.end])

        // Optional trailing fields: issuerUniqueID [1], subjectUniqueID [2], extensions [3]
        var dnsNames: [String] = []
        var ipAddresses: [Data] = []
        let sanOid: [UInt8] = [0x55, 0x1D, 0x11] // 2.5.29.17 (id-ce-subjectAltName)

        while fieldCursor < tbsEnd {
            guard let opt = readDerTLV(bytes, at: &fieldCursor, expectedTag: nil),
                  opt.end <= tbsEnd else {
                return nil
            }
            if bytes[opt.tlvStart] == 0xA3 {
                var extListCursor = opt.valueStart
                guard let extSeq = readDerTLV(bytes, at: &extListCursor, expectedTag: 0x30),
                      extSeq.end <= opt.end else {
                    return nil
                }
                var extCursor = extSeq.valueStart
                while extCursor < extSeq.end {
                    guard let ext = readDerTLV(bytes, at: &extCursor, expectedTag: 0x30),
                          ext.end <= extSeq.end else {
                        return nil
                    }
                    var inner = ext.valueStart
                    guard let oid = readDerTLV(bytes, at: &inner, expectedTag: 0x06),
                          oid.end <= ext.end else {
                        return nil
                    }
                    if inner < ext.end, bytes[inner] == 0x01 {
                        guard readDerTLV(bytes, at: &inner, expectedTag: 0x01) != nil else { return nil }
                    }
                    guard let extVal = readDerTLV(bytes, at: &inner, expectedTag: 0x04),
                          extVal.end <= ext.end else {
                        return nil
                    }
                    if Array(bytes[oid.valueStart..<oid.end]) == sanOid {
                        var gnCursor = extVal.valueStart
                        guard let gnSeq = readDerTLV(bytes, at: &gnCursor, expectedTag: 0x30),
                              gnSeq.end <= extVal.end else {
                            return nil
                        }
                        var nameCursor = gnSeq.valueStart
                        while nameCursor < gnSeq.end {
                            guard let gn = readDerTLV(bytes, at: &nameCursor, expectedTag: nil),
                                  gn.end <= gnSeq.end else {
                                return nil
                            }
                            let gnTag = bytes[gn.tlvStart]
                            if gnTag == 0x82 {
                                if let dns = String(bytes: bytes[gn.valueStart..<gn.end], encoding: .utf8), !dns.isEmpty {
                                    dnsNames.append(dns)
                                }
                            } else if gnTag == 0x87 {
                                let len = gn.end - gn.valueStart
                                if len == 4 || len == 16 {
                                    ipAddresses.append(Data(bytes[gn.valueStart..<gn.end]))
                                }
                            }
                        }
                    }
                }
            }
        }

        return X509CertificateInfo(
            spkiDER: spkiDER,
            notBeforeUnix: notBefore,
            notAfterUnix: notAfter,
            dnsNames: dnsNames,
            ipAddresses: ipAddresses
        )
    }

    private struct DerTLV {
        let tlvStart: Int
        let valueStart: Int
        let end: Int
    }

    private static func parseAsn1Time(_ bytes: [UInt8], tlv: DerTLV) -> Int64? {
        let tag = bytes[tlv.tlvStart]
        guard tag == 0x17 || tag == 0x18,
              let raw = String(bytes: bytes[tlv.valueStart..<tlv.end], encoding: .ascii),
              raw.hasSuffix("Z") else {
            return nil
        }
        var body = String(raw.dropLast())
        if let dot = body.firstIndex(of: ".") {
            body = String(body[..<dot])
        }
        let chars = Array(body)
        func digits(_ start: Int, _ count: Int) -> Int64? {
            guard start + count <= chars.count else { return nil }
            var value: Int64 = 0
            for i in start..<(start + count) {
                guard let ascii = chars[i].asciiValue, ascii >= 48 && ascii <= 57 else { return nil }
                value = value * 10 + Int64(ascii - 48)
            }
            return value
        }

        let year: Int64
        let offset: Int
        if tag == 0x17 {
            // UTCTime: YYMMDDHHMM(SS)Z
            guard chars.count == 10 || chars.count == 12, let yy = digits(0, 2) else { return nil }
            year = yy >= 50 ? 1900 + yy : 2000 + yy
            offset = 2
        } else {
            // GeneralizedTime: YYYYMMDDHHMM(SS)Z
            guard chars.count == 12 || chars.count == 14, let yyyy = digits(0, 4) else { return nil }
            year = yyyy
            offset = 4
        }

        guard let month = digits(offset, 2), (1...12).contains(month),
              let day = digits(offset + 2, 2), (1...31).contains(day),
              let hour = digits(offset + 4, 2), (0...23).contains(hour),
              let minute = digits(offset + 6, 2), (0...59).contains(minute) else {
            return nil
        }
        let second: Int64
        if chars.count == offset + 10 {
            guard let s = digits(offset + 8, 2), (0...60).contains(s) else { return nil }
            second = min(s, 59)
        } else {
            second = 0
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        return days * 86400 + hour * 3600 + minute * 60 + second
    }

    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
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
