import AppKit
import CryptoKit
import UniformTypeIdentifiers
import WebKit

/// Socket file owned by this helper process; removed when it exits via `close`.
nonisolated(unsafe) var daemonSocketPath = ""
nonisolated(unsafe) var daemonSession = "default"
/// nil = temporary (in-memory) profile; otherwise the name of a persistent profile.
nonisolated(unsafe) var daemonProfile: String? = nil

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

final class DownloadInfo {
    let id: Int
    var url: String
    var name = ""
    var path = ""
    var state = "downloading"  // downloading | done | failed
    var bytes = 0
    var error: String?
    init(id: Int, url: String) { self.id = id; self.url = url }

    var dict: [String: Any] {
        var d: [String: Any] = ["id": id, "url": url, "name": name, "path": path, "state": state, "bytes": bytes]
        if let error { d["error"] = error }
        return d
    }
}

// MARK: - Tab

/// One page: a web view plus its own navigation state. Delegates live here so each tab tracks
/// its own loads.
@MainActor
final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: String
    let webView: WatchWebView
    unowned let browser: Browser
    var navInFlight = false
    var navCount = 0
    var lastStatus: Int?
    private var dlSeqAtStart = 0
    private var navWaiters: [(id: Int, cont: CheckedContinuation<NavResult, Never>)] = []
    private var nextWaiterId = 0

    init(id: String, configuration: WKWebViewConfiguration, browser: Browser) {
        self.id = id
        self.browser = browser
        webView = WatchWebView(frame: NSRect(origin: .zero, size: Browser.viewport), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    // MARK: navigation delegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if navigationAction.targetFrame?.isMainFrame ?? true, let u = navigationAction.request.url {
            browser.log("navigation", ["url": u.absoluteString], tab: self)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame else { return decisionHandler(.allow) }
        let http = navigationResponse.response as? HTTPURLResponse
        if let http { lastStatus = http.statusCode }
        let attachment = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        decisionHandler(attachment || !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        browser.adopt(download, from: self)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        browser.adopt(download, from: self)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navInFlight = true
        dlSeqAtStart = browser.downloadSeq
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        browser.log("redirect", ["url": webView.url?.absoluteString ?? ""], tab: self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navCount += 1
        browser.log("load", ["url": webView.url?.absoluteString ?? ""], tab: self)
        finishNavigation(.finished)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        let ns = error as NSError
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 {
            // "Frame load interrupted": what WebKit reports when a navigation turned into a download.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                if self.browser.downloadSeq != self.dlSeqAtStart { self.finishNavigation(.finished) }
                else { self.reportFailure(error) }
            }
            return
        }
        reportFailure(error)
    }

    private func reportFailure(_ error: Error) {
        browser.log("navigation-failed", ["error": error.localizedDescription], tab: self)
        finishNavigation(.failed(error.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        browser.log("page-crashed", tab: self)
        finishNavigation(.failed("web content process terminated"))
    }

    // MARK: UI delegate (dialogs are auto-accepted and recorded)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        browser.log("dialog", ["kind": "alert", "message": message], tab: self)
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        browser.log("dialog", ["kind": "confirm", "message": message, "accepted": true], tab: self)
        completionHandler(true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        browser.log("dialog", ["kind": "prompt", "message": prompt, "accepted": true], tab: self)
        completionHandler(defaultText ?? "")
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        // There is no human to pick a file; agents use `upload <ref> <path>` on the file input instead.
        browser.log("file-chooser-blocked", ["hint": "use upload <ref> <path> on the input[type=file]"], tab: self)
        completionHandler(nil)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let tab = browser.openTab(configuration: configuration)
        browser.log("tab-opened", ["new_tab": tab.id, "url": navigationAction.request.url?.absoluteString ?? ""], tab: self)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser.tabClosedByPage(self)
    }

    // MARK: navigation waiting

    func finishNavigation(_ r: NavResult) {
        navInFlight = false
        let ws = navWaiters
        navWaiters = []
        for w in ws { w.cont.resume(returning: r) }
    }

    func waitForNavigation(timeout: Double) async -> NavResult {
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
}

// MARK: - Browser

@MainActor
final class Browser: NSObject, WKScriptMessageHandler, WKDownloadDelegate {
    let window: NSWindow
    private(set) var watch: WatchWindow!
    private let configuration: WKWebViewConfiguration
    private(set) var tabs: [Tab] = []
    private(set) var current: Tab!
    private var nextTabId = 1
    private var snapCounter = 0

    private var events: [[String: Any]] = []
    private var busy = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var lastActivity = Date()

    private(set) var downloads: [DownloadInfo] = []
    private(set) var downloadSeq = 0
    private var downloadByObject: [ObjectIdentifier: DownloadInfo] = [:]

    static let viewport = NSSize(width: 1280, height: 800)

    /// Stable store id derived from the profile name, so the same name always reopens the same data.
    private static func storeID(for profile: String) -> UUID {
        var b = Array(SHA256.hash(data: Data("agent-browser-profile:\(profile)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    override init() {
        let config = WKWebViewConfiguration()
        if let p = daemonProfile {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Browser.storeID(for: p))
        } else {
            config.websiteDataStore = .nonPersistent()  // temporary profile
        }
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let ucc = WKUserContentController()
        config.userContentController = ucc
        configuration = config
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Browser.viewport), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        super.init()

        ucc.addUserScript(WKUserScript(source: pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(self, name: "ab")

        let first = openTab(configuration: config, attach: false)
        watch = WatchWindow(window: window, webView: first.webView, session: daemonSession)
    }

    // MARK: tabs

    /// Creates a tab and makes it current. `configuration` must be the one WebKit passes for popups.
    @discardableResult
    func openTab(configuration config: WKWebViewConfiguration? = nil, attach: Bool = true) -> Tab {
        let tab = Tab(id: "t\(nextTabId)", configuration: config ?? configuration.copy() as! WKWebViewConfiguration, browser: self)
        nextTabId += 1
        tabs.append(tab)
        current = tab
        if attach { watch.attach(tab.webView) }
        return tab
    }

    private func switchTo(_ tab: Tab) {
        current = tab
        watch.attach(tab.webView)
    }

    func tabClosedByPage(_ tab: Tab) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        removeTab(at: i)
    }

    private func removeTab(at i: Int) {
        let t = tabs.remove(at: i)
        t.webView.removeFromSuperview()
        t.webView.navigationDelegate = nil
        t.webView.uiDelegate = nil
        if current === t { switchTo(tabs[min(i, tabs.count - 1)]) }
    }

    private func tab(_ id: String) throws -> Tab {
        guard let t = tabs.first(where: { $0.id == id }) else {
            throw CmdError(code: "NO_SUCH_TAB", message: "no tab \"\(id)\"; open tabs: \(tabs.map(\.id).joined(separator: ", "))")
        }
        return t
    }

    // Per-tab state used by the commands below always refers to the current tab.
    private var webView: WatchWebView { current.webView }
    private var navInFlight: Bool { current.navInFlight }
    private var navCount: Int { current.navCount }
    private func waitForNavigation(timeout: Double) async -> NavResult { await current.waitForNavigation(timeout: timeout) }

    // MARK: events

    func log(_ type: String, _ fields: [String: Any] = [:], tab: Tab? = nil) {
        var e = fields
        e["type"] = type
        e["t"] = Int(Date().timeIntervalSince1970 * 1000)
        if let tab, tabs.count > 1 { e["tab"] = tab.id }
        events.append(e)
    }

    private func drainEvents() -> [[String: Any]] {
        let e = events
        events = []
        return e
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard var body = message.body as? [String: Any], let type = body.removeValue(forKey: "type") as? String else { return }
        let origin = tabs.first(where: { $0.webView === message.webView })
        log(type, body.compactMapValues { $0 is NSNull ? nil : $0 }, tab: origin)
    }

    // MARK: downloads

    private static var downloadDir: URL {
        let u = URL(fileURLWithPath: NSHomeDirectory() + "/.agent-browser/downloads/\(sanitizeSession(daemonSession))")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func adopt(_ download: WKDownload, from tab: Tab) {
        downloadSeq += 1
        let info = DownloadInfo(id: downloadSeq, url: download.originalRequest?.url?.absoluteString ?? "")
        downloads.append(info)
        downloadByObject[ObjectIdentifier(download)] = info
        download.delegate = self
        log("download-started", ["url": info.url], tab: tab)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        guard let info = downloadByObject[ObjectIdentifier(download)] else { return completionHandler(nil) }
        var name = (suggestedFilename as NSString).lastPathComponent
        if name.isEmpty || name == "." || name == ".." { name = "download" }
        let dir = Browser.downloadDir
        var dest = dir.appendingPathComponent(name)
        var n = 1
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            n += 1
        }
        info.name = dest.lastPathComponent
        info.path = dest.path
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let info = downloadByObject[ObjectIdentifier(download)] else { return }
        info.state = "done"
        info.bytes = ((try? FileManager.default.attributesOfItem(atPath: info.path)[.size]) as? NSNumber)?.intValue ?? 0
        log("download-finished", ["name": info.name, "path": info.path, "bytes": info.bytes])
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let info = downloadByObject[ObjectIdentifier(download)] else { return }
        info.state = "failed"
        info.error = error.localizedDescription
        log("download-failed", ["url": info.url, "error": error.localizedDescription])
    }

    private var downloadsInFlight: Int { downloads.filter { $0.state == "downloading" }.count }

    private func waitForDownloads(timeout: Double) async {
        let start = Date()
        while downloadsInFlight > 0 && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 50_000_000)
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

        if let want = req["profile"] as? String, want != (daemonProfile ?? "") {
            let have = daemonProfile.map { "profile \"\($0)\"" } ?? "a temporary profile"
            return ["ok": false, "events": [], "error": CmdError(
                code: "PROFILE_MISMATCH",
                message: "session \"\(daemonSession)\" is already running with \(have); run close first to switch to profile \"\(want)\"").dict]
        }
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
        for k in ["action", "url", "ref", "id", "mode", "selector", "gone", "text", "path"] {
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
        case "upload": return try await upload(args)
        case "wait": return try await wait(args)
        case "screenshot": return try await screenshot(try str(args, "path"))
        case "tabs": return try await tabList()
        case "tab": return try await tabCommand(args)
        case "downloads": return ["downloads": downloads.map(\.dict), "dir": Browser.downloadDir.path]
        case "cookies": return try await cookies(args)
        case "storage": return try await storage(args)
        case "status": return await status()
        case "watch": return try watchCommand(args)
        case "close":
            let sock = daemonSocketPath
            // Persistent profiles get a moment to flush cookies/storage to disk.
            let delay = daemonProfile == nil ? 0.1 : 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
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

    private func status() async -> [String: Any] {
        ["session": daemonSession, "profile": daemonProfile ?? NSNull(), "persistent": daemonProfile != nil,
         "tabs": tabs.count, "current_tab": current.id, "watching": watch.visible, "paused": watch.paused,
         "downloads_dir": Browser.downloadDir.path] as [String: Any]
    }

    private func open(_ args: [String: Any]) async throws -> [String: Any] {
        var raw = try str(args, "url").trimmingCharacters(in: .whitespaces)
        if !raw.contains("://") && !raw.hasPrefix("about:") && !raw.hasPrefix("data:") {
            raw = raw.hasPrefix("/") ? "file://" + raw : "https://" + raw
        }
        guard let url = URL(string: raw) else { throw CmdError(code: "BAD_URL", message: "not a valid URL: \(raw)") }
        let timeout = (args["timeout"] as? Double) ?? 30
        let dlBefore = downloadSeq
        current.lastStatus = nil
        current.navInFlight = true
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
        if downloadSeq != dlBefore {  // the URL was a file download rather than a page
            await waitForDownloads(timeout: 120)
            let d = downloads.last
            return ["url": raw, "download": d?.dict ?? [:], "outcome": d.map { "download: \($0.name) (\($0.bytes) bytes)" } ?? "download"]
        }
        var out: [String: Any] = ["url": webView.url?.absoluteString ?? raw, "tab": current.id]
        out["title"] = (try? await js("return document.title") as? String) ?? ""
        if let s = current.lastStatus { out["status"] = s }
        return out
    }

    private func snapshot() async throws -> [String: Any] {
        if navInFlight { _ = await waitForNavigation(timeout: 15) }
        // Snapshot ids are unique across tabs, so a ref from another tab can never match this one.
        snapCounter += 1
        guard var r = try await js("return window.__abApi.snapshot(id)", ["id": snapCounter]) as? [String: Any] else {
            throw CmdError(code: "SNAPSHOT_FAILED", message: "no page is open; run open <url> first")
        }
        r["tab"] = current.id
        return r
    }

    private func act(_ op: String, ref: String, arg: String) async throws -> [String: Any] {
        if navInFlight { _ = await waitForNavigation(timeout: 15) }
        let beforeURL = webView.url?.absoluteString
        let beforeNav = navCount
        let beforeDl = downloadSeq
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

        // Let a navigation or download start (if any) and finish before reporting the outcome.
        var waited = 0
        while !navInFlight && navCount == beforeNav && downloadSeq == beforeDl && waited < 250 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            waited += 25
        }
        if navInFlight { _ = await waitForNavigation(timeout: 15) }
        if downloadSeq != beforeDl { await waitForDownloads(timeout: 120) }
        try? await Task.sleep(nanoseconds: 30_000_000)  // let trailing page events arrive

        let mine = events[min(mark, events.count)...]
        let afterURL = webView.url?.absoluteString
        let outcome: String
        if downloadSeq != beforeDl, let d = downloads.last {
            outcome = d.state == "done" ? "download: \(d.name) (\(d.bytes) bytes) -> \(d.path)"
                                        : "download-failed: \(d.error ?? "unknown error")"
            res["download"] = d.dict
        } else if let d = mine.last(where: { $0["type"] as? String == "dialog" }) {
            outcome = "dialog: \(d["kind"] as? String ?? "alert")(\"\(d["message"] as? String ?? "")\")"
        } else if let f = mine.last(where: { $0["type"] as? String == "navigation-failed" }) {
            outcome = "navigation-failed: \(f["error"] as? String ?? "")"
        } else if let t = mine.last(where: { $0["type"] as? String == "tab-opened" }) {
            outcome = "opened tab \(t["new_tab"] as? String ?? "?") (now current): \(pathOf(t["url"] as? String))"
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

    // MARK: uploads

    private func upload(_ args: [String: Any]) async throws -> [String: Any] {
        let ref = try str(args, "ref")
        guard let paths = args["paths"] as? [String], !paths.isEmpty else {
            throw CmdError(code: "USAGE", message: "upload needs at least one file path")
        }
        var files: [[String: Any]] = []
        var total = 0
        for p in paths {
            let path = (p as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else {
                throw CmdError(code: "BAD_PATH", message: "upload paths must be absolute: \(p)")
            }
            guard let data = FileManager.default.contents(atPath: path) else {
                throw CmdError(code: "FILE_NOT_FOUND", message: "cannot read \(path)")
            }
            total += data.count
            if total > 25 * 1024 * 1024 {
                throw CmdError(code: "FILE_TOO_LARGE", message: "uploads are limited to 25 MB in total")
            }
            let name = (path as NSString).lastPathComponent
            let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            files.append(["name": name, "type": mime, "b64": data.base64EncodedString()])
        }
        let json = String(data: try JSONSerialization.data(withJSONObject: files), encoding: .utf8) ?? "[]"
        return try await act("upload", ref: ref, arg: json)
    }

    // MARK: wait

    private func wait(_ args: [String: Any]) async throws -> [String: Any] {
        let timeout = (args["timeout"] as? Double) ?? 10_000
        let start = Date()
        func elapsed() -> Double { Date().timeIntervalSince(start) * 1000 }

        if let ms = args["ms"] as? Double {
            try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
        }
        let wantLoad = args["load"] as? Bool ?? false
        let wantIdle = args["idle"] as? Bool ?? false
        let wantDownload = args["download"] as? Bool ?? false
        let sel = args["selector"] as? String ?? ""
        let gone = args["gone"] as? String ?? ""
        let text = args["text"] as? String ?? ""
        let urlSub = args["url"] as? String ?? ""
        if !wantLoad && !wantIdle && !wantDownload && sel.isEmpty && gone.isEmpty && text.isEmpty && urlSub.isEmpty {
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
            if wantDownload && (downloadsInFlight > 0 || !downloads.contains { $0.state == "done" }) { unmet.append("download") }
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

    // MARK: tabs

    private func tabList() async throws -> [String: Any] {
        let list: [[String: Any]] = tabs.map { t in
            ["id": t.id, "url": t.webView.url?.absoluteString ?? "", "title": t.webView.title ?? "", "active": t === current]
        }
        return ["tabs": list, "current": current.id]
    }

    private func tabCommand(_ args: [String: Any]) async throws -> [String: Any] {
        switch args["action"] as? String ?? "" {
        case "new":
            let t = openTab()
            if let u = args["url"] as? String, !u.isEmpty {
                var a: [String: Any] = ["url": u]
                if let to = args["timeout"] { a["timeout"] = to }
                var r = try await open(a)
                r["tab"] = t.id
                return r
            }
            return ["tab": t.id, "current": t.id]
        case "switch":
            let t = try tab(try str(args, "id"))
            switchTo(t)
            return ["current": t.id, "url": t.webView.url?.absoluteString ?? "", "title": t.webView.title ?? ""]
        case "close":
            let t = try args["id"].flatMap { $0 as? String }.map { try tab($0) } ?? current!
            guard tabs.count > 1, let i = tabs.firstIndex(where: { $0 === t }) else {
                throw CmdError(code: "LAST_TAB", message: "cannot close the only tab; use close to stop the browser")
            }
            removeTab(at: i)
            return ["closed": t.id, "current": current.id]
        default:
            throw CmdError(code: "USAGE", message: "tab takes new [url] | switch <id> | close [id]")
        }
    }

    // MARK: cookies and storage

    private func cookieDict(_ c: HTTPCookie) -> [String: Any] {
        var d: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path,
                                "secure": c.isSecure, "httpOnly": c.isHTTPOnly]
        if let e = c.expiresDate { d["expires"] = e.timeIntervalSince1970 }
        if let s = c.sameSitePolicy { d["sameSite"] = s.rawValue }
        return d
    }

    private func makeCookie(_ d: [String: Any]) -> HTTPCookie? {
        guard let name = d["name"] as? String, let value = d["value"] as? String, let domain = d["domain"] as? String else { return nil }
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: d["path"] as? String ?? "/"]
        if d["secure"] as? Bool == true { p[.secure] = "TRUE" }
        if d["httpOnly"] as? Bool == true { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let e = (d["expires"] as? NSNumber)?.doubleValue { p[.expires] = Date(timeIntervalSince1970: e) }
        if let s = d["sameSite"] as? String { p[.sameSitePolicy] = s }
        return HTTPCookie(properties: p)
    }

    private func readJSONFile(_ path: String) throws -> Any {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw CmdError(code: "FILE_NOT_FOUND", message: "cannot read \(path)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw CmdError(code: "BAD_JSON", message: "\(path) is not valid JSON")
        }
        return obj
    }

    private func writeJSONFile(_ obj: Any, _ path: String) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            chmod(path, 0o600)  // cookies and tokens: owner only
        } catch {
            throw CmdError(code: "WRITE_FAILED", message: "could not write \(path): \(error.localizedDescription)")
        }
    }

    private func cookies(_ args: [String: Any]) async throws -> [String: Any] {
        let store = configuration.websiteDataStore.httpCookieStore
        let path = args["path"] as? String ?? ""
        switch args["action"] as? String ?? "" {
        case "export":
            let all = await store.allCookies().map(cookieDict).sorted { ($0["domain"] as? String ?? "") < ($1["domain"] as? String ?? "") }
            if path.isEmpty { return ["count": all.count, "cookies": all] }
            try writeJSONFile(all, path)
            return ["count": all.count, "path": path]
        case "import":
            guard !path.isEmpty else { throw CmdError(code: "USAGE", message: "cookies import needs a file path") }
            guard let list = try readJSONFile(path) as? [[String: Any]] else {
                throw CmdError(code: "BAD_JSON", message: "\(path) must contain a JSON array of cookie objects")
            }
            var n = 0, skipped = 0
            for d in list {
                if let c = makeCookie(d) { await store.setCookie(c); n += 1 } else { skipped += 1 }
            }
            return ["imported": n, "skipped": skipped]
        case "clear":
            let all = await store.allCookies()
            for c in all { await store.deleteCookie(c) }
            return ["cleared": all.count]
        default:
            throw CmdError(code: "USAGE", message: "cookies takes export [path] | import <path> | clear")
        }
    }

    /// localStorage / sessionStorage of the current page's origin.
    private func storage(_ args: [String: Any]) async throws -> [String: Any] {
        let path = args["path"] as? String ?? ""
        switch args["action"] as? String ?? "" {
        case "export":
            guard let r = try await js("""
                try { return { origin: location.origin, local: Object.fromEntries(Object.entries(localStorage)),
                               session: Object.fromEntries(Object.entries(sessionStorage)) }; }
                catch (e) { return { error: String(e) }; }
                """) as? [String: Any], r["error"] == nil else {
                throw CmdError(code: "STORAGE_UNAVAILABLE", message: "this page's origin does not allow web storage (open an http(s) page first)")
            }
            if path.isEmpty { return r }
            try writeJSONFile(r, path)
            return ["origin": r["origin"] ?? "", "path": path]
        case "import":
            guard !path.isEmpty else { throw CmdError(code: "USAGE", message: "storage import needs a file path") }
            guard let d = try readJSONFile(path) as? [String: Any] else {
                throw CmdError(code: "BAD_JSON", message: "\(path) must contain the object printed by storage export")
            }
            let r = try await js("""
                if (origin && origin !== location.origin) return { mismatch: location.origin };
                try {
                  for (const [k, v] of Object.entries(local || {})) localStorage.setItem(k, String(v));
                  for (const [k, v] of Object.entries(session || {})) sessionStorage.setItem(k, String(v));
                  return { local: Object.keys(local || {}).length, session: Object.keys(session || {}).length };
                } catch (e) { return { error: String(e) }; }
                """, ["origin": d["origin"] as? String ?? "", "local": d["local"] ?? [:], "session": d["session"] ?? [:]]) as? [String: Any] ?? [:]
            if let m = r["mismatch"] as? String {
                throw CmdError(code: "ORIGIN_MISMATCH", message: "file is for \(d["origin"] as? String ?? "?") but the current page is \(m); open the matching page first")
            }
            if r["error"] != nil { throw CmdError(code: "STORAGE_UNAVAILABLE", message: "this page's origin does not allow web storage") }
            return ["imported_local": r["local"] ?? 0, "imported_session": r["session"] ?? 0]
        default:
            throw CmdError(code: "USAGE", message: "storage takes export [path] | import <path>")
        }
    }
}
