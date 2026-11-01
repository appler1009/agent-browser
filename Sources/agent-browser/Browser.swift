import AppKit
import WebKit

/// Socket file owned by this helper process; removed when it exits via `close`.
nonisolated(unsafe) var daemonSocketPath = ""
nonisolated(unsafe) var daemonSession = "default"

struct CmdError: Error {
    var code: String
    var message: String
    /// True when the command had no effect, so running it again (after fixing the cause) is safe.
    var retrySafe: Bool = true
    var extra: [String: Any] = [:]

    var dict: [String: Any] {
        var d: [String: Any] = ["code": code, "message": message, "retry_safe": retrySafe]
        for (k, v) in extra { d[k] = v }
        return d
    }
}

enum NavResult {
    case finished
    case failed(String)
    case timeout
}

@MainActor
final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let window: NSWindow
    let webView: WatchWebView
    private(set) var watch: WatchWindow!

    private var events: [[String: Any]] = []
    private var navInFlight = false
    private var navCount = 0
    private var lastStatus: Int?
    private var navWaiters: [(id: Int, cont: CheckedContinuation<NavResult, Never>)] = []
    private var nextWaiterId = 0
    private var busy = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var lastActivity = Date()

    static let viewport = NSSize(width: 1280, height: 800)

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()  // temporary profile
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let ucc = WKUserContentController()
        config.userContentController = ucc
        let frame = NSRect(origin: .zero, size: Browser.viewport)
        webView = WatchWebView(frame: frame, configuration: config)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()

        ucc.addUserScript(WKUserScript(source: pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(self, name: "ab")
        webView.navigationDelegate = self
        webView.uiDelegate = self

        // Windowless by default; `watch on` shows the same page on screen.
        watch = WatchWindow(window: window, webView: webView, session: daemonSession)
    }

    // MARK: events

    private func log(_ type: String, _ fields: [String: Any] = [:]) {
        var e = fields
        e["type"] = type
        e["t"] = Int(Date().timeIntervalSince1970 * 1000)
        events.append(e)
    }

    private func drainEvents() -> [[String: Any]] {
        let e = events
        events = []
        return e
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard var body = message.body as? [String: Any], let type = body.removeValue(forKey: "type") as? String else { return }
        log(type, body.compactMapValues { $0 is NSNull ? nil : $0 })
    }

    // MARK: navigation delegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame ?? true, let u = navigationAction.request.url {
            log("navigation", ["url": u.absoluteString])
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            lastStatus = http.statusCode
        }
        if navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType {
            log("download-blocked", ["url": navigationResponse.response.url?.absoluteString ?? "",
                                     "mime": navigationResponse.response.mimeType ?? ""])
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navInFlight = true
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        log("redirect", ["url": webView.url?.absoluteString ?? ""])
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navCount += 1
        log("load", ["url": webView.url?.absoluteString ?? ""])
        finishNavigation(.finished)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("navigation-failed", ["error": error.localizedDescription])
        finishNavigation(.failed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("navigation-failed", ["error": error.localizedDescription])
        finishNavigation(.failed(error.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("page-crashed")
        finishNavigation(.failed("web content process terminated"))
    }

    // MARK: UI delegate (dialogs are auto-accepted and recorded)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        log("dialog", ["kind": "alert", "message": message])
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        log("dialog", ["kind": "confirm", "message": message, "accepted": true])
        completionHandler(true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        log("dialog", ["kind": "prompt", "message": prompt, "accepted": true])
        completionHandler(defaultText ?? "")
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Single-tab MVP: new-window requests load in the current page.
        if let u = navigationAction.request.url {
            log("popup-redirected", ["url": u.absoluteString])
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: navigation waiting

    private func finishNavigation(_ r: NavResult) {
        navInFlight = false
        let ws = navWaiters
        navWaiters = []
        for w in ws { w.cont.resume(returning: r) }
    }

    private func waitForNavigation(timeout: Double) async -> NavResult {
        if !navInFlight { return .finished }
        let id = nextWaiterId
        nextWaiterId += 1
        return await withCheckedContinuation { cont in
            navWaiters.append((id, cont))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let i = self.navWaiters.firstIndex(where: { $0.id == id }) {
                    self.navWaiters.remove(at: i).cont.resume(returning: .timeout)
                }
            }
        }
    }

    // MARK: command plumbing

    private func withLock<T>(_ body: () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { lockWaiters.append($0) }
        } else {
            busy = true
        }
        let r = await body()
        if lockWaiters.isEmpty { busy = false } else { lockWaiters.removeFirst().resume() }
        return r
    }

    func handleLine(_ line: String) async -> String {
        guard let req = parseJSON(line) else {
            return jsonString(["ok": false, "events": [],
                               "error": CmdError(code: "BAD_REQUEST", message: "request was not valid JSON").dict])
        }
        return jsonString(await handle(req))
    }

    private func handle(_ req: [String: Any]) async -> [String: Any] {
        // `watch` must work while a paused command holds the lock, and must not steal its events.
        if req["cmd"] as? String == "watch" { return await execute(req, drain: false) }
        return await withLock { await execute(req, drain: true) }
    }

    private func execute(_ req: [String: Any], drain: Bool) async -> [String: Any] {
        lastActivity = Date()
        let cmd = req["cmd"] as? String ?? ""
        let args = req["args"] as? [String: Any] ?? [:]
        func events() -> [[String: Any]] { drain ? drainEvents() : [] }
        // A human who paused / took over holds the page; agent commands wait.
        if drain && watch.paused && cmd != "close" {
            let t0 = Date()
            log("waiting-for-human")
            while watch.paused { try? await Task.sleep(nanoseconds: 100_000_000) }
            log("resumed", ["waited_ms": Int(Date().timeIntervalSince(t0) * 1000)])
        }
        let label = stepLabel(cmd, args)
        do {
            let result = try await run(cmd, args)
            if drain { watch.step("\(label) → \(stepSummary(result))", ok: true) }
            return ["ok": true, "result": result, "events": events()]
        } catch let e as CmdError {
            if drain { watch.step("\(label) ✗ \(e.code): \(e.message)", ok: false) }
            return ["ok": false, "error": e.dict, "events": events()]
        } catch {
            if drain { watch.step("\(label) ✗ INTERNAL: \(error)", ok: false) }
            return ["ok": false, "error": CmdError(code: "INTERNAL", message: "\(error)", retrySafe: false).dict,
                    "events": events()]
        }
    }

    private func stepLabel(_ cmd: String, _ args: [String: Any]) -> String {
        var parts = [cmd]
        for k in ["url", "ref", "mode", "selector", "gone", "text", "path"] {
            if let v = args[k] as? String, !v.isEmpty { parts.append(v.count > 60 ? String(v.prefix(59)) + "…" : v) }
        }
        return parts.joined(separator: " ")
    }

    private func stepSummary(_ r: [String: Any]) -> String {
        if let o = r["outcome"] as? String { return o }
        if let t = r["title"] as? String, let u = r["url"] as? String { return "\(t) (\(u))" }
        if let n = r["refs"] as? Int { return "\(n) refs" }
        if let p = r["path"] as? String { return p }
        return "ok"
    }

    private func str(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String else {
            throw CmdError(code: "USAGE", message: "missing argument: \(key)")
        }
        return v
    }

    private func run(_ cmd: String, _ args: [String: Any]) async throws -> [String: Any] {
        switch cmd {
        case "open": return try await open(args)
        case "snapshot": return try await snapshot()
        case "click": return try await act("click", ref: try str(args, "ref"), arg: "")
        case "fill": return try await act("fill", ref: try str(args, "ref"), arg: try str(args, "text"))
        case "submit": return try await act("submit", ref: try str(args, "ref"), arg: "")
        case "wait": return try await wait(args)
        case "screenshot": return try await screenshot(try str(args, "path"))
        case "watch": return try watchCommand(args)
        case "close":
            let sock = daemonSocketPath
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if !sock.isEmpty { unlink(sock) }
                exit(0)
            }
            return ["closed": true]
        default:
            throw CmdError(code: "USAGE", message: "unknown command \"\(cmd)\"")
        }
    }

    // MARK: JS bridge

    private func js(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        do {
            return try await webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
        } catch {
            throw CmdError(code: "EVAL_FAILED", message: error.localizedDescription)
        }
    }

    private func pathOf(_ s: String?) -> String {
        guard let s, let u = URL(string: s) else { return s ?? "" }
        var p = u.isFileURL ? u.lastPathComponent : u.path
        if p.isEmpty { p = "/" }
        if let q = u.query { p += "?" + q }
        return p
    }

    // MARK: commands

    private func watchCommand(_ args: [String: Any]) throws -> [String: Any] {
        switch args["mode"] as? String ?? "on" {
        case "on": watch.show()
        case "off": watch.hide()
        case "pause": watch.setPaused(true)
        case "resume": watch.setPaused(false)
        case "status": break
        default: throw CmdError(code: "USAGE", message: "watch takes on|off|pause|resume|status")
        }
        return ["watching": watch.visible, "paused": watch.paused]
    }

    private func open(_ args: [String: Any]) async throws -> [String: Any] {
        var raw = try str(args, "url").trimmingCharacters(in: .whitespaces)
        if !raw.contains("://") && !raw.hasPrefix("about:") && !raw.hasPrefix("data:") {
            raw = raw.hasPrefix("/") ? "file://" + raw : "https://" + raw
        }
        guard let url = URL(string: raw) else { throw CmdError(code: "BAD_URL", message: "not a valid URL: \(raw)") }
        let timeout = (args["timeout"] as? Double) ?? 30
        lastStatus = nil
        navInFlight = true
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        switch await waitForNavigation(timeout: timeout) {
        case .finished: break
        case .failed(let m): throw CmdError(code: "NAVIGATION_FAILED", message: m)
        case .timeout:
            throw CmdError(code: "TIMEOUT", message: "page did not finish loading within \(Int(timeout))s")
        }
        var out: [String: Any] = ["url": webView.url?.absoluteString ?? raw]
        out["title"] = (try? await js("return document.title") as? String) ?? ""
        if let s = lastStatus { out["status"] = s }
        return out
    }

    private func snapshot() async throws -> [String: Any] {
        if navInFlight { _ = await waitForNavigation(timeout: 15) }
        guard let r = try await js("return window.__abApi.snapshot()") as? [String: Any] else {
            throw CmdError(code: "SNAPSHOT_FAILED", message: "no page is open; run open <url> first")
        }
        return r
    }

    private func act(_ op: String, ref: String, arg: String) async throws -> [String: Any] {
        if navInFlight { _ = await waitForNavigation(timeout: 15) }
        let beforeURL = webView.url?.absoluteString
        let beforeNav = navCount
        let beforeMut = (try await js("return window.__abApi.mut") as? NSNumber)?.intValue ?? 0
        let mark = events.count

        guard var res = try await js("return window.__abApi.act(op, ref, arg, watch)",
                                  ["op": op, "ref": ref, "arg": arg, "watch": watch.visible])
            as? [String: Any]
        else { throw CmdError(code: "ACTION_FAILED", message: "no result from page", retrySafe: false) }

        if res["ok"] as? Bool != true {
            var extra = res
            for k in ["ok", "code", "message", "retry_safe"] { extra.removeValue(forKey: k) }
            throw CmdError(code: res["code"] as? String ?? "ACTION_FAILED",
                           message: res["message"] as? String ?? "action failed",
                           retrySafe: res["retry_safe"] as? Bool ?? false, extra: extra)
        }
        res.removeValue(forKey: "ok")

        // Let a navigation start (if any) and finish before reporting the outcome.
        var waited = 0
        while !navInFlight && navCount == beforeNav && waited < 250 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            waited += 25
        }
        if navInFlight { _ = await waitForNavigation(timeout: 15) }
        try? await Task.sleep(nanoseconds: 30_000_000)  // let trailing page events arrive

        let mine = events[min(mark, events.count)...]
        let afterURL = webView.url?.absoluteString
        let outcome: String
        if let d = mine.last(where: { $0["type"] as? String == "dialog" }) {
            outcome = "dialog: \(d["kind"] as? String ?? "alert")(\"\(d["message"] as? String ?? "")\")"
        } else if let f = mine.last(where: { $0["type"] as? String == "navigation-failed" }) {
            outcome = "navigation-failed: \(f["error"] as? String ?? "")"
        } else if navCount != beforeNav {
            outcome = afterURL == beforeURL ? "reloaded: \(pathOf(afterURL))" : "navigated: \(pathOf(afterURL))"
        } else if afterURL != beforeURL {
            outcome = "navigated (client-side): \(pathOf(afterURL))"
        } else if mine.contains(where: { $0["type"] as? String == "form-submit" }) {
            outcome = "submitted (no navigation)"
        } else {
            let afterMut = (try? await js("return window.__abApi.mut") as? NSNumber)?.intValue ?? beforeMut
            outcome = afterMut != beforeMut ? "dom-changed" : "no-op"
        }
        res["outcome"] = outcome
        res["url"] = afterURL ?? ""
        return res
    }

    private func wait(_ args: [String: Any]) async throws -> [String: Any] {
        let timeout = (args["timeout"] as? Double) ?? 10_000
        let start = Date()
        func elapsed() -> Double { Date().timeIntervalSince(start) * 1000 }

        if let ms = args["ms"] as? Double {
            try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
        }
        let wantLoad = args["load"] as? Bool ?? false
        let wantIdle = args["idle"] as? Bool ?? false
        let sel = args["selector"] as? String ?? ""
        let gone = args["gone"] as? String ?? ""
        let text = args["text"] as? String ?? ""
        let urlSub = args["url"] as? String ?? ""
        if !wantLoad && !wantIdle && sel.isEmpty && gone.isEmpty && text.isEmpty && urlSub.isEmpty {
            return ["waited_ms": Int(elapsed())]
        }

        var lastMut = -1
        var stable = 0
        var unmet: [String] = []
        while elapsed() < timeout {
            unmet = []
            var state: [String: Any] = [:]
            if let s = try? await js("return window.__abApi.waitState(sel, gone, text, urlSub)",
                                     ["sel": sel, "gone": gone, "text": text, "urlSub": urlSub]) as? [String: Any] {
                state = s
            }
            if let bad = state["bad_selector"] as? String {
                throw CmdError(code: "BAD_SELECTOR", message: bad)
            }
            if wantLoad && !(navInFlight == false && state["ready"] as? Bool == true) { unmet.append("load") }
            if wantIdle {
                let mut = (state["mut"] as? NSNumber)?.intValue ?? -2
                let pending = (state["pending"] as? NSNumber)?.intValue ?? 1
                if pending == 0 && mut == lastMut && !navInFlight { stable += 1 } else { stable = 0 }
                lastMut = mut
                if stable < 5 { unmet.append("idle") }
            }
            if !sel.isEmpty && state["selector"] as? Bool != true { unmet.append("selector \(sel)") }
            if !gone.isEmpty && state["gone"] as? Bool != true { unmet.append("gone \(gone)") }
            if !text.isEmpty && state["text"] as? Bool != true { unmet.append("text \"\(text)\"") }
            if !urlSub.isEmpty && state["url"] as? Bool != true { unmet.append("url contains \"\(urlSub)\"") }
            if unmet.isEmpty {
                return ["waited_ms": Int(elapsed()), "url": webView.url?.absoluteString ?? ""]
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CmdError(code: "TIMEOUT", message: "timed out after \(Int(timeout))ms waiting for: \(unmet.joined(separator: ", "))")
    }

    private func screenshot(_ path: String) async throws -> [String: Any] {
        if navInFlight { _ = await waitForNavigation(timeout: 15) }
        let image: NSImage
        do {
            image = try await webView.takeSnapshot(configuration: WKSnapshotConfiguration())
        } catch {
            throw CmdError(code: "SCREENSHOT_FAILED", message: error.localizedDescription)
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw CmdError(code: "SCREENSHOT_FAILED", message: "could not encode PNG") }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            throw CmdError(code: "SCREENSHOT_FAILED", message: "could not write \(path): \(error.localizedDescription)")
        }
        return ["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh]
    }
}
