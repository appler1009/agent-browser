import CryptoKit
import Foundation
import LocalAuthentication
import Security

// Credentials for bots, kept apart from the user's own passwords (Passwords app / iCloud Keychain).
//
// - Entries live in the login keychain under their own service name. They are not shared with Safari.
// - The agent only ever sees entry NAMES. The helper resolves a name to a value and types it into the
//   page, and only when the page origin matches the entry. Values never appear in command results.
// - There is deliberately no command that reads a value back.

let vaultService = "dev.appler.agent-browser.vault"

struct VaultMeta: Codable {
    var origins: [String]
    var confirm: Bool
    var totp: Bool
    var created: String
    var recovery: Int? = nil  // number of saved recovery codes
}

struct VaultSecret: Codable {
    var username: String
    var password: String
    var totp: String?
    var recovery: [String]? = nil
}

struct VaultEntry {
    var name: String
    var meta: VaultMeta
    var secret: VaultSecret
}

protocol VaultStore {
    /// True for the file-backed store used by tests; it also enables test-only conveniences.
    var isTestStore: Bool { get }
    var auditPath: String { get }
    func list() throws -> [(name: String, meta: VaultMeta)]
    func get(_ name: String) throws -> VaultEntry?
    func put(_ entry: VaultEntry, replace: Bool) throws
    func remove(_ name: String) throws -> Bool
}

// MARK: - Keychain store

struct KeychainVaultStore: VaultStore {
    var isTestStore: Bool { false }
    var auditPath: String { NSHomeDirectory() + "/.agent-browser/vault-audit.log" }

    private func base(_ name: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: vaultService]
        if let name { q[kSecAttrAccount as String] = name }
        return q
    }

    private func fail(_ status: OSStatus, _ what: String) -> CmdError {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return CmdError(code: "VAULT_KEYCHAIN", message: "\(what): \(msg)", retrySafe: false)
    }

    func list() throws -> [(name: String, meta: VaultMeta)] {
        var q = base()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return [] }
        guard st == errSecSuccess, let rows = out as? [[String: Any]] else { throw fail(st, "cannot list vault entries") }
        return rows.compactMap { r in
            guard let name = r[kSecAttrAccount as String] as? String,
                  let c = r[kSecAttrComment as String] as? String,
                  let meta = try? JSONDecoder().decode(VaultMeta.self, from: Data(c.utf8)) else { return nil }
            return (name, meta)
        }.sorted { $0.name < $1.name }
    }

    func get(_ name: String) throws -> VaultEntry? {
        var q = base(name)
        q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let row = out as? [String: Any],
              let data = row[kSecValueData as String] as? Data,
              let secret = try? JSONDecoder().decode(VaultSecret.self, from: data),
              let c = row[kSecAttrComment as String] as? String,
              let meta = try? JSONDecoder().decode(VaultMeta.self, from: Data(c.utf8))
        else { throw fail(st, "cannot read vault entry \"\(name)\"") }
        return VaultEntry(name: name, meta: meta, secret: secret)
    }

    func put(_ entry: VaultEntry, replace: Bool) throws {
        if try get(entry.name) != nil {
            guard replace else {
                throw CmdError(code: "VAULT_EXISTS", message: "entry \"\(entry.name)\" already exists; pass --replace to overwrite it (the password must be entered again).")
            }
            // Update in place so a failure cannot lose the old entry.
            let changes: [String: Any] = [
                kSecAttrComment as String: String(decoding: try JSONEncoder().encode(entry.meta), as: UTF8.self),
                kSecValueData as String: try JSONEncoder().encode(entry.secret),
            ]
            let st = SecItemUpdate(base(entry.name) as CFDictionary, changes as CFDictionary)
            guard st == errSecSuccess else { throw fail(st, "cannot update vault entry") }
            return
        }
        var q = base(entry.name)
        q[kSecAttrLabel as String] = "agent-browser vault: \(entry.name)"
        q[kSecAttrComment as String] = String(decoding: try JSONEncoder().encode(entry.meta), as: UTF8.self)
        q[kSecValueData as String] = try JSONEncoder().encode(entry.secret)
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw fail(st, "cannot store vault entry") }
    }

    func remove(_ name: String) throws -> Bool {
        let st = SecItemDelete(base(name) as CFDictionary)
        if st == errSecItemNotFound { return false }
        guard st == errSecSuccess else { throw fail(st, "cannot remove vault entry") }
        return true
    }
}

// MARK: - File store (tests only: selected with AGENT_BROWSER_VAULT_FILE; plain JSON, mode 0600)

struct FileVaultStore: VaultStore {
    let path: String
    var isTestStore: Bool { true }
    var auditPath: String { path + ".audit" }

    private struct Row: Codable { var meta: VaultMeta; var secret: VaultSecret }

    private func load() -> [String: Row] {
        guard let d = FileManager.default.contents(atPath: path), let r = try? JSONDecoder().decode([String: Row].self, from: d) else { return [:] }
        return r
    }
    private func save(_ rows: [String: Row]) throws {
        let d = try JSONEncoder().encode(rows)
        FileManager.default.createFile(atPath: path, contents: d, attributes: [.posixPermissions: 0o600])
    }
    func list() throws -> [(name: String, meta: VaultMeta)] { load().map { ($0.key, $0.value.meta) }.sorted { $0.name < $1.name } }
    func get(_ name: String) throws -> VaultEntry? { load()[name].map { VaultEntry(name: name, meta: $0.meta, secret: $0.secret) } }
    func put(_ entry: VaultEntry, replace: Bool) throws {
        var rows = load()
        if rows[entry.name] != nil && !replace {
            throw CmdError(code: "VAULT_EXISTS", message: "entry \"\(entry.name)\" already exists; pass --replace to overwrite it (the password must be entered again).")
        }
        rows[entry.name] = Row(meta: entry.meta, secret: entry.secret)
        try save(rows)
    }
    func remove(_ name: String) throws -> Bool {
        var rows = load()
        guard rows.removeValue(forKey: name) != nil else { return false }
        try save(rows)
        return true
    }
}

func makeVaultStore() -> VaultStore {
    if let f = ProcessInfo.processInfo.environment["AGENT_BROWSER_VAULT_FILE"], !f.isEmpty { return FileVaultStore(path: absolutePath(f)) }
    return KeychainVaultStore()
}

// MARK: - Names, origins

func validVaultName(_ n: String) -> Bool {
    !n.isEmpty && n.count <= 64 && n.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." }
}

/// scheme://host[:port] with default ports dropped; the same shape the page script builds from `location`.
func canonicalOrigin(_ url: URL?) -> String? {
    guard let url, let scheme = url.scheme?.lowercased() else { return nil }
    if scheme == "file" { return "file://" }
    guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
    if host.contains(":") { host = "[\(host)]" }
    var o = "\(scheme)://\(host)"
    if let p = url.port, !((scheme == "https" && p == 443) || (scheme == "http" && p == 80)) { o += ":\(p)" }
    return o
}

/// Validates an origin given by the user. Only https, or http to a loopback host. file:// only for the test store.
func normalizeVaultOrigin(_ s: String, allowFile: Bool) throws -> String {
    guard let u = URL(string: s), let o = canonicalOrigin(u) else {
        throw CmdError(code: "USAGE", message: "\"\(s)\" is not a valid origin; use e.g. https://example.com")
    }
    if o == "file://" {
        guard allowFile else { throw CmdError(code: "USAGE", message: "file:// origins are not allowed for vault entries.") }
        return o
    }
    let loopback = ["localhost", "127.0.0.1", "[::1]"].contains(u.host?.lowercased().contains(":") == true ? "[\(u.host!.lowercased())]" : (u.host?.lowercased() ?? ""))
    guard u.scheme?.lowercased() == "https" || (u.scheme?.lowercased() == "http" && loopback) else {
        throw CmdError(code: "USAGE", message: "origin \(o) must be https (plain http is only allowed for localhost).")
    }
    return o
}

// MARK: - TOTP (RFC 6238)

struct TOTPParams {
    var secret: Data
    var digits = 6
    var period = 30
    var algorithm = "SHA1"
}

func base32Decode(_ s: String) -> Data? {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var bits = 0, acc = 0
    var out = Data()
    for ch in s.uppercased() where ch != " " && ch != "-" && ch != "=" {
        guard let v = alphabet.firstIndex(of: ch) else { return nil }
        acc = (acc << 5) | v
        bits += 5
        if bits >= 8 { bits -= 8; out.append(UInt8((acc >> bits) & 0xFF)) }
    }
    return out.isEmpty ? nil : out
}

func base32Encode(_ data: Data) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var out = "", acc = 0, bits = 0
    for b in data {
        acc = (acc << 8) | Int(b)
        bits += 8
        while bits >= 5 { bits -= 5; out.append(alphabet[(acc >> bits) & 31]) }
        acc &= (1 << bits) - 1
    }
    if bits > 0 { out.append(alphabet[(acc << (5 - bits)) & 31]) }
    return out
}

/// The otpauth:// link for a stored secret (the stored text itself when it already is one).
func otpauthURI(stored: String, issuer: String, account: String) -> String {
    if stored.lowercased().hasPrefix("otpauth://") { return stored }
    var c = URLComponents()
    c.scheme = "otpauth"
    c.host = "totp"
    c.path = "/\(issuer):\(account)"
    c.queryItems = [URLQueryItem(name: "secret", value: base32Encode((try? parseTOTP(stored))?.secret ?? Data())),
                    URLQueryItem(name: "issuer", value: issuer)]
    return c.string ?? stored
}

/// Accepts a bare base32 secret or an otpauth://totp/... URI.
func parseTOTP(_ input: String) throws -> TOTPParams {
    let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
    var secretText = t
    var p = TOTPParams(secret: Data())
    if t.lowercased().hasPrefix("otpauth://") {
        guard let c = URLComponents(string: t), c.host?.lowercased() == "totp",
              let s = c.queryItems?.first(where: { $0.name == "secret" })?.value
        else { throw CmdError(code: "USAGE", message: "not a valid otpauth://totp URI (no secret)") }
        secretText = s
        for q in c.queryItems ?? [] {
            switch q.name {
            case "digits": if let d = Int(q.value ?? ""), (6...8).contains(d) { p.digits = d }
            case "period": if let d = Int(q.value ?? ""), d > 0, d <= 300 { p.period = d }
            case "algorithm": if ["SHA1", "SHA256", "SHA512"].contains((q.value ?? "").uppercased()) { p.algorithm = q.value!.uppercased() }
            default: break
            }
        }
    }
    guard let data = base32Decode(secretText) else { throw CmdError(code: "USAGE", message: "the TOTP secret is not valid base32") }
    p.secret = data
    return p
}

func totpCode(_ p: TOTPParams, at date: Date = Date()) -> String {
    var counter = UInt64(date.timeIntervalSince1970) / UInt64(p.period)
    var msg = Data()
    for _ in 0..<8 { msg.insert(UInt8(counter & 0xFF), at: 0); counter >>= 8 }
    let key = SymmetricKey(data: p.secret)
    let mac: [UInt8]
    switch p.algorithm {
    case "SHA256": mac = Array(HMAC<SHA256>.authenticationCode(for: msg, using: key))
    case "SHA512": mac = Array(HMAC<SHA512>.authenticationCode(for: msg, using: key))
    default: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: key))
    }
    let off = Int(mac[mac.count - 1] & 0x0F)
    let bin = (UInt32(mac[off] & 0x7F) << 24) | (UInt32(mac[off + 1]) << 16) | (UInt32(mac[off + 2]) << 8) | UInt32(mac[off + 3])
    var mod: UInt32 = 1
    for _ in 0..<p.digits { mod *= 10 }
    return String(format: "%0\(p.digits)d", bin % mod)
}

/// RFC 6238 appendix B vectors; `vault selftest` runs these.
func totpSelfTest() -> [String] {
    var bad: [String] = []
    let cases: [(String, String, Int, String)] = [
        ("SHA1", "12345678901234567890", 59, "94287082"),
        ("SHA1", "12345678901234567890", 1111111109, "07081804"),
        ("SHA256", "12345678901234567890123456789012", 59, "46119246"),
        ("SHA512", "1234567890123456789012345678901234567890123456789012345678901234", 59, "90693936"),
    ]
    for (alg, secret, t, want) in cases {
        let got = totpCode(TOTPParams(secret: Data(secret.utf8), digits: 8, period: 30, algorithm: alg), at: Date(timeIntervalSince1970: TimeInterval(t)))
        if got != want { bad.append("\(alg)@\(t): got \(got), want \(want)") }
    }
    if base32Decode("gezd gnbv-GY3TQOJQ")?.count != 10 { bad.append("base32 decode") }
    return bad
}

// MARK: - Audit log

func vaultAudit(_ store: VaultStore, _ fields: [String: Any]) {
    var rec = fields
    rec["t"] = ISO8601DateFormatter().string(from: Date())
    let line = jsonString(rec) + "\n"
    let path = store.auditPath
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    }
}

// MARK: - Redaction

/// Every secret value the helper has typed this session. All command output passes through `scrub`, so a
/// secret that a page echoes back (a GET form puts it in the URL, an error message quotes it) never reaches the agent.
final class Redactor {
    private var secrets: Set<String> = []
    func add(_ s: String?) {
        guard let s, s.count >= 4 else { return }
        secrets.insert(s)
    }
    var isEmpty: Bool { secrets.isEmpty }

    /// A TOTP setup secret as a page may display it: plain, in groups of four, dashed, either case, and as the link.
    func addSetupSecret(_ params: TOTPParams, stored: String) {
        let key = base32Encode(params.secret)
        add(key); add(key.lowercased()); add(stored)
        let groups = stride(from: 0, to: key.count, by: 4).map { i -> String in
            let a = key.index(key.startIndex, offsetBy: i), b = key.index(a, offsetBy: 4, limitedBy: key.endIndex) ?? key.endIndex
            return String(key[a..<b])
        }
        for sep in [" ", "-"] { add(groups.joined(separator: sep)); add(groups.joined(separator: sep).lowercased()) }
    }

    private func variants(_ s: String) -> [String] {
        var v = [s]
        if let e = s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { v.append(e) }
        if let e = s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) { v.append(e) }
        v.append(s.replacingOccurrences(of: " ", with: "+"))
        if let e = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { v.append(e) }
        return Array(Set(v)).sorted { $0.count > $1.count }
    }

    func scrub(_ s: String) -> String {
        if secrets.isEmpty { return s }
        var out = s
        for secret in secrets { for v in variants(secret) where v.count >= 4 { out = out.replacingOccurrences(of: v, with: "[redacted]") } }
        return out
    }

    func scrub(_ any: Any) -> Any {
        if secrets.isEmpty { return any }
        switch any {
        case let s as String: return scrub(s)
        case let d as [String: Any]: return d.mapValues { scrub($0) }
        case let a as [Any]: return a.map { scrub($0) }
        default: return any
        }
    }
}

// MARK: - Human approval

private func testStoreApproval() -> (ok: Bool, why: String) {
    // Test store only: never honoured for the real keychain vault, so an agent cannot set it to skip approval.
    switch SessionEnv.get("AGENT_BROWSER_VAULT_APPROVE") {
    case "yes": return (true, "")
    case "no": return (false, "denied")
    default: return (false, "no approval available in the test store")
    }
}

/// Asks the person at the Mac (Touch ID or password) before a vault value is used or shown.
func requestApprovalSync(reason: String, store: VaultStore) -> (ok: Bool, why: String) {
    if store.isTestStore { return testStoreApproval() }
    let ctx = LAContext()
    var nsErr: NSError?
    guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &nsErr) else {
        return (false, "approval is unavailable: \(nsErr?.localizedDescription ?? "no authentication method")")
    }
    final class Box: @unchecked Sendable { var ok = false; var why = "" }
    let box = Box()
    let sem = DispatchSemaphore(value: 0)
    ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, err in
        box.ok = ok
        box.why = ok ? "" : (err?.localizedDescription ?? "denied")
        sem.signal()
    }
    sem.wait()
    return (box.ok, box.why)
}

@MainActor
func requestApproval(reason: String, store: VaultStore) async -> (ok: Bool, why: String) {
    if store.isTestStore { return testStoreApproval() }
    let ctx = LAContext()
    var nsErr: NSError?
    guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &nsErr) else {
        return (false, "approval is unavailable: \(nsErr?.localizedDescription ?? "no authentication method")")
    }
    do {
        let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        return (ok, ok ? "" : "denied")
    } catch {
        return (false, error.localizedDescription)
    }
}
