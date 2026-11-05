import AppKit
import SwiftUI
import SwitchmypanesCore

/// `Switchmypanes --render-overlay <folder>` draws the overlays offscreen, with sample windows, into PNG files, so the
/// look can be checked without opening the real overlay. A real blur needs the window server, so a flat translucent fill
/// stands in for the glass; the layout, typography, colours and spacing are the real ones.
@MainActor
enum OverlayPreview {
    // MARK: sample content

    private static func appIcon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// A fake "screenshot" of a window: dark editor, light browser, terminal, notes...
    private static func fakeWindow(kind: Int, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            let palette: [(NSColor, NSColor)] = [
                (NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 1), NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.95, alpha: 1)),  // editor
                (NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1), NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.95, alpha: 1)),  // browser
                (NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.06, alpha: 1), NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.45, alpha: 1)),  // terminal
                (NSColor(calibratedRed: 0.99, green: 0.97, blue: 0.88, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.15, alpha: 1)),  // notes
            ]
            let (bg, accent) = palette[kind % palette.count]
            bg.setFill(); r.fill()
            // title bar with the three dots
            (kind % 2 == 0 ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.06)).setFill()
            NSRect(x: 0, y: r.height - 22, width: r.width, height: 22).fill()
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill(); NSBezierPath(ovalIn: NSRect(x: 8 + CGFloat(i) * 14, y: r.height - 16, width: 9, height: 9)).fill()
            }
            // a sidebar and lines of "text"
            (kind % 2 == 0 ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.05)).setFill()
            NSRect(x: 0, y: 0, width: r.width * 0.22, height: r.height - 22).fill()
            let ink = kind % 2 == 0 ? NSColor.white.withAlphaComponent(0.42) : NSColor.black.withAlphaComponent(0.36)
            var y = r.height - 44
            var n = 0
            while y > 14 {
                (n % 5 == 0 ? accent : ink).setFill()
                let w = CGFloat([0.52, 0.38, 0.62, 0.28, 0.46, 0.34][n % 6]) * r.width * 0.7
                NSBezierPath(roundedRect: NSRect(x: r.width * 0.27, y: y, width: w, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
                y -= 14; n += 1
            }
            return true
        }
    }

    private static func sampleWindows() -> [(WindowInfo, NSImage?)] {
        let size = NSSize(width: 480, height: 300)
        func info(_ id: UInt32, _ app: String, _ title: String, bundle: String, label: String? = nil, placement: SwitchmypanesCore.WindowPlacement = .currentSpace) -> WindowInfo {
            WindowInfo(id: id, pid: 1, appName: app, title: title, frame: .zero, icon: appIcon(bundle), placement: placement, spaceLabel: label, bundleID: bundle)
        }
        return [
            (info(1, "Code", "ARCHITECTURE.md — switchmypanes", bundle: "com.microsoft.VSCode"), fakeWindow(kind: 0, size: size)),
            (info(2, "Google Chrome", "praneel-core/switchmypanes: An alternative for Alt+Tab for Mac.", bundle: "com.google.Chrome"), fakeWindow(kind: 1, size: size)),
            (info(3, "Terminal", "Terminal", bundle: "com.apple.Terminal"), fakeWindow(kind: 2, size: size)),
            (info(4, "Code", "Snapncrop Mac prompt — snapncrop", bundle: "com.microsoft.VSCode", label: "Full screen", placement: .otherSpace(.fullScreen)), fakeWindow(kind: 0, size: size)),
            (info(5, "Notes", "Shopping list", bundle: "com.apple.Notes", label: "Minimized", placement: .hiddenOrMinimized), fakeWindow(kind: 3, size: size)),
            (info(6, "Safari", "Safari", bundle: "com.apple.Safari", label: "Desktop 2", placement: .otherSpace(.desktop)), nil),   // no picture yet: shows the icon
        ]
    }

    // MARK: rendering

    private static func png(of view: NSView, over wallpaper: Bool, to url: URL) {
        view.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2, margin: CGFloat = 70
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        let panelImage = NSImage(size: size); panelImage.addRepresentation(rep)

        let canvasSize = NSSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        let out = NSImage(size: canvasSize, flipped: false) { r in
            if wallpaper {   // a colourful "desktop" behind, so the translucency and shadow can be judged
                NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.32, blue: 0.62, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.28, blue: 0.60, alpha: 1),
                                    NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.40, alpha: 1)])?.draw(in: r, angle: 35)
            }
            let shadow = NSShadow(); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            NSGraphicsContext.saveGraphicsState(); shadow.set()
            panelImage.draw(in: NSRect(x: margin, y: margin, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        guard let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
              let data = bmp.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    static func render(to folder: URL) {
        OverlayTheme.offscreenRender = true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let samples = sampleWindows()
        let thumbs = Dictionary(uniqueKeysWithValues: samples.compactMap { w, img in img.map { (w.id, $0) } })

        func make(_ windows: [WindowInfo], selected: Int, caption: String?, hints: [Hint], layout: SwitcherLayout? = nil) -> SwitcherPanel {
            let panel = SwitcherPanel()
            let plan = layout ?? SwitcherLayout.plan(count: windows.count, screen: screen)
            panel.present(windows: windows, layout: plan, selected: selected, on: screen, caption: caption, hints: hints, show: false,
                          thumbnail: { thumbs[$0] })
            return panel
        }
        let all = samples.map(\.0)
        // The first pass over an app icon renders it blank (icons load lazily), so warm them up with a throw-away pass.
        let warmUp = make(all, selected: 1, caption: nil, hints: .switcher(modifier: "⌥"))
        png(of: warmUp.contentSnapshotView, over: true, to: folder.appendingPathComponent(".warmup.png"))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(".warmup.png"))
        let switcher = make(all, selected: 1, caption: nil, hints: .switcher(modifier: "⌥"))
        png(of: switcher.contentSnapshotView, over: true, to: folder.appendingPathComponent("switcher.png"))
        let few = make(Array(all.prefix(3)), selected: 1, caption: nil, hints: .switcher(modifier: "⌥"))
        png(of: few.contentSnapshotView, over: true, to: folder.appendingPathComponent("switcher-3-windows.png"))
        let assist = make(Array(all.prefix(4)), selected: 0, caption: "Snap Assist: pick a window for the empty area", hints: .assist,
                          layout: SwitcherLayout.plan(count: 4, bounds: CGSize(width: 760, height: 800), widthFraction: 0.95, heightFraction: 0.9))
        png(of: assist.contentSnapshotView, over: true, to: folder.appendingPathComponent("snap-assist.png"))

        // Preferences (SwiftUI): hosted in an offscreen window so it can be drawn
        let host = NSHostingView(rootView: PreferencesView(settings: SettingsStore.shared))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 560)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -4000, y: -4000))     // far off every screen; never shown
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        png(of: host, over: false, to: folder.appendingPathComponent("preferences.png"))

        let choice = LayoutChoicePanel()
        choice.present(layouts: SnapLayout.presets, selected: 4, on: screen, show: false)
        png(of: choice.contentSnapshotView, over: true, to: folder.appendingPathComponent("snap-layouts.png"))
    }
}
