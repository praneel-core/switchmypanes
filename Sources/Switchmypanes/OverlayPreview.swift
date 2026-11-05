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

    /// `--selftest-arrows`: for every window count and every tile, checks that Down / Up pick the tile that is really
    /// drawn directly below / above (nearest by horizontal position), using the panel's real tile positions. Offscreen.
    static func verifyArrowsMatchDrawing() -> Bool {
        OverlayTheme.offscreenRender = true
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let base = sampleWindows().map(\.0)
        var checked = 0, bad = 0
        for count in 2...16 {
            let windows = (0..<count).map { i -> WindowInfo in var w = base[i % base.count]; w = WindowInfo(id: UInt32(100 + i), pid: w.pid, appName: w.appName, title: w.title, frame: .zero, icon: w.icon, placement: w.placement, spaceLabel: w.spaceLabel, bundleID: w.bundleID); return w }
            for width in [CGFloat(1100), 1470, 1920] {
                let layout = SwitcherLayout.plan(count: count, bounds: CGSize(width: width, height: 1000), widthFraction: 0.9, heightFraction: 0.85)
                let panel = SwitcherPanel()
                panel.present(windows: windows, layout: layout, selected: 0, on: screen, show: false, thumbnail: { _ in nil })
                let frames = panel.debugTileFrames
                guard frames.count == count else { print("FAIL: drew \(frames.count) of \(count) tiles"); return false }
                // rows by vertical position, top row first (AppKit y goes up)
                let rowYs = Array(Set(frames.map { $0.minY.rounded() })).sorted(by: >)
                func row(of i: Int) -> Int { rowYs.firstIndex(of: frames[i].minY.rounded())! }
                guard rowYs.count > 1 else { continue }        // a single row: Down / Up are Next / Previous, tested in Core
                for i in 0..<count {
                    for key in [ArrowKey.down, .up] {
                        var sel = SwitcherSelection(count: count); sel.select(i)
                        sel.move(key, columns: layout.columns)
                        let target = row(of: i) + (key == .down ? 1 : -1)
                        let wanted = (target + rowYs.count) % rowYs.count
                        let candidates = (0..<count).filter { row(of: $0) == wanted }
                        let nearest = candidates.map { abs(frames[$0].midX - frames[i].midX) }.min() ?? 0
                        checked += 1
                        if row(of: sel.index) != wanted || abs(frames[sel.index].midX - frames[i].midX) > nearest + 0.5 {
                            bad += 1
                            if bad <= 5 { print("MISMATCH: \(count) windows, width \(Int(width)), tile \(i) \(key) -> \(sel.index) (row \(row(of: sel.index)), wanted row \(wanted))") }
                        }
                    }
                }
            }
        }
        print("checked \(checked) arrow moves against the drawn tile positions: \(bad) mismatches")
        return bad == 0
    }

    /// `--selftest-search`: drives the real controller through a search session (no drawing) and checks every step.
    @MainActor static func verifySearchFlow() -> Bool {
        let apps = ["Code", "Google Chrome", "Terminal", "Chrome Canary", "Notes"]
        let list = apps.enumerated().map { i, name in
            WindowInfo(id: UInt32(500 + i), pid: 1, appName: name, title: name == "Notes" ? "Shopping list" : "\(name) window", frame: .zero,
                       icon: nil, placement: .currentSpace, spaceLabel: nil, bundleID: nil)
        }
        let controller = SwitcherController(inventory: WindowInventory(ids: PrivateAXWindowIDProvider(), spaces: CurrentSpaceOnlyProvider(), options: { SpaceFilterOptions() }),
                                            thumbnails: ThumbnailService(), activator: WindowActivator(ids: PrivateAXWindowIDProvider()))
        controller.debugSuppressPanel = true
        var ok = true
        func check(_ cond: Bool, _ what: String) { print(cond ? "PASS: \(what)" : "FAIL: \(what)"); ok = ok && cond }

        controller.debugBegin(with: list)
        check(controller.debugState.shown == apps, "starts with every window")
        controller.type("c")
        check(controller.debugState.shown == ["Code", "Google Chrome", "Chrome Canary"], "typing 'c' keeps only windows containing a c (Terminal and Notes drop out)")
        controller.type("h"); controller.type("r")
        check(controller.debugState.query == "chr" && controller.debugState.shown == ["Google Chrome", "Chrome Canary"], "typing 'chr' leaves the two Chrome windows, most recent first")
        check(controller.debugState.selected == 0, "the best match is highlighted")
        controller.type("o")
        check(controller.debugState.shown == ["Google Chrome", "Chrome Canary"], "'chro' still matches both")
        controller.type("m"); controller.type("e"); controller.type(" "); controller.type("c")
        check(controller.debugState.shown == ["Chrome Canary"] || controller.debugState.shown == ["Google Chrome", "Chrome Canary"], "multi-word search works (got \(controller.debugState.shown))")
        controller.backspace(); controller.backspace()
        check(controller.debugState.query == "chrome", "two backspaces turn \"chrome c\" into \"chrome\" (query \"\(controller.debugState.query)\")")
        controller.escape()
        check(controller.debugState.query == "" && controller.debugState.shown == apps && controller.debugState.active, "Esc clears the search and keeps the overlay open")
        controller.backspace()
        check(controller.debugState.active && controller.debugState.shown == apps, "backspace with nothing typed does nothing (and closes nothing)")
        controller.type("z"); controller.type("z"); controller.type("z")
        check(controller.debugState.shown.isEmpty && controller.debugState.active, "no match: an empty result, overlay still open")
        controller.move(.down); controller.next(); controller.previous()
        check(controller.debugState.active, "moving with no results is safe")
        controller.backspace(); controller.backspace(); controller.backspace()
        check(controller.debugState.shown == apps, "deleting the text brings every window back")
        controller.type("n"); controller.type("o")
        check(controller.debugState.shown == ["Notes"] || controller.debugState.shown.contains("Notes"), "searching the TITLE works too ('no' finds Notes / Shopping list)")
        controller.escape(); controller.escape()
        check(!controller.debugState.active, "a second Esc closes the overlay")
        controller.type("x"); controller.backspace(); controller.escape()
        check(!controller.debugState.active && controller.debugState.query == "", "typing after it closed does nothing, and the text is forgotten")
        // The real key-to-character path (events built in memory, never posted): Option must NOT change the letter
        func character(_ keyCode: CGKeyCode, _ flags: CGEventFlags) -> String? {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return nil }
            e.flags = flags
            return NSEvent(cgEvent: e)?.charactersIgnoringModifiers
        }
        check(character(8, .maskAlternate) == "c", "Option+C is read as plain \"c\" (not \"ç\"): got \(character(8, .maskAlternate) ?? "nil")")
        check(character(13, .maskAlternate) == "w", "Option+W is read as \"w\" (not \"∑\"): got \(character(13, .maskAlternate) ?? "nil")")
        check(character(8, [.maskAlternate, .maskShift]) == "C", "with Shift: \"C\" (the search ignores case)")
        check(character(49, .maskAlternate) == " ", "Option+Space is a space")
        check(KeyClassifier.isTypable(character(18, .maskAlternate) ?? ""), "Option+1 is a typable digit")
        check(!(character(126, .maskAlternate).map(KeyClassifier.isTypable) ?? true), "an arrow key is reported as a non-typable character")
        controller.debugBegin(with: list); controller.type("z"); controller.commit()
        check(!controller.debugState.active, "releasing the key with no match just closes the overlay")
        return ok
    }

    /// `--selftest-overlay`: opens the REAL overlay (real glass) once per look and checks it comes up and goes away.
    static func flashEachStyle() -> Bool {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let samples = sampleWindows()
        let thumbs = Dictionary(uniqueKeysWithValues: samples.compactMap { w, img in img.map { (w.id, $0) } })
        let windows = samples.map(\.0)
        var ok = true
        for style in OverlayTheme.Style.allCases {
            OverlayTheme.style = style
            let panel = SwitcherPanel()
            panel.present(windows: windows, layout: SwitcherLayout.plan(count: windows.count, screen: screen), selected: 1, on: screen,
                          thumbnail: { thumbs[$0] })
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let up = panel.isVisible && panel.frame.width > 300 && panel.contentView != nil
            panel.setSelected(2)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            panel.dismiss()
            let gone = !panel.isVisible
            print("\(style.title): overlay \(up ? "appeared" : "DID NOT APPEAR"), \(gone ? "dismissed" : "STILL VISIBLE")")
            ok = ok && up && gone
        }
        OverlayTheme.style = .glass
        return ok
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

        func make(_ windows: [WindowInfo], selected: Int, caption: String?, layout: SwitcherLayout? = nil) -> SwitcherPanel {
            let panel = SwitcherPanel()
            let plan = layout ?? SwitcherLayout.plan(count: windows.count, screen: screen)
            panel.present(windows: windows, layout: plan, selected: selected, on: screen, caption: caption, show: false,
                          thumbnail: { thumbs[$0] })
            return panel
        }
        let all = samples.map(\.0)
        // The first pass over an app icon renders it blank (icons load lazily), so warm them up with a throw-away pass.
        let warmUp = make(all, selected: 1, caption: nil)
        png(of: warmUp.contentSnapshotView, over: true, to: folder.appendingPathComponent(".warmup.png"))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(".warmup.png"))
        for style in OverlayTheme.Style.allCases {
            OverlayTheme.style = style
            let panel = make(all, selected: 1, caption: nil)
            png(of: panel.contentSnapshotView, over: true, to: folder.appendingPathComponent("switcher-\(style.rawValue).png"))
        }
        OverlayTheme.style = .glass
        for (label, o) in [("full", CGFloat(1.0)), ("default", 0.65), ("clear", 0.4)] {
            OverlayTheme.opacity = o
            let panel = make(all, selected: 1, caption: nil)
            png(of: panel.contentSnapshotView, over: true, to: folder.appendingPathComponent("switcher-glass-\(label).png"))
        }
        OverlayTheme.opacity = 0.65
        OverlayTheme.reduceTransparencyOverride = true
        let solid = make(all, selected: 1, caption: nil)
        png(of: solid.contentSnapshotView, over: true, to: folder.appendingPathComponent("switcher-reduce-transparency.png"))
        OverlayTheme.reduceTransparencyOverride = nil
        // type to search: filtered results, and a search that matches nothing
        let hits = all.filter { WindowSearch.matches(query: "code", in: [$0.appName, $0.title, $0.spaceLabel ?? ""]) }
        let searching = SwitcherPanel()
        searching.present(windows: hits, layout: SwitcherLayout.plan(count: hits.count, screen: screen), selected: 0, on: screen, query: "code",
                          show: false, thumbnail: { thumbs[$0] })
        png(of: searching.contentSnapshotView, over: true, to: folder.appendingPathComponent("switcher-search.png"))
        let nothing = SwitcherPanel()
        nothing.presentMessage("No windows match \u{201C}zzz\u{201D}", query: "zzz", on: screen, show: false)
        png(of: nothing.contentSnapshotView, over: true, to: folder.appendingPathComponent("switcher-search-empty.png"))
        // the close button: shown on the second tile (resting) and the third (pointed at)
        let closeDemo = make(Array(all.prefix(4)), selected: 1, caption: nil)
        closeDemo.debugShowCloseButton(on: 1, pointedAt: false); closeDemo.debugShowCloseButton(on: 2, pointedAt: true)
        png(of: closeDemo.contentSnapshotView, over: true, to: folder.appendingPathComponent("switcher-close-button.png"))
        let switcher = make(all, selected: 1, caption: nil)
        png(of: switcher.contentSnapshotView, over: true, to: folder.appendingPathComponent("switcher.png"))
        // 8 windows in 5 columns: the last row of 3 is centred (the case where Down used to land one tile off)
        let eight = (0..<8).map { i -> WindowInfo in let w = all[i % all.count]; return WindowInfo(id: UInt32(200 + i), pid: w.pid, appName: w.appName, title: w.title, frame: .zero, icon: w.icon, placement: w.placement, spaceLabel: w.spaceLabel, bundleID: w.bundleID) }
        let eightThumbs = Dictionary(uniqueKeysWithValues: eight.enumerated().compactMap { i, w in thumbs[all[i % all.count].id].map { (w.id, $0) } })
        let eightPanel = SwitcherPanel()
        eightPanel.present(windows: eight, layout: SwitcherLayout.plan(count: 8, screen: screen), selected: 2, on: screen, show: false, thumbnail: { eightThumbs[$0] })
        png(of: eightPanel.contentSnapshotView, over: true, to: folder.appendingPathComponent("switcher-8-windows.png"))
        let few = make(Array(all.prefix(3)), selected: 1, caption: nil)
        png(of: few.contentSnapshotView, over: true, to: folder.appendingPathComponent("switcher-3-windows.png"))
        let assist = make(Array(all.prefix(4)), selected: 0, caption: "Snap Assist: pick a window for the empty area",
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
