// Draws the app icon: a deep indigo-to-teal squircle with a white globe and the green "session open" dot
// of the menu bar item. Writes an .iconset folder; package.sh turns it into AppIcon.icns with iconutil.
// Usage: swift Scripts/make-icon.swift <output.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let body = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)   // the macOS icon grid
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0, 0, 0, 0.35); shadow.shadowBlurRadius = s * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    color(0.1, 0.12, 0.35).setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: color(0.17, 0.16, 0.50), ending: color(0.06, 0.62, 0.70))!.draw(in: body, angle: 55)
    NSGradient(starting: color(1, 1, 1, 0.20), ending: color(1, 1, 1, 0))!
        .draw(from: NSPoint(x: s / 2, y: body.maxY), to: NSPoint(x: s / 2, y: body.midY), options: [])
    NSGraphicsContext.restoreGraphicsState()

    // White globe.
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .regular).applying(.init(paletteColors: [.white]))
    if let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let g = globe.size
        let r = NSRect(x: (s - g.width) / 2, y: (s - g.height) / 2 + s * 0.01, width: g.width, height: g.height)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = color(0, 0, 0, 0.25); sh.shadowBlurRadius = s * 0.015; sh.shadowOffset = NSSize(width: 0, height: -s * 0.008); sh.set()
        globe.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
    }

    // The "session open" dot, as on the menu bar icon.
    let d = s * 0.15
    let dot = NSRect(x: body.maxX - d * 1.75, y: body.minY + d * 0.75, width: d, height: d)
    color(0.06, 0.12, 0.30).setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -d * 0.16, dy: -d * 0.16)).fill()
    color(0.30, 0.90, 0.50).setFill(); NSBezierPath(ovalIn: dot).fill()

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
