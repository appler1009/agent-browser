// Draws the DMG window background in the icon's colors: indigo to teal, a curved arrow from the app to the
// Applications folder, and a one-line instruction at the top. Finder draws the icon names itself (black in
// light mode, white in dark mode), so the colors stay mid-tone and the pads behind the icons are faint.
// Icon positions must match package.sh (app at 170,200 and Applications at 490,200 in a 660x400 window).
// Usage: swift Scripts/make-dmg-background.swift <output.png> [scale]
import AppKit

let width: CGFloat = 660
let height: CGFloat = 400
let args = Array(CommandLine.arguments.dropFirst())
let out = args.first ?? "background.png"
let scale = args.count > 1 ? CGFloat(Double(args[1]) ?? 1) : 1

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)   // points, so a 2x bitmap is the retina representation
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let canvas = NSRect(x: 0, y: 0, width: width, height: height)
NSGradient(starting: color(0.22, 0.24, 0.62), ending: color(0.10, 0.62, 0.74))!.draw(in: canvas, angle: 20)
NSGradient(starting: color(1, 1, 1, 0), ending: color(1, 1, 1, 0.14))!
    .draw(from: NSPoint(x: width / 2, y: 120), to: NSPoint(x: width / 2, y: height), options: [])

// A faint globe line-art in the corner, echoing the icon.
let ring = NSBezierPath(ovalIn: NSRect(x: width - 150, y: -70, width: 230, height: 230))
ring.lineWidth = 2; color(1, 1, 1, 0.10).setStroke(); ring.stroke()
for k in [0.35, 0.7] as [CGFloat] {
    let e = NSBezierPath(ovalIn: NSRect(x: width - 150 + 115 * (1 - k), y: -70, width: 230 * k, height: 230))
    e.lineWidth = 2; e.stroke()
}

for x: CGFloat in [170, 490] {
    let pad = NSBezierPath(ovalIn: NSRect(x: x - 92, y: 200 - 92, width: 184, height: 184))
    color(1, 1, 1, 0.09).setFill(); pad.fill()
}

let arrow = NSBezierPath()
let start = NSPoint(x: 268, y: 214), end = NSPoint(x: 392, y: 214), control2 = NSPoint(x: 355, y: 262)
arrow.move(to: start)
arrow.curve(to: end, controlPoint1: NSPoint(x: 305, y: 262), controlPoint2: control2)
arrow.lineWidth = 7; arrow.lineCapStyle = .round
color(1, 1, 1, 0.92).setStroke(); arrow.stroke()
let heading = atan2(end.y - control2.y, end.x - control2.x)
func headPoint(_ o: CGFloat) -> NSPoint {
    let a = heading + .pi + o
    return NSPoint(x: end.x + 22 * cos(a), y: end.y + 22 * sin(a))
}
let head = NSBezierPath()
head.move(to: headPoint(0.55)); head.line(to: end); head.line(to: headPoint(-0.55))
head.lineWidth = 7; head.lineCapStyle = .round; head.lineJoinStyle = .round
head.stroke()

let style = NSMutableParagraphStyle(); style.alignment = .center
NSAttributedString(string: "Drag Agent Browser to Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: color(1, 1, 1, 0.95), .paragraphStyle: style,
]).draw(in: NSRect(x: 0, y: height - 56, width: width, height: 26))
NSAttributedString(string: "Open it once for the menu bar item. Its menu can install the agent-browser command.", attributes: [
    .font: NSFont.systemFont(ofSize: 12, weight: .regular), .foregroundColor: color(1, 1, 1, 0.78), .paragraphStyle: style,
]).draw(in: NSRect(x: 30, y: 36, width: width - 60, height: 34))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
