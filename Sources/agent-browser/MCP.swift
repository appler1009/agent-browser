import Foundation

// Minimal MCP server (JSON-RPC 2.0, newline-delimited, over stdio). Each tool maps 1:1 onto a
// helper command, so the CLI and MCP behave identically.

private let mcpInstructions = """
Local WebKit browser for agents. Loop: browser_snapshot -> act on a ref (browser_click / browser_fill / \
browser_submit) -> browser_snapshot again. Refs look like @s2:e5 and are only valid for the snapshot that \
printed them; after a navigation or a new snapshot, old refs return STALE_REF (no action was performed). \
Actions fail loudly: ELEMENT_COVERED names the element in the way, ELEMENT_HIDDEN / ELEMENT_DISABLED / \
VALIDATION_FAILED explain why nothing happened. Every result lists page events (navigation, dialogs, console \
errors, failed requests). Use browser_wait (selector, text, url, idle) instead of sleeping. browser_watch \
shows a live window the user can pause to take over.
"""

private func tool(_ name: String, _ description: String, _ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
    ["name": name, "description": description,
     "inputSchema": ["type": "object", "properties": props, "required": required] as [String: Any]]
}
private let sRef: [String: Any] = ["type": "string", "description": "Ref from the latest snapshot, e.g. @s2:e5"]

private let mcpTools: [[String: Any]] = [
    tool("browser_open", "Navigate to a URL (https:// is assumed if missing). Starts the browser on first use.",
         ["url": ["type": "string"], "timeout_ms": ["type": "number", "description": "default 30000"]], required: ["url"]),
    tool("browser_snapshot", "Accessibility-style tree of the page with refs for interactive elements. Flags covered, offscreen and disabled elements."),
    tool("browser_click", "Click an element by ref. Errors if it is hidden, disabled or covered. Reports the outcome (navigated, dialog, dom-changed, no-op).",
         ["ref": sRef], required: ["ref"]),
    tool("browser_fill", "Replace the text of an input, textarea or contenteditable by ref.",
         ["ref": sRef, "text": ["type": "string"]], required: ["ref", "text"]),
    tool("browser_submit", "Submit a form (ref may be the form or any control in it). Respects HTML validation and reports the first invalid field.",
         ["ref": sRef], required: ["ref"]),
    tool("browser_wait", "Wait until all given conditions hold, or time out. Provide at least one condition.",
         ["load": ["type": "boolean"], "download": ["type": "boolean", "description": "a download has finished and none is in progress"], "idle": ["type": "boolean", "description": "no pending fetch/XHR and no DOM changes for ~500ms"],
          "selector": ["type": "string", "description": "CSS selector that is present and visible"],
          "gone": ["type": "string", "description": "CSS selector that is absent or hidden"],
          "text": ["type": "string"], "url": ["type": "string", "description": "substring of the current URL"],
          "ms": ["type": "number", "description": "fixed delay"], "timeout_ms": ["type": "number", "description": "default 10000"]]),
    tool("browser_screenshot", "Screenshot of the viewport, returned as an image.",
         ["path": ["type": "string", "description": "optional absolute path to also keep the PNG"]]),
    tool("browser_upload", "Set files on an input[type=file] by ref (hidden file inputs are listed in snapshots). Paths must be absolute; 25 MB total.",
         ["ref": sRef, "paths": ["type": "array", "items": ["type": "string"]]], required: ["ref", "paths"]),
    tool("browser_tabs", "List open tabs (id, url, title, active)."),
    tool("browser_tab", "Manage tabs. Popups and target=_blank links open as a new current tab and are reported as 'opened tab tN'. Refs from another tab's snapshot are STALE_REF.",
         ["action": ["type": "string", "enum": ["new", "switch", "close"]], "url": ["type": "string", "description": "for new"],
          "id": ["type": "string", "description": "tab id like t2, for switch/close"]], required: ["action"]),
    tool("browser_downloads", "Files saved from downloads. A click that triggers a download also reports it as its outcome."),
    tool("browser_cookies", "Export (returns cookies inline, or writes 'path'), import (from absolute 'path') or clear cookies of the profile.",
         ["action": ["type": "string", "enum": ["export", "import", "clear"]], "path": ["type": "string"]], required: ["action"]),
    tool("browser_storage", "Export or import localStorage/sessionStorage for the current page's origin.",
         ["action": ["type": "string", "enum": ["export", "import"]], "path": ["type": "string"]], required: ["action"]),
    tool("browser_status", "Session, profile (null = temporary), tab count, watch state."),
    tool("browser_watch", "Show or hide the live watch window for the user. 'pause' hands control to the user; agent commands then wait until 'resume'.",
         ["mode": ["type": "string", "enum": ["on", "off", "pause", "resume", "status"]]], required: ["mode"]),
    tool("browser_close", "Stop the browser helper and discard its temporary profile."),
]

private func toolRequest(_ name: String, _ a: [String: Any]) -> [String: Any]? {
    func s(_ k: String) -> String { a[k] as? String ?? "" }
    func n(_ k: String) -> Double? { (a[k] as? NSNumber)?.doubleValue }
    switch name {
    case "browser_open":
        var args: [String: Any] = ["url": s("url")]
        if let t = n("timeout_ms") { args["timeout"] = t / 1000 }
        return ["cmd": "open", "args": args]
    case "browser_snapshot": return ["cmd": "snapshot", "args": [:]]
    case "browser_click": return ["cmd": "click", "args": ["ref": s("ref")]]
    case "browser_fill": return ["cmd": "fill", "args": ["ref": s("ref"), "text": s("text")]]
    case "browser_submit": return ["cmd": "submit", "args": ["ref": s("ref")]]
    case "browser_wait":
        var args: [String: Any] = [:]
        for k in ["load", "idle", "download"] { if a[k] as? Bool == true { args[k] = true } }
        for k in ["selector", "gone", "text", "url"] where !s(k).isEmpty { args[k] = s(k) }
        if let ms = n("ms") { args["ms"] = ms }
        if let t = n("timeout_ms") { args["timeout"] = t }
        return ["cmd": "wait", "args": args]
    case "browser_screenshot":
        let keep = s("path")
        let path = keep.isEmpty ? NSTemporaryDirectory() + "agent-browser-\(UUID().uuidString).png" : keep
        return ["cmd": "screenshot", "args": ["path": path], "_keep": !keep.isEmpty]
    case "browser_upload":
        return ["cmd": "upload", "args": ["ref": s("ref"), "paths": a["paths"] as? [String] ?? []]]
    case "browser_tabs": return ["cmd": "tabs", "args": [:]]
    case "browser_tab":
        var args: [String: Any] = ["action": s("action")]
        if !s("url").isEmpty { args["url"] = s("url") }
        if !s("id").isEmpty { args["id"] = s("id") }
        return ["cmd": "tab", "args": args]
    case "browser_downloads": return ["cmd": "downloads", "args": [:]]
    case "browser_cookies", "browser_storage":
        var args: [String: Any] = ["action": s("action")]
        if !s("path").isEmpty { args["path"] = s("path") }
        return ["cmd": name == "browser_cookies" ? "cookies" : "storage", "args": args]
    case "browser_status": return ["cmd": "status", "args": [:]]
    case "browser_watch": return ["cmd": "watch", "args": ["mode": s("mode").isEmpty ? "on" : s("mode")]]
    case "browser_close": return ["cmd": "close", "args": [:]]
    default: return nil
    }
}

private func text(_ s: String) -> [String: Any] { ["type": "text", "text": s] }

private func callTool(session: String, profile: String?, name: String, arguments: [String: Any]) -> [String: Any] {
    guard var req = toolRequest(name, arguments) else {
        return ["isError": true, "content": [text("unknown tool \(name)")]]
    }
    let keep = req.removeValue(forKey: "_keep") as? Bool ?? true
    let cmd = req["cmd"] as? String ?? ""
    let reply: [String: Any]
    switch sendToHelper(session: session, profile: profile, request: req) {
    case .success(let line):
        reply = parseJSON(line) ?? ["ok": false, "error": ["code": "BAD_REPLY", "message": line]]
    case .failure(let e):
        if cmd == "close" && e.code == "NO_RESPONSE" { reply = ["ok": true, "result": ["closed": true], "events": []] }
        else { reply = ["ok": false, "error": ["code": e.code, "message": e.message, "retry_safe": true], "events": []] }
    }
    let ok = reply["ok"] as? Bool == true
    var content: [[String: Any]] = []
    let result = reply["result"] as? [String: Any] ?? [:]
    let events = reply["events"] as? [[String: Any]] ?? []

    if ok, cmd == "snapshot", let tree = result["tree"] as? String {
        let head = "# \(result["url"] as? String ?? "") — \(result["title"] as? String ?? "") (snapshot s\(result["snapshot"] as? Int ?? 0), \(result["refs"] as? Int ?? 0) refs\(result["truncated"] as? Bool == true ? ", TRUNCATED" : ""))"
        content.append(text(head + "\n" + tree))
    } else if ok, cmd == "screenshot", let path = result["path"] as? String, let d = FileManager.default.contents(atPath: path) {
        content.append(["type": "image", "data": d.base64EncodedString(), "mimeType": "image/png"])
        if keep { content.append(text(jsonString(["path": path]))) } else { try? FileManager.default.removeItem(atPath: path) }
    } else {
        var out: [String: Any] = ok ? ["result": result] : ["error": reply["error"] ?? [:]]
        out["ok"] = ok
        content.append(text(jsonString(out)))
    }
    if !events.isEmpty { content.append(text("events: " + jsonString(["events": events]))) }
    return ["isError": !ok, "content": content]
}

func runMCP(session: String, profile: String? = nil) -> Never {
    func send(_ obj: [String: Any]) {
        FileHandle.standardOutput.write(Data((jsonString(obj) + "\n").utf8))
    }
    while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        guard let msg = parseJSON(line) else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
            continue
        }
        guard let method = msg["method"] as? String else { continue }  // a response; we send no requests
        guard let id = msg["id"] else { continue }                      // notification: no reply
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            send(["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "agent-browser", "version": "0.1.0"],
                "instructions": mcpInstructions,
            ] as [String: Any]])
        case "ping":
            send(["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]])
        case "tools/list":
            send(["jsonrpc": "2.0", "id": id, "result": ["tools": mcpTools]])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            send(["jsonrpc": "2.0", "id": id,
                  "result": callTool(session: session, profile: profile, name: name, arguments: params["arguments"] as? [String: Any] ?? [:])])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
    }
    exit(0)
}
