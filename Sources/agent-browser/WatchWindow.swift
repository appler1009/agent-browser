import AppKit
import WebKit

/// WKWebView that only receives mouse/scroll input while a human has taken over.
final class WatchWebView: WKWebView {
    var interactive = false
    override func hitTest(_ point: NSPoint) -> NSView? { interactive ? super.hitTest(point) : nil }
    override func scrollWheel(with event: NSEvent) { if interactive { super.scrollWheel(with: event) } }
}

/// Owns the window the page lives in. Hidden mode is a borderless off-screen window (the
/// default, "windowless"); watch mode shows the same page on screen with a step timeline and
/// a pause / take-over button. Showing it never activates the app or steals focus.
@MainActor
final class WatchWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var webView: WatchWebView
    private let title: String
    private let container = NSView()
    private let webHolder = NSView()
    private let toolbar = NSView()
    private let status = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Pause / take over", target: nil, action: nil)
    private let timeline = NSTextView()
    private let scroll = NSScrollView()
    private(set) var visible = false
    private(set) var paused = false

    private static let toolbarH: CGFloat = 34
    private static let timelineH: CGFloat = 150
    private var vp: NSSize { Browser.viewport }

    init(window: NSWindow, webView: WatchWebView, session: String) {
        self.window = window
        self.webView = webView
        self.title = "agent-browser — \(session)"
        super.init()

        window.delegate = self
        window.isReleasedWhenClosed = false
        // A regular, resizable, titled window (not a panel or utility window), so a window manager can tile and move it.
        window.hasShadow = true
        window.isExcludedFromWindowsMenu = false
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.contentView = container

        webHolder.addSubview(webView)
        container.addSubview(webHolder)

        status.font = .systemFont(ofSize: 12, weight: .medium)
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(togglePause)
        toolbar.addSubview(status)
        toolbar.addSubview(button)
        container.addSubview(toolbar)

        timeline.isEditable = false
        timeline.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        timeline.textContainerInset = NSSize(width: 6, height: 6)
        timeline.isVerticallyResizable = true
        timeline.autoresizingMask = [.width]
        scroll.documentView = timeline
        scroll.hasVerticalScroller = true
        container.addSubview(scroll)

        refreshControls()
        hide()
    }

    /// Makes `wv` the page shown in the window (used when the current tab changes).
    func attach(_ wv: WatchWebView) {
        if wv === webView && wv.superview === webHolder { return }
        webView.removeFromSuperview()
        webView.interactive = false
        webView = wv
        wv.interactive = paused
        webHolder.addSubview(wv)
        wv.frame = NSRect(origin: .zero, size: vp)
    }

    /// Re-applies the layout after the viewport size changed.
    func relayout() { if visible { show() } else { hide() } }

    // MARK: show / hide

    func show() {
        visible = true
        // The screen the pointer is on, so the window appears where the person is looking
        // (NSScreen.main can be another display for a background app).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let chrome = Self.toolbarH + Self.timelineH
        let scale = min(1, (vis.width - 40) / vp.width, (vis.height - 60 - chrome) / vp.height)
        let w = (vp.width * scale).rounded(), h = (vp.height * scale).rounded()

        NSApplication.shared.setActivationPolicy(.regular)  // a Dock entry while the window exists, as for any app window
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 520, height: 420)
        window.title = title
        window.alphaValue = 1
        window.level = .normal
        window.ignoresMouseEvents = false
        window.setContentSize(NSSize(width: w, height: h + chrome))
        container.frame = NSRect(x: 0, y: 0, width: w, height: h + chrome)
        layoutContent()
        toolbar.isHidden = false
        scroll.isHidden = false
        window.setFrameTopLeftPoint(NSPoint(x: vis.maxX - w - 20, y: vis.maxY - 20))
        window.orderFrontRegardless()  // visible, but the app is not activated
        scrollTimelineToEnd()
    }

    /// Fits the page (scaled to keep its proportions), the toolbar and the timeline into the current window size.
    private func layoutContent() {
        let cw = container.bounds.width, ch = container.bounds.height
        let availH = max(1, ch - Self.toolbarH - Self.timelineH)
        let scale = max(0.05, min(cw / vp.width, availH / vp.height))
        let w = (vp.width * scale).rounded(), h = (vp.height * scale).rounded()
        timeline.frame.size.width = cw
        scroll.frame = NSRect(x: 0, y: 0, width: cw, height: Self.timelineH)
        webHolder.frame = NSRect(x: ((cw - w) / 2).rounded(), y: Self.timelineH + ((availH - h) / 2).rounded(), width: w, height: h)
        webHolder.bounds = NSRect(origin: .zero, size: vp)  // scales the page to the window
        webView.frame = NSRect(origin: .zero, size: vp)
        toolbar.frame = NSRect(x: 0, y: ch - Self.toolbarH, width: cw, height: Self.toolbarH)
        status.frame = NSRect(x: 10, y: 8, width: max(40, cw - 190), height: 18)
        button.frame = NSRect(x: cw - 170, y: 4, width: 160, height: 26)
    }

    /// Asks the person about a page's confirm() or prompt() in a sheet on the watch window (shown if hidden).
    /// Gives up after `timeout` seconds so an unattended session never hangs; that counts as Cancel.
    func ask(kind: String, host: String, message: String, defaultText: String?, timeout: TimeInterval)
        async -> (accepted: Bool, text: String?, timedOut: Bool) {
        let alert = NSAlert()
        alert.messageText = kind == "prompt" ? "A page is asking for input" : "A page is asking you to confirm"
        let shown = message.count > 600 ? String(message.prefix(599)) + "…" : message
        alert.informativeText = (host.isEmpty ? "" : host + "\n\n") + shown
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        var field: NSTextField?
        if kind == "prompt" {
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            f.stringValue = defaultText ?? ""
            alert.accessoryView = f
            field = f
        }
        NSApplication.shared.activate(ignoringOtherApps: true)  // a question for you is worth the focus
        return await withCheckedContinuation { cont in
            var done = false
            var timedOut = false
            alert.beginSheetModal(for: window) { response in
                if done { return }
                done = true
                cont.resume(returning: (response == .alertFirstButtonReturn, field?.stringValue, timedOut))
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !done { timedOut = true; self.window.endSheet(alert.window, returnCode: .cancel) }
            }
        }
    }

    nonisolated func windowDidResize(_ notification: Notification) {
        MainActor.assumeIsolated { if visible { layoutContent() } }
    }

    func hide() {
        visible = false
        window.styleMask = [.borderless]
        window.ignoresMouseEvents = true
        toolbar.isHidden = true
        scroll.isHidden = true
        window.setContentSize(vp)
        container.frame = NSRect(origin: .zero, size: vp)
        webHolder.frame = NSRect(origin: .zero, size: vp)
        webHolder.bounds = NSRect(origin: .zero, size: vp)
        webView.frame = NSRect(origin: .zero, size: vp)
        // Hidden means hidden: no window at all (nothing transparent that could swallow clicks or confuse the person).
        // WebKit then treats the page as not visible, so pageScript keeps visibilityState and requestAnimationFrame working.
        window.orderOut(nil)
        NSApplication.shared.setActivationPolicy(.accessory)  // no Dock entry while hidden
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { hide() }
        return false  // keep the page alive; closing only hides the watch window
    }

    // MARK: pause / take over

    @objc private func togglePause() { setPaused(!paused) }

    func setPaused(_ p: Bool) {
        paused = p
        webView.interactive = p
        refreshControls()
        step(p ? "-- paused: human has control --" : "-- resumed: agent has control --", ok: true)
    }

    private func refreshControls() {
        button.title = paused ? "Resume agent" : "Pause / take over"
        status.stringValue = paused ? "PAUSED — you have control; agent commands wait" : "Agent running"
        status.textColor = paused ? .systemOrange : .secondaryLabelColor
    }

    // MARK: timeline

    /// The last steps, newest last (shown in the menu bar item).
    private(set) var recentSteps: [String] = []

    func step(_ text: String, ok: Bool) {
        recentSteps.append((ok ? "" : "✗ ") + text)
        if recentSteps.count > 12 { recentSteps.removeFirst(recentSteps.count - 12) }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date()))  \(text)\n"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: ok ? NSColor.labelColor : NSColor.systemRed,
        ]
        let storage = timeline.textStorage!
        storage.append(NSAttributedString(string: line, attributes: attrs))
        if storage.length > 200_000 { storage.deleteCharacters(in: NSRange(location: 0, length: 100_000)) }
        if visible { scrollTimelineToEnd() }
    }

    private func scrollTimelineToEnd() {
        timeline.scrollRangeToVisible(NSRange(location: timeline.string.utf16.count, length: 0))
    }
}
