import AppKit
import SwitchmypanesCore

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

        @MainActor func scenario(_ name: String, notifications: Bool) -> Bool {
            line("\n== \(name)")
            let pa = host("selftest-A"), pb = host("selftest-B")
            defer { pa.terminate(); pb.terminate() }
            spin(1.8)
            guard let a = axWindow(of: pa), let b = axWindow(of: pb), let ida = ids.windowID(of: a), let idb = ids.windowID(of: b) else {
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
            spin(1.8)
            guard let a = axWindow(of: pa), let b = axWindow(of: pb), let ida = ids.windowID(of: a), let idb = ids.windowID(of: b) else {
                line("FAIL: could not reach the helper windows through Accessibility"); return false
            }
            let controller = LinkedGroupController(settings: SettingsStore.shared)
            controller.forceShowDividers = true
            controller.debugLog = { line("   [linked] \($0)") }
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
            spin(1.8)
            guard let a = axWindow(of: pa), let b = axWindow(of: pb), let ida = ids.windowID(of: a), let idb = ids.windowID(of: b) else {
                line("FAIL: could not reach the helper windows through Accessibility"); return false
            }
            let controller = LinkedGroupController(settings: SettingsStore.shared)
            controller.forceShowDividers = true
            controller.debugLog = { line("   [linked] \($0)") }
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
        let one = (only == nil || only == "1") ? scenario("separate processes, Accessibility notifications", notifications: true) : true
        let two = (only == nil || only == "2") ? scenario("separate processes, mouse-drag polling only (no notifications)", notifications: false) : true
        let three = (only == nil || only == "3") ? dividerScenario() : true
        let four = (only == nil || only == "4") ? laggyScenario() : true
        allPassed = one && two && three && four
        line("\n" + (allPassed ? "ALL PASSED" : "SOMETHING FAILED"))
    }
    exit(allPassed ? 0 : 1)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar app: no Dock icon
app.run()
