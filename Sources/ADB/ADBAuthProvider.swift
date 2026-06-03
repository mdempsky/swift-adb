import Foundation
import Security
import CryptoKit

/// A type that provides RSA-2048 signing and public key material for ADB authentication.
///
/// ADB authenticates the host (your Mac or iPhone) to the device using an RSA-2048
/// key pair. The device challenges the host with a random token; the host signs it
/// and, if the device doesn't recognize the public key, presents the public key for
/// the user to approve.
///
/// Implement this protocol to control how and where the key pair is stored. Common
/// implementations use the macOS keychain (see `FileSystemAuth` in the CLI target)
/// or the iOS Secure Enclave / Keychain (see `KeychainAuth` in the app target).
///
/// Use ``ADBPublicKey`` to convert a PKCS#1 DER public key into the formats this
/// protocol requires.
public protocol ADBAuthProvider: AnyObject {

    /// Signs an ADB challenge token using PKCS#1 v1.5 with SHA-1.
    ///
    /// The `token` is a 20-byte value that the device sends during the AUTH
    /// handshake. Sign it as a pre-hashed digest using
    /// `SecKeyAlgorithm.rsaSignatureDigestPKCS1v15SHA1` (or an equivalent).
    ///
    /// - Parameter token: The 20-byte challenge token from the device.
    /// - Returns: The PKCS#1 v1.5 RSA signature over `token`.
    /// - Throws: Any error from the underlying signing operation (e.g., Keychain access denied).
    func sign(token: Data) throws -> Data

    /// Returns the ADB public key wire bytes.
    ///
    /// The format is: `base64(MontgomeryStruct) + " label\0"`, where
    /// `MontgomeryStruct` is the 524-byte structure defined by the ADB protocol.
    /// Use ``ADBPublicKey/authData(pkcs1DER:label:)`` to produce this from a
    /// standard PKCS#1 DER-encoded RSA-2048 public key.
    ///
    /// - Returns: The public key payload to include in an `AUTH(RSAPUBLICKEY)` message.
    /// - Throws: Any error from the underlying key retrieval operation.
    func publicKeyBytes() throws -> Data

    /// Returns the MD5 fingerprint of the public key for display to the user.
    ///
    /// The format is 16 lowercase hex pairs separated by colons (e.g.,
    /// `"ab:cd:ef:..."`), matching the fingerprint Android shows in the
    /// "Allow USB debugging?" dialog. Use ``ADBPublicKey/fingerprint(pkcs1DER:)``
    /// to derive this from a PKCS#1 DER public key.
    ///
    /// - Returns: The 47-character colon-separated MD5 fingerprint string.
    /// - Throws: Any error from the underlying key retrieval operation.
    func fingerprint() throws -> String
}

// MARK: - ADBPublicKey

/// Utilities for encoding RSA-2048 public keys in the ADB wire format.
///
/// ADB represents public keys as a Montgomery-form struct base64-encoded with a
/// label suffix — not as standard PEM or DER. This type converts a standard
/// PKCS#1 DER-encoded RSA-2048 public key into that format.
///
/// These helpers are intended for use inside ``ADBAuthProvider`` implementations.
public enum ADBPublicKey {

    /// Encodes a PKCS#1 DER RSA-2048 public key as the ADB Montgomery base64 string.
    ///
    /// The output is the base64 encoding of the 524-byte Montgomery struct that
    /// ADB uses to verify signatures on the device side. This is the inner value
    /// that ``authData(pkcs1DER:label:)`` and ``fingerprint(pkcs1DER:)`` build on.
    ///
    /// - Parameter pkcs1DER: A DER-encoded PKCS#1 RSA-2048 public key.
    /// - Returns: The base64-encoded Montgomery struct, without line breaks.
    /// - Throws: ``ADBError/protocolError(_:)`` if the key cannot be parsed or
    ///   is not RSA-2048 (i.e., the modulus is not exactly 256 bytes).
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

    /// Returns the full `AUTH(RSAPUBLICKEY)` payload for the given key and label.
    ///
    /// The payload is `base64(MontgomeryStruct) + " {label}\0"`. Pass the result
    /// to ``ADBAuthProvider/publicKeyBytes()`` of your ``ADBAuthProvider``
    /// implementation.
    ///
    /// - Parameters:
    ///   - pkcs1DER: A DER-encoded PKCS#1 RSA-2048 public key.
    ///   - label: A human-readable label appended to the key. Defaults to `"SwiftADB"`.
    ///     Android displays this in the "Allow USB debugging?" dialog.
    /// - Returns: The null-terminated UTF-8 payload bytes for an `AUTH(RSAPUBLICKEY)` message.
    /// - Throws: ``ADBError/protocolError(_:)`` if the key cannot be parsed.
    public static func authData(pkcs1DER: Data, label: String = "SwiftADB") throws -> Data {
        let b64 = try encode(pkcs1DER: pkcs1DER)
        return Data((b64 + " \(label)\0").utf8)
    }

    /// Returns the MD5 fingerprint of the encoded key as a colon-separated hex string.
    ///
    /// Produces the same fingerprint that Android displays in the
    /// "Allow USB debugging?" dialog, e.g., `"ab:12:cd:34:..."`.
    /// Pass the result to ``ADBAuthProvider/fingerprint()`` of your
    /// ``ADBAuthProvider`` implementation.
    ///
    /// - Parameter pkcs1DER: A DER-encoded PKCS#1 RSA-2048 public key.
    /// - Returns: 16 lowercase hex pairs joined by colons (47 characters total).
    /// - Throws: ``ADBError/protocolError(_:)`` if the key cannot be parsed.
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
