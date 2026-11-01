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
    private let vp = Browser.viewport

    init(window: NSWindow, webView: WatchWebView, session: String) {
        self.window = window
        self.webView = webView
        self.title = "agent-browser — \(session)"
        super.init()

        window.delegate = self
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .transient]
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

    // MARK: show / hide

    func show() {
        visible = true
        let screen = NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let chrome = Self.toolbarH + Self.timelineH
        let scale = min(1, (vis.width - 40) / vp.width, (vis.height - 60 - chrome) / vp.height)
        let w = (vp.width * scale).rounded(), h = (vp.height * scale).rounded()

        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = title
        window.ignoresMouseEvents = false
        window.setContentSize(NSSize(width: w, height: h + chrome))
        container.frame = NSRect(x: 0, y: 0, width: w, height: h + chrome)
        timeline.frame.size.width = w
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: Self.timelineH)
        webHolder.frame = NSRect(x: 0, y: Self.timelineH, width: w, height: h)
        webHolder.bounds = NSRect(origin: .zero, size: vp)  // scales the page down on small screens
        webView.frame = NSRect(origin: .zero, size: vp)
        toolbar.frame = NSRect(x: 0, y: Self.timelineH + h, width: w, height: Self.toolbarH)
        status.frame = NSRect(x: 10, y: 8, width: w - 190, height: 18)
        button.frame = NSRect(x: w - 170, y: 4, width: 160, height: 26)
        toolbar.isHidden = false
        scroll.isHidden = false
        window.setFrameTopLeftPoint(NSPoint(x: vis.maxX - w - 20, y: vis.maxY - 20))
        window.orderFrontRegardless()  // visible, but the app is not activated
        scrollTimelineToEnd()
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
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
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

    func step(_ text: String, ok: Bool) {
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
