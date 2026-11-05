import AppKit
import SwitchmypanesCore

// `Switchmypanes --help` lists the diagnostic flags (nothing here runs in normal use of the app).
if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
    Switchmypanes: Windows-style Alt-Tab and window snapping for macOS (a menu bar app).
    Started without flags it runs as the menu bar app. Diagnostic flags (run the binary from a terminal):

      --list-windows            print the windows the switcher would show (app, title, desktop / minimized status,
                                whether a preview could be captured), then exit. No side effects.
          --exclude=<bundle id> also apply a "hide from switcher" exclusion (repeatable), to test the rule.
      --render-overlay <folder> draw the overlays offscreen with sample windows into PNG files (no side effects).
      --selftest-arrows         check that Down / Up pick the tile that is really drawn below / above, for every window count
                                (offscreen, no side effects). Prints PASS / FAIL.
      --selftest-overlay        open the real overlay once per look (Glass / Frosted / Dark) for about a second each, to check it
                                works. WARNING: the overlay flashes on your screen three times. Prints PASS / FAIL.
      --selftest-motion         play the snap animation once on screen (a glowing rectangle for about half a second)
                                and check it disappears again. Prints PASS / FAIL.
      --selftest-linked         test linked resizing against helper processes (normal, stubborn and slow apps, and the
                                hover behaviour). Opens nearly invisible helper windows in the bottom-right corner for
                                about a minute. Prints PASS / FAIL.
      --selftest-spaces         test going to a window on another desktop whose app also has a window here.
                                WARNING: it switches your desktop and back. Prints SKIPPED if you have no such setup.
      --help, -h                this text

    Environment: SWITCHMYPANES_DEBUG=1 logs what linked resizing is doing to the terminal.
    """)
    exit(0)
}

// `Switchmypanes --render-overlay <folder>`: draws the overlays offscreen, with sample windows, into PNG files.
if let i = CommandLine.arguments.firstIndex(of: "--render-overlay") {
    let folder = CommandLine.arguments.dropFirst(i + 1).first ?? "overlay-previews"
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        OverlayPreview.render(to: URL(fileURLWithPath: folder))
    }
    print("rendered to \(folder)")
    exit(0)
}

// `Switchmypanes --selftest-arrows`: checks the arrow keys against the real, drawn tile positions (offscreen, no side effects).
if CommandLine.arguments.contains("--selftest-arrows") {
    var ok = false
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        ok = OverlayPreview.verifyArrowsMatchDrawing()
        print(ok ? "PASS" : "FAIL")
    }
    exit(ok ? 0 : 1)
}

// `Switchmypanes --selftest-overlay`: opens the real overlay once per look (Glass / Frosted / Dark) and checks it works.
if CommandLine.arguments.contains("--selftest-overlay") {
    var ok = false
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        ok = OverlayPreview.flashEachStyle()
        print(ok ? "PASS" : "FAIL")
    }
    exit(ok ? 0 : 1)
}

// `Switchmypanes --selftest-motion`: plays the snap animation once and checks it appears, then disappears completely.
if CommandLine.arguments.contains("--selftest-motion") {
    var ok = false
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        guard let d = DisplayProvider.layout().displays.first else { print("no display"); return }
        let v = d.visibleFrame
        let motion = SnapMotion()
        motion.play(from: CGRect(x: v.minX + 200, y: v.minY + 150, width: 500, height: 350),
                    to: CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height))
        spin(0.12)
        let during = motion.debugIsVisible
        spin(1.2)
        let after = motion.debugIsVisible
        print(OverlayTheme.motionEnabled ? "motion allowed" : "Reduce motion is ON: nothing should play")
        print(during || !OverlayTheme.motionEnabled ? "PASS: the outline appears while snapping" : "FAIL: the outline never appeared")
        print(!after ? "PASS: it is completely gone afterwards" : "FAIL: the outline is still on screen")
        ok = (during || !OverlayTheme.motionEnabled) && !after
    }
    exit(ok ? 0 : 1)
}

// Diagnostic: `Switchmypanes --list-windows` prints the windows the switcher would show (with their
// desktop / minimized status), then exits. Handy for checking what macOS reports. Prints to the terminal only.
if CommandLine.arguments.contains("--list-windows") {
    MainActor.assumeIsolated {
        // `--exclude=com.example.App` applies the "hide from switcher" exclusion, to check the rule against real windows.
        let excluded = CommandLine.arguments.compactMap { $0.hasPrefix("--exclude=") ? String($0.dropFirst(10)) : nil }
        let inventory = WindowInventory(ids: PrivateAXWindowIDProvider(), spaces: makeSpaceProvider(), options: { SpaceFilterOptions() },
                                        exclusions: { excluded.map { AppExclusion(pattern: $0) } })
        inventory.startTracking()
        RunLoop.current.run(until: Date().addingTimeInterval(3.5))   // lets the background minimized / hidden check finish
        let windows = inventory.snapshot(includeOtherSpaces: true, for: excluded.isEmpty ? nil : .switcher)
        let thumbnails = ThumbnailService()
        thumbnails.captureInBackground(windowIDs: windows.filter(\.isOnCurrentSpace).map(\.id), minInterval: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(3))     // let the captures finish
        for w in windows {
            let t = thumbnails.cached(w.id).map { "thumbnail \(Int($0.size.width))x\(Int($0.size.height))" } ?? "no thumbnail"
            print("\(w.id)\t\(w.appName)\t\(w.title)\t\(w.spaceLabel ?? "this desktop")\t\(t)")
        }
    }
    exit(0)
}

// Diagnostics for linked resizing (nothing here runs in normal use).
//  `--selftest-host <title>`  : a helper process with ONE nearly invisible window (used by the self-test below).
//  `--selftest-linked`        : spawns two such helper processes, links their windows as a group, "drags" the
//                               divider through Accessibility and reports whether the neighbour followed. It runs
//                               once with Accessibility notifications and once with mouse-drag polling only.
//                               The windows are 2% opaque, in the bottom-right corner, for about 15 seconds.
/// A test window that applies new frames a moment late, like apps that resize asynchronously (Chrome, Electron...).
final class LaggyWindow: NSWindow {
    var lag: TimeInterval = 0
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if lag <= 0 { super.setFrame(frameRect, display: flag); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + lag) { super.setFrame(frameRect, display: flag) }
    }
}

if let hostIndex = CommandLine.arguments.firstIndex(of: "--selftest-host") {
    let hostArgs = Array(CommandLine.arguments.dropFirst(hostIndex + 1))
    let title = hostArgs.first ?? "selftest"
    let minWidth = hostArgs.dropFirst().first.flatMap { Double($0) }.flatMap { $0 > 0 ? $0 : nil }
    let lagMs = hostArgs.dropFirst(2).first.flatMap { Double($0) } ?? 0
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let w = LaggyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 160), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.lag = lagMs / 1000
        w.title = title; w.alphaValue = 0.02; w.ignoresMouseEvents = true; w.isReleasedWhenClosed = false
        if let minWidth { w.minSize = NSSize(width: minWidth, height: 100) }     // a window that refuses to get narrower
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { exit(0) }     // never linger
        app.run()
    }
    exit(0)
}

if CommandLine.arguments.contains("--selftest-linked") {
    var allPassed = true
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func line(_ s: String) { print(s); fflush(stdout) }
        let ids = PrivateAXWindowIDProvider()
        guard let exe = Bundle.main.executablePath, let display = DisplayProvider.layout().displays.first else { line("setup failed"); allPassed = false; return }
        let visible = display.visibleFrame
        let base = CGRect(x: visible.maxX - 660, y: visible.maxY - 220, width: 600, height: 160)

        func host(_ title: String, minWidth: Int? = nil, lagMs: Int = 0) -> Process {
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["--selftest-host", title, String(minWidth ?? 0), String(lagMs)]
            try? p.run(); return p
        }
        func axWindow(of p: Process) -> AXUIElement? { AX.windows(of: AX.app(pid: p.processIdentifier)).first }
        /// A freshly built binary can take a few seconds to start its helper processes: wait for the window, up to 10 s.
        func waitFor(_ p: Process) -> AXUIElement? {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let w = axWindow(of: p) { spin(0.3); return w }
                spin(0.25)
            }
            return nil
        }

        @MainActor func scenario(_ name: String, notifications: Bool) -> Bool {
            line("\n== \(name)")
            let pa = host("selftest-A"), pb = host("selftest-B")
            defer { pa.terminate(); pb.terminate() }
            guard let a = waitFor(pa), let b = waitFor(pb), let ida = ids.windowID(of: a), let idb = ids.windowID(of: b) else {
                line("FAIL: could not reach the helper windows through Accessibility"); return false
            }
            let controller = LinkedGroupController(settings: SettingsStore.shared)
            controller.useNotifications = notifications
            controller.debugLog = { line("   [linked] \($0)") }
            WindowMover.apply(CGRect(x: base.minX, y: base.minY, width: 300, height: 160), to: a, bounds: visible)
            WindowMover.apply(CGRect(x: base.minX + 300, y: base.minY, width: 300, height: 160), to: b, bounds: visible)
            spin(0.4)
            line("placed: A \(AX.frame(a).map { "\($0)" } ?? "?")  B \(AX.frame(b).map { "\($0)" } ?? "?")")
            controller.register([.init(pid: pa.processIdentifier, windowID: ida, element: a), .init(pid: pb.processIdentifier, windowID: idb, element: b)], gap: 0, bounds: visible)
            spin(0.9)

            @MainActor func drag(_ delta: CGFloat) {
                let start = AX.frame(a)!
                for step in 1...5 {
                    AX.setSize(a, CGSize(width: start.width + delta / 5 * CGFloat(step), height: start.height))
                    if !notifications { controller.poll() }          // what a real mouse-drag event triggers
                    spin(0.06)
                }
                spin(0.8)
            }
            let startB = AX.frame(b)!
            drag(100)
            let a1 = AX.frame(a)!, b1 = AX.frame(b)!
            line("divider dragged right: A \(a1)  B \(b1)")
            let followed = abs(b1.minX - a1.maxX) <= 2 && b1.minX > startB.minX + 50
            drag(-100)
            let a2 = AX.frame(a)!, b2 = AX.frame(b)!
            line("dragged back:          A \(a2)  B \(b2)")
            let back = abs(b2.minX - a2.maxX) <= 2 && abs(b2.minX - startB.minX) <= 4
            line(followed ? "PASS: neighbour followed" : "FAIL: neighbour did NOT follow")
            line(back ? "PASS: followed back (link intact)" : "FAIL: dragging back broke the link")
            controller.removeAll()
            return followed && back
        }
                @MainActor func dividerScenario() -> Bool {
            line("\n== dragging the visible divider; the right window refuses to get narrower than 250")
            let pa = host("selftest-A"), pb = host("selftest-B", minWidth: 250)
            defer { pa.terminate(); pb.terminate() }
            guard let a = waitFor(pa), let b = waitFor(pb), let ida = ids.windowID(of: a), let idb = ids.windowID(of: b) else {
                line("FAIL: could not reach the helper windows through Accessibility"); return false
            }
            let controller = LinkedGroupController(settings: SettingsStore.shared)
            controller.debugLog = { line("   [linked] \($0)") }
            controller.debugWindowStack = { [(idb, AX.frame(b) ?? .zero), (ida, AX.frame(a) ?? .zero)] }    // the group's own windows are on top
            WindowMover.apply(CGRect(x: base.minX, y: base.minY, width: 300, height: 160), to: a, bounds: visible)
            WindowMover.apply(CGRect(x: base.minX + 300, y: base.minY, width: 300, height: 160), to: b, bounds: visible)
            spin(0.4)
            controller.register([.init(pid: pa.processIdentifier, windowID: ida, element: a), .init(pid: pb.processIdentifier, windowID: idb, element: b)], gap: 0, bounds: visible)
            spin(1.0)
            let line0 = controller.debugFirstDividerPosition
            line("divider line at x = \(line0.map { "\($0)" } ?? "none")   (expected \(base.minX + 300))")
            var ok = line0 != nil && abs(line0! - (base.minX + 300)) <= 2

            // 1. a normal drag: +40
            controller.debugDragFirstDivider(through: (1...4).map { base.minX + 300 + 10 * CGFloat($0) }, pause: { spin(0.06) })
            spin(1.4)
            var fa = AX.frame(a)!, fb = AX.frame(b)!
            line("dragged +40:        A \(fa)  B \(fb)  line at \(controller.debugFirstDividerPosition.map { "\($0)" } ?? "none")")
            let normal = abs(fa.maxX - (base.minX + 340)) <= 2 && abs(fb.minX - fa.maxX) <= 2
            line(normal ? "PASS: both windows moved with the divider" : "FAIL: windows did not follow a normal drag"); ok = ok && normal

            // 2. drag far to the right: B cannot get narrower than 250, so the line must stop at x = base + 350
            controller.debugDragFirstDivider(through: (1...12).map { base.minX + 340 + 15 * CGFloat($0) }, pause: { spin(0.08) })
            spin(2.6)
            fa = AX.frame(a)!; fb = AX.frame(b)!
            line("dragged far right:  A \(fa)  B \(fb)  line at \(controller.debugFirstDividerPosition.map { "\($0)" } ?? "none")")
            let noOverlap = fa.maxX <= fb.minX + 2, flush = abs(fa.maxX - fb.minX) <= 3, stopped = fb.width >= 249 && fb.minX <= base.minX + 352
            line(noOverlap ? "PASS: no overlap" : "FAIL: the windows overlap"); line(flush ? "PASS: still flush" : "FAIL: a gap opened up")
            line(stopped ? "PASS: the divider stopped at the stubborn window's limit" : "FAIL: it did not stop at the limit")
            ok = ok && noOverlap && flush && stopped

            // 3. drag back: the link must still work
            controller.debugDragFirstDivider(through: (1...12).map { base.minX + 520 - 20 * CGFloat($0) }, pause: { spin(0.08) })
            spin(2.2)
            fa = AX.frame(a)!; fb = AX.frame(b)!
            line("dragged back left:  A \(fa)  B \(fb)  line at \(controller.debugFirstDividerPosition.map { "\($0)" } ?? "none")")
            let back = abs(fb.minX - fa.maxX) <= 3 && fa.width < 300
            line(back ? "PASS: dragging back works, the link is intact" : "FAIL: the link broke"); ok = ok && back
            controller.removeAll()
            return ok
        }
                @MainActor func laggyScenario() -> Bool {
            line("\n== dragging the divider with slow apps (they apply resizes ~90 ms late), right and then left")
            let pa = host("selftest-A", lagMs: 90), pb = host("selftest-B", lagMs: 90)
            defer { pa.terminate(); pb.terminate() }
            guard let a = waitFor(pa), let b = waitFor(pb), let ida = ids.windowID(of: a), let idb = ids.windowID(of: b) else {
                line("FAIL: could not reach the helper windows through Accessibility"); return false
            }
            let controller = LinkedGroupController(settings: SettingsStore.shared)
            controller.debugLog = { line("   [linked] \($0)") }
            controller.debugWindowStack = { [(idb, AX.frame(b) ?? .zero), (ida, AX.frame(a) ?? .zero)] }    // the group's own windows are on top
            WindowMover.apply(CGRect(x: base.minX, y: base.minY, width: 300, height: 160), to: a, bounds: visible)
            WindowMover.apply(CGRect(x: base.minX + 300, y: base.minY, width: 300, height: 160), to: b, bounds: visible)
            spin(0.8)
            line("placed (slow apps): A \(AX.frame(a).map { "\($0)" } ?? "?")  B \(AX.frame(b).map { "\($0)" } ?? "?")")
            controller.register([.init(pid: pa.processIdentifier, windowID: ida, element: a), .init(pid: pb.processIdentifier, windowID: idb, element: b)], gap: 0, bounds: visible)
            spin(1.2)
            var ok = true

            controller.debugDragFirstDivider(through: (1...12).map { base.minX + 300 + 6 * CGFloat($0) }, pause: { spin(0.03) })   // fast drag, +72
            spin(2.4)
            var fa = AX.frame(a)!, fb = AX.frame(b)!
            line("dragged right +72:  A \(fa)  B \(fb)  line at \(controller.debugFirstDividerPosition.map { "\($0)" } ?? "none")")
            let right = abs(fa.maxX - (base.minX + 372)) <= 3 && abs(fb.minX - fa.maxX) <= 3
            line(right ? "PASS: both windows followed to the right, flush" : "FAIL: right drag glitched or did not finish flush"); ok = ok && right

            controller.debugDragFirstDivider(through: (1...20).map { base.minX + 372 - 8 * CGFloat($0) }, pause: { spin(0.03) })   // fast drag, -160
            spin(2.4)
            fa = AX.frame(a)!; fb = AX.frame(b)!
            line("dragged left -160:  A \(fa)  B \(fb)  line at \(controller.debugFirstDividerPosition.map { "\($0)" } ?? "none")")
            let left = abs(fa.maxX - (base.minX + 212)) <= 3 && abs(fb.minX - fa.maxX) <= 3
            line(left ? "PASS: both windows followed to the left, flush" : "FAIL: left drag glitched, or the link broke"); ok = ok && left

            let stillLinked = controller.debugFirstDividerPosition != nil
            line(stillLinked ? "PASS: the link (and its line) is still there" : "FAIL: the group dissolved"); ok = ok && stillLinked
            let bogus = controller.debugLearnedCount
            line(bogus == 0 ? "PASS: no bogus minimum size was learned from a slow app" : "FAIL: learned \(bogus) bogus minimum size(s) from a slow app"); ok = ok && bogus == 0
            controller.removeAll()
            return ok
        }
        let only = CommandLine.arguments.first { $0.hasPrefix("--only=") }.map { String($0.dropFirst(7)) }
                @MainActor func hoverScenario() -> Bool {
            line("\n== the divider line is hidden until you hover the middle of the seam")
            let pa = host("selftest-A"), pb = host("selftest-B")
            defer { pa.terminate(); pb.terminate() }
            guard let a = waitFor(pa), let b = waitFor(pb), let ida = ids.windowID(of: a), let idb = ids.windowID(of: b) else {
                line("FAIL: could not reach the helper windows through Accessibility"); return false
            }
            let controller = LinkedGroupController(settings: SettingsStore.shared)
            controller.debugWindowStack = { [(idb, AX.frame(b) ?? .zero), (ida, AX.frame(a) ?? .zero)] }    // the group's own windows are on top
            WindowMover.apply(CGRect(x: base.minX, y: base.minY, width: 300, height: 160), to: a, bounds: visible)
            WindowMover.apply(CGRect(x: base.minX + 300, y: base.minY, width: 300, height: 160), to: b, bounds: visible)
            spin(0.4)
            controller.register([.init(pid: pa.processIdentifier, windowID: ida, element: a), .init(pid: pb.processIdentifier, windowID: idb, element: b)], gap: 0, bounds: visible)
            spin(1.0)
            guard let ext = controller.debugDividerExtent else { line("FAIL: no divider was created"); return false }
            let mid = (ext.start + ext.end) / 2
            var ok = true
            func check(_ cond: Bool, _ pass: String, _ fail: String) { line(cond ? "PASS: \(pass)" : "FAIL: \(fail)"); ok = ok && cond }

            check(controller.debugRevealedLines == 0, "hidden by default", "the line is showing without hovering")
            controller.debugHover(at: CGPoint(x: ext.position + 40, y: mid)); spin(0.1)
            check(controller.debugRevealedLines == 0, "hovering NEXT to the seam does nothing", "revealed by a cursor away from the seam")
            controller.debugHover(at: CGPoint(x: ext.position, y: ext.start + 3)); spin(0.1)
            check(controller.debugRevealedLines == 0, "hovering the very end of the seam (scrollbar area) does nothing", "revealed near the end of the seam")
            controller.debugHover(at: CGPoint(x: ext.position + 2, y: mid)); spin(0.1)
            check(controller.debugRevealedLines == 1, "hovering the middle reveals the line", "the line did not appear when hovering the middle")
            controller.debugHover(at: CGPoint(x: ext.position, y: ext.start + 3)); spin(0.6)
            check(controller.debugRevealedLines == 1, "it stays while the cursor is anywhere along the line", "it vanished while the cursor was still on the line")
            controller.debugHover(at: CGPoint(x: ext.position + 120, y: mid)); spin(0.15)
            check(controller.debugRevealedLines == 1, "it does not vanish instantly when the cursor leaves", "it vanished instantly (no grace period)")
            spin(0.5)
            check(controller.debugRevealedLines == 0, "it fades out shortly after the cursor leaves", "it stayed visible after the cursor left")
            controller.debugHover(at: CGPoint(x: ext.position, y: mid)); spin(0.1)
            check(controller.debugRevealedLines == 1, "and comes back when you return to the middle", "it did not come back")
            controller.removeAll()
            return ok
        }
                @MainActor func coverScenario() -> Bool {
            line("\n== a divider line stays hidden while another window covers the seam")
            let pa = host("selftest-A"), pb = host("selftest-B")
            defer { pa.terminate(); pb.terminate() }
            guard let a = waitFor(pa), let b = waitFor(pb), let ida = ids.windowID(of: a), let idb = ids.windowID(of: b) else {
                line("FAIL: could not reach the helper windows through Accessibility"); return false
            }
            let controller = LinkedGroupController(settings: SettingsStore.shared)
            let frameA = CGRect(x: base.minX, y: base.minY, width: 300, height: 160), frameB = CGRect(x: base.minX + 300, y: base.minY, width: 300, height: 160)
            WindowMover.apply(frameA, to: a, bounds: visible); WindowMover.apply(frameB, to: b, bounds: visible)
            spin(0.5)
            // A made-up window stack (front to back), so this test does not depend on what else is on your screen.
            let plain: [(id: CGWindowID, bounds: CGRect)] = [(idb, frameB), (ida, frameA), (12345, visible)]
            controller.debugWindowStack = { plain }
            controller.register([.init(pid: pa.processIdentifier, windowID: ida, element: a), .init(pid: pb.processIdentifier, windowID: idb, element: b)], gap: 0, bounds: visible)
            spin(1.0)
            var ok = true
            func check(_ cond: Bool, _ pass: String, _ fail: String) { line(cond ? "PASS: \(pass)" : "FAIL: \(fail)"); ok = ok && cond }
            guard let ext = controller.debugDividerExtent else { line("FAIL: no divider was created"); return false }
            let mid = (ext.start + ext.end) / 2
            check(controller.debugVisibleDividerCount == 1, "seam in plain view: the line is allowed", "the line was suppressed although nothing covers the seam")

            // another window (even of the same app) in front of both, covering the seam
            let cover = CGRect(x: base.minX + 220, y: base.minY - 10, width: 160, height: 180)
            controller.debugWindowStack = { [(99999, cover)] + plain }
            controller.windowsChanged()
            check(controller.debugVisibleDividerCount == 0, "a window covers the seam: the line is hidden", "the line is still allowed over a covering window")
            controller.debugHover(at: CGPoint(x: ext.position + 2, y: mid)); spin(0.15)
            check(controller.debugRevealedLines == 0, "and hovering cannot bring it back over that window", "hovering revealed the line over a covering window")

            // a window that covers only the END of the seam does not matter (the middle is what is probed)
            controller.debugWindowStack = { [(99998, CGRect(x: base.minX + 220, y: base.minY - 40, width: 160, height: 30))] + plain }
            controller.windowsChanged()
            check(controller.debugVisibleDividerCount == 1, "something covering only the end of the seam does not hide it", "a covering window at the very end hid the line")

            controller.debugWindowStack = { plain }
            controller.windowsChanged()
            check(controller.debugVisibleDividerCount == 1, "the covering window goes away: the line is allowed again", "the line did not come back")
            controller.debugHover(at: CGPoint(x: ext.position + 2, y: mid)); spin(0.15)
            check(controller.debugRevealedLines == 1, "and hovering reveals it again", "hovering did not reveal it")
            controller.removeAll()
            return ok
        }
        let one = (only == nil || only == "1") ? scenario("separate processes, Accessibility notifications", notifications: true) : true
        let two = (only == nil || only == "2") ? scenario("separate processes, mouse-drag polling only (no notifications)", notifications: false) : true
        let three = (only == nil || only == "3") ? dividerScenario() : true
        let four = (only == nil || only == "4") ? laggyScenario() : true
        let five = (only == nil || only == "5") ? hoverScenario() : true
        let six = (only == nil || only == "6") ? coverScenario() : true
        allPassed = one && two && three && four && five && six
        line("\n" + (allPassed ? "ALL PASSED" : "SOMETHING FAILED"))
    }
    exit(allPassed ? 0 : 1)
}

// Diagnostic: `Switchmypanes --selftest-spaces` tests switching to a window on ANOTHER desktop whose app also has a
// window on the current desktop (the case that used to fail). It SWITCHES YOUR DESKTOP and then switches back.
if CommandLine.arguments.contains("--selftest-spaces") {
    var passed = false
    MainActor.assumeIsolated {
        func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func line(_ s: String) { print(s); fflush(stdout) }
        let ids = PrivateAXWindowIDProvider(), spaces = makeSpaceProvider()
        let inventory = WindowInventory(ids: ids, spaces: spaces, options: { SpaceFilterOptions() })
        inventory.startTracking()
        spin(3.5)
        let windows = inventory.snapshot(includeOtherSpaces: true, for: nil)
        guard let startSpaces = spaces.snapshot()?.activeSpaces,
              let home = windows.first(where: { $0.isOnCurrentSpace }),
              let target = windows.first(where: { w in
                  if case .otherSpace = w.placement { return windows.contains { $0.pid == w.pid && $0.isOnCurrentSpace } }
                  return false
              }) else {
            line("SKIPPED: no window on another desktop whose app also has a window on this desktop (put an app such as VS Code full screen on one desktop and keep another of its windows on this one, then run this again)"); passed = true; return
        }
        line("current desktop windows start with: \(home.appName) — \(home.title)")
        line("target (other desktop, same app also here): \(target.appName) — \(target.title) [\(target.spaceLabel ?? "?")]")
        SkyLightWindowFocus.debug = { line("   [skylight] \($0)") }
        let skyLight = SkyLightWindowFocus()
        line("SkyLight focus available: \(skyLight != nil)")

        func activeSpaces() -> Set<Int> { spaces.snapshot()?.activeSpaces ?? [] }
        func waitForSpaceChange(from: Set<Int>, seconds: Double) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if activeSpaces() != from { return true }; spin(0.2) }
            return false
        }
        func goHome() {
            guard activeSpaces() != startSpaces else { return }
            var finished = false
            spaces.switchToSpace(ofWindow: home.id) { _ in finished = true }
            let end = Date().addingTimeInterval(8)
            while Date() < end && !finished { spin(0.2) }
            spin(0.5)
        }

        // 1. the OLD method (ask the app to come forward): reproduces the bug
        line("\n-- old method (app-level activation only)")
        let oldActivator = WindowActivator(ids: ids, focus: nil, spaces: CurrentSpaceOnlyProvider())
        oldActivator.activate(target)
        let oldSwitched = waitForSpaceChange(from: startSpaces, seconds: 3)
        line(oldSwitched ? "old method DID switch desktop" : "old method did NOT switch desktop (this is the bug)")
        goHome(); spin(1.0)

        // 2. the NEW method
        line("\n-- new method (focus that exact window)")
        let newActivator = WindowActivator(ids: ids)
        newActivator.activate(target)
        let newSwitched = waitForSpaceChange(from: startSpaces, seconds: 4)
        spin(1.0)
        line(newSwitched ? "PASS: switched to the other desktop" : "FAIL: did not switch desktop")
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        line(frontPID == target.pid ? "PASS: the app is frontmost" : "NOTE: frontmost app is not the target app")
        withExtendedLifetime(oldActivator) {}
        withExtendedLifetime(newActivator) {}
        goHome(); spin(1.5)
        let back = activeSpaces() == startSpaces
        line(back ? "returned to the original desktop" : "WARNING: could not return to the original desktop automatically")
        passed = newSwitched
    }
    exit(passed ? 0 : 1)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar app: no Dock icon
app.run()
