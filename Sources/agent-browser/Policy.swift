import Darwin
import Foundation

// Limits a person sets for what the browser may do on its own. Stored in ~/.agent-browser/policy.json (owner-only) and
// changed only with `agent-browser policy set` from an interactive terminal, like the vault, so a page or an agent
// that talks to the browser cannot loosen them. Helpers re-read the file when it changes.
// What it does not cover: an agent that can run shell commands as you can edit the file itself, and subresource
// requests (images, scripts, fetch) are not filtered: only navigations, frames, popups, downloads and dialogs.

struct Policy {
    var allowHosts: [String] = []       // when not empty, only these hosts may be navigated to
    var denyHosts: [String] = []        // never these (wins over allow)
    var privateNetworks = "block"       // "block": a public page may not send the browser to a private address; "allow"
    var maxTabs = 8
    var maxDownloads = 20               // per session
    var maxDownloadMB = 200
    var dialogs = "ask"                 // confirm()/prompt(): "ask" the person, or "accept" / "dismiss" automatically

    static var path: String {
        if let p = ProcessInfo.processInfo.environment["AGENT_BROWSER_POLICY_FILE"], !p.isEmpty { return p }
        return NSHomeDirectory() + "/.agent-browser/policy.json"
    }
    static var isTestFile: Bool { !(ProcessInfo.processInfo.environment["AGENT_BROWSER_POLICY_FILE"] ?? "").isEmpty }

    var json: [String: Any] {
        ["allow_hosts": allowHosts, "deny_hosts": denyHosts, "private_networks": privateNetworks, "max_tabs": maxTabs,
         "max_downloads": maxDownloads, "max_download_mb": maxDownloadMB, "dialogs": dialogs]
    }

    init() {}
    init(json d: [String: Any]) {
        allowHosts = (d["allow_hosts"] as? [String]) ?? []
        denyHosts = (d["deny_hosts"] as? [String]) ?? []
        if let v = d["private_networks"] as? String, ["block", "allow"].contains(v) { privateNetworks = v }
        if let v = d["max_tabs"] as? Int, v >= 1 { maxTabs = v }
        if let v = d["max_downloads"] as? Int, v >= 0 { maxDownloads = v }
        if let v = d["max_download_mb"] as? Int, v >= 1 { maxDownloadMB = v }
        if let v = d["dialogs"] as? String, ["ask", "accept", "dismiss"].contains(v) { dialogs = v }
    }

    static func load() -> Policy {
        guard let data = FileManager.default.contents(atPath: path),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Policy() }
        return Policy(json: d)
    }

    func save() throws {
        let dir = (Policy.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: Policy.path), options: .atomic)
        chmod(Policy.path, 0o600)
    }
}

/// Re-reads the policy file only when its modification time changes.
@MainActor
final class PolicyCache {
    private var stamp: timespec?
    private var cached = Policy()
    var current: Policy {
        var st = stat()
        if stat(Policy.path, &st) != 0 {
            if stamp != nil { stamp = nil; cached = Policy() }
            return cached
        }
        if stamp == nil || stamp!.tv_sec != st.st_mtimespec.tv_sec || stamp!.tv_nsec != st.st_mtimespec.tv_nsec {
            stamp = st.st_mtimespec
            cached = Policy.load()
        }
        return cached
    }
}

// MARK: - hosts

/// "example.com" matches that host only; "*.example.com" matches any subdomain (not the bare domain).
func policyHostMatches(_ pattern: String, _ host: String) -> Bool {
    let p = pattern.lowercased(), h = host.lowercased()
    if p.hasPrefix("*.") { return h.hasSuffix(String(p.dropFirst(1))) && h.count > p.count - 1 }
    return p == h
}

func validPolicyHost(_ s: String) -> Bool {
    let t = s.lowercased()
    let body = t.hasPrefix("*.") ? String(t.dropFirst(2)) : t
    return !body.isEmpty && body.count < 254 && body.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == ":" || $0 == "[" || $0 == "]" } && !body.hasPrefix(".") && !body.hasSuffix(".")
}

private func privateV4(_ a: UInt32) -> Bool {
    let b1 = a >> 24, b2 = (a >> 16) & 255
    return b1 == 0 || b1 == 10 || b1 == 127 || (b1 == 100 && (b2 & 0xC0) == 64) || (b1 == 169 && b2 == 254)
        || (b1 == 172 && (b2 & 0xF0) == 16) || (b1 == 192 && b2 == 168) || (b1 == 198 && (b2 & 0xFE) == 18)
}

private func privateAddress(_ ai: UnsafePointer<addrinfo>) -> Bool {
    switch ai.pointee.ai_family {
    case AF_INET:
        let sin = ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        return privateV4(UInt32(bigEndian: sin.sin_addr.s_addr))
    case AF_INET6:
        let sin6 = ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
        let b = withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }
        if b.dropLast().allSatisfy({ $0 == 0 }) && (b.last == 0 || b.last == 1) { return true }   // :: and ::1
        if (b[0] & 0xFE) == 0xFC { return true }                                                  // fc00::/7
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }                                  // fe80::/10
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {                  // ::ffff:a.b.c.d
            return privateV4(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
        }
        return false
    default: return false
    }
}

nonisolated(unsafe) private var privateHostCache: [String: Bool] = [:]
private let privateHostLock = NSLock()

private func storeHostPrivate(_ host: String, _ v: Bool) {
    privateHostLock.lock(); defer { privateHostLock.unlock() }
    if privateHostCache.count > 500 { privateHostCache.removeAll() }
    privateHostCache[host] = v
}

/// What is already known about a host, without a lookup (used when a page commits).
func cachedHostIsPrivate(_ host: String) -> Bool? {
    let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
    privateHostLock.lock(); defer { privateHostLock.unlock() }
    return privateHostCache[h]
}

/// True when the host is, or resolves to, a loopback, link-local or private address (any of its addresses).
func hostIsPrivate(_ host: String) async -> Bool {
    let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
    if let c = cachedHostIsPrivate(h) { return c }
    // nil = the lookup failed; that is not remembered, so the next navigation looks again.
    let result: Bool? = await Task.detached { () -> Bool? in
        var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(h, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let cur = p { if privateAddress(UnsafePointer(cur)) { return true }; p = cur.pointee.ai_next }
        return false
    }.value
    guard let result else { return false }
    storeHostPrivate(h, result)
    return result
}

/// Pages that are not on the public internet (file, about, data, localhost, private addresses).
func urlIsLocalOrPrivate(_ url: URL) async -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return true }
    guard scheme == "http" || scheme == "https" else { return true }
    guard let host = url.host else { return true }
    return await hostIsPrivate(host)
}

/// Why a navigation to `url` must not happen, or nil. `explicit` is true for an address the person or agent typed
/// (`open`, `tab new`): those may go to private addresses, but the allow and deny lists still apply.
func navigationBlockReason(_ url: URL, policy: Policy, chainPrivateOK: Bool, explicit: Bool) async -> String? {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return nil }
    if let p = policy.denyHosts.first(where: { policyHostMatches($0, host) }) { return "\(host) is denied by policy (\(p))" }
    if !policy.allowHosts.isEmpty && !policy.allowHosts.contains(where: { policyHostMatches($0, host) }) {
        return "\(host) is not in the policy's allowed hosts"
    }
    guard policy.privateNetworks == "block" && !explicit && !chainPrivateOK else { return nil }
    if await hostIsPrivate(host) {
        return "a page on the public internet may not send the browser to a private address (\(host)); policy private_networks is block"
    }
    return nil
}

// MARK: - CLI

func runPolicyCLI(_ args: [String]) -> Never {
    func out(_ r: [String: Any]) -> Never { print(jsonString(["ok": true, "result": r, "events": []])); exit(0) }
    var rest = args
    let sub = rest.isEmpty ? "show" : rest.removeFirst()
    func values(_ name: String) -> [String] {
        var v: [String] = []
        while let i = rest.firstIndex(of: "--\(name)") {
            guard i + 1 < rest.count else { fail("USAGE", "--\(name) needs a value") }
            v.append(rest[i + 1]); rest.removeSubrange(i...(i + 1))
        }
        return v
    }
    func flag(_ name: String) -> Bool {
        guard let i = rest.firstIndex(of: "--\(name)") else { return false }
        rest.remove(at: i); return true
    }
    func needTTY() {
        if isatty(STDIN_FILENO) == 0 && !Policy.isTestFile {
            fail("POLICY_NEEDS_TTY", "changing the policy needs an interactive terminal (run it yourself, not through an agent), so that limits cannot be loosened by a program.")
        }
    }
    func int(_ name: String, min: Int) -> Int? {
        guard let s = values(name).last else { return nil }
        guard let n = Int(s), n >= min else { fail("USAGE", "--\(name) needs a whole number >= \(min)") }
        return n
    }
    switch sub {
    case "show":
        out(["path": Policy.path, "exists": FileManager.default.fileExists(atPath: Policy.path), "policy": Policy.load().json])
    case "check":  // read-only: what would the policy do with this address?
        guard let u = rest.first, let url = URL(string: u), rest.count == 1 || rest.contains("--from") else {
            fail("USAGE", "policy check <url> [--from public|private|typed]   (public: a page on the internet leads there; private: a local page does; typed: you open it)")
        }
        let from = values("from").last ?? "public"
        guard ["public", "private", "typed"].contains(from) else { fail("USAGE", "--from takes public, private or typed") }
        final class Box: @unchecked Sendable { var reason: String? }
        let box = Box(), sem = DispatchSemaphore(value: 0)
        let pol = Policy.load()
        Task.detached {
            box.reason = await navigationBlockReason(url, policy: pol, chainPrivateOK: from == "private", explicit: from == "typed")
            sem.signal()
        }
        sem.wait()
        out(["url": u, "from": from, "allowed": box.reason == nil, "reason": box.reason ?? NSNull()])
    case "reset":
        needTTY()
        try? FileManager.default.removeItem(atPath: Policy.path)
        out(["reset": true, "policy": Policy().json])
    case "set":
        needTTY()
        var p = Policy.load()
        let allow = values("allow-host"), deny = values("deny-host")
        for h in allow + deny where !validPolicyHost(h) { fail("USAGE", "not a host name or *.domain pattern: \(h)") }
        if flag("no-allow-hosts") { p.allowHosts = [] }
        if flag("no-deny-hosts") { p.denyHosts = [] }
        if !allow.isEmpty { p.allowHosts = Array(Set(allow.map { $0.lowercased() })).sorted() }
        if !deny.isEmpty { p.denyHosts = Array(Set(deny.map { $0.lowercased() })).sorted() }
        if let v = values("private").last {
            guard ["block", "allow"].contains(v) else { fail("USAGE", "--private takes block or allow") }
            p.privateNetworks = v
        }
        if let v = values("dialogs").last {
            guard ["ask", "accept", "dismiss"].contains(v) else { fail("USAGE", "--dialogs takes ask, accept or dismiss") }
            p.dialogs = v
        }
        if let n = int("max-tabs", min: 1) { p.maxTabs = n }
        if let n = int("max-downloads", min: 0) { p.maxDownloads = n }
        if let n = int("max-download-mb", min: 1) { p.maxDownloadMB = n }
        guard rest.isEmpty else { fail("USAGE", "unknown policy option: \(rest.joined(separator: " "))") }
        do { try p.save() } catch { fail("POLICY_WRITE", "\(error.localizedDescription)") }
        out(["path": Policy.path, "policy": p.json])
    default:
        fail("USAGE", "policy [show] | check <url> [--from public|private|typed] | set [--allow-host H]... [--deny-host H]... [--no-allow-hosts] [--no-deny-hosts] [--private block|allow] [--max-tabs N] [--max-downloads N] [--max-download-mb N] [--dialogs ask|accept|dismiss] | reset   (hosts: example.com or *.example.com)")
    }
}
