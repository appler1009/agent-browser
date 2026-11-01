import AppKit
import WebKit

// A thin Chrome DevTools Protocol shim: "compatible enough" for common Puppeteer/Playwright-style
// flows, not Chrome parity. Anything WebKit cannot do (request interception, browser contexts,
// touch, ...) fails loudly with a protocol error instead of pretending to work.

struct CDPError: Error {
    var code: Int
    var message: String
}

private let cdpUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15 agent-browser/\(agentBrowserVersion)"

@MainActor
final class CDP {
    unowned let browser: Browser
    private let server = CDPServer()
    private let browserId = UUID().uuidString.lowercased()

    private final class Session {
        let id: String
        let tab: Tab
        let implicit: Bool  // /devtools/page/<id> connections: messages carry no sessionId
        var enabled = Set<String>()
        var lifecycle = false
        init(id: String, tab: Tab, implicit: Bool) { self.id = id; self.tab = tab; self.implicit = implicit }
    }

    private final class ConnState {
        let conn: CDPConnection
        var sessions: [String: Session] = [:]
        var implicit: Session?
        var discover = false
        var autoAttach = false
        init(_ c: CDPConnection) { conn = c }
    }

    private final class TabState {
        var loaderSeq = 0
        var loaderId = "L0"
        var contextId = 0
        var requestSeq = 0
    }

    private var conns: [ObjectIdentifier: ConnState] = [:]
    private var tabStates: [String: TabState] = [:]
    private var initScripts: [(id: String, source: String)] = []
    private var nextScript = 1
    private var contextSeq = 1
    /// In-memory streams handed out for Page.printToPDF with transferMode=ReturnAsStream (read via IO.read).
    private var streams: [String: Data] = [:]
    private var streamSeq = 0
    /// Named isolated worlds clients asked for; announced again on every new document (we evaluate in the page world).
    private var worldNames: [String] = []

    init(browser: Browser) {
        self.browser = browser
    }

    // MARK: lifecycle

    func start(port: UInt16) throws -> [String: Any] {
        if !server.running {
            server.onOpen = { [unowned self] c in DispatchQueue.main.async { MainActor.assumeIsolated { self.opened(c) } } }
            server.onMessage = { [unowned self] c, t in DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(c, t) } } }
            server.onClose = { [unowned self] c in DispatchQueue.main.async { MainActor.assumeIsolated { self.closed(c) } } }
            server.http = { [unowned self] m, p, h in
                DispatchQueue.main.sync { MainActor.assumeIsolated { self.httpRoute(m, p, h) } }
            }
            _ = try server.start(port: port)
            browser.cdpObserver = { [unowned self] type, fields, tab in self.observe(type, fields, tab) }
        }
        return status()
    }

    func stop() {
        browser.cdpObserver = nil
        for st in conns.values { st.conn.close() }
        conns = [:]
        server.stop()
    }

    func status() -> [String: Any] {
        guard server.running else { return ["running": false] }
        let http = "http://127.0.0.1:\(server.port)"
        return ["running": true, "port": Int(server.port), "http": http,
                "ws": "ws://127.0.0.1:\(server.port)/devtools/browser/\(browserId)", "connections": conns.count]
    }

    // MARK: HTTP endpoints

    private func json(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    private func listEntry(_ t: Tab, host: String) -> [String: Any] {
        ["id": t.targetId, "type": "page", "title": t.webView.title ?? "", "url": t.webView.url?.absoluteString ?? "about:blank",
         "description": "", "webSocketDebuggerUrl": "ws://\(host)/devtools/page/\(t.targetId)"]
    }

    private func httpRoute(_ method: String, _ path: String, _ host: String) -> (Int, Data) {
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        let route = parts[0]
        let query = parts.count > 1 ? parts[1] : ""
        switch route {
        case "/json/version":
            return (200, json(["Browser": "agent-browser/\(agentBrowserVersion)", "Protocol-Version": "1.3", "User-Agent": cdpUserAgent,
                               "V8-Version": "", "WebKit-Version": "605.1.15",
                               "webSocketDebuggerUrl": "ws://\(host)/devtools/browser/\(browserId)"]))
        case "/json", "/json/list":
            return (200, json(browser.tabs.map { listEntry($0, host: host) }))
        case "/json/new":
            let tab = browser.openTab()
            if query.hasPrefix("http") || query.hasPrefix("file:") || query.hasPrefix("about:"), let u = URL(string: query.removingPercentEncoding ?? query) {
                tab.webView.load(URLRequest(url: u))
            }
            return (200, json(listEntry(tab, host: host)))
        default:
            if route.hasPrefix("/json/activate/") || route.hasPrefix("/json/close/") {
                let id = String(route.split(separator: "/").last ?? "")
                guard let tab = browser.tabs.first(where: { $0.targetId == id }) else {
                    return (404, Data("No such target id: \(id)".utf8))
                }
                if route.hasPrefix("/json/activate/") { browser.activate(tab); return (200, Data("Target activated".utf8)) }
                browser.closeTab(tab)
                return (200, Data("Target is closing".utf8))
            }
            return (404, Data("not found".utf8))
        }
    }

    // MARK: connections

    private func opened(_ conn: CDPConnection) {
        let st = ConnState(conn)
        conns[ObjectIdentifier(conn)] = st
        if conn.path.hasPrefix("/devtools/page/") {
            let id = String(conn.path.dropFirst("/devtools/page/".count))
            guard let tab = browser.tabs.first(where: { $0.targetId == id }) else { conn.close(); conns[ObjectIdentifier(conn)] = nil; return }
            let s = Session(id: "", tab: tab, implicit: true)
            st.implicit = s
        } else if !conn.path.hasPrefix("/devtools/browser/") {
            conn.close()
            conns[ObjectIdentifier(conn)] = nil
        }
    }

    private func closed(_ conn: CDPConnection) {
        conns[ObjectIdentifier(conn)] = nil
    }

    private func receive(_ conn: CDPConnection, _ text: String) {
        browser.touch()
        trace("->", text)
        guard let msg = parseJSON(text), let st = conns[ObjectIdentifier(conn)] else { return }
        // Tasks are created in arrival order on the main actor, so each command starts in order.
        Task { @MainActor in await self.handle(msg, st) }
    }

    /// Set AGENT_BROWSER_CDP_TRACE=<file> when the helper starts to log protocol traffic (for debugging clients).
    private let tracePath = ProcessInfo.processInfo.environment["AGENT_BROWSER_CDP_TRACE"]

    private func trace(_ dir: String, _ text: String) {
        guard let tracePath, let h = FileHandle(forWritingAtPath: tracePath) ?? {
            FileManager.default.createFile(atPath: tracePath, contents: nil)
            return FileHandle(forWritingAtPath: tracePath)
        }() else { return }
        h.seekToEndOfFile()
        h.write(Data("\(dir) \(text.prefix(600))\n".utf8))
        try? h.close()
    }

    private func send(_ st: ConnState, _ obj: [String: Any]) {
        let text = jsonString(obj)
        trace("<-", text)
        st.conn.send(text)
    }

    private func handle(_ msg: [String: Any], _ st: ConnState) async {
        guard let id = msg["id"] as? Int, let method = msg["method"] as? String else { return }
        let params = msg["params"] as? [String: Any] ?? [:]
        let sid = msg["sessionId"] as? String
        func reply(_ body: [String: Any]) {
            var out = body
            out["id"] = id
            if let sid { out["sessionId"] = sid }
            send(st, out)
        }
        var session: Session? = st.implicit
        if let sid {
            guard let s = st.sessions[sid] else {
                return reply(["error": ["code": -32001, "message": "Session with given id not found."]])
            }
            session = s
        }
        do {
            let result = try await dispatch(method, params, st, session)
            reply(["result": result])
        } catch let e as CDPError {
            reply(["error": ["code": e.code, "message": e.message]])
        } catch let e as CmdError {
            reply(["error": ["code": -32000, "message": e.message]])
        } catch {
            reply(["error": ["code": -32603, "message": "\(error)"]])
        }
    }

    // MARK: targets and sessions

    private func tabState(_ t: Tab) -> TabState {
        if let s = tabStates[t.targetId] { return s }
        let s = TabState()
        tabStates[t.targetId] = s
        return s
    }

    private func origin(_ url: String) -> String {
        guard let u = URL(string: url), let scheme = u.scheme else { return "://" }
        if scheme == "file" { return "file://" }
        guard let host = u.host else { return "://" }
        return "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "")
    }

    private func targetInfo(_ t: Tab) -> [String: Any] {
        let attached = conns.values.contains { $0.sessions.values.contains { $0.tab === t } || $0.implicit?.tab === t }
        return ["targetId": t.targetId, "type": "page", "title": t.webView.title ?? "", "url": t.webView.url?.absoluteString ?? "about:blank",
                "attached": attached, "canAccessOpener": false, "browserContextId": "DEFAULT"]
    }

    private func frame(_ t: Tab) -> [String: Any] {
        let url = t.webView.url?.absoluteString ?? "about:blank"
        return ["id": t.targetId, "loaderId": tabState(t).loaderId, "url": url, "domainAndRegistry": "",
                "securityOrigin": origin(url), "mimeType": t.lastMime.isEmpty ? "text/html" : t.lastMime,
                "adFrameStatus": ["adFrameType": "none"], "secureContextType": "Secure",
                "crossOriginIsolatedContextType": "NotIsolated", "gatedAPIFeatures": []]
    }

    @discardableResult
    private func attach(_ st: ConnState, _ tab: Tab) -> Session {
        if let existing = st.sessions.values.first(where: { $0.tab === tab }) { return existing }
        let s = Session(id: UUID().uuidString.replacingOccurrences(of: "-", with: ""), tab: tab, implicit: false)
        st.sessions[s.id] = s
        send(st, ["method": "Target.attachedToTarget",
                  "params": ["sessionId": s.id, "targetInfo": targetInfo(tab), "waitingForDebugger": false]])
        return s
    }

    private func tab(forTarget id: String?) throws -> Tab {
        guard let id, let t = browser.tabs.first(where: { $0.targetId == id }) else {
            throw CDPError(code: -32602, message: "No target with given id found")
        }
        return t
    }

    /// Every session attached to `tab`, across connections.
    private func sessions(of tab: Tab) -> [(ConnState, Session)] {
        var out: [(ConnState, Session)] = []
        for st in conns.values {
            if let i = st.implicit, i.tab === tab { out.append((st, i)) }
            for s in st.sessions.values where s.tab === tab { out.append((st, s)) }
        }
        return out
    }

    private func emit(_ method: String, _ params: [String: Any], tab: Tab, requires domain: String? = nil, lifecycle: Bool = false) {
        for (st, s) in sessions(of: tab) {
            if let d = domain, !s.enabled.contains(d) { continue }
            if lifecycle && !s.lifecycle { continue }
            var m: [String: Any] = ["method": method, "params": params]
            if !s.implicit { m["sessionId"] = s.id }
            send(st, m)
        }
    }

    private func now() -> Double { Date().timeIntervalSince1970 }

    private func contextDescription(_ t: Tab, id: Int, isDefault: Bool = true, name: String = "") -> [String: Any] {
        let url = t.webView.url?.absoluteString ?? ""
        return ["id": id, "origin": origin(url), "name": name, "uniqueId": UUID().uuidString,
                "auxData": ["isDefault": isDefault, "type": isDefault ? "default" : "isolated", "frameId": t.targetId]]
    }

    // MARK: browser events -> protocol events

    private func observe(_ type: String, _ f: [String: Any], _ tab: Tab?) {
        guard server.running, let tab else { return }
        let ts = tabState(tab)
        let url = tab.webView.url?.absoluteString ?? (f["url"] as? String ?? "")
        switch type {
        case "target-created":
            for st in conns.values {
                if st.discover { send(st, ["method": "Target.targetCreated", "params": ["targetInfo": targetInfo(tab)]]) }
                if st.autoAttach { attach(st, tab) }
            }
        case "target-closed":
            for st in conns.values {
                for (sid, s) in st.sessions where s.tab === tab {
                    send(st, ["method": "Target.detachedFromTarget", "params": ["sessionId": sid, "targetId": tab.targetId]])
                    st.sessions[sid] = nil
                }
                if st.discover { send(st, ["method": "Target.targetDestroyed", "params": ["targetId": tab.targetId]]) }
                if st.implicit?.tab === tab { st.conn.close() }
            }
            tabStates[tab.targetId] = nil
        case "navigation":
            ts.loaderSeq += 1
            ts.loaderId = "L\(ts.loaderSeq)"
            let rid = ts.loaderId
            emit("Page.frameStartedLoading", ["frameId": tab.targetId], tab: tab, requires: "Page")
            emit("Network.requestWillBeSent", [
                "requestId": rid, "loaderId": rid, "documentURL": f["url"] as? String ?? url,
                "request": ["url": f["url"] as? String ?? url, "method": "GET", "headers": [:] as [String: Any], "initialPriority": "VeryHigh", "referrerPolicy": "strict-origin-when-cross-origin"],
                "timestamp": now(), "wallTime": now(), "initiator": ["type": "other"], "type": "Document",
                "frameId": tab.targetId, "hasUserGesture": false, "redirectHasExtraInfo": false,
            ], tab: tab, requires: "Network")
        case "commit":
            emit("Runtime.executionContextsCleared", [:], tab: tab, requires: "Runtime")
            emit("Network.responseReceived", [
                "requestId": ts.loaderId, "loaderId": ts.loaderId, "timestamp": now(), "type": "Document", "frameId": tab.targetId,
                "response": ["url": url, "status": tab.lastStatus ?? 200, "statusText": "", "headers": [:] as [String: Any],
                             "mimeType": tab.lastMime.isEmpty ? "text/html" : tab.lastMime, "connectionReused": false,
                             "connectionId": 0, "encodedDataLength": 0, "securityState": url.hasPrefix("https") ? "secure" : "neutral"],
            ], tab: tab, requires: "Network")
            emit("Page.frameNavigated", ["frame": frame(tab), "type": "Navigation"], tab: tab, requires: "Page")
            lifecycleEvent("init", tab)
            ts.contextId = contextSeq
            contextSeq += 1
            emit("Runtime.executionContextCreated", ["context": contextDescription(tab, id: ts.contextId)], tab: tab, requires: "Runtime")
            for name in worldNames {
                emit("Runtime.executionContextCreated", ["context": contextDescription(tab, id: contextSeq, isDefault: false, name: name)],
                     tab: tab, requires: "Runtime")
                contextSeq += 1
            }
            for st in conns.values where st.discover {
                send(st, ["method": "Target.targetInfoChanged", "params": ["targetInfo": targetInfo(tab)]])
            }
        case "load":
            lifecycleEvent("DOMContentLoaded", tab)
            emit("Page.domContentEventFired", ["timestamp": now()], tab: tab, requires: "Page")
            lifecycleEvent("load", tab)
            emit("Page.loadEventFired", ["timestamp": now()], tab: tab, requires: "Page")
            emit("Network.loadingFinished", ["requestId": ts.loaderId, "timestamp": now(), "encodedDataLength": 0], tab: tab, requires: "Network")
            emit("Page.frameStoppedLoading", ["frameId": tab.targetId], tab: tab, requires: "Page")
            let loader = ts.loaderId
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard self.tabStates[tab.targetId]?.loaderId == loader else { return }
                self.lifecycleEvent("networkAlmostIdle", tab)
                self.lifecycleEvent("networkIdle", tab)
            }
        case "navigation-failed":
            emit("Network.loadingFailed", ["requestId": ts.loaderId, "timestamp": now(), "type": "Document",
                                           "errorText": "net::ERR_FAILED", "canceled": false], tab: tab, requires: "Network")
            emit("Page.frameStoppedLoading", ["frameId": tab.targetId], tab: tab, requires: "Page")
        case "dialog":
            let kind = f["kind"] as? String ?? "alert"
            emit("Page.javascriptDialogOpening", ["url": url, "message": f["message"] as? String ?? "", "type": kind,
                                                   "hasBrowserHandler": false, "defaultPrompt": ""], tab: tab, requires: "Page")
            emit("Page.javascriptDialogClosed", ["result": true, "userInput": ""], tab: tab, requires: "Page")
        case "console-error":
            emit("Runtime.consoleAPICalled", ["type": "error", "args": [["type": "string", "value": f["message"] as? String ?? ""]],
                                               "executionContextId": ts.contextId, "timestamp": now() * 1000,
                                               "stackTrace": ["callFrames": []]], tab: tab, requires: "Runtime")
        case "page-error":
            emit("Runtime.exceptionThrown", ["timestamp": now() * 1000, "exceptionDetails": [
                "exceptionId": 1, "text": "Uncaught", "lineNumber": f["line"] as? Int ?? 0, "columnNumber": 0,
                "exception": ["type": "object", "subtype": "error", "description": f["message"] as? String ?? ""]]],
                 tab: tab, requires: "Runtime")
        case "cdp:net":
            ts.requestSeq += 1
            let rid = "R\(ts.requestSeq)", u = f["url"] as? String ?? ""
            let kind = f["kind"] as? String ?? "Fetch"
            emit("Network.requestWillBeSent", ["requestId": rid, "loaderId": ts.loaderId, "documentURL": url,
                "request": ["url": u, "method": f["method"] as? String ?? "GET", "headers": [:] as [String: Any]],
                "timestamp": now(), "wallTime": now(), "initiator": ["type": "script"], "type": kind, "frameId": tab.targetId],
                 tab: tab, requires: "Network")
            let status = (f["status"] as? NSNumber)?.intValue ?? 0
            if status == 0 {
                emit("Network.loadingFailed", ["requestId": rid, "timestamp": now(), "type": kind, "errorText": "net::ERR_FAILED", "canceled": false],
                     tab: tab, requires: "Network")
            } else {
                emit("Network.responseReceived", ["requestId": rid, "loaderId": ts.loaderId, "timestamp": now(), "type": kind, "frameId": tab.targetId,
                    "response": ["url": u, "status": status, "statusText": "", "headers": [:] as [String: Any], "mimeType": "", "connectionReused": false,
                                "connectionId": 0, "encodedDataLength": 0]], tab: tab, requires: "Network")
                emit("Network.loadingFinished", ["requestId": rid, "timestamp": now(), "encodedDataLength": 0], tab: tab, requires: "Network")
            }
        default: break
        }
    }

    private func lifecycleEvent(_ name: String, _ tab: Tab) {
        emit("Page.lifecycleEvent", ["frameId": tab.targetId, "loaderId": tabState(tab).loaderId, "name": name, "timestamp": now()],
             tab: tab, requires: "Page", lifecycle: true)
    }

    // MARK: command dispatch

    private func need(_ s: Session?) throws -> Tab {
        guard let s else { throw CDPError(code: -32601, message: "This command needs a target session (Target.attachToTarget with flatten:true, or connect to /devtools/page/<id>)") }
        return s.tab
    }

    private func page(_ tab: Tab, _ call: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let r = try await browser.eval(on: tab, "return window.__abApi.\(call)", args) as? [String: Any] ?? [:]
        if let e = r["error"] as? String { throw CDPError(code: -32000, message: e) }
        return r
    }

    private func dispatch(_ method: String, _ p: [String: Any], _ st: ConnState, _ sess: Session?) async throws -> [String: Any] {
        switch method {
        // ---- Browser
        case "Browser.getVersion":
            return ["protocolVersion": "1.3", "product": "agent-browser/\(agentBrowserVersion)", "revision": "", "userAgent": cdpUserAgent, "jsVersion": "JavaScriptCore"]
        case "Browser.close":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { if !daemonSocketPath.isEmpty { unlink(daemonSocketPath) }; exit(0) }
            return [:]
        case "Browser.getWindowForTarget":
            return ["windowId": 1, "bounds": ["left": 0, "top": 0, "width": Int(Browser.viewport.width), "height": Int(Browser.viewport.height), "windowState": "normal"]]
        case "Browser.setDownloadBehavior", "Browser.setPermission", "Browser.grantPermissions", "Browser.resetPermissions", "Browser.setWindowBounds":
            return [:]

        // ---- IO (streams for PDFs)
        case "IO.read":
            let h = p["handle"] as? String ?? ""
            guard let data = streams[h] else { throw CDPError(code: -32000, message: "Invalid stream handle") }
            let off = max(0, p["offset"] as? Int ?? 0), size = p["size"] as? Int ?? 1 << 20
            let end = min(data.count, off + size)
            return ["data": data.subdata(in: min(off, data.count)..<end).base64EncodedString(), "base64Encoded": true, "eof": end >= data.count]
        case "IO.close":
            streams[p["handle"] as? String ?? ""] = nil
            return [:]

        // ---- Target
        case "Target.setDiscoverTargets":
            st.discover = p["discover"] as? Bool ?? false
            if st.discover { for t in browser.tabs { send(st, ["method": "Target.targetCreated", "params": ["targetInfo": targetInfo(t)]]) } }
            return [:]
        case "Target.setAutoAttach":
            if sess != nil { return [:] }  // child-target auto attach: we have no child targets
            st.autoAttach = p["autoAttach"] as? Bool ?? false
            if st.autoAttach { for t in browser.tabs { attach(st, t) } }
            return [:]
        case "Target.attachToTarget":
            return ["sessionId": attach(st, try tab(forTarget: p["targetId"] as? String)).id]
        case "Target.detachFromTarget":
            if let sid = p["sessionId"] as? String, let s = st.sessions.removeValue(forKey: sid) {
                send(st, ["method": "Target.detachedFromTarget", "params": ["sessionId": sid, "targetId": s.tab.targetId]])
            }
            return [:]
        case "Target.getTargets":
            return ["targetInfos": browser.tabs.map(targetInfo)]
        case "Target.getTargetInfo":
            if let id = p["targetId"] as? String { return ["targetInfo": targetInfo(try tab(forTarget: id))] }
            if let s = sess { return ["targetInfo": targetInfo(s.tab)] }
            return ["targetInfo": ["targetId": browserId, "type": "browser", "title": "", "url": "", "attached": true, "canAccessOpener": false]]
        case "Target.createTarget":
            let tab = browser.openTab()
            if let u = p["url"] as? String, !u.isEmpty, u != "about:blank", let url = URL(string: u) {
                tab.webView.load(URLRequest(url: url))
            }
            return ["targetId": tab.targetId]
        case "Target.closeTarget":
            browser.closeTab(try tab(forTarget: p["targetId"] as? String))
            return ["success": true]
        case "Target.activateTarget":
            browser.activate(try tab(forTarget: p["targetId"] as? String))
            return [:]
        case "Target.getBrowserContexts":
            return ["browserContextIds": []]
        case "Target.createBrowserContext", "Target.disposeBrowserContext":
            throw CDPError(code: -32000, message: "Browser contexts are not supported: all pages share the session's single profile")

        // ---- cookies (browser-wide)
        case "Storage.getCookies", "Network.getAllCookies":
            return ["cookies": await browser.cookieStore.allCookies().map(cdpCookie)]
        case "Network.getCookies":
            let all = await browser.cookieStore.allCookies()
            let urls = (p["urls"] as? [String]) ?? [sess?.tab.webView.url?.absoluteString].compactMap { $0 }
            let hosts = urls.compactMap { URL(string: $0)?.host }
            return ["cookies": all.filter { c in hosts.contains { h in h == c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) || h.hasSuffix(c.domain) } }.map(cdpCookie)]
        case "Network.setCookie":
            guard let c = cookie(from: p, default: sess?.tab) else { throw CDPError(code: -32602, message: "Invalid cookie fields") }
            await browser.cookieStore.setCookie(c)
            return ["success": true]
        case "Network.setCookies", "Storage.setCookies":
            for d in (p["cookies"] as? [[String: Any]]) ?? [] {
                guard let c = cookie(from: d, default: sess?.tab) else { throw CDPError(code: -32602, message: "Invalid cookie fields") }
                await browser.cookieStore.setCookie(c)
            }
            return [:]
        case "Network.deleteCookies":
            let name = p["name"] as? String
            for c in await browser.cookieStore.allCookies() where c.name == name {
                if let d = p["domain"] as? String, c.domain != d { continue }
                await browser.cookieStore.deleteCookie(c)
            }
            return [:]
        case "Network.clearBrowserCookies", "Storage.clearCookies":
            for c in await browser.cookieStore.allCookies() { await browser.cookieStore.deleteCookie(c) }
            return [:]

        default: break
        }

        // ---- everything below needs a page session
        let domain = String(method.split(separator: ".").first ?? "")
        if domain == "Fetch" {
            throw CDPError(code: -32000, message: "Request interception (Fetch domain) is not supported by WebKit")
        }
        if method.hasSuffix(".enable") || method.hasSuffix(".disable") {
            if let s = sess {
                if method.hasSuffix(".enable") { s.enabled.insert(domain) } else { s.enabled.remove(domain) }
                if method == "Runtime.enable" {
                    let ts = tabState(s.tab)
                    if ts.contextId == 0 { ts.contextId = contextSeq; contextSeq += 1 }
                    emit("Runtime.executionContextCreated", ["context": contextDescription(s.tab, id: ts.contextId)], tab: s.tab, requires: "Runtime")
                }
            }
            return [:]
        }
        let tab = try need(sess)

        switch method {
        // ---- Page
        case "Page.getFrameTree":
            return ["frameTree": ["frame": frame(tab), "childFrames": []]]
        case "Page.getResourceTree":
            return ["frameTree": ["frame": frame(tab), "resources": [], "childFrames": []]]
        case "Page.navigate": return try await navigate(tab, p)
        case "Page.reload": tab.webView.reload(); return [:]
        case "Page.stopLoading": tab.webView.stopLoading(); return [:]
        case "Page.bringToFront": browser.activate(tab); return [:]
        case "Page.close": browser.closeTab(tab); return [:]
        case "Page.captureScreenshot": return try await screenshot(tab, p)
        case "Page.printToPDF":
            let data = try await tab.webView.pdf()
            if p["transferMode"] as? String == "ReturnAsStream" {
                streamSeq += 1
                let h = "pdf\(streamSeq)"
                streams[h] = data
                return ["data": "", "stream": h]
            }
            return ["data": data.base64EncodedString()]
        case "Page.getLayoutMetrics":
            let m = try await page(tab, "cdpMetrics()")
            let w = (m["w"] as? NSNumber)?.doubleValue ?? 0, h = (m["h"] as? NSNumber)?.doubleValue ?? 0
            let x = (m["x"] as? NSNumber)?.doubleValue ?? 0, y = (m["y"] as? NSNumber)?.doubleValue ?? 0
            let sw = (m["sw"] as? NSNumber)?.doubleValue ?? w, sh = (m["sh"] as? NSNumber)?.doubleValue ?? h
            let layout: [String: Any] = ["pageX": x, "pageY": y, "clientWidth": w, "clientHeight": h]
            let visual: [String: Any] = ["offsetX": 0, "offsetY": 0, "pageX": x, "pageY": y, "clientWidth": w, "clientHeight": h, "scale": 1, "zoom": 1]
            let content: [String: Any] = ["x": 0, "y": 0, "width": sw, "height": sh]
            return ["layoutViewport": layout, "visualViewport": visual, "contentSize": content,
                    "cssLayoutViewport": layout, "cssVisualViewport": visual, "cssContentSize": content]
        case "Page.addScriptToEvaluateOnNewDocument":
            let id = "\(nextScript)"
            nextScript += 1
            initScripts.append((id, p["source"] as? String ?? ""))
            if let w = p["worldName"] as? String, !w.isEmpty, !worldNames.contains(w) { worldNames.append(w) }
            browser.setInitScripts(initScripts.map(\.source))
            return ["identifier": id]
        case "Page.removeScriptToEvaluateOnNewDocument":
            initScripts.removeAll { $0.id == p["identifier"] as? String }
            browser.setInitScripts(initScripts.map(\.source))
            return [:]
        case "Page.createIsolatedWorld":
            // Evaluation always happens in the page's own world; the id exists so clients can proceed.
            let id = contextSeq
            contextSeq += 1
            if let w = p["worldName"] as? String, !w.isEmpty, !worldNames.contains(w) { worldNames.append(w) }
            emit("Runtime.executionContextCreated", ["context": contextDescription(tab, id: id, isDefault: false, name: p["worldName"] as? String ?? "")],
                 tab: tab, requires: "Runtime")
            return ["executionContextId": id]
        case "Page.setLifecycleEventsEnabled":
            sess?.lifecycle = p["enabled"] as? Bool ?? false
            if sess?.lifecycle == true, tab.webView.url != nil {
                lifecycleEvent("init", tab); lifecycleEvent("DOMContentLoaded", tab); lifecycleEvent("load", tab)
            }
            return [:]
        case "Page.getNavigationHistory":
            let list = tab.webView.backForwardList
            let items = list.backList + (list.currentItem.map { [$0] } ?? []) + list.forwardList
            return ["currentIndex": list.backList.count,
                    "entries": items.enumerated().map { ["id": $0.offset, "url": $0.element.url.absoluteString, "userTypedURL": $0.element.url.absoluteString,
                                                         "title": $0.element.title ?? "", "transitionType": "typed"] as [String: Any] }]
        case "Page.navigateToHistoryEntry":
            let list = tab.webView.backForwardList
            let items = list.backList + (list.currentItem.map { [$0] } ?? []) + list.forwardList
            guard let i = p["entryId"] as? Int, items.indices.contains(i) else { throw CDPError(code: -32602, message: "Invalid entryId") }
            tab.webView.go(to: items[i])
            return [:]
        case "Page.handleJavaScriptDialog":
            return [:]  // dialogs are accepted automatically (and reported as events)
        case "Page.setBypassCSP", "Page.setInterceptFileChooserDialog", "Page.setAdBlockingEnabled", "Page.setWebLifecycleState",
             "Page.resetNavigationHistory", "Page.addCompilationCache", "Page.setPrerenderingAllowed":
            return [:]

        // ---- Runtime
        case "Runtime.evaluate":
            return try await runtime(tab, "cdpEvaluate(expr, byValue, awaitP)",
                                     ["expr": p["expression"] as? String ?? "", "byValue": p["returnByValue"] as? Bool ?? false, "awaitP": p["awaitPromise"] as? Bool ?? false])
        case "Runtime.callFunctionOn":
            return try await runtime(tab, "cdpCall(fn, thisId, args, byValue, awaitP)",
                                     ["fn": p["functionDeclaration"] as? String ?? "", "thisId": p["objectId"] as? String ?? "",
                                      "args": p["arguments"] as? [[String: Any]] ?? [], "byValue": p["returnByValue"] as? Bool ?? false,
                                      "awaitP": p["awaitPromise"] as? Bool ?? false])
        case "Runtime.getProperties":
            return try await page(tab, "cdpProps(id, own)", ["id": p["objectId"] as? String ?? "", "own": p["ownProperties"] as? Bool ?? false])
        case "Runtime.releaseObject":
            _ = try await page(tab, "cdpRelease(id)", ["id": p["objectId"] as? String ?? ""])
            return [:]
        case "Runtime.releaseObjectGroup":
            _ = try await page(tab, "cdpRelease('')")
            return [:]
        case "Runtime.runIfWaitingForDebugger", "Runtime.discardConsoleEntries", "Runtime.setAsyncCallStackDepth",
             "Runtime.addBinding", "Runtime.removeBinding", "Runtime.setCustomObjectFormatterEnabled":
            return [:]  // addBinding is accepted but exposed bindings are not callable (documented gap)

        // ---- DOM
        case "DOM.setFileInputFiles":
            let spec = try browser.filesSpec((p["files"] as? [String]) ?? [])
            _ = try await page(tab, "cdpFiles(p, JSON.parse(spec))", ["p": p, "spec": spec])
            return [:]
        case "DOM.getDocument", "DOM.describeNode", "DOM.resolveNode", "DOM.requestNode", "DOM.querySelector", "DOM.querySelectorAll",
             "DOM.getBoxModel", "DOM.getContentQuads", "DOM.scrollIntoViewIfNeeded", "DOM.focus", "DOM.getOuterHTML", "DOM.getAttributes":
            return try await page(tab, "cdpDom(op, p)", ["op": String(method.dropFirst(4)).prefix(1).lowercased() + method.dropFirst(5), "p": p])

        // ---- Input
        case "Input.dispatchMouseEvent":
            _ = try await page(tab, "cdpMouse(t, x, y, b, c, dx, dy)", [
                "t": p["type"] as? String ?? "", "x": p["x"] as? Double ?? 0, "y": p["y"] as? Double ?? 0,
                "b": p["button"] as? String ?? "left", "c": p["clickCount"] as? Int ?? 1,
                "dx": p["deltaX"] as? Double ?? 0, "dy": p["deltaY"] as? Double ?? 0])
            return [:]
        case "Input.dispatchKeyEvent":
            _ = try await page(tab, "cdpKey(t, key, code, text, mods, kc)", [
                "t": p["type"] as? String ?? "", "key": p["key"] as? String ?? "", "code": p["code"] as? String ?? "",
                "text": p["text"] as? String ?? "", "mods": p["modifiers"] as? Int ?? 0, "kc": p["windowsVirtualKeyCode"] as? Int ?? 0])
            return [:]
        case "Input.insertText":
            _ = try await page(tab, "cdpInsert(text)", ["text": p["text"] as? String ?? ""])
            return [:]
        case "Input.setIgnoreInputEvents":
            return [:]

        // ---- Accessibility
        case "Accessibility.getFullAXTree":
            return try await page(tab, "cdpAx()")

        // ---- Emulation / Network settings that map onto WebKit
        case "Emulation.setUserAgentOverride", "Network.setUserAgentOverride":
            tab.webView.customUserAgent = p["userAgent"] as? String
            return [:]
        case "Emulation.setDeviceMetricsOverride", "Emulation.clearDeviceMetricsOverride", "Emulation.setEmulatedMedia",
             "Emulation.setTouchEmulationEnabled", "Emulation.setDefaultBackgroundColorOverride", "Emulation.setFocusEmulationEnabled",
             "Emulation.setScrollbarsHidden", "Emulation.setAutoDarkModeOverride", "Emulation.setEmitTouchEventsForMouse",
             "Network.setCacheDisabled", "Network.setBypassServiceWorker", "Security.setIgnoreCertificateErrors",
             "Log.clear", "Performance.getMetrics", "Inspector.enable":
            return method == "Performance.getMetrics" ? ["metrics": []] : [:]
        case "Network.getResponseBody":
            throw CDPError(code: -32000, message: "No resource with given identifier found (response bodies are not available from WebKit)")
        case "Network.setExtraHTTPHeaders", "Network.setRequestInterception", "Network.emulateNetworkConditions",
             "Network.emulateNetworkConditionsByRule":
            throw CDPError(code: -32000, message: "\(method) is not supported: WKWebView cannot modify or throttle requests")
        default:
            if domain == "Fetch" {
                throw CDPError(code: -32000, message: "Request interception (Fetch domain) is not supported by WebKit")
            }
            throw CDPError(code: -32601, message: "'\(method)' wasn't found")
        }
    }

    // MARK: command helpers

    private func runtime(_ tab: Tab, _ call: String, _ args: [String: Any]) async throws -> [String: Any] {
        try await page(tab, call, args)
    }

    private func navigate(_ tab: Tab, _ p: [String: Any]) async throws -> [String: Any] {
        guard var raw = p["url"] as? String, !raw.isEmpty else { throw CDPError(code: -32602, message: "Cannot navigate to invalid URL") }
        if !raw.contains(":") { raw = "https://" + raw }
        guard let url = URL(string: raw) else { throw CDPError(code: -32602, message: "Cannot navigate to invalid URL") }
        let ts = tabState(tab)
        // Fragment-only changes stay in the same document (no new loader, no commit).
        if let cur = tab.webView.url, url.fragment != nil,
           cur.absoluteString.components(separatedBy: "#")[0] == raw.components(separatedBy: "#")[0] {
            _ = try await browser.eval(on: tab, "location.href = u", ["u": raw])
            return ["frameId": tab.targetId]
        }
        let commits = tab.committedCount, dls = browser.downloadSeq
        tab.lastFailure = nil
        if url.isFileURL { tab.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { tab.webView.load(URLRequest(url: url)) }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if tab.committedCount != commits { return ["frameId": tab.targetId, "loaderId": ts.loaderId] }
            if let f = tab.lastFailure { return ["frameId": tab.targetId, "loaderId": ts.loaderId, "errorText": "net::ERR_FAILED: \(f)"] }
            if browser.downloadSeq != dls { return ["frameId": tab.targetId, "loaderId": ts.loaderId, "errorText": "net::ERR_ABORTED"] }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CDPError(code: -32000, message: "Navigation timed out after 30s")
    }

    private func screenshot(_ tab: Tab, _ p: [String: Any]) async throws -> [String: Any] {
        if browser.current !== tab { browser.activate(tab) }  // a page must be on the window to render
        let cfg = WKSnapshotConfiguration()
        if let c = p["clip"] as? [String: Any], let x = (c["x"] as? NSNumber)?.doubleValue, let y = (c["y"] as? NSNumber)?.doubleValue,
           let w = (c["width"] as? NSNumber)?.doubleValue, let h = (c["height"] as? NSNumber)?.doubleValue, w > 0, h > 0 {
            cfg.rect = NSRect(x: x, y: y, width: w, height: h)
        }
        let image = try await tab.webView.takeSnapshot(configuration: cfg)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            throw CDPError(code: -32000, message: "Could not capture screenshot")
        }
        let fmt = p["format"] as? String ?? "png"
        let data: Data?
        if fmt == "jpeg" {
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: Double(p["quality"] as? Int ?? 80) / 100])
        } else {
            data = rep.representation(using: .png, properties: [:])
        }
        guard let data else { throw CDPError(code: -32000, message: "Could not encode screenshot") }
        return ["data": data.base64EncodedString()]
    }

    private func cdpCookie(_ c: HTTPCookie) -> [String: Any] {
        var d: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path,
                                "expires": c.expiresDate?.timeIntervalSince1970 ?? -1, "size": c.name.utf8.count + c.value.utf8.count,
                                "httpOnly": c.isHTTPOnly, "secure": c.isSecure, "session": c.expiresDate == nil,
                                "priority": "Medium", "sameParty": false, "sourceScheme": c.isSecure ? "Secure" : "NonSecure"]
        if let s = c.sameSitePolicy?.rawValue { d["sameSite"] = s.prefix(1).uppercased() + s.dropFirst().lowercased() }
        return d
    }

    private func cookie(from d: [String: Any], default tab: Tab?) -> HTTPCookie? {
        var m = d
        if m["domain"] == nil {
            let urlString = (d["url"] as? String) ?? tab?.webView.url?.absoluteString
            guard let u = urlString.flatMap(URL.init(string:)), let host = u.host else { return nil }
            m["domain"] = host
            if m["path"] == nil { m["path"] = "/" }
            if m["secure"] == nil, u.scheme == "https" { m["secure"] = true }
        }
        if let e = (m["expires"] as? NSNumber)?.doubleValue, e <= 0 { m["expires"] = nil }
        return browser.makeCookie(m)
    }
}
