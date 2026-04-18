import Foundation
import Security
import ADB

/// ADBAuthProvider that loads/generates the RSA key at ~/.android/adbkey (same as the official adb tool).
final class FileSystemAuth: ADBAuthProvider {
    private let keyPath: String
    private var cached: (SecKey, SecKey)?

    init(keyPath: String = NSHomeDirectory() + "/.android/adbkey") {
        self.keyPath = keyPath
    }

    func sign(token: Data) throws -> Data {
        let (priv, _) = try loadOrCreate()
        var err: Unmanaged<CFError>?
        // ADB uses RSA_sign(NID_sha1, token, 20) — token is a pre-computed digest.
        guard let sig = SecKeyCreateSignature(priv, .rsaSignatureDigestPKCS1v15SHA1,
                                              token as CFData, &err) as Data? else {
            throw err!.takeRetainedValue()
        }
        return sig
    }

    func publicKeyBytes() throws -> Data {
        let (_, pub) = try loadOrCreate()
        return try ADBPublicKey.authData(pkcs1DER: externalRep(pub), label: "SwiftADB@mac")
    }

    func fingerprint() throws -> String {
        let (_, pub) = try loadOrCreate()
        return try ADBPublicKey.fingerprint(pkcs1DER: externalRep(pub))
    }

    // MARK: - Private

    private func loadOrCreate() throws -> (SecKey, SecKey) {
        if let c = cached { return c }
        let pair: (SecKey, SecKey)
        if FileManager.default.fileExists(atPath: keyPath) {
            let priv = try loadPEM(path: keyPath)
            pair = (priv, SecKeyCopyPublicKey(priv)!)
        } else {
            pair = try generateAndSave()
        }
        cached = pair
        return pair
    }

    private func loadPEM(path: String) throws -> SecKey {
        let pem = try String(contentsOfFile: path, encoding: .utf8)
        let b64 = pem.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let der = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
            throw ADBError.protocolError("invalid PEM key at \(path)")
        }
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err) else {
            throw err!.takeRetainedValue()
        }
        return key
    }

    private func generateAndSave() throws -> (SecKey, SecKey) {
        var err: Unmanaged<CFError>?
        let params: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let priv = SecKeyCreateRandomKey(params as CFDictionary, &err) else {
            throw err!.takeRetainedValue()
        }
        let pub = SecKeyCopyPublicKey(priv)!
        let privDER = try externalRep(priv)
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n"
            + privDER.base64EncodedString(options: .lineLength64Characters)
            + "\n-----END RSA PRIVATE KEY-----\n"
        try FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/.android", withIntermediateDirectories: true)
        try pem.write(toFile: keyPath, atomically: true, encoding: .utf8)
        let pubBytes = try ADBPublicKey.authData(pkcs1DER: externalRep(pub), label: "SwiftADB@mac")
        try String(data: pubBytes, encoding: .utf8)?.write(toFile: keyPath + ".pub", atomically: true, encoding: .utf8)
        fputs("Generated new ADB key pair at \(keyPath)\n", stderr)
        return (priv, pub)
    }

    private func externalRep(_ key: SecKey) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(key, &err) as Data? else {
            throw err!.takeRetainedValue()
        }
        return der
    }
}
