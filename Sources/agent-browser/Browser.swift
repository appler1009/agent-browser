import AppKit
import CoreServices
import CryptoKit
import UniformTypeIdentifiers
import Vision
import WebKit

/// Per-request settings from the caller's environment (test overrides such as the dialog timeout or vault approval).
/// One host process serves many sessions, so these are carried with the request instead of read from the process.
enum SessionEnv {
    @TaskLocal static var values: [String: String] = [:]
    static func get(_ key: String) -> String? { values[key] ?? ProcessInfo.processInfo.environment[key] }
    static let forwarded = ["AGENT_BROWSER_DIALOG_TIMEOUT", "AGENT_BROWSER_VAULT_APPROVE"]
}

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
    var quarantined = false
    var blockedByPolicy = false
    init(id: Int, url: String) { self.id = id; self.url = url }

    var dict: [String: Any] {
        var d: [String: Any] = ["id": id, "url": url, "name": name, "path": path, "state": state, "bytes": bytes]
        if let error { d["error"] = error }
        if state == "done" { d["quarantined"] = quarantined }
        return d
    }
}

// MARK: - Tab

/// One page: a web view plus its own navigation state. Delegates live here so each tab tracks
/// its own loads.
@MainActor
final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: String
    /// Stable DevTools target id (32 hex chars, like Chrome's).
    let targetId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let webView: WatchWebView
    unowned let browser: Browser
    var committedCount = 0
    var lastFailure: String?
    var lastMime = ""
    var navInFlight = false
    /// May the next navigation go to a private address? True while the browser is on a local or private page
    /// (or the person typed a private address); false on the public internet.
    var chainPrivateOK = true
    var navCount = 0
    var lastStatus: Int?
    private var dlSeqAtStart = 0
    private var navWaiters: [(id: Int, cont: CheckedContinuation<NavResult, Never>)] = []
    private var nextWaiterId = 0

    init(id: String, configuration: WKWebViewConfiguration, browser: Browser) {
        self.id = id
        self.browser = browser
        webView = WatchWebView(frame: NSRect(origin: .zero, size: browser.viewport), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    // MARK: navigation delegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        let url = navigationAction.request.url
        let download = navigationAction.shouldPerformDownload
        let policy = browser.policy
        let privateOK = chainPrivateOK
        Task { @MainActor in
            if let url, let why = await navigationBlockReason(url, policy: policy, chainPrivateOK: privateOK, explicit: false) {
                browser.log("navigation-blocked", ["url": url.absoluteString, "reason": why, "main_frame": isMain], tab: self)
                if isMain && navInFlight { finishNavigation(.failed("navigation blocked: \(why)")) }
                decisionHandler(.cancel)
                return
            }
            if download { decisionHandler(.download); return }
            if isMain, let u = url { browser.log("navigation", ["url": u.absoluteString], tab: self) }
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame else { return decisionHandler(.allow) }
        let http = navigationResponse.response as? HTTPURLResponse
        if let http { lastStatus = http.statusCode }
        lastMime = navigationResponse.response.mimeType ?? ""
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
        lastFailure = nil
        dlSeqAtStart = browser.downloadSeq
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committedCount += 1
        if let u = webView.url, let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", let h = u.host {
            chainPrivateOK = cachedHostIsPrivate(h) ?? false
        } else {
            chainPrivateOK = true
        }
        browser.notify("commit", ["url": webView.url?.absoluteString ?? ""], tab: self)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        browser.log("redirect", ["url": webView.url?.absoluteString ?? ""], tab: self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navCount += 1
        browser.log("load", ["url": webView.url?.absoluteString ?? ""], tab: self)
        if browser.watch.visible, browser.current === self { Task { @MainActor in await browser.refreshFavicon() } }
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
        lastFailure = error.localizedDescription
        browser.log("navigation-failed", ["error": error.localizedDescription], tab: self)
        finishNavigation(.failed(error.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        browser.log("page-crashed", tab: self)
        finishNavigation(.failed("web content process terminated"))
    }

    // MARK: UI delegate (alert() is accepted and recorded; confirm() and prompt() follow the policy's `dialogs` setting)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        browser.log("dialog", ["kind": "alert", "message": message], tab: self)
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let host = frame.request.url?.host ?? ""
        Task { @MainActor in
            let r = await browser.decideDialog(kind: "confirm", message: message, defaultText: nil, host: host)
            browser.log("dialog", ["kind": "confirm", "message": message, "accepted": r.accepted, "answered_by": r.by], tab: self)
            completionHandler(r.accepted)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let host = frame.request.url?.host ?? ""
        Task { @MainActor in
            let r = await browser.decideDialog(kind: "prompt", message: prompt, defaultText: defaultText, host: host)
            browser.log("dialog", ["kind": "prompt", "message": prompt, "accepted": r.accepted, "answered_by": r.by], tab: self)
            completionHandler(r.accepted ? (r.text ?? defaultText ?? "") : nil)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        // There is no human to pick a file; agents use `upload <ref> <path>` on the file input instead.
        browser.log("file-chooser-blocked", ["hint": "use upload <ref> <path> on the input[type=file]"], tab: self)
        completionHandler(nil)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if browser.tabCount >= browser.policy.maxTabs {
            browser.log("popup-blocked", ["url": navigationAction.request.url?.absoluteString ?? "",
                                          "reason": "policy max_tabs (\(browser.policy.maxTabs)) reached"], tab: self)
            return nil
        }
        let tab = browser.openTab(configuration: configuration)
        tab.chainPrivateOK = chainPrivateOK
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
            // Weak: a sleeping timeout must not keep a closed tab (its page, data store and process pool) alive.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let self, let i = self.navWaiters.firstIndex(where: { $0.id == id }) {
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
    private let policyCache = PolicyCache()
    var policy: Policy { policyCache.current }
    var tabCount: Int { tabs.count }
    private(set) var current: Tab!
    private var nextTabId = 1
    private var snapCounter = 0

    private var events: [[String: Any]] = []
    private var busy = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var lastActivity = Date()
    func touch() { lastActivity = Date(); resumeMedia() }

    /// Idle sessions stop playing media (autoplaying video and audio keep the page, GPU and decoder busy for nothing).
    /// The next command resumes it. Pages keep their other state.
    private(set) var mediaSuspended = false
    func suspendMediaIfIdle(after seconds: Double) {
        guard !mediaSuspended, !watch.visible, Date().timeIntervalSince(lastActivity) > seconds else { return }
        mediaSuspended = true
        for t in tabs { t.webView.pauseAllMediaPlayback { }; t.webView.setAllMediaPlaybackSuspended(true) { } }
    }
    func resumeMedia() {
        guard mediaSuspended else { return }
        mediaSuspended = false
        for t in tabs { t.webView.setAllMediaPlaybackSuspended(false) { } }
    }

    /// DevTools shim hook: sees every logged event plus CDP-only notifications (commit, cdp:net, target-*).
    var cdpObserver: ((String, [String: Any], Tab?) -> Void)?
    private var cdp: CDP?
    var cookieStore: WKHTTPCookieStore { configuration.websiteDataStore.httpCookieStore }

    private(set) var downloads: [DownloadInfo] = []
    private(set) var downloadSeq = 0
    private var downloadByObject: [ObjectIdentifier: DownloadInfo] = [:]

    /// Page viewport in CSS pixels; changed by the `viewport` command.
    var viewport = NSSize(width: 1280, height: 800)
    /// Session name and persistent profile (nil = temporary, in-memory) of this browser.
    let session: String
    let profile: String?
    /// Called once the session has shut down (the host closes its socket and window).
    var onClose: (@MainActor () -> Void)?
    private var dialogTimeoutOverride: String?
    private var userAgent: String?
    private var blockRules: [(label: String, rule: [String: Any])] = []

    /// Stable store id derived from the profile name, so the same name always reopens the same data.
    static func storeID(for profile: String) -> UUID {
        var b = Array(SHA256.hash(data: Data("agent-browser-profile:\(profile)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    init(session: String, profile: String?) {
        self.session = session
        self.profile = profile
        let config = WKWebViewConfiguration()
        if let p = profile {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Browser.storeID(for: p))
        } else {
            config.websiteDataStore = .nonPersistent()  // temporary profile
        }
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"  // Safari-like, so sites serve normal pages
        let ucc = WKUserContentController()
        config.userContentController = ucc
        configuration = config
        window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 1280, height: 800)), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        super.init()

        ucc.addUserScript(WKUserScript(source: visibilityShim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(self, name: "ab")

        let first = openTab(configuration: config, attach: false)
        watch = WatchWindow(window: window, webView: first.webView, session: session, viewport: { [unowned self] in self.viewport })
        if cookieFile != nil { cookieRestore = Task { await restoreCookies() } }
    }

    // MARK: tabs

    /// Creates a tab and makes it current. `configuration` must be the one WebKit passes for popups.
    @discardableResult
    func openTab(configuration config: WKWebViewConfiguration? = nil, attach: Bool = true) -> Tab {
        let tab = Tab(id: "t\(nextTabId)", configuration: config ?? configuration.copy() as! WKWebViewConfiguration, browser: self)
        nextTabId += 1
        if let ua = userAgent { tab.webView.customUserAgent = ua }
        tabs.append(tab)
        current = tab
        if attach { watch.attach(tab.webView) }
        notify("target-created", [:], tab: tab)
        return tab
    }

    func activate(_ tab: Tab) { switchTo(tab) }

    /// Closes a tab; the only remaining tab is blanked instead (a session always has one page).
    func closeTab(_ t: Tab) {
        if tabs.count > 1, let i = tabs.firstIndex(where: { $0 === t }) { removeTab(at: i) }
        else { t.webView.load(URLRequest(url: URL(string: "about:blank")!)) }
    }

    /// Evaluates JS in a specific tab's page world (the CLI commands use `js`, which targets the current tab).
    func eval(on tab: Tab, _ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        do {
            return try await tab.webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
        } catch {
            throw CmdError(code: "EVAL_FAILED", message: error.localizedDescription)
        }
    }

    /// Scripts run at document start in every page (Page.addScriptToEvaluateOnNewDocument).
    func setInitScripts(_ sources: [String]) {
        let ucc = configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        for src in sources { ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
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
        notify("target-closed", [:], tab: tabs[i])
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
        if events.count > 2000 { events.removeFirst(events.count - 2000) }  // nobody is draining (CDP-only use)
        cdpObserver?(type, e, tab)
    }

    /// Reaches only DevTools clients, not the CLI's per-command event list.
    func notify(_ type: String, _ fields: [String: Any] = [:], tab: Tab? = nil) {
        cdpObserver?(type, fields, tab)
    }

    private func drainEvents() -> [[String: Any]] {
        let e = events
        events = []
        return e
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard var body = message.body as? [String: Any], let type = body.removeValue(forKey: "type") as? String else { return }
        let origin = tabs.first(where: { $0.webView === message.webView })
        let fields = body.compactMapValues { $0 is NSNull ? nil : $0 }
        if type.hasPrefix("cdp:") { notify(type, fields, tab: origin) } else { log(type, fields, tab: origin) }
    }

    // MARK: downloads

    /// Where downloads are saved; created only when a download actually happens.
    private var downloadDir: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.agent-browser/downloads/\(sanitizeSession(session))")
    }

    func adopt(_ download: WKDownload, from tab: Tab) {
        downloadSeq += 1
        let info = DownloadInfo(id: downloadSeq, url: download.originalRequest?.url?.absoluteString ?? "")
        downloads.append(info)
        downloadByObject[ObjectIdentifier(download)] = info
        download.delegate = self
        if downloads.count > policy.maxDownloads {
            stopDownload(download, info, "policy max_downloads (\(policy.maxDownloads)) per session reached")
            return
        }
        log("download-started", ["url": info.url], tab: tab)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        guard let info = downloadByObject[ObjectIdentifier(download)] else { return completionHandler(nil) }
        if info.blockedByPolicy { return completionHandler(nil) }  // cancelled in adopt(); WebKit may still ask where to save
        let capMB = policy.maxDownloadMB, cap = Int64(capMB) * 1_048_576
        if response.expectedContentLength > cap {
            info.blockedByPolicy = true
            info.state = "failed"
            info.error = "download blocked: \(response.expectedContentLength / 1_048_576) MB is over policy max_download_mb (\(capMB))"
            log("download-blocked", ["url": info.url, "reason": info.error ?? ""])
            completionHandler(nil)
            return
        }
        var name = (suggestedFilename as NSString).lastPathComponent
        if name.isEmpty || name == "." || name == ".." { name = "download" }
        let dir = downloadDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        // A server may not announce the size: watch what arrives and stop at the cap.
        Task { @MainActor in
            while info.state == "downloading" {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if download.progress.completedUnitCount > cap {
                    self.stopDownload(download, info, "over policy max_download_mb (\(capMB) MB)")
                    break
                }
            }
        }
    }

    /// Cancels a download for a policy reason and keeps no partial file.
    private func stopDownload(_ download: WKDownload, _ info: DownloadInfo, _ reason: String) {
        info.blockedByPolicy = true
        info.state = "failed"
        info.error = "download blocked: \(reason)"
        log("download-blocked", ["url": info.url, "reason": reason])
        download.cancel { _ in }
        if !info.path.isEmpty { try? FileManager.default.removeItem(atPath: info.path) }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let info = downloadByObject[ObjectIdentifier(download)] else { return }
        info.state = "done"
        info.bytes = ((try? FileManager.default.attributesOfItem(atPath: info.path)[.size]) as? NSNumber)?.intValue ?? 0
        info.quarantined = markQuarantined(info.path, from: info.url)
        log("download-finished", ["name": info.name, "path": info.path, "bytes": info.bytes])
    }

    /// Makes sure a downloaded file carries the macOS quarantine flag, so Gatekeeper checks it before it is opened.
    private func markQuarantined(_ path: String, from url: String) -> Bool {
        var u = URL(fileURLWithPath: path)
        if (try? u.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties != nil { return true }
        var v = URLResourceValues()
        v.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
                                  kLSQuarantineAgentNameKey as String: "agent-browser",
                                  kLSQuarantineDataURLKey as String: url]
        do { try u.setResourceValues(v); return true } catch { return false }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let info = downloadByObject[ObjectIdentifier(download)] else { return }
        if info.blockedByPolicy { return }  // already reported with the policy reason
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
        let env = (req["env"] as? [String: String] ?? [:]).filter { SessionEnv.forwarded.contains($0.key) }
        // Dialogs are answered from WebKit callbacks, outside the command's task, so this one is remembered per session.
        if let t = env["AGENT_BROWSER_DIALOG_TIMEOUT"] { dialogTimeoutOverride = t }
        let reply = await SessionEnv.$values.withValue(env) { await handle(req) }
        return jsonString(redactor.scrub(reply) as? [String: Any] ?? [:])
    }

    private func handle(_ req: [String: Any]) async -> [String: Any] {
        // `watch`, `status` and `close` must work while a paused or waiting command holds the lock,
        // and must not steal its events (the menu bar item polls `status`).
        if ["watch", "status", "close"].contains(req["cmd"] as? String ?? "") { return await execute(req, drain: false) }
        return await withLock { await execute(req, drain: true) }
    }

    private func execute(_ req: [String: Any], drain: Bool) async -> [String: Any] {
        // The menu bar item polls `status` every few seconds; that must not keep a forgotten session alive.
        if req["cmd"] as? String != "status" { lastActivity = Date(); resumeMedia() }
        await cookieRestore?.value
        let cmd = req["cmd"] as? String ?? ""
        let args = req["args"] as? [String: Any] ?? [:]
        func events() -> [[String: Any]] { drain ? drainEvents() : [] }

        if let want = req["profile"] as? String, want != (profile ?? "") {
            let have = profile.map { "profile \"\($0)\"" } ?? "a temporary profile"
            return ["ok": false, "events": [], "error": CmdError(
                code: "PROFILE_MISMATCH",
                message: "session \"\(session)\" is already running with \(have); run close first to switch to profile \"\(want)\"").dict]
        }
        // A human who paused / took over holds the page; agent commands wait.
        if drain && watch.paused && cmd != "close" {
            let t0 = Date()
            log("waiting-for-human")
            waitingForHuman = true
            while watch.paused { try? await Task.sleep(nanoseconds: 100_000_000) }
            waitingForHuman = false
            log("resumed", ["waited_ms": Int(Date().timeIntervalSince(t0) * 1000)])
        }
        let label = stepLabel(cmd, args)
        if drain { runningLabel = label }
        defer { if drain { runningLabel = nil } }
        do {
            var result = try await run(cmd, args)
            if drain, ["open", "snapshot", "tab"].contains(cmd), let u = current.webView.url, u.scheme == "http" || u.scheme == "https",
               let h = u.host.flatMap({ NoteStore.normalizeHost($0) }) {
                let n = NoteStore.applicable(h).reduce(0) { $0 + $1.notes.count }
                if n > 0 { result["notes"] = ["count": n, "host": h, "hint": "Notes about this site are saved: read them with note show --here (CLI) or browser_notes (MCP) before you continue."] }
            }
            if drain, Browser.humanCheckCommands.contains(cmd) {
                humanCheckPending = false
                if let h = try? await js("return window.__abApi && window.__abApi.humanCheck ? window.__abApi.humanCheck() : null") as? [String: Any],
                   let kind = h["kind"] as? String {
                    humanCheckPending = true
                    result["needs_human"] = ["kind": kind, "reason": h["reason"] as? String ?? "",
                        "hint": "Do not try to solve or bypass this. Run watch on, then watch pause, tell the user what to do on the page and wait for them to say it is done, then watch resume and snapshot again."]
                }
            }
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
        case "snapshot": return try await snapshot(args)
        case "click": return try await act("click", ref: try str(args, "ref"), arg: "")
        case "fill":
            if let name = args["secret"] as? String { return try await fillSecret(name, args) }
            return try await act("fill", ref: try str(args, "ref"), arg: try str(args, "text"))
        case "login": return try await login(args)
        case "enroll": return try await enrollTOTP(args)
        case "recovery": return try await saveRecovery(args)
        case "vault": return try vaultList()
        case "note": return try noteCommand(args)
        case "submit": return try await act("submit", ref: try str(args, "ref"), arg: "")
        case "upload": return try await upload(args)
        case "wait": return try await wait(args)
        case "screenshot": return try await screenshot(try str(args, "path"))
        case "tabs": return try await tabList()
        case "tab": return try await tabCommand(args)
        case "downloads": return ["downloads": downloads.map(\.dict), "dir": downloadDir.path]
        case "cookies": return try await cookies(args)
        case "storage": return try await storage(args)
        case "status": return await status()
        case "cdp": return try cdpCommand(args)
        case "viewport": return try await viewportCommand(args)
        case "useragent": return try await userAgentCommand(args)
        case "block": return try await blockCommand(args)
        case "watch": return try watchCommand(args)
        case "close":
            await shutdown()
            return ["closed": true]
        default:
            throw CmdError(code: "USAGE", message: "unknown command \"\(cmd)\"")
        }
    }

    /// Stops this session. Persistent profiles need time to flush cookies/storage to disk: a round trip to the
    /// network process first makes sure it has seen every recent cookie change; the pause lets it write them.
    func shutdown() async {
        if profile != nil {
            await flushCookies(); await persistCookies()
            // Keep logins and site data, drop the page cache: it grows to tens of MB per profile and only speeds up reloads.
            // Best effort and bounded: closing must never wait on WebKit.
            let store = configuration.websiteDataStore
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                var resumed = false
                let finish = { if !resumed { resumed = true; cont.resume() } }
                store.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache],
                                 modifiedSince: .distantPast) { finish() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish() }
            }
        }
        let delay = profile == nil ? 0.1 : 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            MainActor.assumeIsolated {
                cdp?.stop()
                cdp = nil
                cdpObserver = nil
                cookiePersistTimer?.invalidate()
                cookiePersistTimer = nil
                watch.destroy()
                releaseWebViews()
                let done = onClose
                onClose = nil
                done?()
            }
        }
    }

    /// Breaks the reference cycles that keep a closed session alive (the content controller holds this object as a
    /// script message handler), so WebKit can end the session's helper processes and free its memory.
    private func releaseWebViews() {
        for t in tabs {
            t.webView.navigationDelegate = nil
            t.webView.uiDelegate = nil
            t.webView.stopLoading()
            let ucc = t.webView.configuration.userContentController
            ucc.removeAllScriptMessageHandlers()
            ucc.removeAllUserScripts()
            t.webView.removeFromSuperview()
        }
        configuration.userContentController.removeAllScriptMessageHandlers()
        configuration.userContentController.removeAllUserScripts()
        tabs.removeAll()
        current = nil
        window.contentView = nil
    }

    // MARK: persistent cookies
    //
    // A persistent profile keeps WebKit's own store, but WebKit on some macOS versions (15.x) does not write
    // cookies to disk before the helper exits, and it never keeps session cookies across a restart. So the helper
    // also keeps ALL the profile's cookies (session cookies too, stored without an expiry) in the profile folder
    // and loads them at startup. The file is encrypted (AES-GCM, key in the login keychain) and owner-only.
    // WebKit's own copy of a persistent profile (its data folder under ~/Library/WebKit) is not ours to encrypt.

    private var cookieRestore: Task<Void, Never>?
    private var cookiePersistTimer: Timer?
    private var cookiesSaved: (count: Int, at: Date)?
    private var cookieSaveError: String?
    private var undecryptable = false

    private var profileDir: String? { profile.map { NSHomeDirectory() + "/.agent-browser/profiles/\($0)" } }
    private var cookieFile: String? { profileDir.map { $0 + "/cookies.enc" } }
    private var legacyCookieFile: String? { profileDir.map { $0 + "/cookies.json" } }

    private func restoreCookies() async {
        guard let file = cookieFile else { return }
        let store = configuration.websiteDataStore.httpCookieStore
        var list: [[String: Any]] = []
        var migrated = false
        if let blob = FileManager.default.contents(atPath: file) {
            do {
                let loaded = ((try JSONSerialization.jsonObject(with: try CookieVault.open(blob))) as? [[String: Any]]) ?? []
                list += loaded
                // What is on disk right now, so status and the menu are right before the first save of this run.
                let at = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate]) as? Date ?? Date()
                cookiesSaved = (loaded.count, at)
            } catch { cookieSaveError = "saved cookies could not be decrypted (\(error))"; undecryptable = true }
        }
        // An earlier version wrote plain JSON; load it (also if an encrypted file exists) and remove it once re-saved.
        if let old = legacyCookieFile, let data = FileManager.default.contents(atPath: old),
           let l = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            list += l
            migrated = true
        }
        for d in list {
            if let e = (d["expires"] as? NSNumber)?.doubleValue, Date(timeIntervalSince1970: e) < Date() { continue }
            if let c = makeCookie(d) { await store.setCookie(c) }
        }
        if migrated {
            await persistCookies()
            if cookieSaveError == nil, let old = legacyCookieFile { Self.wipe(old) }  // only once the encrypted copy exists
        }
        // Save changes made while browsing, in case the helper is killed instead of closed.
        cookiePersistTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.persistCookies() }
        }
    }

    private static func wipe(_ path: String) {
        if let h = FileHandle(forWritingAtPath: path) {
            let n = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: 0)
            try? h.write(contentsOf: Data(count: Int(n)))
            try? h.synchronize()
            try? h.close()
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    func persistCookies() async {
        guard let file = cookieFile else { return }
        let now = Date()
        let keep = await configuration.websiteDataStore.httpCookieStore.allCookies()
            .filter { ($0.expiresDate ?? .distantFuture) > now }   // session cookies have no expiry: keep them
            .map(cookieDict)
            .sorted { ($0["domain"] as? String ?? "") < ($1["domain"] as? String ?? "") }
        let dir = (file as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if undecryptable {  // keep the file we cannot read (the key may come back) instead of overwriting it
            try? FileManager.default.removeItem(atPath: file + ".unreadable")
            try? FileManager.default.moveItem(atPath: file, toPath: file + ".unreadable")
            undecryptable = false
        }
        do {
            let json = try JSONSerialization.data(withJSONObject: keep, options: [.sortedKeys, .withoutEscapingSlashes])
            try CookieVault.seal(json).write(to: URL(fileURLWithPath: file), options: .atomic)
            chmod(file, 0o600)
            cookiesSaved = (keep.count, now)
            cookieSaveError = nil
        } catch {
            // Never fall back to plain text: if the key is unavailable the cookies are simply not saved.
            cookieSaveError = "cookies not saved: \(error)"
        }
    }

    /// Asks WebKit to write cookies to disk now. Older macOS versions only do it on a timer, and the helper
    /// exits right after `close`. Uses WebKit's own flush call when present (it is not public API), and
    /// otherwise falls back to a round trip to the network process plus the wait in `close`.
    private func flushCookies() async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        _ = await store.allCookies()
        let sel = NSSelectorFromString("_flushCookiesToDiskWithCompletionHandler:")
        guard store.responds(to: sel) else { return }
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let finish: @convention(block) () -> Void = {
                DispatchQueue.main.async { if !once.done { once.done = true; c.resume() } }
            }
            _ = store.perform(sel, with: unsafeBitCast(finish, to: AnyObject.self))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if !once.done { once.done = true; c.resume() } }
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

    private func cdpCommand(_ args: [String: Any]) throws -> [String: Any] {
        let c = cdp ?? CDP(browser: self)
        cdp = c
        switch args["action"] as? String ?? "start" {
        case "start":
            if !redactor.isEmpty {
                throw CmdError(code: "VAULT_CDP_BLOCKED", message: "this session has typed vault secrets into pages; a DevTools client could read them back, so cdp cannot start here. Use a different --session for DevTools.")
            }
            return try c.start(port: UInt16((args["port"] as? Double) ?? 0))
        case "stop": c.stop(); return ["running": false]
        case "status": return c.status()
        default: throw CmdError(code: "USAGE", message: "cdp takes start [--port N] | stop | status")
        }
    }

    // MARK: viewport, user agent, content blocking

    private func viewportCommand(_ args: [String: Any]) async throws -> [String: Any] {
        if let w = args["width"] as? Double, let h = args["height"] as? Double {
            guard (200...4000).contains(w), (200...4000).contains(h) else {
                throw CmdError(code: "USAGE", message: "viewport width and height must be between 200 and 4000")
            }
            viewport = NSSize(width: w.rounded(), height: h.rounded())
            for t in tabs { t.webView.frame = NSRect(origin: .zero, size: viewport) }
            watch.relayout()
            try? await Task.sleep(nanoseconds: 150_000_000)  // let the page see the resize
        }
        return ["width": Int(viewport.width), "height": Int(viewport.height)]
    }

    private func userAgentCommand(_ args: [String: Any]) async throws -> [String: Any] {
        if let ua = args["userAgent"] as? String {
            userAgent = ua == "reset" || ua.isEmpty ? nil : ua
            for t in tabs { t.webView.customUserAgent = userAgent }
        }
        let effective = (try? await js("return navigator.userAgent") as? String) ?? ""
        return ["userAgent": effective, "custom": userAgent != nil, "applies_to": "pages loaded from now on"]
    }

    private func blockCommand(_ args: [String: Any]) async throws -> [String: Any] {
        let resourceTypes = ["images": "image", "media": "media", "fonts": "font", "scripts": "script", "styles": "style-sheet"]
        switch args["action"] as? String ?? "status" {
        case "clear": blockRules = []
        case "status": break
        case "url":
            guard let re = args["pattern"] as? String, !re.isEmpty else { throw CmdError(code: "USAGE", message: "block url needs a regex") }
            blockRules.append(("url \(re)", ["trigger": ["url-filter": re], "action": ["type": "block"]]))
        case let kind where resourceTypes[kind] != nil:
            if !blockRules.contains(where: { $0.label == kind }) {
                blockRules.append((kind, ["trigger": ["url-filter": ".*", "resource-type": [resourceTypes[kind]!]], "action": ["type": "block"]]))
            }
        default:
            throw CmdError(code: "USAGE", message: "block takes images|media|fonts|scripts|styles | url <regex> | clear | status")
        }
        let ucc = configuration.userContentController
        ucc.removeAllContentRuleLists()
        if blockRules.isEmpty {
            try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "agent-browser")
        } else {
            let json = String(data: try JSONSerialization.data(withJSONObject: blockRules.map(\.rule)), encoding: .utf8) ?? "[]"
            do {
                if let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "agent-browser", encodedContentRuleList: json) {
                    ucc.add(list)
                }
            } catch {
                blockRules.removeLast()
                throw CmdError(code: "BAD_RULE", message: "rule rejected by WebKit: \(error.localizedDescription)")
            }
        }
        return ["blocking": blockRules.map(\.label), "applies_to": "requests made from now on (reload to apply to the current page)"]
    }

    /// `note` from the MCP server: notes for a host (default: the page that is open).
    private func noteCommand(_ args: [String: Any]) throws -> [String: Any] {
        var host = (args["host"] as? String).flatMap { NoteStore.normalizeHost($0) }
        if host == nil, (args["host"] as? String ?? "").isEmpty, let u = current.webView.url, u.scheme == "http" || u.scheme == "https" {
            host = u.host.flatMap { NoteStore.normalizeHost($0) }
        }
        guard let h = host else { throw CmdError(code: "NOTE_NO_HOST", message: "no host given and the current page is not a web page") }
        switch args["action"] as? String ?? "show" {
        case "add":
            let n = try NoteStore.add(host: h, text: try str(args, "text"))
            return ["host": h, "note": n.json]
        default:
            return notesResult(host: h)
        }
    }

    private func watchCommand(_ args: [String: Any]) throws -> [String: Any] {
        switch args["mode"] as? String ?? "on" {
        case "on":
            watch.show()
            Task { @MainActor in await refreshFavicon(); await updateTabIcon() }  // the tab shows the page icon
        case "off": watch.hide()
        case "pause": watch.setPaused(true)
        case "resume": watch.setPaused(false)
        case "status": break
        default: throw CmdError(code: "USAGE", message: "watch takes on|off|pause|resume|status")
        }
        return ["watching": watch.visible, "paused": watch.paused]
    }

    // What the menu bar item shows. Updated by execute() and unlock().
    private var runningLabel: String?
    private var waitingForHuman = false
    private var humanCheckPending = false
    private static let humanCheckCommands: Set<String> = ["open", "snapshot", "click", "submit", "fill", "login", "wait", "tab"]
    private var approvalFor: String?
    private var dialogFor: String?
    private let startedAt = Date()

    /// What happens to a page's confirm()/prompt(): the policy says ask (the default), accept or dismiss.
    /// "ask" shows a sheet on the watch window; one dialog at a time; no answer within 60 s counts as Cancel.
    func decideDialog(kind: String, message: String, defaultText: String?, host: String) async -> (accepted: Bool, text: String?, by: String) {
        switch policy.dialogs {
        case "accept": return (true, defaultText, "policy")
        case "dismiss": return (false, nil, "policy")
        default: break
        }
        while dialogFor != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        dialogFor = "\(kind) from \(host.isEmpty ? "a page" : host)"
        defer { dialogFor = nil }
        let wasVisible = watch.visible
        if !wasVisible { watch.show() }
        let seconds = Double(dialogTimeoutOverride ?? SessionEnv.get("AGENT_BROWSER_DIALOG_TIMEOUT") ?? "") ?? 60
        let r = await watch.ask(kind: kind, host: host, message: message, defaultText: defaultText, timeout: seconds)
        if !wasVisible { watch.hide() }
        return (r.accepted, r.text, r.timedOut ? "timeout" : "user")
    }

    /// The page's icon address, asked of the page only when the address changed (or the icon was missing a few seconds
    /// ago): the menu bar item polls `status`, and running page script on every poll costs CPU in the page for nothing.
    /// The picture is fetched for the tab in the watch window, and only while that window is shown.
    func refreshFavicon() async {
        let here = current.webView.url?.absoluteString ?? ""
        guard here != faviconFor || (lastFavicon == nil && Date().timeIntervalSince(faviconAt) > 5) else { return }
        faviconFor = here
        faviconAt = Date()
        lastFavicon = (try? await js("""
            const p = location.protocol; if (p !== 'https:' && p !== 'http:') return null;
            const l = Array.from(document.querySelectorAll('link[rel~="icon" i]')).find(x => x.getAttribute('href'));
            try { return new URL(l ? l.getAttribute('href') : '/favicon.ico', document.baseURI).href; } catch (e) { return null; }
            """)) as? String
        await updateTabIcon()
    }

    private var iconShownFor: String?
    func updateTabIcon() async {
        guard watch.visible else { return }
        guard let f = lastFavicon, let u = URL(string: f) else { watch.setFavicon(nil); iconShownFor = nil; return }
        if iconShownFor == f { return }
        iconShownFor = f
        if await navigationBlockReason(u, policy: policy, chainPrivateOK: current.chainPrivateOK, explicit: false) != nil { watch.setFavicon(nil); return }
        watch.setFavicon(await FaviconFetcher.fetch(u))
    }

    private var lastFavicon: String?
    private var faviconFor = ""
    private var faviconAt = Date.distantPast

    private func status() async -> [String: Any] {
        let dlg = dialogFor  // read before any await: a pending dialog blocks the page's JavaScript
        let state = watch.paused ? "paused" : approvalFor != nil ? "approval" : dlg != nil ? "dialog" : runningLabel != nil ? "working" : "idle"
        var s: [String: Any] = [
            "session": session, "profile": profile ?? NSNull(), "persistent": profile != nil, "media_suspended": mediaSuspended, "tab_icon": watch.hasFavicon,
            "tabs": tabs.count, "current_tab": current.id, "watching": watch.visible, "paused": watch.paused,
            "downloads_dir": downloadDir.path,
            "url": current.webView.url?.absoluteString ?? "", "title": current.webView.title ?? "",
            "state": state, "needs_you": waitingForHuman || approvalFor != nil || dlg != nil || humanCheckPending,
            "pid": Int(ProcessInfo.processInfo.processIdentifier), "started": Int(startedAt.timeIntervalSince1970),
            "recent_steps": watch.recentSteps.suffix(8).map { $0 },
        ]
        if dlg == nil { await refreshFavicon() }
        if let f = lastFavicon { s["favicon"] = f }
        if profile != nil {
            var pc: [String: Any] = ["encrypted": true]
            if let c = cookiesSaved { pc["count"] = c.count; pc["saved_at"] = Int(c.at.timeIntervalSince1970) }
            if let e = cookieSaveError { pc["error"] = e }
            s["profile_cookies"] = pc
        }
        if let r = runningLabel { s["command"] = r }
        if let a = approvalFor { s["approval_for"] = a }
        if let d = dlg { s["dialog_for"] = d }
        return s
    }

    private func open(_ args: [String: Any]) async throws -> [String: Any] {
        var raw = try str(args, "url").trimmingCharacters(in: .whitespaces)
        if !raw.contains("://") && !raw.hasPrefix("about:") && !raw.hasPrefix("data:") {
            raw = raw.hasPrefix("/") ? "file://" + raw : "https://" + raw
        }
        guard let url = URL(string: raw) else { throw CmdError(code: "BAD_URL", message: "not a valid URL: \(raw)") }
        let timeout = (args["timeout"] as? Double) ?? 30
        if let why = await navigationBlockReason(url, policy: policy, chainPrivateOK: true, explicit: true) {
            throw CmdError(code: "NAVIGATION_BLOCKED", message: "not opened: \(why)")
        }
        current.chainPrivateOK = await urlIsLocalOrPrivate(url)  // an address you type may be private; where it leads may not
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
        case .failed(let m): throw CmdError(code: m.hasPrefix("navigation blocked") ? "NAVIGATION_BLOCKED" : "NAVIGATION_FAILED", message: m)
        case .timeout:
            throw CmdError(code: "TIMEOUT", message: "page did not finish loading within \(Int(timeout))s")
        }
        if downloadSeq != dlBefore {  // the URL was a file download rather than a page
            await waitForDownloads(timeout: 120)
            let d = downloads.last
            if let d, d.state != "done" { throw CmdError(code: "DOWNLOAD_FAILED", message: d.error ?? "download failed", retrySafe: false) }
            return ["url": raw, "download": d?.dict ?? [:], "outcome": d.map { "download: \($0.name) (\($0.bytes) bytes)" } ?? "download"]
        }
        var out: [String: Any] = ["url": webView.url?.absoluteString ?? raw, "tab": current.id]
        out["title"] = (try? await js("return document.title") as? String) ?? ""
        if let s = current.lastStatus { out["status"] = s }
        return out
    }

    private func snapshot(_ args: [String: Any] = [:]) async throws -> [String: Any] {
        if navInFlight { _ = await waitForNavigation(timeout: 15) }
        // Snapshot ids are unique across tabs, so a ref from another tab can never match this one.
        snapCounter += 1
        var opts: [String: Any] = [:]
        if args["interactive"] as? Bool == true { opts["interactive"] = true }
        for k in ["maxChars", "maxNodes"] { if let v = args[k] as? Double, v > 0 { opts[k] = v } }
        if let sel = args["selector"] as? String, !sel.isEmpty { opts["selector"] = sel }
        guard var r = try await js("return window.__abApi.snapshot(id, opts)", ["id": snapCounter, "opts": opts]) as? [String: Any] else {
            throw CmdError(code: "SNAPSHOT_FAILED", message: "no page is open; run open <url> first")
        }
        if let e = r["error"] as? String { throw CmdError(code: "BAD_SELECTOR", message: e) }
        r["tab"] = current.id
        return r
    }

    private func act(_ op: String, ref: String, arg: String, opts: [String: Any]? = nil,
                     call: String = "return window.__abApi.act(op, ref, arg, watch, opts)",
                     callArgs: [String: Any]? = nil) async throws -> [String: Any] {
        if navInFlight { _ = await waitForNavigation(timeout: 15) }
        let beforeURL = webView.url?.absoluteString
        let beforeNav = navCount
        let beforeDl = downloadSeq
        let beforeMut = (try await js("return window.__abApi.mut") as? NSNumber)?.intValue ?? 0
        let mark = events.count

        let jsArgs: [String: Any] = callArgs ?? ["op": op, "ref": ref, "arg": arg, "watch": watch.visible, "opts": opts ?? NSNull()]
        guard var res = try await js(call, jsArgs) as? [String: Any]
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

    // MARK: vault

    let redactor = Redactor()
    private lazy var vaultStore: VaultStore = makeVaultStore()

    private func vaultList() throws -> [String: Any] {
        let rows = try vaultStore.list().map { r -> [String: Any] in
            ["name": r.name, "origins": r.meta.origins, "totp": r.meta.totp, "confirm": r.meta.confirm, "recovery": r.meta.recovery ?? 0]
        }
        return ["entries": rows]
    }

    /// Looks an entry up and checks everything that must hold before a value may leave the vault.
    private func unlock(_ name: String, action: String, needs: [String]) async throws -> (VaultEntry, String) {
        guard validVaultName(name) else { throw CmdError(code: "USAGE", message: "invalid vault entry name") }
        guard let entry = try vaultStore.get(name) else {
            let names = (try? vaultStore.list().map(\.name)) ?? []
            throw CmdError(code: "VAULT_NO_ENTRY", message: "no vault entry \"\(name)\"" + (names.isEmpty ? " (the vault is empty; the user adds entries with `agent-browser vault add`)" : "; entries: \(names.joined(separator: ", "))"))
        }
        if cdp?.isRunning == true {
            throw CmdError(code: "VAULT_CDP_BLOCKED", message: "the DevTools endpoint is running; a DevTools client could read typed secrets, so vault entries are not used while it runs. Run `cdp stop` or use another session.")
        }
        let page = canonicalOrigin(webView.url) ?? "(none)"
        guard entry.meta.origins.contains(page) else {
            vaultAudit(vaultStore, ["entry": name, "action": action, "origin": page, "outcome": "ORIGIN_MISMATCH"])
            throw CmdError(code: "ORIGIN_MISMATCH", message: "Vault entry \"\(name)\" is only valid on \(entry.meta.origins.joined(separator: ", ")), but this page is \(page). Nothing was entered.", extra: ["entry": name])
        }
        for f in needs where f == "totp" && entry.secret.totp == nil {
            throw CmdError(code: "VAULT_NO_FIELD", message: "entry \"\(name)\" has no TOTP secret.")
        }
        if entry.meta.confirm {
            watch.step("waiting for approval to use vault entry \(name)…", ok: true)
            approvalFor = name
            let a = await requestApproval(reason: "agent-browser wants to use the saved login \"\(name)\" on \(page)", store: vaultStore)
            approvalFor = nil
            guard a.ok else {
                vaultAudit(vaultStore, ["entry": name, "action": action, "origin": page, "outcome": "APPROVAL_DENIED", "why": a.why])
                throw CmdError(code: "VAULT_APPROVAL_DENIED", message: "use of vault entry \"\(name)\" was not approved (\(a.why)). Nothing was entered.")
            }
        }
        return (entry, page)
    }

    private func fillSecret(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        let ref = try str(args, "ref")
        let field = (args["field"] as? String) ?? "password"
        guard ["username", "password", "totp"].contains(field) else {
            throw CmdError(code: "USAGE", message: "--field must be username, password or totp")
        }
        let (entry, page) = try await unlock(name, action: "fill", needs: [field])
        let value: String
        switch field {
        case "username": value = entry.secret.username
        case "totp": value = totpCode(try parseTOTP(entry.secret.totp ?? ""))
        default: value = entry.secret.password
        }
        if field != "username" { redactor.add(value) }
        do {
            let res = try await act("fill", ref: ref, arg: value, opts: ["origins": entry.meta.origins, "name": name, "secret": true])
            vaultAudit(vaultStore, ["entry": name, "action": "fill", "field": field, "origin": page, "outcome": "ok"])
            return res.merging(["entry": name, "field": field]) { a, _ in a }
        } catch let e as CmdError {
            vaultAudit(vaultStore, ["entry": name, "action": "fill", "field": field, "origin": page, "outcome": e.code])
            throw e
        }
    }

    private func login(_ args: [String: Any]) async throws -> [String: Any] {
        let name = try str(args, "secret")
        let (entry, page) = try await unlock(name, action: "login", needs: [])
        let otp = entry.secret.totp.flatMap { try? parseTOTP($0) }.map { totpCode($0) }
        redactor.add(entry.secret.password)
        redactor.add(otp)
        let plan: [String: Any] = ["name": name, "origins": entry.meta.origins, "username": entry.secret.username,
                                   "password": entry.secret.password, "otp": otp ?? NSNull(),
                                   "submit": args["submit"] as? Bool == true]
        do {
            var res = try await act("login", ref: "", arg: "", call: "return window.__abApi.login(plan, watch)",
                                    callArgs: ["plan": plan, "watch": watch.visible])
            let filled = res["filled"] as? [String] ?? []
            vaultAudit(vaultStore, ["entry": name, "action": "login", "fields": filled, "origin": page,
                                    "submitted": res["submitted"] as? Bool ?? false, "outcome": "ok"])
            res["entry"] = name
            return res
        } catch let e as CmdError {
            vaultAudit(vaultStore, ["entry": name, "action": "login", "origin": page, "outcome": e.code])
            throw e
        }
    }

    // MARK: 2FA enrollment and recovery codes

    /// Reads QR codes off elements that look like one by rendering them and decoding with Vision.
    private func scanQRCodes(count: Int) async -> [String] {
        var payloads: [String] = []
        for i in 0..<min(count, 6) {
            guard let r = try? await js("return window.__abApi.qrRect(i)", ["i": i]) as? [String: Any],
                  let x = (r["x"] as? NSNumber)?.doubleValue, let y = (r["y"] as? NSNumber)?.doubleValue,
                  let w = (r["w"] as? NSNumber)?.doubleValue, let h = (r["h"] as? NSNumber)?.doubleValue,
                  let vw = (r["vw"] as? NSNumber)?.doubleValue, let vh = (r["vh"] as? NSNumber)?.doubleValue
            else { continue }
            try? await Task.sleep(nanoseconds: 80_000_000)  // let the scroll settle
            let pad = 16.0
            let rect = CGRect(x: max(0, x - pad), y: max(0, y - pad), width: min(vw, w + 2 * pad), height: min(vh, h + 2 * pad))
            let cfg = WKSnapshotConfiguration()
            cfg.rect = rect
            cfg.snapshotWidth = NSNumber(value: max(500, rect.width * 2))
            guard let img = try? await webView.takeSnapshot(configuration: cfg),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let req = VNDetectBarcodesRequest()
            req.symbologies = [.qr]
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            payloads += (req.results ?? []).compactMap { $0.payloadStringValue }
        }
        return payloads
    }

    private func enrollTOTP(_ args: [String: Any]) async throws -> [String: Any] {
        let name = try str(args, "secret")
        let replace = args["replace"] as? Bool == true
        let (entry, page) = try await unlock(name, action: "enroll", needs: [])
        if entry.secret.totp != nil && !replace {
            throw CmdError(code: "VAULT_HAS_TOTP", message: "entry \"\(name)\" already has a TOTP secret; pass --replace to overwrite it. Nothing was changed.")
        }
        guard let found = try await js("return window.__abApi.findSetup()") as? [String: Any] else {
            throw CmdError(code: "ENROLL_FAILED", message: "could not inspect the page")
        }
        var candidates: [(params: TOTPParams, stored: String, source: String)] = []
        for u in found["uris"] as? [String] ?? [] { if let p = try? parseTOTP(u) { candidates.append((p, u, "link")) } }
        let qrCount = (found["qr"] as? NSNumber)?.intValue ?? 0
        if qrCount > 0 {
            for payload in await scanQRCodes(count: qrCount) where payload.lowercased().hasPrefix("otpauth://totp") {
                if let p = try? parseTOTP(payload) { candidates.append((p, payload, "qr")) }
            }
        }
        for k in found["keys"] as? [String] ?? [] { if let p = try? parseTOTP(k) { candidates.append((p, k, "key")) } }

        var distinct: [(params: TOTPParams, stored: String, source: String)] = []
        for c in candidates where !distinct.contains(where: { $0.params.secret == c.params.secret }) { distinct.append(c) }
        // Remember everything we saw so it is scrubbed from later output, whether or not it is saved.
        for c in candidates { redactor.addSetupSecret(c.params, stored: c.stored) }
        guard !distinct.isEmpty else {
            vaultAudit(vaultStore, ["entry": name, "action": "enroll", "origin": page, "outcome": "TOTP_NOT_FOUND"])
            throw CmdError(code: "TOTP_NOT_FOUND", message: "no 2FA setup key, otpauth link or QR code was found on this page (\(qrCount) QR-sized images checked). Open the page that shows the setup key, or ask the user to enter the secret with `vault add --totp`.")
        }
        let sources = ["link", "qr", "key"].map { k in "\(k): \(candidates.filter { $0.source == k }.count)" }.joined(separator: ", ")
        guard distinct.count == 1 else {
            vaultAudit(vaultStore, ["entry": name, "action": "enroll", "origin": page, "outcome": "TOTP_AMBIGUOUS"])
            throw CmdError(code: "TOTP_AMBIGUOUS", message: "found \(distinct.count) different 2FA secrets on this page (\(sources)); refusing to guess. Nothing was saved.")
        }
        // Prefer the full link (it carries issuer, digits, period and algorithm) over a bare key.
        let chosen = candidates.first(where: { $0.params.secret == distinct[0].params.secret && $0.stored.lowercased().hasPrefix("otpauth://") }) ?? distinct[0]
        var updated = entry
        updated.secret.totp = chosen.stored
        updated.meta.totp = true
        try vaultStore.put(updated, replace: true)
        vaultAudit(vaultStore, ["entry": name, "action": "enroll", "origin": page, "source": chosen.source, "outcome": "ok"])

        var res: [String: Any] = ["entry": name, "saved": true, "source": chosen.source, "digits": chosen.params.digits,
                                  "period": chosen.params.period, "algorithm": chosen.params.algorithm,
                                  "next": "type the current code into the page's verification field with: fill <ref> --secret \(name) --field totp"]
        if let c = URLComponents(string: chosen.stored), c.host?.lowercased() == "totp" {
            if let issuer = c.queryItems?.first(where: { $0.name == "issuer" })?.value { res["issuer"] = issuer }
            let label = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !label.isEmpty { res["account"] = label.split(separator: ":", maxSplits: 1).last.map(String.init) ?? label }
        }
        return res
    }

    private func saveRecovery(_ args: [String: Any]) async throws -> [String: Any] {
        let name = try str(args, "secret")
        let (entry, page) = try await unlock(name, action: "recovery", needs: [])
        let sel = (args["selector"] as? String) ?? ""
        guard let found = try await js("return window.__abApi.findRecovery(sel)", ["sel": sel]) as? [String: Any] else {
            throw CmdError(code: "RECOVERY_FAILED", message: "could not inspect the page")
        }
        if found["ok"] as? Bool != true {
            vaultAudit(vaultStore, ["entry": name, "action": "recovery", "origin": page, "outcome": found["code"] as? String ?? "failed"])
            throw CmdError(code: found["code"] as? String ?? "NO_RECOVERY_CODES", message: found["message"] as? String ?? "no recovery codes found")
        }
        let codes = found["codes"] as? [String] ?? []
        for c in codes { redactor.add(c) }
        var updated = entry
        updated.secret.recovery = codes
        updated.meta.recovery = codes.count
        try vaultStore.put(updated, replace: true)
        vaultAudit(vaultStore, ["entry": name, "action": "recovery", "origin": page, "count": codes.count, "outcome": "ok"])
        return ["entry": name, "saved": codes.count,
                "note": "stored in the vault; the user can view them with `vault export \(name)` in a terminal"]
    }

    // MARK: uploads

    private func upload(_ args: [String: Any]) async throws -> [String: Any] {
        let ref = try str(args, "ref")
        guard let paths = args["paths"] as? [String], !paths.isEmpty else {
            throw CmdError(code: "USAGE", message: "upload needs at least one file path")
        }
        let json = try filesSpec(paths)
        return try await act("upload", ref: ref, arg: json)
    }

    /// JSON describing files (name, mime type, base64 bytes) for the page-side File constructor.
    func filesSpec(_ paths: [String]) throws -> String {
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
        return String(data: try JSONSerialization.data(withJSONObject: files), encoding: .utf8) ?? "[]"
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
            if tabs.count >= policy.maxTabs {
                throw CmdError(code: "TAB_LIMIT", message: "policy max_tabs (\(policy.maxTabs)) reached; close a tab first")
            }
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

    func cookieDict(_ c: HTTPCookie) -> [String: Any] {
        var d: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path,
                                "secure": c.isSecure, "httpOnly": c.isHTTPOnly]
        if let e = c.expiresDate { d["expires"] = e.timeIntervalSince1970 }
        if let s = c.sameSitePolicy { d["sameSite"] = s.rawValue }
        return d
    }

    func makeCookie(_ d: [String: Any]) -> HTTPCookie? {
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
            await persistCookies()
            return ["imported": n, "skipped": skipped]
        case "clear":
            let all = await store.allCookies()
            for c in all { await store.deleteCookie(c) }
            await persistCookies()
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
