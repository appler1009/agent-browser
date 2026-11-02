import AppKit
import Foundation

// Menu bar item: shows every running session and lets the person show its window, take over, or close it.
// It is a separate process from the helpers (which keep working if it quits) and never starts a helper.

struct MenuEntry {
    var title: String
    var action: String? = nil          // "watch on demo", "open audit", ...; nil = not clickable
    var children: [MenuEntry]? = nil
    var separator = false
    var checked = false
    var icon: String? = nil            // favicon URL of the page; the menu bar item loads it

    var json: [String: Any] {
        var d: [String: Any] = ["title": title]
        if let action { d["action"] = action }
        if separator { d["separator"] = true }
        if checked { d["checked"] = true }
        if let icon { d["icon"] = icon }
        if let children { d["children"] = children.map(\.json) }
        return d
    }
    static let sep = MenuEntry(title: "", separator: true)
}

private func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

private func stateText(_ s: [String: Any]) -> String {
    switch s["state"] as? String ?? "idle" {
    case "working": return "working: " + clip(s["command"] as? String ?? "…", 50)
    case "paused": return (s["needs_you"] as? Bool == true) ? "paused, a command is waiting for you" : "paused (you have control)"
    case "approval": return "waiting for your approval of \"\(s["approval_for"] as? String ?? "a saved login")\""
    default: return "idle"
    }
}

func menubarHeaderGlyph(_ s: [String: Any]) -> String {
    if s["needs_you"] as? Bool == true { return "▲" }
    switch s["state"] as? String ?? "idle" {
    case "working": return "●"
    case "paused": return "❚❚"
    default: return "○"
    }
}

/// The whole menu as data, so it can be tested without a screen (`menubar --dump-menu`).
func menuModel(sessions: [[String: Any]], stale: Int, auditExists: Bool, loginItem: Bool) -> [MenuEntry] {
    var m: [MenuEntry] = [MenuEntry(title: "agent-browser \(agentBrowserVersion)"), .sep]
    if sessions.isEmpty {
        m.append(MenuEntry(title: "No running sessions"))
    }
    for s in sessions {
        let name = s["session"] as? String ?? "?"
        let host = URL(string: s["url"] as? String ?? "")?.host ?? ""
        let attention = s["needs_you"] as? Bool == true
        var sub: [MenuEntry] = []
        let title = (s["title"] as? String) ?? ""
        if !title.isEmpty { sub.append(MenuEntry(title: clip(title, 60))) }
        if let u = s["url"] as? String, !u.isEmpty { sub.append(MenuEntry(title: clip(u, 70))) }
        sub.append(MenuEntry(title: "State: " + stateText(s)))
        let prof = (s["profile"] as? String).map { "profile \($0)" } ?? "temporary profile"
        sub.append(MenuEntry(title: "\(s["tabs"] as? Int ?? 1) tab(s) · \(prof)"))
        sub.append(.sep)
        let watching = s["watching"] as? Bool == true, paused = s["paused"] as? Bool == true
        sub.append(MenuEntry(title: watching ? "Hide window" : "Show window", action: "watch \(watching ? "off" : "on") \(name)"))
        sub.append(paused ? MenuEntry(title: "Resume (give control back)", action: "watch resume \(name)")
                          : MenuEntry(title: "Take over (pause the agent)", action: "takeover \(name)"))
        sub.append(MenuEntry(title: "Save screenshot to Desktop", action: "screenshot \(name)"))
        if let steps = s["recent_steps"] as? [String], !steps.isEmpty {
            sub.append(MenuEntry(title: "Recent steps", children: steps.reversed().map { MenuEntry(title: clip($0, 80)) }))
        }
        sub.append(.sep)
        sub.append(MenuEntry(title: "Close session", action: "close \(name)"))
        // The favicon (or a globe) stands in front of the row, so the state glyph is only shown when something is going on.
        let glyph = menubarHeaderGlyph(s)
        m.append(MenuEntry(title: (glyph == "○" ? "" : "\(glyph)  ") + name + (host.isEmpty ? "" : " — \(host)") + (attention ? "  (needs you)" : ""),
                           children: sub, icon: s["favicon"] as? String ?? ""))
    }
    if stale > 0 { m.append(MenuEntry(title: "\(stale) stale session file(s)")) }
    m.append(.sep)
    m.append(MenuEntry(title: "Vault audit log…", action: auditExists ? "open audit" : nil))
    m.append(MenuEntry(title: "Open downloads folder", action: "open downloads"))
    m.append(.sep)
    m.append(MenuEntry(title: "Start at login", action: "login-item toggle", checked: loginItem))
    m.append(MenuEntry(title: "Quit menu bar item", action: "quit"))
    return m
}

// MARK: - launch agent ("start at login")

private let launchLabel = "dev.appler.agent-browser.menubar"
private func launchAgentsDir() -> String {
    ProcessInfo.processInfo.environment["AGENT_BROWSER_LAUNCH_AGENTS_DIR"] ?? NSHomeDirectory() + "/Library/LaunchAgents"
}
private var launchPlistPath: String { launchAgentsDir() + "/\(launchLabel).plist" }
func loginItemInstalled() -> Bool { FileManager.default.fileExists(atPath: launchPlistPath) }

private func launchctl(_ args: [String]) {
    if ProcessInfo.processInfo.environment["AGENT_BROWSER_LAUNCH_AGENTS_DIR"] != nil { return }  // tests: never touch launchd
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

func installLoginItem() throws -> String {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let abs = exe.hasPrefix("/") ? exe : FileManager.default.currentDirectoryPath + "/" + exe
    let plist: [String: Any] = ["Label": launchLabel, "ProgramArguments": [abs, "menubar", "--foreground"],
                                "RunAtLoad": true, "KeepAlive": false, "ProcessType": "Interactive"]
    try FileManager.default.createDirectory(atPath: launchAgentsDir(), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: launchPlistPath))
    launchctl(["bootout", "gui/\(getuid())/\(launchLabel)"])
    launchctl(["bootstrap", "gui/\(getuid())", launchPlistPath])
    return launchPlistPath
}

func removeLoginItem() {
    launchctl(["bootout", "gui/\(getuid())/\(launchLabel)"])
    try? FileManager.default.removeItem(atPath: launchPlistPath)
}

// MARK: - app

@MainActor
final class MenubarApp: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var sessions: [[String: Any]] = []
    private var stale = 0
    private var needs: Set<String> = []
    private var menuOpen = false

    func start() {
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refreshNow()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAsync() }
        }
    }

    private func refreshAsync() {
        DispatchQueue.global().async {
            let r = listSessions()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(r.sessions, r.stale) } }
        }
    }

    private func refreshNow() {
        let r = listSessions(timeout: 0.4)
        apply(r.sessions, r.stale)
    }

    // Favicons: fetched here, once per URL, with no cookies and no disk cache. Only https (or loopback http),
    // at most 256 KB, 5 s. The page chooses the URL, so this is the one request the menu bar item makes for a page.
    private var favicons: [String: NSImage] = [:]
    private var faviconTried: Set<String> = []
    private static let faviconSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5; c.timeoutIntervalForResource = 8
        c.httpCookieStorage = nil; c.urlCredentialStorage = nil; c.urlCache = nil
        return URLSession(configuration: c)
    }()

    private func loadFavicons() {
        for s in sessions {
            guard let f = s["favicon"] as? String, !faviconTried.contains(f), let u = URL(string: f),
                  u.scheme == "https" || (u.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(u.host ?? "")) else { continue }
            faviconTried.insert(f)
            if faviconTried.count > 200 { faviconTried.removeAll(); favicons.removeAll() }
            Self.faviconSession.dataTask(with: u) { data, resp, _ in
                guard let data, data.count <= 262_144, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let img = NSImage(data: data), img.size.width > 0 else { return }
                img.size = NSSize(width: 16, height: 16)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.favicons[f] = img } }
            }.resume()
        }
    }

    private func apply(_ s: [[String: Any]], _ staleCount: Int) {
        sessions = s
        stale = staleCount
        loadFavicons()
        updateIcon()
        notifyNewlyWaiting()
    }

    private func updateIcon() {
        let attention = sessions.contains { $0["needs_you"] as? Bool == true }
        let working = sessions.contains { $0["state"] as? String == "working" }
        let paused = sessions.contains { $0["state"] as? String == "paused" }
        let names = attention ? ["exclamationmark.circle.fill", "exclamationmark.circle"]
                  : paused ? ["pause.circle.fill", "pause.circle"]
                  : working ? ["arrow.triangle.2.circlepath", "circle.dotted"]
                  : ["globe"]
        guard let button = item.button else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize, weight: .regular)
        let base = names.lazy.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: "agent-browser")?.withSymbolConfiguration(cfg)
        }.first
        button.title = ""
        if let base {
            button.image = Self.badged(base, dot: !sessions.isEmpty)
        } else {
            button.image = nil
            button.title = sessions.isEmpty ? "AB" : "AB•"
        }
        button.toolTip = sessions.isEmpty ? "agent-browser: no running sessions" : "agent-browser: \(sessions.count) session(s)"
    }

    /// The symbol with a small dot at its lower right when any session is open (no count, to keep the bar quiet).
    /// Point size of the globe; the system default for a menu bar symbol is about 15.
    private static let iconPointSize: CGFloat = 16

    private static func badged(_ base: NSImage, dot: Bool) -> NSImage {
        let s = base.size
        let size = NSSize(width: ceil(s.width) + 2, height: max(20, ceil(s.height) + 2))
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            if dot {
                let d: CGFloat = 6
                let spot = NSRect(x: rect.maxX - d - 0.5, y: 0.5, width: d, height: d)
                NSGraphicsContext.current?.compositingOperation = .clear   // thin gap around the dot so it reads on the globe
                NSBezierPath(ovalIn: spot.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: spot).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func notifyNewlyWaiting() {
        let now = Set(sessions.filter { $0["needs_you"] as? Bool == true }.compactMap { $0["session"] as? String })
        for name in now.subtracting(needs) {
            let s = sessions.first { $0["session"] as? String == name }
            let what = s?["state"] as? String == "approval" ? "is waiting for you to approve a saved login" : "has a command waiting while you have control"
            notify(title: "agent-browser", body: "Session \"\(name)\" \(what).")
        }
        needs = now
    }

    private func notify(title: String, body: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: menu

    private var auditPath: String { makeVaultStore().auditPath }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menuOpen = true
        refreshNow()
        menu.removeAllItems()
        let model = menuModel(sessions: sessions, stale: stale, auditExists: FileManager.default.fileExists(atPath: auditPath),
                              loginItem: loginItemInstalled())
        for e in model { menu.addItem(makeItem(e)) }
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func makeItem(_ e: MenuEntry) -> NSMenuItem {
        if e.separator { return .separator() }
        let mi = NSMenuItem(title: e.title, action: e.action == nil ? nil : #selector(run(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = e.action
        mi.isEnabled = e.action != nil || e.children != nil
        mi.state = e.checked ? .on : .off
        if let ic = e.icon {  // session rows: the site's favicon once loaded, a globe until then
            mi.image = favicons[ic]
                ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        if let kids = e.children {
            let sub = NSMenu(title: e.title)
            sub.autoenablesItems = false
            for k in kids { sub.addItem(makeItem(k)) }
            mi.submenu = sub
        }
        return mi
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        let parts = action.split(separator: " ").map(String.init)
        switch parts.first ?? "" {
        case "quit": NSApplication.shared.terminate(nil)
        case "open":
            if parts.dropFirst().first == "audit" { NSWorkspace.shared.open(URL(fileURLWithPath: auditPath)) }
            else {
                let root = NSHomeDirectory() + "/.agent-browser/downloads"
                NSWorkspace.shared.open(URL(fileURLWithPath: FileManager.default.fileExists(atPath: root) ? root : NSHomeDirectory() + "/.agent-browser"))
            }
        case "login-item":
            if loginItemInstalled() { removeLoginItem() } else { _ = try? installLoginItem() }
        default:
            let session = parts.last ?? ""
            DispatchQueue.global().async {
                switch parts.first ?? "" {
                case "watch": _ = sendToRunning(session: session, request: ["cmd": "watch", "args": ["mode": parts[1]]])
                case "takeover":
                    _ = sendToRunning(session: session, request: ["cmd": "watch", "args": ["mode": "on"]])
                    _ = sendToRunning(session: session, request: ["cmd": "watch", "args": ["mode": "pause"]])
                case "screenshot":
                    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
                    let path = NSHomeDirectory() + "/Desktop/agent-browser \(session) \(f.string(from: Date())).png"
                    _ = sendToRunning(session: session, request: ["cmd": "screenshot", "args": ["path": path]], timeout: 30)
                case "close": _ = sendToRunning(session: session, request: ["cmd": "close", "args": [:]])
                default: break
                }
            }
        }
    }
}

// MARK: - command line

func runMenubarCLI(_ args: [String]) -> Never {
    let sub = args.first ?? "start"
    switch sub {
    case "--dump-menu":
        let r = listSessions()
        let m = menuModel(sessions: r.sessions, stale: r.stale, auditExists: FileManager.default.fileExists(atPath: makeVaultStore().auditPath),
                          loginItem: loginItemInstalled())
        print(jsonString(["ok": true, "result": ["menu": m.map(\.json)], "events": []]))
        exit(0)
    case "install":
        do { print(jsonString(["ok": true, "result": ["installed": try installLoginItem()], "events": []])) }
        catch { fail("MENUBAR_INSTALL_FAILED", "\(error)") }
        exit(0)
    case "uninstall":
        removeLoginItem()
        print(jsonString(["ok": true, "result": ["installed": false], "events": []]))
        exit(0)
    case "start":  // detach so the terminal can be closed
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        p.arguments = ["menubar", "--foreground"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { fail("MENUBAR_START_FAILED", "\(error)") }
        print(jsonString(["ok": true, "result": ["started": true, "note": "menu bar item is running; `menubar install` makes it start at login"], "events": []]))
        exit(0)
    case "--foreground":
        // One menu bar item per user.
        let dir = NSHomeDirectory() + "/.agent-browser"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockFd = open(dir + "/menubar.lock", O_CREAT | O_RDWR, 0o600)
        if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 { exit(0) }  // already running
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let m = MenubarApp()
            m.start()
            app.run()
            _ = m
        }
        exit(0)
    default:
        fail("USAGE", "menubar takes: [start] | install | uninstall | --dump-menu")
    }
}
