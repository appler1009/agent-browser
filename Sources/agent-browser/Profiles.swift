import AppKit
import Foundation
import WebKit

// Persistent profiles keep cookies (ours, encrypted) and WebKit's own data (localStorage, caches) on disk.
// `profile list` shows what each takes; `profile rm` deletes one for good. Deleting is for the person in a terminal.

private func dirSize(_ path: String) -> Int {
    guard let e = FileManager.default.enumerator(atPath: path) else { return 0 }
    var total = 0
    for case let f as String in e {
        if let a = try? FileManager.default.attributesOfItem(atPath: path + "/" + f), (a[.type] as? FileAttributeType) == .typeRegular {
            total += (a[.size] as? Int) ?? 0
        }
    }
    return total
}

/// Folders WebKit may keep this app's data store in, depending on whether it runs bare or from the app bundle.
private func storeDirs(_ id: UUID) -> [String] {
    let lib = NSHomeDirectory() + "/Library/WebKit"
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: lib)) ?? []).filter { $0.contains("agent-browser") }
    return names.flatMap { n in
        ["WebsiteDataStore"].flatMap { sub -> [String] in
            let base = "\(lib)/\(n)/\(sub)"
            return ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [])
                .filter { $0.lowercased() == id.uuidString.lowercased() }.map { "\(base)/\($0)" }
        }
    }
}

private func profileNames() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.agent-browser/profiles")) ?? []).sorted()
}

@MainActor
func runProfileCLI(_ args: [String]) -> Never {
    func out(_ r: [String: Any]) -> Never { print(jsonString(["ok": true, "result": r, "events": []])); exit(0) }
    let sub = args.first ?? "list"
    switch sub {
    case "list":
        let live = listSessions().sessions.compactMap { $0["profile"] as? String }
        let rows: [[String: Any]] = profileNames().map { n in
            let mine = dirSize(NSHomeDirectory() + "/.agent-browser/profiles/" + n)
            let web = storeDirs(Browser.storeID(for: n)).reduce(0) { $0 + dirSize($1) }
            return ["profile": n, "cookies_bytes": mine, "webkit_bytes": web, "total_bytes": mine + web, "in_use": live.contains(n)]
        }
        out(["profiles": rows, "total_bytes": rows.reduce(0) { $0 + ($1["total_bytes"] as? Int ?? 0) }])
    case "rm":
        guard args.count == 2 else { fail("USAGE", "profile rm <name>") }
        let name = args[1]
        guard profileNames().contains(name) else { fail("NOT_FOUND", "no profile named \"\(name)\"") }
        if isatty(STDIN_FILENO) == 0 && ProcessInfo.processInfo.environment["AGENT_BROWSER_PROFILE_RM_YES"] != "1" {
            fail("NEEDS_TERMINAL", "profile rm deletes saved logins; run it yourself in a terminal")
        }
        if listSessions().sessions.contains(where: { $0["profile"] as? String == name }) {
            fail("PROFILE_IN_USE", "a running session uses profile \"\(name)\"; run close for it first")
        }
        // WebKit's own remove call needs a running web process pool (it crashes without one), and no session uses this
        // profile, so its data folders are deleted directly.
        for d in storeDirs(Browser.storeID(for: name)) { try? FileManager.default.removeItem(atPath: d) }
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.agent-browser/profiles/" + name)
        let left = storeDirs(Browser.storeID(for: name)).count
        let failure: String? = left == 0 ? nil : "could not delete WebKit's data folder for the profile"
        if let failure { fail("PROFILE_RM_FAILED", failure) }
        out(["removed": name])
    case "prune":
        // WebKit data folders that belong to no profile any more (a profile folder deleted by hand, test runs).
        // Lists them; deletes only with --yes, and only from a terminal.
        let delete = args.contains("--yes")
        if delete && isatty(STDIN_FILENO) == 0 && ProcessInfo.processInfo.environment["AGENT_BROWSER_PROFILE_RM_YES"] != "1" {
            fail("NEEDS_TERMINAL", "profile prune --yes deletes data; run it yourself in a terminal")
        }
        let known = Set((profileNames() + listSessions().sessions.compactMap { $0["profile"] as? String })
                        .map { Browser.storeID(for: $0).uuidString.lowercased() })
        let lib = NSHomeDirectory() + "/Library/WebKit"
        var found = 0, bytes = 0
        for app in ((try? FileManager.default.contentsOfDirectory(atPath: lib)) ?? []) where app.contains("agent-browser") {
            let base = "\(lib)/\(app)/WebsiteDataStore"
            for d in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] {
                let id = d.lowercased()
                let isOurs = id.count == 36 && id[id.index(id.startIndex, offsetBy: 14)] == "5"  // our ids are name-based (version 5)
                if isOurs && !known.contains(id) {
                    bytes += dirSize("\(base)/\(d)")
                    found += 1
                    if delete { try? FileManager.default.removeItem(atPath: "\(base)/\(d)") }
                }
            }
        }
        out(["orphaned_folders": found, "bytes": bytes, "deleted": delete])
    default:
        fail("USAGE", "profile list | rm <name> | prune [--yes]")
    }
}
