// Draws the Switchmypanes app icon at every size macOS needs and builds Resources/AppIcon.icns.
// Run:  swift tools/make-app-icon.swift          (needs only the Command Line Tools; uses iconutil)
// The icon is drawn in code (no image files to edit): a dark glass squircle holding a 3-window layout, with the
// "selected" window lit in an accent gradient and a divider grip between the windows.
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        // macOS icon grid: the artwork is 824 of 1024 points, centred, with a soft drop shadow
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let radius = 186 * s
        let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 28 * s; shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.set()
        NSColor.black.setFill(); squircle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        // background: deep indigo to violet, with a lighter bloom top-left (like light through glass)
        NSGradient(colors: [NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.27, alpha: 1),
                            NSColor(calibratedRed: 0.30, green: 0.18, blue: 0.62, alpha: 1),
                            NSColor(calibratedRed: 0.46, green: 0.27, blue: 0.80, alpha: 1)])?.draw(in: body, angle: -55)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0)])?
            .draw(fromCenter: NSPoint(x: body.minX + 180 * s, y: body.maxY - 120 * s), radius: 0,
                  toCenter: NSPoint(x: body.minX + 180 * s, y: body.maxY - 120 * s), radius: 520 * s, options: [])

        // three windows: a tall one on the left, two stacked on the right
        let pad = 92 * s, gap = 30 * s
        let inner = body.insetBy(dx: pad, dy: pad)
        let leftW = (inner.width - gap) * 0.46
        let rightW = inner.width - gap - leftW
        let left = NSRect(x: inner.minX, y: inner.minY, width: leftW, height: inner.height)
        let topH = (inner.height - gap) / 2
        let rightTop = NSRect(x: inner.minX + leftW + gap, y: inner.minY + topH + gap, width: rightW, height: topH)
        let rightBottom = NSRect(x: inner.minX + leftW + gap, y: inner.minY, width: rightW, height: topH)

        func glassWindow(_ r: NSRect, selected: Bool) {
            let r2 = 46 * s
            let path = NSBezierPath(roundedRect: r, xRadius: r2, yRadius: r2)
            if selected {
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow(); glow.shadowBlurRadius = 40 * s; glow.shadowOffset = .zero
                glow.shadowColor = NSColor(calibratedRed: 0.30, green: 0.80, blue: 1.0, alpha: 0.75); glow.set()
                NSColor(calibratedRed: 0.20, green: 0.70, blue: 1.0, alpha: 1).setFill(); path.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGradient(colors: [NSColor(calibratedRed: 0.42, green: 0.90, blue: 1.0, alpha: 1),
                                    NSColor(calibratedRed: 0.16, green: 0.52, blue: 1.0, alpha: 1)])?.draw(in: path, angle: -60)
            } else {
                NSColor.white.withAlphaComponent(0.20).setFill(); path.fill()
            }
            // fine light edge, and a soft highlight along the top: glass
            NSColor.white.withAlphaComponent(selected ? 0.55 : 0.32).setStroke()
            path.lineWidth = 3 * s; path.stroke()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSGradient(colors: [NSColor.white.withAlphaComponent(selected ? 0.42 : 0.26), NSColor.white.withAlphaComponent(0)])?
                .draw(in: NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2), angle: -90)
            NSGraphicsContext.restoreGraphicsState()
            // a title bar's three dots
            for (i, c) in [0.95, 0.80, 0.65].enumerated() {
                NSColor.white.withAlphaComponent(c * (selected ? 0.9 : 0.55)).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.minX + (34 + CGFloat(i) * 30) * s, y: r.maxY - 52 * s, width: 15 * s, height: 15 * s)).fill()
            }
        }
        glassWindow(left, selected: false)
        glassWindow(rightBottom, selected: false)
        glassWindow(rightTop, selected: true)

        // the divider grip between the left window and the right ones: "these are linked"
        let gx = inner.minX + leftW + gap / 2
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: NSRect(x: gx - 7 * s, y: inner.midY - 70 * s, width: 14 * s, height: 140 * s), xRadius: 7 * s, yRadius: 7 * s).fill()
        NSGraphicsContext.restoreGraphicsState()

        // outer fine edge of the squircle
        NSColor.white.withAlphaComponent(0.22).setStroke()
        let edge = NSBezierPath(roundedRect: body.insetBy(dx: 1.5 * s, dy: 1.5 * s), xRadius: radius, yRadius: radius)
        edge.lineWidth = 3 * s; edge.stroke()
        return true
    }
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources", isDirectory: true)
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
// (name, point size, scale)
for (point, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = point * scale
    // drawn at exactly this size (vector), not scaled down from a big one, so small sizes stay crisp
    writePNG(drawIcon(size: CGFloat(pixels)), pixels: pixels, to: iconset.appendingPathComponent("icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"))
}
writePNG(drawIcon(size: 1024), pixels: 1024, to: root.appendingPathComponent("AppIcon-preview.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try? p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "wrote \(root.path)/AppIcon.icns (and AppIcon-preview.png)" : "iconutil failed")
