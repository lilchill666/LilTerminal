import AppKit
import Foundation

// Draws the app icon at any size and writes the .iconset macOS expects.
// Generated rather than hand-drawn so it can be regenerated and tweaked in code.

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
    ctx.setAllowsAntialiasing(true)

    // macOS icons sit inside the canvas with a margin rather than filling it.
    let inset = size * 0.085
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    // The system "squircle" is a continuous corner curve, ~22.4% of the width.
    let radius = rect.width * 0.224
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    shape.addClip()

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.31, green: 0.36, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.44, alpha: 1),
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.20, alpha: 1),
    ], atLocations: [0.0, 0.55, 1.0], colorSpace: .sRGB)
    gradient?.draw(in: rect, angle: -90)

    // A soft highlight across the top edge, the way Apple's icons catch light.
    let sheen = NSGradient(starting: NSColor(white: 1, alpha: 0.22),
                           ending: NSColor(white: 1, alpha: 0))
    sheen?.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2),
                angle: -90)
    ctx.restoreGState()

    // Prompt chevron and cursor: the universally legible "this is a terminal".
    let unit = rect.width
    let strokeWidth = unit * 0.085
    let chevron = NSBezierPath()
    chevron.lineWidth = strokeWidth
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    let cx = rect.minX + unit * 0.375
    let cy = rect.midY + unit * 0.055
    let arm = unit * 0.13
    chevron.move(to: CGPoint(x: cx - arm, y: cy + arm))
    chevron.line(to: CGPoint(x: cx + arm * 0.55, y: cy))
    chevron.line(to: CGPoint(x: cx - arm, y: cy - arm))
    NSColor(srgbRed: 0.72, green: 0.80, blue: 1.0, alpha: 1).setStroke()
    chevron.stroke()

    // Underscore cursor, sitting on the chevron's baseline.
    let cursor = NSBezierPath(roundedRect: CGRect(
        x: cx + arm * 0.95,
        y: cy - arm - strokeWidth / 2,
        width: unit * 0.26,
        height: strokeWidth
    ), xRadius: strokeWidth / 2, yRadius: strokeWidth / 2)
    NSColor.white.setFill()
    cursor.fill()

    // A hairline rim keeps the icon from bleeding into a light Dock.
    ctx.saveGState()
    NSColor(white: 1, alpha: 0.16).setStroke()
    let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                           xRadius: radius, yRadius: radius)
    rim.lineWidth = max(1, size * 0.004)
    rim.stroke()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL, pixels: Int) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/LilTerminal.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// The exact set iconutil requires.
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in entries {
    writePNG(draw(size: CGFloat(pixels)), to: out.appendingPathComponent("\(name).png"), pixels: pixels)
}
print("wrote \(out.path)")
