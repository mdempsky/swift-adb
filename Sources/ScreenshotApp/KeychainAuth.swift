import Foundation
import Security
import ADB

final class KeychainAuth: ADBAuthProvider {
    static let shared = KeychainAuth()
    private static let tag = "soy.mdempsky.AndroidScreenshot.adbkey"
    private var cached: (SecKey, SecKey)?

    func sign(token: Data) throws -> Data {
        let (priv, _) = try loadOrCreate()
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(priv, .rsaSignatureDigestPKCS1v15SHA1,
                                              token as CFData, &err) as Data? else {
            throw err!.takeRetainedValue()
        }
        return sig
    }

    func publicKeyBytes() throws -> Data {
        let (_, pub) = try loadOrCreate()
        return try ADBPublicKey.authData(pkcs1DER: externalRep(pub), label: "AndroidScreenshot@Mac")
    }

    func fingerprint() throws -> String {
        let (_, pub) = try loadOrCreate()
        return try ADBPublicKey.fingerprint(pkcs1DER: externalRep(pub))
    }

    private func loadOrCreate() throws -> (SecKey, SecKey) {
        if let c = cached { return c }
        let pair: (SecKey, SecKey)
        if let priv = loadFromKeychain() {
            pair = (priv, SecKeyCopyPublicKey(priv)!)
        } else {
            pair = try generateInKeychain()
        }
        cached = pair
        return pair
    }

    private func loadFromKeychain() -> SecKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: Self.tag.data(using: .utf8)!,
            kSecReturnRef: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as! SecKey)
    }

    private func generateInKeychain() throws -> (SecKey, SecKey) {
        let params: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: Self.tag.data(using: .utf8)!,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            ],
        ]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(params as CFDictionary, &err) else {
            throw err!.takeRetainedValue()
        }
        return (priv, SecKeyCopyPublicKey(priv)!)
    }

    private func externalRep(_ key: SecKey) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(key, &err) as Data? else {
            throw err!.takeRetainedValue()
        }
        return der
    }
}
