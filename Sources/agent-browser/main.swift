import AppKit
import Foundation

signal(SIGPIPE, SIG_IGN)

let usage = """
usage: agent-browser [--session NAME] [--profile NAME] <command> [args]
  open <url> [--timeout MS]        navigate (starts the background helper on first use)
  snapshot [--text] [--interactive] [--max-chars N] [--max-nodes N] [--selector CSS]
                                   accessibility-style tree with refs like @s1:e3; the flags cap its size (tokens)
  click <ref>
  fill <ref> <text...>
  fill <ref> --secret <entry> [--field username|password|totp]   type a vault value; the agent never sees it
  login <entry> [--submit]         fill the username/password/one-time-code fields on the page from a vault entry
  totp enroll <entry> [--replace]  on a 2FA setup page: read the setup key / otpauth link / QR code straight into the entry
  recovery save <entry> [--selector CSS]   save the recovery codes shown on the page into the entry
  vault list | audit [--limit N]   saved logins (names and sites only)
  vault add|rm|export|recovery     for the user, in a terminal: create/remove entries, back up TOTP secrets and recovery codes
  submit <ref>                     ref may be the form or any control inside it
  wait [--load] [--idle] [--download] [--selector CSS] [--gone CSS] [--text T] [--url SUBSTR] [--ms N] [--timeout MS]
  screenshot [path]                default ./screenshot.png
  upload <ref> <abs-path...>       set files on an input[type=file] (hidden ones are listed in snapshots)
  tabs | tab new [url] | tab switch <id> | tab close [id]
  downloads                        files saved from downloads (also reported as an action's outcome)
  cookies export [file] | import <file> | clear
  storage export [file] | import <file>      localStorage/sessionStorage of the current origin
  viewport [W H]                   page size in CSS pixels (default 1280 800)
  useragent <string...>|reset      user agent for pages loaded from now on
  block images|media|fonts|scripts|styles | url <regex> | clear | status   content blocking for new requests
  status                           session, profile, tabs
  cdp [start [--port N] | stop | status]   thin DevTools-protocol endpoint on 127.0.0.1 for Puppeteer/Playwright-style tools
  watch [on|off|pause|resume|status]   show/hide the live watch window; pause = human takes over
  close                            stop the helper
  sessions                         every running session with its state (never starts one)
  menubar [start|install|uninstall]   menu bar item listing sessions: show window, take over, close; install = start at login
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
            if Date().timeIntervalSince(browser.lastActivity) > 30 * 60 {
                unlink(path)
                Task { @MainActor in await browser.persistCookies(); exit(0) }
            }
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
    let boolFlags: Set<String> = cmd == "snapshot" ? ["text", "interactive"] : ["load", "idle", "download", "submit", "replace"]
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
    case "close", "tabs", "downloads", "status":
        break
    case "snapshot":
        if flags["interactive"] != nil { args["interactive"] = true }
        if let v = num("max-chars") { args["maxChars"] = v }
        if let v = num("max-nodes") { args["maxNodes"] = v }
        if let v = flags["selector"] { args["selector"] = v }
    case "viewport":
        let dims = positional.flatMap { $0.lowercased().split(separator: "x").map(String.init) }
        if !dims.isEmpty {
            guard dims.count == 2, let w = Double(dims[0]), let h = Double(dims[1]) else { fail("USAGE", "viewport takes <width> <height> (or WxH)") }
            args["width"] = w
            args["height"] = h
        }
    case "useragent":
        needPositional(1, "<string>|reset")
        args["userAgent"] = positional.joined(separator: " ")
    case "block":
        needPositional(1, "images|media|fonts|scripts|styles | url <regex> | clear | status")
        args["action"] = positional[0]
        if positional[0] == "url" { needPositional(2, "<regex>"); args["pattern"] = positional[1] }
    case "click", "submit":
        needPositional(1, "<ref>")
        args["ref"] = positional[0]
    case "fill":
        if let name = flags["secret"] {
            needPositional(1, "<ref>")
            if positional.count > 1 { fail("USAGE", "fill --secret takes no text; the value comes from the vault") }
            args["ref"] = positional[0]
            args["secret"] = name
            if let f = flags["field"] { args["field"] = f }
        } else {
            needPositional(2, "<ref> <text>")
            args["ref"] = positional[0]
            args["text"] = positional[1...].joined(separator: " ")
        }
    case "totp":
        needPositional(2, "enroll <entry> [--replace]")
        if positional[0] != "enroll" { fail("USAGE", "totp takes: enroll <entry> [--replace]") }
        args["secret"] = positional[1]
        if flags["replace"] != nil { args["replace"] = true }
        return (["cmd": "enroll", "args": args], false)
    case "recovery":
        needPositional(2, "save <entry> [--selector CSS]")
        if positional[0] != "save" { fail("USAGE", "recovery takes: save <entry> [--selector CSS]") }
        args["secret"] = positional[1]
        if let v = flags["selector"] { args["selector"] = v }
    case "login":
        needPositional(1, "<entry>")
        args["secret"] = positional[0]
        if flags["submit"] != nil { args["submit"] = true }
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
    case "cdp":
        args["action"] = positional.first ?? "start"
        if let port = num("port") { args["port"] = port }
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
if cmd == "sessions" {
    let r = listSessions()
    print(jsonString(["ok": true, "result": ["sessions": r.sessions, "stale": r.stale], "events": []]))
    exit(0)
}
if cmd == "menubar" {
    runMenubarCLI(Array(argv.dropFirst()))
}
if cmd == "vault" {
    runVaultCLI(Array(argv.dropFirst()))
}
if cmd == "mcp" {
    runMCP(session: session, profile: profile)
}
if cmd == "--version" || cmd == "-v" || cmd == "version" {
    print("agent-browser \(agentBrowserVersion)")
    exit(0)
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
