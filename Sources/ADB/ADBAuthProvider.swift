import Foundation
import Security
import CryptoKit

/// An object that provides RSA-2048 signing and public key material for ADB authentication.
public protocol ADBAuthProvider: AnyObject {
    /// Signs the 20-byte ADB token. Must use PKCS#1 v1.5 with SHA-1 treating the token
    /// as a pre-computed digest (SecKeyAlgorithm .rsaSignatureDigestPKCS1v15SHA1).
    func sign(token: Data) throws -> Data

    /// Returns the ADB public key wire bytes: base64(Montgomery struct) + " label\0".
    func publicKeyBytes() throws -> Data

    /// Returns the MD5 fingerprint of the public key as "xx:xx:..." (matches Android display).
    func fingerprint() throws -> String
}

// MARK: - ADBPublicKey helpers (for use by ADBAuthProvider implementors)

/// Utilities for encoding RSA-2048 public keys in ADB's Montgomery wire format.
public enum ADBPublicKey {

    /// Encodes a PKCS#1 DER RSA-2048 public key into the ADB wire format (base64 of Montgomery struct).
    public static func encode(pkcs1DER: Data) throws -> String {
        let modulusLE = try extractModulusLE(der: pkcs1DER)
        guard modulusLE.count == 256 else {
            throw ADBError.protocolError("unexpected RSA modulus size \(modulusLE.count)")
        }
        let n0 = modulusLE.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian }
        let n0inv = montgomeryN0Inv(n0: n0)
        let rr = montgomeryRR(modulusLE: modulusLE)

        var s = Data()
        func u32le(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { s.append(contentsOf: $0) } }
        u32le(64); u32le(n0inv); s.append(modulusLE); s.append(rr); u32le(65537)
        return s.base64EncodedString()
    }

    /// Returns the full AUTH(RSAPUBLICKEY) payload: base64(Montgomery struct) + " {label}\0"
    public static func authData(pkcs1DER: Data, label: String = "SwiftADB") throws -> Data {
        let b64 = try encode(pkcs1DER: pkcs1DER)
        return Data((b64 + " \(label)\0").utf8)
    }

    /// Returns the MD5 fingerprint of the encoded key as "xx:xx:..." (16 colon-separated hex pairs).
    public static func fingerprint(pkcs1DER: Data) throws -> String {
        let b64 = try encode(pkcs1DER: pkcs1DER)
        guard let keyBytes = Data(base64Encoded: b64) else {
            throw ADBError.protocolError("fingerprint: bad base64")
        }
        return Insecure.MD5.hash(data: keyBytes).map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    // MARK: - DER parsing

    private static func extractModulusLE(der: Data) throws -> Data {
        var i = der.startIndex
        guard der[i] == 0x30 else { throw ADBError.protocolError("DER: expected SEQUENCE") }
        i = der.index(after: i); skipLen(der, &i)
        guard der[i] == 0x02 else { throw ADBError.protocolError("DER: expected INTEGER") }
        i = der.index(after: i)
        let len = readLen(der, &i)
        var bytes = der[i..<der.index(i, offsetBy: len)]
        if bytes.first == 0x00 { bytes = bytes.dropFirst() }
        return Data(bytes.reversed())
    }

    private static func skipLen(_ d: Data, _ i: inout Data.Index) {
        let b = d[i]; i = d.index(after: i)
        if b >= 0x80 { i = d.index(i, offsetBy: Int(b & 0x7F)) }
    }

    private static func readLen(_ d: Data, _ i: inout Data.Index) -> Int {
        let b = d[i]; i = d.index(after: i)
        if b < 0x80 { return Int(b) }
        var len = 0
        for _ in 0..<Int(b & 0x7F) { len = (len << 8) | Int(d[i]); i = d.index(after: i) }
        return len
    }

    // MARK: - Montgomery parameters

    private static func montgomeryN0Inv(n0: UInt32) -> UInt32 {
        var x: UInt32 = 1
        for _ in 0..<5 { x = x &* (2 &- n0 &* x) }
        return 0 &- x
    }

    private static func montgomeryRR(modulusLE: Data) -> Data {
        var n = [UInt32](repeating: 0, count: 64)
        modulusLE.withUnsafeBytes { p in
            for i in 0..<64 { n[i] = p.loadUnaligned(fromByteOffset: i*4, as: UInt32.self).littleEndian }
        }
        var rr = [UInt32](repeating: 0, count: 64); rr[0] = 1
        for _ in 0..<4096 {
            var carry: UInt32 = 0
            var s = [UInt32](repeating: 0, count: 64)
            for i in 0..<64 {
                let v = UInt64(rr[i]) << 1 | UInt64(carry)
                s[i] = UInt32(truncatingIfNeeded: v); carry = UInt32(v >> 32)
            }
            if carry != 0 || bigCmp(s, n) >= 0 {
                var borrow: Int64 = 0
                for i in 0..<64 {
                    let d = Int64(s[i]) - Int64(n[i]) - borrow
                    rr[i] = UInt32(bitPattern: Int32(truncatingIfNeeded: d)); borrow = d < 0 ? 1 : 0
                }
            } else { rr = s }
        }
        var out = Data(count: 256)
        out.withUnsafeMutableBytes { p in
            for i in 0..<64 { p.storeBytes(of: rr[i].littleEndian, toByteOffset: i*4, as: UInt32.self) }
        }
        return out
    }

    private static func bigCmp(_ a: [UInt32], _ b: [UInt32]) -> Int {
        for i in stride(from: 63, through: 0, by: -1) { if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 } }
        return 0
    }
}
