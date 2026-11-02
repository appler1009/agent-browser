import CryptoKit
import Foundation
import Security

// Encryption at rest for the cookies a persistent profile keeps in its folder.
// AES-256-GCM; the key is random, lives in the login keychain, and never in a file (outside the test override).
// File layout: "ABCK1\n" followed by the sealed box (nonce + ciphertext + tag).

enum CookieVault {
    static let magic = Data("ABCK1\n".utf8)
    private static let service = "dev.appler.agent-browser.cookie-key"
    private static let account = "profile-cookies"
    nonisolated(unsafe) private static var cached: SymmetricKey?

    enum Failure: Error, CustomStringConvertible {
        case key(String), format
        var description: String {
            switch self { case .key(let m): return m; case .format: return "not an encrypted cookie file" }
        }
    }

    static func key() throws -> SymmetricKey {
        if let cached { return cached }
        // Tests keep the key in a file so the real keychain is never touched.
        if let f = ProcessInfo.processInfo.environment["AGENT_BROWSER_COOKIE_KEY_FILE"], !f.isEmpty {
            if let d = FileManager.default.contents(atPath: f), d.count == 32 { cached = SymmetricKey(data: d); return cached! }
            let k = SymmetricKey(size: .bits256)
            let data = k.withUnsafeBytes { Data($0) }
            try data.write(to: URL(fileURLWithPath: f), options: .atomic)
            chmod(f, 0o600)
            cached = k
            return k
        }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        func read() -> Data? {
            var out: AnyObject?
            var query = q
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 else { return nil }
            return d
        }
        if let d = read() { cached = SymmetricKey(data: d); return cached! }
        let k = SymmetricKey(size: .bits256)
        var add = q
        add[kSecValueData as String] = k.withUnsafeBytes { Data($0) }
        let st = SecItemAdd(add as CFDictionary, nil)
        if st == errSecDuplicateItem, let d = read() { cached = SymmetricKey(data: d); return cached! }  // another helper won the race
        guard st == errSecSuccess else {
            throw Failure.key("keychain: \(SecCopyErrorMessageString(st, nil) as String? ?? "status \(st)")")
        }
        cached = k
        return k
    }

    static func seal(_ plain: Data) throws -> Data {
        let box = try AES.GCM.seal(plain, using: try key())
        return magic + box.combined!
    }

    static func open(_ blob: Data) throws -> Data {
        guard blob.starts(with: magic) else { throw Failure.format }
        let box = try AES.GCM.SealedBox(combined: blob.dropFirst(magic.count))
        return try AES.GCM.open(box, using: try key())
    }
}
