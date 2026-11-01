import AppKit
import Foundation

signal(SIGPIPE, SIG_IGN)

let usage = """
usage: agent-browser [--session NAME] [--profile NAME] <command> [args]
  open <url> [--timeout MS]        navigate (starts the background helper on first use)
  snapshot [--text]                accessibility-style tree with refs like @s1:e3
  click <ref>
  fill <ref> <text...>
  submit <ref>                     ref may be the form or any control inside it
  wait [--load] [--idle] [--download] [--selector CSS] [--gone CSS] [--text T] [--url SUBSTR] [--ms N] [--timeout MS]
  screenshot [path]                default ./screenshot.png
  upload <ref> <abs-path...>       set files on an input[type=file] (hidden ones are listed in snapshots)
  tabs | tab new [url] | tab switch <id> | tab close [id]
  downloads                        files saved from downloads (also reported as an action's outcome)
  cookies export [file] | import <file> | clear
  storage export [file] | import <file>      localStorage/sessionStorage of the current origin
  status                           session, profile, tabs
  watch [on|off|pause|resume|status]   show/hide the live watch window; pause = human takes over
  close                            stop the helper
  mcp                              run as an MCP server on stdio (same tools, for Claude Code, Cursor, ...)
--profile NAME keeps cookies/storage between runs (default: temporary, discarded on close).
Every command prints one JSON object: {ok, result, events, error}.
"""

// MARK: - daemon

@MainActor
func runDaemon(session: String) -> Never {
    let path = socketPath(session: session)
    if let fd = connectSocket(path) {  // another helper already owns this session
        close(fd)
        exit(0)
    }
    guard let listenFd = listenSocket(path) else {
        FileHandle.standardError.write(Data("cannot listen on \(path)\n".utf8))
        exit(1)
    }
    daemonSocketPath = path
    daemonSession = session
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // no Dock icon, never takes focus
    let browser = Browser()

    Thread.detachNewThread {
        while true {
            let c = accept(listenFd, nil, nil)
            if c < 0 { continue }
            DispatchQueue.global().async {
                guard let line = readLineFromSocket(c) else { close(c); return }
                Task { @MainActor in
                    let resp = await browser.handleLine(line)
                    writeAllToSocket(c, resp + "\n")
                    close(c)
                }
            }
        }
    }

    // Exit after 30 idle minutes so a forgotten helper does not linger.
    Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
        MainActor.assumeIsolated {
            if Date().timeIntervalSince(browser.lastActivity) > 30 * 60 { unlink(path); exit(0) }
        }
    }
    app.run()
    exit(0)
}

// MARK: - CLI

func fail(_ code: String, _ message: String) -> Never {
    print(jsonString(["ok": false, "events": [], "error": ["code": code, "message": message, "retry_safe": true]]))
    exit(1)
}

func absolutePath(_ p: String) -> String {
    let e = (p as NSString).expandingTildeInPath
    return e.hasPrefix("/") ? e : FileManager.default.currentDirectoryPath + "/" + e
}

func buildRequest(_ cmd: String, _ rest: [String]) -> ([String: Any], Bool) {
    var positional: [String] = []
    var flags: [String: String] = [:]
    let boolFlags: Set<String> = cmd == "snapshot" ? ["text"] : ["load", "idle", "download"]
    var i = 0
    while i < rest.count {
        let a = rest[i]
        if a.hasPrefix("--") && a.count > 2 && !(cmd == "fill" && positional.count >= 2) {
            let k = String(a.dropFirst(2))
            if boolFlags.contains(k) { flags[k] = "1" }
            else if i + 1 < rest.count { flags[k] = rest[i + 1]; i += 1 }
            else { fail("USAGE", "--\(k) needs a value") }
        } else { positional.append(a) }
        i += 1
    }
    var args: [String: Any] = [:]
    func needPositional(_ n: Int, _ what: String) {
        if positional.count < n { fail("USAGE", "\(cmd): missing \(what)\n\(usage)") }
    }
    func num(_ k: String) -> Double? {
        guard let v = flags[k] else { return nil }
        guard let d = Double(v) else { fail("USAGE", "--\(k) must be a number") }
        return d
    }
    switch cmd {
    case "open":
        needPositional(1, "<url>")
        args["url"] = positional[0]
        if let t = num("timeout") { args["timeout"] = t / 1000 }
    case "snapshot", "close", "tabs", "downloads", "status":
        break
    case "click", "submit":
        needPositional(1, "<ref>")
        args["ref"] = positional[0]
    case "fill":
        needPositional(2, "<ref> <text>")
        args["ref"] = positional[0]
        args["text"] = positional[1...].joined(separator: " ")
    case "wait":
        if flags["load"] != nil { args["load"] = true }
        if flags["idle"] != nil { args["idle"] = true }
        if flags["download"] != nil { args["download"] = true }
        for k in ["selector", "gone", "text", "url"] { if let v = flags[k] { args[k] = v } }
        if let ms = num("ms") { args["ms"] = ms }
        if let t = num("timeout") { args["timeout"] = t }
    case "upload":
        needPositional(2, "<ref> <abs-path...>")
        args["ref"] = positional[0]
        args["paths"] = positional.dropFirst().map { absolutePath($0) }
    case "tab":
        needPositional(1, "new [url] | switch <id> | close [id]")
        args["action"] = positional[0]
        if positional.count > 1 { args[positional[0] == "new" ? "url" : "id"] = positional[1] }
    case "cookies", "storage":
        needPositional(1, cmd == "cookies" ? "export [file] | import <file> | clear" : "export [file] | import <file>")
        args["action"] = positional[0]
        if positional.count > 1 { args["path"] = absolutePath(positional[1]) }
    case "watch":
        let mode = positional.first ?? "on"
        if !["on", "off", "pause", "resume", "status"].contains(mode) { fail("USAGE", "watch takes on|off|pause|resume|status") }
        args["mode"] = mode
    case "screenshot":
        let p = positional.first ?? "screenshot.png"
        args["path"] = absolutePath(p)
    default:
        fail("USAGE", "unknown command \"\(cmd)\"\n\(usage)")
    }
    return (["cmd": cmd, "args": args], cmd == "snapshot" && flags["text"] != nil)
}

var argv = Array(CommandLine.arguments.dropFirst())
var session = ProcessInfo.processInfo.environment["AGENT_BROWSER_SESSION"] ?? "default"
if let i = argv.firstIndex(of: "--session"), i + 1 < argv.count {
    session = argv[i + 1]
    argv.removeSubrange(i...(i + 1))
}
session = sanitizeSession(session)
var profile: String? = ProcessInfo.processInfo.environment["AGENT_BROWSER_PROFILE"]
if let i = argv.firstIndex(of: "--profile"), i + 1 < argv.count {
    profile = argv[i + 1]
    argv.removeSubrange(i...(i + 1))
}
if let p = profile {
    let ok = !p.isEmpty && p.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    if !ok { fail("USAGE", "--profile may only contain letters, digits, - and _") }
}

guard let cmd = argv.first else {
    print(usage)
    exit(2)
}

if cmd == "daemon" {
    daemonProfile = profile
    MainActor.assumeIsolated { runDaemon(session: session) }
}
if cmd == "mcp" {
    runMCP(session: session, profile: profile)
}
if cmd == "--help" || cmd == "-h" || cmd == "help" {
    print(usage)
    exit(0)
}

var (request, textOnly) = buildRequest(cmd, Array(argv.dropFirst()))
if let p = profile { request["profile"] = p }

if cmd == "close", connectSocket(socketPath(session: session)) == nil {
    print(jsonString(["ok": true, "result": ["closed": false, "note": "no helper was running"], "events": []]))
    exit(0)
}

let line: String
switch sendToHelper(session: session, profile: profile, request: request) {
case .success(let l): line = l
case .failure(let e):
    if cmd == "close" && e.code == "NO_RESPONSE" {  // helper exits right after acknowledging close
        print(jsonString(["ok": true, "result": ["closed": true], "events": []]))
        exit(0)
    }
    fail(e.code, e.message)
}

if textOnly, let r = parseJSON(line), r["ok"] as? Bool == true,
   let res = r["result"] as? [String: Any], let tree = res["tree"] as? String {
    print("# \(res["url"] as? String ?? "") — \(res["title"] as? String ?? "") (snapshot s\(res["snapshot"] as? Int ?? 0), \(res["refs"] as? Int ?? 0) refs\(res["truncated"] as? Bool == true ? ", TRUNCATED" : ""))")
    print(tree)
    exit(0)
}
print(line)
exit((parseJSON(line)?["ok"] as? Bool) == true ? 0 : 1)
