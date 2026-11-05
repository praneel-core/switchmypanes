// Plain test runner (XCTest is not available with only the Command Line Tools installed).
// Run with:  swift run CoreChecks     Exit code is non-zero if any check fails.
import CoreGraphics
import Foundation
import SwitchmypanesCore

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var total = 0

func check(_ cond: @autoclosure () -> Bool, _ name: String, line: Int = #line) {
    total += 1
    if !cond() { failures += 1; print("  FAIL (line \(line)): \(name)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ name: String, line: Int = #line) {
    total += 1
    if a != b { failures += 1; print("  FAIL (line \(line)): \(name)\n    got:      \(a)\n    expected: \(b)") }
}
func section(_ s: String) { print("• \(s)") }

// MARK: coordinates
section("Coordinate conversion")
do {
    let c = CoordinateConverter(primaryHeight: 900)
    // AppKit bottom-left rect at the bottom of the screen -> top-left rect at y = 900 - 100
    eq(c.flip(CGRect(x: 10, y: 0, width: 200, height: 100)), CGRect(x: 10, y: 800, width: 200, height: 100), "bottom strip")
    let r = CGRect(x: -1440, y: 300, width: 800, height: 600)  // a screen left of and above the primary
    eq(c.flip(c.flip(r)), r, "flip is its own inverse")
    eq(c.flip(CGPoint(x: 5, y: 100)), CGPoint(x: 5, y: 800), "point flip")
    // A display above the primary has negative y in top-left coordinates
    eq(c.flip(CGRect(x: 0, y: 900, width: 1440, height: 900)).minY, -900, "screen above primary")
}

// MARK: zone geometry
section("Zone frames")
let visible = CGRect(x: 0, y: 25, width: 1440, height: 800)   // menu bar takes the top 25
do {
    eq(SnapEngine.frame(for: .left, in: visible), CGRect(x: 0, y: 25, width: 720, height: 800), "left half")
    eq(SnapEngine.frame(for: .right, in: visible), CGRect(x: 720, y: 25, width: 720, height: 800), "right half")
    eq(SnapEngine.frame(for: .maximize, in: visible), visible, "maximize")
    eq(SnapEngine.frame(for: .topLeft, in: visible), CGRect(x: 0, y: 25, width: 720, height: 400), "top-left")
    eq(SnapEngine.frame(for: .bottomRight, in: visible), CGRect(x: 720, y: 425, width: 720, height: 400), "bottom-right")
    let g = SnapEngine.frame(for: .left, in: visible, gap: 10)
    let h = SnapEngine.frame(for: .right, in: visible, gap: 10)
    eq(h.minX - g.maxX, 10, "gap between halves")
    eq(g.minX, 10, "gap at screen edge")
    eq(h.maxX, 1430, "right half fills to the inner edge")
    // odd sizes still tile exactly with no overlap and no hole
    let odd = CGRect(x: 0, y: 0, width: 1001, height: 701)
    let l = SnapEngine.frame(for: .left, in: odd), r = SnapEngine.frame(for: .right, in: odd)
    eq(l.maxX, r.minX, "odd width tiles exactly"); eq(r.maxX, odd.maxX, "odd width reaches edge")
    let tl = SnapEngine.frame(for: .topLeft, in: odd), bl = SnapEngine.frame(for: .bottomLeft, in: odd)
    eq(tl.maxY, bl.minY, "odd height tiles exactly")
}

section("Zone detection")
do {
    for z in SnapZone.allCases {
        eq(SnapEngine.detectZone(of: SnapEngine.frame(for: z, in: visible), in: visible), z, "detect \(z)")
    }
    let nudged = SnapEngine.frame(for: .left, in: visible).offsetBy(dx: 5, dy: 0)
    eq(SnapEngine.detectZone(of: nudged, in: visible), .left, "tolerates small drift")
    eq(SnapEngine.detectZone(of: CGRect(x: 100, y: 100, width: 600, height: 400), in: visible), nil, "unsnapped")
    eq(SnapEngine.detectZone(of: SnapEngine.frame(for: .left, in: visible, gap: 8), in: visible, gap: 8), .left, "detect with gap")
}

// MARK: state machine
section("Windows-style transitions")
func t(_ s: SnapZone?, _ k: ArrowKey, l: Bool = false, r: Bool = false) -> SnapAction {
    SnapEngine.transition(from: s, key: k, hasDisplayLeft: l, hasDisplayRight: r)
}
do {
    eq(t(nil, .left), .snap(.left), "unsnapped + left")
    eq(t(nil, .right), .snap(.right), "unsnapped + right")
    eq(t(nil, .up), .snap(.maximize), "unsnapped + up")
    eq(t(nil, .down), .minimize, "unsnapped + down minimizes")
    eq(t(.maximize, .down), .restore, "maximized + down restores")
    eq(t(.maximize, .left), .snap(.left), "maximized + left")
    eq(t(.left, .up), .snap(.topLeft), "Left then Up = top-left")
    eq(t(.left, .down), .snap(.bottomLeft), "Left then Down = bottom-left")
    eq(t(.right, .up), .snap(.topRight), "Right then Up = top-right")
    eq(t(.right, .down), .snap(.bottomRight), "Right then Down = bottom-right")
    eq(t(SnapZone.maximize, .up), .none, "maximized + up does nothing")
    eq(t(.left, .right), .restore, "left then right restores")
    eq(t(.left, .left), .none, "left edge, single display")
    eq(t(.left, .left, l: true), .moveToDisplay(.left, .right), "left half hops to display on the left")
    eq(t(.right, .right, r: true), .moveToDisplay(.right, .left), "right half hops to display on the right")
    eq(t(.topLeft, .right), .snap(.topRight), "top-left + right")
    eq(t(.topLeft, .up), .snap(.maximize), "top-left + up maximizes")
    eq(t(.bottomLeft, .down), .restore, "bottom-left + down restores")
    // every state/key pair yields something (no crashes, exhaustive)
    for s in [nil] + SnapZone.allCases.map({ Optional($0) }) {
        for k in [ArrowKey.left, .right, .up, .down] { _ = t(s, k, l: true, r: true) }
    }
    eq(SnapEngine.moveTransition(from: .left, key: .right, hasDisplayLeft: false, hasDisplayRight: true),
       .moveToDisplay(.right, .left), "shift+right keeps zone")
    eq(SnapEngine.moveTransition(from: nil, key: .left, hasDisplayLeft: true, hasDisplayRight: false),
       .moveToDisplay(.left, nil), "shift+left unsnapped")
    eq(SnapEngine.moveTransition(from: .left, key: .left, hasDisplayLeft: false, hasDisplayRight: false), .none, "no display to move to")
}

section("Drag to edge")
do {
    let d = CGRect(x: 0, y: 0, width: 1440, height: 900)
    func z(_ x: CGFloat, _ y: CGFloat, l: Bool = true, r: Bool = true) -> SnapZone? {
        SnapEngine.dragZone(at: CGPoint(x: x, y: y), in: d, leftIsSnapEdge: l, rightIsSnapEdge: r)
    }
    eq(z(700, 450), nil, "middle of the screen")
    eq(z(2, 450), .left, "left edge"); eq(z(1438, 450), .right, "right edge")
    eq(z(700, 1), .maximize, "top edge"); eq(z(700, 899), nil, "bottom edge has no zone")
    eq(z(2, 2), .topLeft, "top-left corner"); eq(z(1438, 2), .topRight, "top-right corner")
    eq(z(2, 898), .bottomLeft, "bottom-left corner"); eq(z(1438, 898), .bottomRight, "bottom-right corner")
    eq(z(2, 60), .topLeft, "left edge near the top counts as the corner")
    eq(z(40, 1), .topLeft, "top edge near the left counts as the corner")
    eq(z(2, 300), .left, "left edge below the corner zone")
    eq(z(2, 450, l: false), nil, "left edge shared with another display: not a snap edge")
    eq(z(2, 1, l: false), .maximize, "top-left with shared left edge falls back to maximize")
    eq(z(1438, 450, r: false), nil, "right edge shared with another display")
    eq(z(10, 450), nil, "just outside the 6 pt edge band")
}

section("Restore memory")
do {
    var m = RestoreMemory<Int>()
    let original = CGRect(x: 50, y: 60, width: 500, height: 400)
    m.willSnap(1, currentFrame: original, wasSnapped: false)
    m.willSnap(1, currentFrame: CGRect(x: 0, y: 0, width: 720, height: 800), wasSnapped: true)
    eq(m.peek(1), original, "snapped->snapped keeps the original")
    m.willSnap(1, currentFrame: CGRect(x: 9, y: 9, width: 300, height: 300), wasSnapped: false)
    eq(m.peek(1)?.minX, 9, "user moved it by hand: remember the new unsnapped frame")
    eq(m.take(1)?.width, 300, "take returns it"); eq(m.peek(1), nil, "and clears it")
}

section("Multi-display")
do {
    // Primary 1440x900 (menu bar 25) plus a bigger 2560x1440 display to its right, aligned at the top.
    let a = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                        visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800))
    let b = DisplayInfo(id: 2, frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440),
                        visibleFrame: CGRect(x: 1440, y: 25, width: 2560, height: 1380))
    let layout = DisplayLayout(displays: [b, a])   // deliberately unordered
    eq(layout.display(containing: CGRect(x: 100, y: 100, width: 500, height: 400))?.id, 1, "window on primary")
    eq(layout.display(containing: CGRect(x: 1300, y: 100, width: 600, height: 400))?.id, 2, "straddling: majority wins")
    eq(layout.display(containing: CGRect(x: 9000, y: 9000, width: 10, height: 10))?.id, 2, "offscreen: nearest")
    eq(layout.neighbor(of: a, .right)?.id, 2, "right neighbour"); eq(layout.neighbor(of: a, .left)?.id, nil, "no left neighbour")
    eq(layout.neighbor(of: b, .left)?.id, 1, "left neighbour")
    let moved = SnapEngine.frameOnDisplay(zone: .right, window: .zero, from: a.visibleFrame, to: b.visibleFrame)
    eq(moved, CGRect(x: 2720, y: 25, width: 1280, height: 1380), "zone is recomputed on the target display")
    let win = CGRect(x: 360, y: 225, width: 720, height: 400)  // centred-ish on a
    let rel = SnapEngine.frameOnDisplay(zone: nil, window: win, from: a.visibleFrame, to: b.visibleFrame)
    check(b.visibleFrame.contains(rel), "relative move stays inside the target")
    check(abs(rel.width / b.visibleFrame.width - win.width / a.visibleFrame.width) < 0.001, "relative width preserved")
    // negative coordinates: display above and to the left of the primary
    let c = DisplayInfo(id: 3, frame: CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
                        visibleFrame: CGRect(x: -1920, y: -1080, width: 1920, height: 1080))
    let l2 = DisplayLayout(displays: [a, c])
    eq(l2.display(containing: CGRect(x: -1500, y: -900, width: 400, height: 300))?.id, 3, "negative-origin display")
    eq(l2.neighbor(of: a, .left)?.id, 3, "left neighbour with negative origin")
    eq(SnapEngine.defaultRestoreFrame(in: a.visibleFrame), CGRect(x: 288, y: 185, width: 864, height: 480), "fallback restore frame")
}

// MARK: MRU
section("MRU ordering")
do {
    var m = MRUList<Int>()
    eq(m.ordered(live: [3, 2, 1]), [3, 2, 1], "unknown windows keep z-order")
    m.reconcile(live: [3, 2, 1])
    m.touch(1)
    eq(m.ordered(live: [3, 2, 1]), [1, 3, 2], "touch moves to front")
    eq(m.ordered(live: [3, 1]), [1, 3], "closed windows are dropped from the result")
    eq(m.ordered(live: [9, 3, 2, 1]), [9, 1, 3, 2], "new window goes in front")
    m.reconcile(live: [9, 3, 2, 1]); m.touch(2)
    eq(m.ordered(live: [9, 3, 2, 1]), [2, 9, 1, 3], "toggle order after touch")
    // Quick-tap toggle: windows A(front),B. Tap 1 selects index 1 (B) and commits it -> order B,A.
    // Tap 2 again selects index 1, which is now A: the two windows toggle.
    var toggle = MRUList<Int>(); toggle.reconcile(live: [10, 20])
    let tap1 = toggle.ordered(live: [10, 20])[SwitcherSelection(count: 2).index]
    toggle.touch(tap1); toggle.reconcile(live: [20, 10])
    let tap2 = toggle.ordered(live: [20, 10])[SwitcherSelection(count: 2).index]
    eq(tap1, 20, "first tap goes to the previous window"); eq(tap2, 10, "second tap comes back")
    var capped = MRUList<Int>(cap: 3); capped.reconcile(live: [1, 2, 3, 4, 5]); capped.reconcile(live: [5])
    check(capped.order.count <= 3, "dead entries are capped"); check(capped.order.contains(5), "live entries survive the cap")
    // Windows on another Space keep their place while they are not live.
    var spaces = MRUList<Int>(); spaces.reconcile(live: [30, 20, 10]); spaces.touch(10)   // order: 10, 30, 20
    spaces.reconcile(live: [20])                                                          // only 20 is on this Space
    eq(spaces.order, [10, 30, 20], "off-Space windows are not pushed to the back")
    eq(spaces.ordered(live: [30, 20, 10]), [10, 30, 20], "and are still in recency order when they come back")
    spaces.reconcile(live: [99, 20]); eq(spaces.order.first, 99, "a brand-new window goes to the front")
}

section("Switcher selection")
do {
    var s = SwitcherSelection(count: 4)
    eq(s.index, 1, "starts on the second window")
    s.next(); s.next(); eq(s.index, 3, "tab forward"); s.next(); eq(s.index, 0, "wraps forward")
    s.previous(); eq(s.index, 3, "shift+tab wraps backward")
    eq(SwitcherSelection(count: 4, reverse: true).index, 3, "reverse start is the last window")
    eq(SwitcherSelection(count: 1).index, 0, "single window"); eq(SwitcherSelection(count: 0).index, 0, "no windows")
    var e = SwitcherSelection(count: 0); e.next(); e.previous(); eq(e.index, 0, "empty selection is safe")
    var g = SwitcherSelection(count: 7); g.select(1)                 // 3 columns: rows are 0-2, 3-5 and just 6
    g.move(.down, columns: 3); eq(g.index, 4, "down moves one row")
    g.move(.down, columns: 3); eq(g.index, 6, "down into a short last row lands on its only window")
    g.move(.down, columns: 3); eq(g.index, 0, "down from the last row wraps to the top")
    g.move(.up, columns: 3); eq(g.index, 6, "up from the top row wraps to the bottom")
    g.move(.up, columns: 3); eq(g.index, 3, "up moves one row")
    var h = SwitcherSelection(count: 7); h.select(2)
    h.move(.down, columns: 3); eq(h.index, 5, "down within full rows")
    h.move(.down, columns: 3); eq(h.index, 6, "...then into the short last row")
    h = SwitcherSelection(count: 7); h.select(5)
    h.move(.down, columns: 3); eq(h.index, 6, "a short last row: down lands on its only window")
    h.move(.up, columns: 3); eq(h.index, 3, "and up from it goes back up a row")
    h = SwitcherSelection(count: 7); h.select(2); h.move(.up, columns: 3); eq(h.index, 5, "up from the top row into a column the short last row lacks: the row above it")
    // a single row: Down = next, Up = previous (this used to do nothing)
    var one = SwitcherSelection(count: 4); one.select(1)
    one.move(.down, columns: 4); eq(one.index, 2, "single row: down = next"); one.move(.down, columns: 4); one.move(.down, columns: 4); eq(one.index, 0, "single row: down wraps like tab")
    one.move(.up, columns: 4); eq(one.index, 3, "single row: up = previous (wraps)")
    var two = SwitcherSelection(count: 2); two.select(1); two.move(.down, columns: 5); eq(two.index, 0, "two windows: down still works")
    var none = SwitcherSelection(count: 0); none.move(.down, columns: 3); eq(none.index, 0, "no windows: safe")
    g.select(99); eq(g.index, 3, "out-of-range select ignored")
}

// MARK: keys
section("Key classification")
do {
    let cfg = ShortcutConfig()
    func kd(_ code: Int64, _ f: ShortcutModifiers, rep: Bool = false, active: Bool = false, _ c: ShortcutConfig = cfg) -> KeyAction {
        KeyClassifier.classifyKeyDown(keyCode: code, flags: f, isRepeat: rep, switcherActive: active, config: c)
    }
    eq(kd(48, .option), .switcherOpen(reverse: false), "Option+Tab opens")
    eq(kd(48, [.option, .shift]), .switcherOpen(reverse: true), "Option+Shift+Tab opens reversed")
    eq(kd(48, .command), .passThrough, "Cmd+Tab is left to macOS")
    eq(kd(48, []), .passThrough, "plain Tab is untouched")
    eq(kd(48, [.option, .control]), .passThrough, "extra modifier: not ours")
    eq(kd(48, .option, rep: true), .swallow, "auto-repeat while inactive is swallowed")
    eq(kd(48, .option, active: true), .switcherNext, "Tab while open")
    eq(kd(48, [.option, .shift], active: true), .switcherPrevious, "Shift+Tab while open")
    eq(kd(48, .option, rep: true, active: true), .switcherNext, "holding Tab keeps cycling")
    eq(kd(53, .option, active: true), .switcherCancel, "Esc cancels")
    eq(kd(124, .option, active: true), .switcherMove(.right), "arrow moves selection")
    eq(kd(12, .option, active: true), .passThrough, "Option+Q while open is not ours")
    eq(kd(48, [], active: true), .switcherCommit, "missed release is caught")
    eq(kd(123, [.control, .option]), .snap(.left, moveToDisplay: false), "Ctrl+Opt+Left snaps")
    eq(kd(126, [.control, .option, .shift]), .snap(.up, moveToDisplay: true), "with Shift: move display")
    eq(kd(123, .option), .passThrough, "Option+Left (word jump) is untouched")
    eq(kd(123, .command), .passThrough, "Cmd+Left is untouched")
    eq(kd(123, [.control, .option], rep: true), .swallow, "snap auto-repeat swallowed")
    eq(kd(0, [.control, .option]), .passThrough, "other keys pass through")
    var off = cfg; off.snapEnabled = false; off.switcherEnabled = false
    eq(kd(123, [.control, .option], off), .passThrough, "snap disabled"); eq(kd(48, .option, off), .passThrough, "switcher disabled")
    var cmdSnap = cfg; cmdSnap.snapModifiers = [.control, .command]
    eq(kd(124, [.control, .command], cmdSnap), .snap(.right, moveToDisplay: false), "custom modifiers")
    eq(kd(124, [.control, .option], cmdSnap), .passThrough, "old modifiers no longer match")
    eq(KeyClassifier.classifyFlagsChanged(flags: [], switcherActive: true, config: cfg), .switcherCommit, "release commits")
    eq(KeyClassifier.classifyFlagsChanged(flags: .option, switcherActive: true, config: cfg), .passThrough, "still held")
    eq(KeyClassifier.classifyFlagsChanged(flags: [], switcherActive: false, config: cfg), .passThrough, "inactive ignores")
}

section("Snap Layouts")
do {
    let layouts = SnapLayout.presets
    eq(layouts.count, 9, "nine presets (digit keys 1-9)")
    let v = CGRect(x: 0, y: 25, width: 1440, height: 800)
    for l in layouts {
        // At gap 0 the zones tile the screen exactly: total area equals the screen and nothing overlaps.
        let fs = (0..<l.zones.count).map { l.frame(ofZone: $0, in: v) }
        eq(fs.reduce(0) { $0 + $1.width * $1.height }, v.width * v.height, "\(l.name): zones cover the screen")
        var overlap = false
        for i in 0..<fs.count { for j in (i + 1)..<fs.count where fs[i].intersection(fs[j]).width > 0.5 && fs[i].intersection(fs[j]).height > 0.5 { overlap = true } }
        check(!overlap, "\(l.name): no overlap")
        check(fs.allSatisfy { v.contains($0) }, "\(l.name): inside the screen")
    }
    eq(layouts[0].frame(ofZone: 0, in: v), SnapEngine.frame(for: .left, in: v), "halves match the left snap zone")
    let grid = layouts[4]
    eq(grid.frame(ofZone: 3, in: v), SnapEngine.frame(for: .bottomRight, in: v), "grid zone 4 = bottom-right quarter")
    // gap: exactly `gap` between neighbours, and `gap` to the screen edge, even with awkward thirds
    let cols = layouts[3], odd = CGRect(x: 0, y: 0, width: 1001, height: 700)
    let a = cols.frame(ofZone: 0, in: odd, gap: 10), b = cols.frame(ofZone: 1, in: odd, gap: 10), c = cols.frame(ofZone: 2, in: odd, gap: 10)
    eq(b.minX - a.maxX, 10, "gap between column 1 and 2"); eq(c.minX - b.maxX, 10, "gap between column 2 and 3")
    eq(a.minX, 10, "gap at left edge"); eq(c.maxX, 991, "gap at right edge"); eq(a.minY, 10, "gap at top")
    let g = grid.frame(ofZone: 0, in: odd, gap: 8), g2 = grid.frame(ofZone: 3, in: odd, gap: 8)
    eq(g2.minY - g.maxY, 8, "gap between grid rows"); eq(g2.minX - g.maxX, 8, "gap between grid columns")
}

section("Picker keys")
do {
    let cfg = ShortcutConfig()
    func kd(_ code: Int64, _ f: ShortcutModifiers = [], rep: Bool = false, picker: Bool = false, active: Bool = false) -> KeyAction {
        KeyClassifier.classifyKeyDown(keyCode: code, flags: f, isRepeat: rep, switcherActive: active, pickerActive: picker, config: cfg)
    }
    eq(kd(6, .option), .layoutsOpen, "Option+Z opens Snap Layouts")
    eq(kd(6, .option, rep: true), .swallow, "repeat swallowed")
    eq(kd(6, []), .passThrough, "plain Z untouched"); eq(kd(6, [.option, .shift]), .passThrough, "Option+Shift+Z untouched")
    var off = cfg; off.layoutsEnabled = false
    eq(KeyClassifier.classifyKeyDown(keyCode: 6, flags: .option, isRepeat: false, switcherActive: false, config: off), .passThrough, "disabled")
    eq(kd(6, .option, active: true), .passThrough, "not while the Option+Tab switcher is open")
    eq(kd(53, picker: true), .pickerCancel, "Esc cancels"); eq(kd(36, picker: true), .pickerConfirm, "Return confirms")
    eq(kd(76, picker: true), .pickerConfirm, "keypad Enter confirms"); eq(kd(49, picker: true), .pickerSkip, "Space skips")
    eq(kd(124, picker: true), .pickerMove(.right), "arrow moves"); eq(kd(48, [.shift], picker: true), .pickerMove(.left), "Shift+Tab moves back")
    eq(kd(18, picker: true), .pickerChoose(1), "1"); eq(kd(25, picker: true), .pickerChoose(9), "9"); eq(kd(23, picker: true), .pickerChoose(5), "5")
    eq(kd(0, picker: true), .swallow, "other keys are swallowed while the picker is open")
    eq(kd(12, .command, picker: true), .passThrough, "Cmd+Q still works")
    eq(kd(6, .option, picker: true), .swallow, "Option+Z inside the picker does not reopen it")
}

section("Snap Assist")
do {
    eq(SnapEngine.assistTarget(afterSnappingTo: .left), .right, "left half leaves the right half")
    eq(SnapEngine.assistTarget(afterSnappingTo: .right), .left, "right half leaves the left half")
    eq(SnapEngine.assistTarget(afterSnappingTo: .maximize), nil, "maximize leaves nothing")
    eq(SnapEngine.assistTarget(afterSnappingTo: .topLeft), nil, "quarters: no assist")
    let cfg = ShortcutConfig()
    func a(_ code: Int64, _ f: ShortcutModifiers = []) -> KeyAction {
        KeyClassifier.classifyKeyDown(keyCode: code, flags: f, isRepeat: false, switcherActive: false,
                                      pickerActive: true, assistMode: true, config: cfg)
    }
    eq(a(53), .pickerCancel, "Esc closes"); eq(a(36), .pickerConfirm, "Return places")
    eq(a(124), .pickerMove(.right), "plain arrow moves"); eq(a(48, .shift), .pickerMove(.left), "Shift+Tab moves back")
    eq(a(126, [.control, .option]), .pickerDismiss, "a snap shortcut closes Assist, then snaps")
    eq(a(0), .pickerDismiss, "typing closes Assist and still types")
    eq(a(12, .command), .passThrough, "Cmd+Q untouched")
    eq(a(18), .pickerDismiss, "digits do not pick in Assist")
}

section("Space classification")
do {
    let kinds: [Int: SpaceKind] = [1: .desktop, 2: .desktop, 3: .fullScreen]
    func c(_ on: Bool, _ spaces: [Int], active: Set<Int> = [1]) -> WindowPlacement {
        SpaceClassifier.classify(isOnScreen: on, windowSpaces: spaces, activeSpaces: active, kinds: kinds)
    }
    eq(c(true, [1]), .currentSpace, "drawn = current Space")
    eq(c(false, [2]), .otherSpace(.desktop), "other desktop")
    eq(c(false, [3]), .otherSpace(.fullScreen), "full-screen app")
    eq(c(false, []), .noSpace, "junk window with no Space")
    eq(c(false, [1]), .hiddenOrMinimized, "not drawn but on the visible Space: minimized or hidden")
    eq(c(false, [3], active: [3]), .hiddenOrMinimized, "same, while you are inside a full-screen Space")
    eq(c(false, [1], active: [3]), .otherSpace(.desktop), "inside a full-screen Space, the desktop's windows are 'other'")
    eq(c(false, [2], active: [1, 2]), .hiddenOrMinimized, "two displays: each display's current Space counts")
    eq(c(false, [9]), .otherSpace(.other), "unknown Space kind")
    func o(_ ordered: Bool?, _ spaces: [Int] = [2]) -> WindowPlacement {
        SpaceClassifier.classify(isOnScreen: false, windowSpaces: spaces, activeSpaces: [1], kinds: kinds, isOrderedIn: ordered)
    }
    eq(o(true), .otherSpace(.desktop), "ordered in on another desktop: a real window")
    eq(o(true, [3]), .otherSpace(.fullScreen), "ordered in in a full-screen Space: a real full-screen window")
    eq(o(false), .orderedOutElsewhere, "ordered out on another desktop: closed to the background")
    eq(o(nil), .otherSpace(.desktop), "unknown: behave as before")
    eq(SpaceClassifier.classify(isOnScreen: true, windowSpaces: [1], activeSpaces: [1], kinds: kinds, isOrderedIn: false), .currentSpace, "drawn always wins")
    eq(SpaceClassifier.classify(isOnScreen: false, windowSpaces: [1], activeSpaces: [1], kinds: kinds, isOrderedIn: false), .hiddenOrMinimized, "on the visible Space: still minimized/hidden")
    let all = SpaceFilterOptions(), none = SpaceFilterOptions(includeOtherDesktops: false, includeFullScreen: false)
    check(SpaceClassifier.isIncluded(.currentSpace, options: none), "current Space always included")
    check(SpaceClassifier.isIncluded(.otherSpace(.desktop), options: all), "other desktops on")
    check(!SpaceClassifier.isIncluded(.otherSpace(.desktop), options: none), "other desktops off")
    check(SpaceClassifier.isIncluded(.otherSpace(.fullScreen), options: SpaceFilterOptions(includeOtherDesktops: false)), "full-screen independent of desktops")
    check(!SpaceClassifier.isIncluded(.otherSpace(.fullScreen), options: SpaceFilterOptions(includeFullScreen: false)), "full-screen off")
    check(SpaceClassifier.isIncluded(.orderedOutElsewhere, options: all) && !SpaceClassifier.isIncluded(.orderedOutElsewhere, options: SpaceFilterOptions(includeMinimized: false)), "ordered-out windows follow the minimized option")
    check(!SpaceClassifier.isIncluded(.noSpace, options: all), "windows with no Space are never included")
    check(SpaceClassifier.isIncluded(.hiddenOrMinimized, options: all), "minimized / hidden included by default")
    check(!SpaceClassifier.isIncluded(.hiddenOrMinimized, options: SpaceFilterOptions(includeMinimized: false)), "minimized off")
    check(SpaceClassifier.isIncluded(.otherSpace(.desktop), options: SpaceFilterOptions(includeMinimized: false)), "minimized off does not affect desktops")
    check(SpaceFilterOptions(includeOtherDesktops: false, includeFullScreen: false).needsFullWindowList, "minimized alone needs the full list")
    check(!SpaceFilterOptions(includeOtherDesktops: false, includeFullScreen: false, includeMinimized: false).needsFullWindowList, "all off: public on-screen list is enough")
}

section("Closing windows from the overlay")
do {
    var s = SwitcherSelection(count: 5); s.select(2)
    s.didRemove(at: 4, newCount: 4); eq(s.index, 2, "closing a later window keeps the highlight")
    s.didRemove(at: 0, newCount: 3); eq(s.index, 1, "closing an earlier window follows the same window")
    s.didRemove(at: 1, newCount: 2); eq(s.index, 1, "closing the highlighted window selects the next one")
    s.didRemove(at: 1, newCount: 1); eq(s.index, 0, "closing the last-listed highlighted window selects the one before")
    s.didRemove(at: 0, newCount: 0); eq(s.index, 0, "empty"); eq(s.count, 0, "count follows")
    var t = SwitcherSelection(count: 3); t.didRemove(at: 2, newCount: 2); eq(t.count, 2, "count shrinks"); t.next(); t.next(); eq(t.index, 1, "cycling uses the new count")
    let cfg = ShortcutConfig()
    func kd(_ code: Int64, _ f: ShortcutModifiers = .option, active: Bool = true) -> KeyAction {
        KeyClassifier.classifyKeyDown(keyCode: code, flags: f, isRepeat: false, switcherActive: active, config: cfg)
    }
    eq(kd(51), .switcherClose, "Delete closes"); eq(kd(13), .switcherClose, "W closes"); eq(kd(117), .switcherClose, "forward Delete closes")
    eq(kd(13, [], active: false), .passThrough, "W outside the switcher is untouched")
    eq(kd(13, .option, active: false), .passThrough, "Option+W outside the switcher is untouched")
}

section("Preview policy")
do {
    let ex = PreviewPolicy.defaultExcludedApps
    check(PreviewPolicy.isExcluded(bundleID: "com.1password.1password", excluded: ex), "1Password (wildcard)")
    check(PreviewPolicy.isExcluded(bundleID: "com.agilebits.onepassword7", excluded: ex), "1Password 7 (older ID)")
    check(PreviewPolicy.isExcluded(bundleID: "com.apple.keychainaccess", excluded: ex), "Keychain Access (exact)")
    check(PreviewPolicy.isExcluded(bundleID: "COM.APPLE.PASSWORDS", excluded: ex), "case-insensitive")
    check(!PreviewPolicy.isExcluded(bundleID: "com.apple.Safari", excluded: ex), "Safari is not excluded")
    check(!PreviewPolicy.isExcluded(bundleID: "com.apple.keychainaccessory", excluded: ["com.apple.keychainaccess"]), "exact means exact")
    check(!PreviewPolicy.isExcluded(bundleID: nil, excluded: ex), "no bundle ID: not excluded")
    check(!PreviewPolicy.isExcluded(bundleID: "com.1password.x", excluded: []), "empty list excludes nothing")
    func a(_ enabled: Bool = true, paused: Bool = false, locked: Bool = false, idle: Double = 5, low: Bool = false) -> Bool {
        PreviewPolicy.allowsAutomaticCapture(enabled: enabled, paused: paused, screenLocked: locked, idleSeconds: idle, lowPowerMode: low)
    }
    check(a(), "normal use: allowed")
    check(!a(false), "switched off"); check(!a(paused: true), "paused"); check(!a(locked: true), "screen locked")
    check(!a(idle: 120), "idle for two minutes"); check(!a(low: true), "low power mode"); check(a(idle: 60), "exactly at the idle limit is fine")
}

section("Shortcut display")
do {
    eq(ShortcutDisplay.symbols([.command, .control, .option, .shift]), "⌃⌥⇧⌘", "macOS symbol order")
    eq(ShortcutDisplay.describe(.option, key: "Tab"), "⌥Tab", "Option+Tab"); eq(ShortcutDisplay.describe([.control, .option], key: "←"), "⌃⌥←", "snap")
    eq(ShortcutDisplay.keyName(6), "Z", "Z"); eq(ShortcutDisplay.keyName(126), "↑", "up arrow"); eq(ShortcutDisplay.keyName(999), "Key 999", "unknown key")
    eq(ShortcutModifiers([.control, .option]).count, 2, "modifier count"); eq(ShortcutModifiers([]).count, 0, "empty count")
}

section("Shortcut validation")
do {
    let c = ShortcutConfig()      // ⌥Tab switcher, ⌃⌥ arrows, ⌥Z layouts
    func v(_ k: ShortcutKind, _ m: ShortcutModifiers, _ code: Int64, _ cfg: ShortcutConfig? = nil) -> String? {
        ShortcutValidator.validate(k, modifiers: m, keyCode: code, current: cfg ?? c)
    }
    check(v(.switcher, .option, 48) == nil, "⌥Tab ok"); check(v(.switcher, [.control, .option], 48) == nil, "⌃⌥Tab ok")
    check(v(.switcher, .control, 48) == nil, "⌃Tab ok")
    check(v(.switcher, .command, 48) != nil, "⌘Tab rejected (macOS)"); check(v(.switcher, [.command, .option], 48) == nil, "⌘⌥Tab ok")
    check(v(.switcher, [], 48) != nil, "Tab alone rejected"); check(v(.switcher, [.option, .shift], 48) != nil, "Shift rejected")
    check(v(.switcher, .option, 6) != nil, "switcher needs Tab")
    var layTab = c; layTab.layoutsKeyCode = 48; layTab.layoutsModifier = .control
    check(v(.switcher, .control, 48, layTab) != nil, "clash with Snap Layouts")

    check(v(.snap, [.control, .option], 123) == nil, "⌃⌥← ok"); check(v(.snap, [.control, .command], 124) == nil, "⌃⌘→ ok")
    check(v(.snap, .option, 123) != nil, "⌥← alone rejected (word jump)"); check(v(.snap, .control, 123) != nil, "⌃← alone rejected (Spaces)")
    check(v(.snap, .command, 123) != nil, "⌘← alone rejected (text editing)")
    check(v(.snap, [.control, .option, .shift], 123) != nil, "Shift rejected"); check(v(.snap, [.control, .option], 6) != nil, "needs an arrow")
    var layArrow = c; layArrow.layoutsKeyCode = 126; layArrow.layoutsModifier = [.control, .command]
    check(v(.snap, [.control, .command], 123, layArrow) != nil, "clash with Snap Layouts on an arrow")

    check(v(.layouts, .option, 6) == nil, "⌥Z ok"); check(v(.layouts, [.control, .option], 7) == nil, "⌃⌥X ok")
    check(v(.layouts, [], 6) != nil, "Z alone rejected"); check(v(.layouts, .shift, 6) != nil, "Shift+Z rejected")
    check(v(.layouts, .option, 53) != nil, "Esc rejected"); check(v(.layouts, .command, 12) != nil, "⌘Q rejected"); check(v(.layouts, .command, 13) != nil, "⌘W rejected")
    check(v(.layouts, .command, 6) == nil, "⌘Z ok (not reserved here)"); check(v(.layouts, .option, 48) != nil, "clash with the switcher")
    check(v(.layouts, [.control, .option], 124) != nil, "clash with snapping")
    check(v(.layouts, [.control, .option, .shift], 124) != nil, "clash with snapping + Shift (move display)")
    check(v(.layouts, [.control, .option], 11) == nil, "⌃⌥B ok")
}

section("Custom shortcuts in the classifier")
do {
    var cfg = ShortcutConfig()
    cfg.switcherModifier = [.control, .option]; cfg.layoutsKeyCode = 11; cfg.layoutsModifier = [.control, .option]
    func kd(_ code: Int64, _ f: ShortcutModifiers, active: Bool = false) -> KeyAction {
        KeyClassifier.classifyKeyDown(keyCode: code, flags: f, isRepeat: false, switcherActive: active, config: cfg)
    }
    eq(kd(48, [.control, .option]), .switcherOpen(reverse: false), "⌃⌥Tab opens with a two-key modifier")
    eq(kd(48, .option), .passThrough, "⌥Tab no longer opens")
    eq(kd(48, [.control, .option, .shift]), .switcherOpen(reverse: true), "with Shift: reverse")
    eq(kd(48, [.control, .option], active: true), .switcherNext, "Tab while open")
    eq(kd(48, .option, active: true), .switcherCommit, "releasing one of the two modifiers commits")
    eq(KeyClassifier.classifyFlagsChanged(flags: .option, switcherActive: true, config: cfg), .switcherCommit, "flags: one modifier released")
    eq(KeyClassifier.classifyFlagsChanged(flags: [.control, .option], switcherActive: true, config: cfg), .passThrough, "flags: both still held")
    eq(kd(11, [.control, .option]), .layoutsOpen, "custom Snap Layouts key (B)")
    eq(kd(6, .option), .passThrough, "old Snap Layouts key no longer works")
}

section("App exclusions")
do {
    let list = [AppExclusion(pattern: "com.spotify.client", inSwitcher: true, inSnapping: false),
                AppExclusion(pattern: "us.zoom.*", inSwitcher: false, inSnapping: true),
                AppExclusion(pattern: "com.apple.calculator")]
    func x(_ id: String?, _ s: ExclusionScope) -> Bool { AppExclusions.isExcluded(bundleID: id, for: s, in: list) }
    check(x("com.spotify.client", .switcher), "Spotify hidden from the switcher")
    check(!x("com.spotify.client", .snapping), "...but can still be snapped")
    check(x("us.zoom.xos", .snapping), "Zoom (wildcard) not snapped"); check(!x("us.zoom.xos", .switcher), "...but still listed")
    check(x("com.apple.calculator", .switcher) && x("com.apple.calculator", .snapping), "both scopes by default")
    check(x("COM.SPOTIFY.CLIENT", .switcher), "case-insensitive")
    check(!x("com.apple.Safari", .switcher) && !x("com.apple.Safari", .snapping), "other apps untouched")
    check(!x(nil, .switcher), "no bundle ID: never excluded")
    check(!AppExclusions.isExcluded(bundleID: "com.apple.calculator", for: .switcher, in: []), "empty list")
    eq(AppExclusions.adding("com.foo.bar", to: []).count, 1, "add"); eq(AppExclusions.adding("COM.FOO.BAR", to: AppExclusions.adding("com.foo.bar", to: [])).count, 1, "no duplicates")
    eq(AppExclusions.decode(AppExclusions.encode(list)), list, "survives saving and loading")
    eq(AppExclusions.decode(nil), [], "missing data"); eq(AppExclusions.decode(Data("garbage".utf8)), [], "corrupt data")
    check(BundlePattern.matches("com.a.*", bundleID: "com.a.b.c") && !BundlePattern.matches("com.a.*", bundleID: "com.ab"), "wildcard needs the dot")
}

section("Linked resize")
do {
    typealias L = LinkedResize
    let v = CGRect(x: 0, y: 0, width: 1200, height: 800)
    func zones(_ layout: SnapLayout, gap: CGFloat = 0) -> [Int: CGRect] {
        Dictionary(uniqueKeysWithValues: (0..<layout.zones.count).map { ($0, layout.frame(ofZone: $0, in: v, gap: gap)) })
    }
    let halves = SnapLayout.presets[0], cols = SnapLayout.presets[3], grid = SnapLayout.presets[4], main2 = SnapLayout.presets[5]

    eq(L.classify(old: CGRect(x: 0, y: 0, width: 500, height: 400), new: CGRect(x: 0, y: 0, width: 500.5, height: 400)), .none, "tiny jitter is nothing")
    eq(L.classify(old: CGRect(x: 0, y: 0, width: 500, height: 400), new: CGRect(x: 80, y: 30, width: 500, height: 400)), .moved, "dragged elsewhere")
    eq(L.classify(old: CGRect(x: 0, y: 0, width: 500, height: 400), new: CGRect(x: 0, y: 0, width: 560, height: 400)), .resized, "resized")
    eq(L.classify(old: CGRect(x: 600, y: 0, width: 600, height: 400), new: CGRect(x: 540, y: 0, width: 660, height: 400)), .resized, "left-edge resize moves the origin too")

    // two halves: drag the left window's right edge 100 to the right
    var m = zones(halves), new = m[0]!; new.size.width += 100
    var r = L.resolve(members: m, changed: 0, newFrame: new)
    eq(r[0]!.maxX, 700, "left window grew"); eq(r[1]!.minX, 700, "right window's edge followed"); eq(r[1]!.maxX, 1200, "right window still reaches the screen edge")
    eq(r[0]!.height, 800, "heights untouched")
    // from the other side: drag the right window's left edge to the left
    new = m[1]!; new.origin.x -= 150; new.size.width += 150
    r = L.resolve(members: m, changed: 1, newFrame: new)
    eq(r[1]!.minX, 450, "right window grew leftwards"); eq(r[0]!.maxX, 450, "left window shrank to match")
    // gap preserved
    m = zones(halves, gap: 10); new = m[0]!; new.size.width += 40
    r = L.resolve(members: m, changed: 0, newFrame: new, gap: 10)
    eq(r[1]!.minX - r[0]!.maxX, 10, "the gap stays 10 after a linked resize"); eq(r[1]!.maxX, m[1]!.maxX, "outer edge stays put")

    // outer edge: only that window changes
    m = zones(halves); new = m[0]!; new.origin.x += 60; new.size.width -= 60      // shrink the left window from its OUTER (left) edge
    r = L.resolve(members: m, changed: 0, newFrame: new)
    eq(r[0]!, CGRect(x: 60, y: 0, width: 540, height: 800), "outer edge resizes just that window"); eq(r[1]!, m[1]!, "neighbour untouched")

    // three columns: dragging divider 1 only affects columns 1 and 2
    m = zones(cols); new = m[0]!; new.size.width += 50
    r = L.resolve(members: m, changed: 0, newFrame: new)
    eq(r[1]!.minX, m[1]!.minX + 50, "column 2 follows"); eq(r[2]!, m[2]!, "column 3 is not touched")
    // ...and dragging divider 2 from column 3
    new = m[2]!; new.origin.x -= 70; new.size.width += 70
    r = L.resolve(members: m, changed: 2, newFrame: new)
    eq(r[1]!.maxX, m[1]!.maxX - 70, "column 2 shrinks from the right"); eq(r[0]!, m[0]!, "column 1 untouched")

    // 2x2 grid: the vertical divider runs the whole height, so all four follow
    m = zones(grid); new = m[0]!; new.size.width += 100
    r = L.resolve(members: m, changed: 0, newFrame: new)
    eq(r[1]!.minX, 700, "top-right follows"); eq(r[2]!.maxX, 700, "bottom-left follows"); eq(r[3]!.minX, 700, "bottom-right follows")
    // horizontal divider, dragged from the bottom-right window's top edge
    new = m[3]!; new.origin.y -= 60; new.size.height += 60
    r = L.resolve(members: m, changed: 3, newFrame: new)
    eq(r[1]!.maxY, 340, "top-right shrinks"); eq(r[0]!.maxY, 340, "top-left shrinks"); eq(r[2]!.minY, 340, "bottom-left grows"); eq(r[3]!.minY, 340, "dragged window itself")
    // corner drag: both axes at once (top-left window's bottom-right corner)
    new = m[0]!; new.size.width += 40; new.size.height += 30
    r = L.resolve(members: m, changed: 0, newFrame: new)
    eq(r[3]!.minX, 640, "diagonal neighbour follows horizontally"); eq(r[3]!.minY, 430, "and vertically")

    // main + two stacked: horizontal divider only exists on the right
    m = zones(main2); new = m[1]!; new.size.height += 50
    r = L.resolve(members: m, changed: 1, newFrame: new)
    eq(r[2]!.minY, 450, "lower right window follows"); eq(r[0]!, m[0]!, "the left window does not care")
    // the vertical divider moves all three
    new = m[0]!; new.size.width -= 100
    r = L.resolve(members: m, changed: 0, newFrame: new)
    eq(r[1]!.minX, 500, "upper right follows the main window"); eq(r[2]!.minX, 500, "lower right too")

    // minimum size: the divider stops, and the dragged window is pulled back
    m = zones(halves); new = m[0]!; new.size.width = 1150   // would leave the right window at 50 wide
    r = L.resolve(members: m, changed: 0, newFrame: new)
    eq(r[1]!.width, 120, "neighbour stops at the minimum width"); eq(r[0]!.maxX, r[1]!.minX, "still flush"); eq(r[0]!.width, 1080, "dragged window pulled back")
    new = m[0]!; new.size.width = 60                          // dragged window itself would go below the minimum
    r = L.resolve(members: m, changed: 0, newFrame: new)
    eq(r[0]!.width, 120, "dragged window cannot go below the minimum either"); eq(r[1]!.minX, 120, "neighbour follows the stopped divider")

    // REAL minimum sizes (learned from apps that refused to shrink) stop the divider before anything overlaps
    let flush: [Int: CGRect] = [0: CGRect(x: 0, y: 0, width: 500, height: 800), 1: CGRect(x: 500, y: 0, width: 700, height: 800)]
    new = flush[0]!; new.size.width += 100                       // drag right: the right window (700 wide) cannot shrink
    r = L.resolve(members: flush, changed: 0, newFrame: new, minSizes: [1: CGSize(width: 700, height: 100)])
    eq(r[0]!, flush[0]!, "divider stops: the dragged window is pulled back"); eq(r[1]!, flush[1]!, "the stubborn window is not overlapped")
    eq(r[0]!.maxX, r[1]!.minX, "still flush, so linking is intact")
    new = flush[0]!; new.size.width -= 100                        // ...then drag back: the link still works
    r = L.resolve(members: flush, changed: 0, newFrame: new, minSizes: [1: CGSize(width: 700, height: 100)])
    eq(r[0]!.maxX, 400, "dragging back moves the divider"); eq(r[1]!.minX, 400, "and the stubborn window follows"); eq(r[1]!.maxX, 1200, "its outer edge stays")
    // without the learned minimum the old assumption would have overlapped (documenting why it is needed)
    new = flush[0]!; new.size.width += 100
    check(L.resolve(members: flush, changed: 0, newFrame: new)[1]!.width == 600, "default minimum alone allows shrinking to 600")
    // the dragged window's own real minimum
    let wide: [Int: CGRect] = [0: CGRect(x: 0, y: 0, width: 600, height: 800), 1: CGRect(x: 600, y: 0, width: 600, height: 800)]
    new = wide[0]!; new.size.width = 300
    r = L.resolve(members: wide, changed: 0, newFrame: new, minSizes: [0: CGSize(width: 450, height: 100)])
    eq(r[0]!.width, 450, "dragged window stops at ITS minimum"); eq(r[1]!.minX, 450, "neighbour follows the stopped divider")
    // vertical: a stubborn window with a minimum HEIGHT
    let stack: [Int: CGRect] = [0: CGRect(x: 0, y: 0, width: 1200, height: 300), 1: CGRect(x: 0, y: 300, width: 1200, height: 500)]
    new = stack[0]!; new.size.height += 100
    r = L.resolve(members: stack, changed: 0, newFrame: new, minSizes: [1: CGSize(width: 100, height: 500)])
    eq(r[1]!, stack[1]!, "vertical divider stops at the neighbour's minimum height"); eq(r[0]!.maxY, r[1]!.minY, "still flush vertically")
    // grid: one stubborn window stops the whole divider (all four share it)
    m = zones(grid); new = m[0]!; new.size.width += 120
    r = L.resolve(members: m, changed: 0, newFrame: new, minSizes: [3: CGSize(width: 600, height: 100)])
    eq(r[0]!, m[0]!, "grid: one window at its minimum stops the whole divider"); eq(r[1]!, m[1]!, "top-right unchanged"); eq(r[2]!, m[2]!, "bottom-left unchanged")

    // learning a real minimum: needs the refusal to persist (a slow app must not be mistaken for a stubborn one)
    do {
        let want = CGRect(x: 800, y: 0, width: 400, height: 800), big = CGRect(x: 600, y: 0, width: 600, height: 800)
        var o = MinSizeLearning.check(intended: want, real: big, refusals: 0, current: nil)
        check(!o.learned && o.refusals == 1 && o.minSize == nil, "first 'too big' reading: wait and see")
        o = MinSizeLearning.check(intended: want, real: want, refusals: o.refusals, current: o.minSize)
        check(!o.learned && o.refusals == 0, "the app caught up (it was just slow): nothing learned")
        o = MinSizeLearning.check(intended: want, real: big, refusals: 0, current: nil)
        o = MinSizeLearning.check(intended: want, real: big, refusals: o.refusals, current: o.minSize)
        check(o.learned && o.minSize?.width == 600, "too big twice in a row: 600 wide is its real minimum")
        check(o.minSize?.height == LinkedResize.defaultMinSize.height, "height keeps the default when only width was refused")
        let tall = CGRect(x: 0, y: 0, width: 400, height: 700)
        o = MinSizeLearning.check(intended: CGRect(x: 0, y: 0, width: 400, height: 300), real: tall, refusals: 1, current: CGSize(width: 500, height: 90))
        check(o.learned && o.minSize == CGSize(width: 500, height: 700), "height learned, the known width is kept")
        o = MinSizeLearning.check(intended: want, real: CGRect(x: 800, y: 0, width: 401, height: 801), refusals: 1, current: nil)
        check(!o.learned && o.refusals == 0, "within 2 pt of the request counts as complying")
        o = MinSizeLearning.check(intended: want, real: CGRect(x: 800, y: 0, width: 300, height: 800), refusals: 1, current: nil)
        check(!o.learned && o.refusals == 0, "smaller than asked is not a refusal")
        o = MinSizeLearning.check(intended: want, real: big, refusals: 1, current: CGSize(width: 900, height: 90))
        eq(o.minSize?.width, 900, "a learned minimum never goes down")
    }

    // ---- dividers (the visible line you drag)
    do {
        let hv = L.dividers(members: zones(halves))
        eq(hv.count, 1, "halves: one divider"); eq(hv[0].axis, .vertical, "vertical"); eq(hv[0].position, 600, "in the middle")
        eq(hv[0].start, 0, "extends the full height (start)"); eq(hv[0].end, 800, "(end)"); eq(hv[0].before, [0], "window 0 is before it"); eq(hv[0].after, [1], "window 1 after")
        let gv = L.dividers(members: zones(halves, gap: 10), gap: 10)
        eq(gv[0].position, 600, "with a gap the line sits in the middle of the gap"); eq(gv[0].start, 10, "and spans the windows, not the margins")
        let cv = L.dividers(members: zones(cols))
        eq(cv.count, 2, "three columns: two dividers"); eq(cv.map(\.position), [400, 800], "at the third marks")
        let gd = L.dividers(members: zones(grid))
        eq(gd.count, 2, "2x2 grid: one vertical and one horizontal"); eq(gd.filter { $0.axis == .vertical }.count, 1, "one vertical")
        let gv0 = gd.first { $0.axis == .vertical }!, gh0 = gd.first { $0.axis == .horizontal }!
        eq(gv0.before, [0, 2], "the vertical line has both left windows before it"); eq(gv0.after, [1, 3], "and both right windows after")
        eq(gv0.start, 0, "full height"); eq(gv0.end, 800, "full height"); eq(gh0.position, 400, "horizontal line at mid height"); eq(gh0.start, 0, "full width"); eq(gh0.end, 1200, "full width")
        let md = L.dividers(members: zones(main2))
        eq(md.count, 2, "main + two stacked: a vertical and a horizontal divider")
        let mh = md.first { $0.axis == .horizontal }!
        eq(mh.start, 600, "the horizontal divider only spans the right column"); eq(mh.end, 1200, "(to the screen edge)")
        let farApart: [Int: CGRect] = [0: CGRect(x: 0, y: 0, width: 400, height: 800), 1: CGRect(x: 700, y: 0, width: 500, height: 800)]
        let noOverlap: [Int: CGRect] = [0: CGRect(x: 0, y: 0, width: 600, height: 300), 1: CGRect(x: 600, y: 500, width: 600, height: 300)]
        eq(L.dividers(members: farApart).count, 0, "windows with a gap between them have no divider")
        eq(L.dividers(members: noOverlap).count, 0, "windows that do not share vertical extent have no divider")
        eq(L.dividers(members: [0: CGRect(x: 0, y: 0, width: 500, height: 500)]).count, 0, "a single window has none")
        // dragging a divider
        var r2 = L.dragDivider(members: zones(halves), divider: hv[0], to: 700)
        eq(r2[0]!.maxX, 700, "dragging the divider to 700 moves the left window's edge"); eq(r2[1]!.minX, 700, "and the right window's")
        r2 = L.dragDivider(members: zones(halves, gap: 10), divider: gv[0], to: 500, gap: 10)
        eq(r2[1]!.minX - r2[0]!.maxX, 10, "the gap is kept while dragging"); eq((r2[0]!.maxX + r2[1]!.minX) / 2, 500, "and the line is where you put it")
        r2 = L.dragDivider(members: zones(grid), divider: gv0, to: 800)
        eq(r2[1]!.minX, 800, "grid: the whole vertical line moves"); eq(r2[2]!.maxX, 800, "including the lower left window"); eq(r2[3]!.minX, 800, "and the lower right")
        r2 = L.dragDivider(members: zones(grid), divider: gh0, to: 300)
        eq(r2[2]!.minY, 300, "grid: the horizontal line moves"); eq(r2[1]!.maxY, 300, "both rows follow")
        r2 = L.dragDivider(members: zones(halves), divider: hv[0], to: 1190)
        eq(r2[1]!.width, 120, "the divider stops where the right window reaches its minimum"); eq(r2[0]!.maxX, r2[1]!.minX, "still flush")
        r2 = L.dragDivider(members: zones(halves), divider: hv[0], to: 10)
        eq(r2[0]!.width, 120, "and where the left window reaches its minimum")
        r2 = L.dragDivider(members: flush, divider: L.dividers(members: flush)[0], to: 900, minSizes: [1: CGSize(width: 700, height: 100)])
        eq(r2[1]!, flush[1]!, "a window with a large real minimum is never overlapped"); eq(r2[0]!, flush[0]!, "the divider simply does not move")
        // the divider line follows reality afterwards
        let after = L.dividers(members: L.dragDivider(members: zones(halves), divider: hv[0], to: 700))
        eq(after.count, 1, "still exactly one divider after dragging"); eq(after[0].position, 700, "now at the new position")
    }

    // ---- hover zones for revealing a divider
    do {
        let d = L.dividers(members: zones(halves))[0]                     // vertical line x = 600, y 0...800
        let z = d.revealZone()
        eq(z, CGRect(x: 586, y: 250, width: 28, height: 300), "reveal zone: the middle 300 points of an 800 point line, 14 either side")
        check(z.contains(CGPoint(x: 600, y: 400)) && z.contains(CGPoint(x: 590, y: 300)), "hovering the middle reveals it")
        check(!z.contains(CGPoint(x: 600, y: 50)) && !z.contains(CGPoint(x: 600, y: 760)), "near the ends does NOT (scrollbars stay free)")
        check(!z.contains(CGPoint(x: 560, y: 400)) && !z.contains(CGPoint(x: 640, y: 400)), "away from the seam does not")
        let k = d.keepZone()
        check(k.contains(CGPoint(x: 600, y: 10)) && k.contains(CGPoint(x: 605, y: 795)), "once revealed it stays while you are anywhere along the line")
        check(!k.contains(CGPoint(x: 640, y: 400)), "and goes when the cursor leaves the seam")
        // short lines: at least 120 long, never beyond the line
        let short = Divider(axis: .vertical, position: 300, start: 100, end: 300, before: [0], after: [1])
        eq(short.revealZone().height, 120, "a 200 long line gets a 120 long zone"); eq(short.revealZone().minY, 140, "centred")
        let tiny = Divider(axis: .vertical, position: 300, start: 100, end: 180, before: [0], after: [1])
        eq(tiny.revealZone().minY, 100, "a very short line: clipped to the line"); eq(tiny.revealZone().maxY, 180, "(whole line)")
        // horizontal dividers mirror it
        let h = L.dividers(members: zones(grid)).first { $0.axis == .horizontal }!      // y = 400, x 0...1200
        eq(h.revealZone(), CGRect(x: 450, y: 386, width: 300, height: 28), "horizontal: the middle 300 points")
        check(!h.revealZone().contains(CGPoint(x: 50, y: 400)), "not near the screen edge")
        check(h.keepZone().contains(CGPoint(x: 50, y: 400)), "but visible all along once revealed")
    }

    // a missing zone does not break anything; no-op returns the same frames
    var sparse = zones(grid); sparse.removeValue(forKey: 3)
    new = sparse[0]!; new.size.width += 30
    r = L.resolve(members: sparse, changed: 0, newFrame: new)
    eq(r[1]!.minX, 630, "works with an empty zone"); eq(r.count, 3, "no phantom members")
    eq(L.resolve(members: zones(halves), changed: 0, newFrame: zones(halves)[0]!), zones(halves), "no change in, no change out")
    eq(L.resolve(members: zones(halves), changed: 9, newFrame: .zero), zones(halves), "unknown member is ignored")
    // windows that are NOT touching (user placed them apart) are not linked
    let apart: [Int: CGRect] = [0: CGRect(x: 0, y: 0, width: 400, height: 800), 1: CGRect(x: 700, y: 0, width: 500, height: 800)]
    new = apart[0]!; new.size.width += 60
    r = L.resolve(members: apart, changed: 0, newFrame: new)
    eq(r[1]!, apart[1]!, "windows with a gap between them are independent")
    // windows touching the divider line but not connected vertically are not dragged along
    let stacked: [Int: CGRect] = [0: CGRect(x: 0, y: 0, width: 600, height: 300), 1: CGRect(x: 600, y: 500, width: 600, height: 300)]
    new = stacked[0]!; new.size.width += 40
    r = L.resolve(members: stacked, changed: 0, newFrame: new)
    eq(r[1]!, stacked[1]!, "no shared vertical extent: not linked")
}

section("Snap motion")
do {
    let a = CGRect(x: 100, y: 100, width: 600, height: 400), b = CGRect(x: 0, y: 25, width: 720, height: 800)
    check(SnapMotionPolicy.shouldAnimate(from: a, to: b, enabled: true, reduceMotion: false), "a real snap animates")
    check(!SnapMotionPolicy.shouldAnimate(from: a, to: b, enabled: false, reduceMotion: false), "switched off")
    check(!SnapMotionPolicy.shouldAnimate(from: a, to: b, enabled: true, reduceMotion: true), "Reduce motion: never")
    check(!SnapMotionPolicy.shouldAnimate(from: a, to: a.offsetBy(dx: 3, dy: 2), enabled: true, reduceMotion: false), "a nudge of a few points does not")
    check(SnapMotionPolicy.shouldAnimate(from: a, to: CGRect(x: 100, y: 100, width: 640, height: 400), enabled: true, reduceMotion: false), "a pure resize animates")
    check(!SnapMotionPolicy.shouldAnimate(from: .zero, to: b, enabled: true, reduceMotion: false), "unknown start frame: no animation")
    check(!SnapMotionPolicy.shouldAnimate(from: a, to: .zero, enabled: true, reduceMotion: false), "unknown end frame: no animation")
    let short = SnapMotionPolicy.duration(from: a, to: a.offsetBy(dx: 20, dy: 0)), long = SnapMotionPolicy.duration(from: a, to: CGRect(x: 2000, y: 900, width: 700, height: 800))
    check(short >= 0.16 && long <= 0.30, "durations stay between 0.16 s and 0.30 s"); check(long > short, "a longer trip takes longer")
}

print("\n\(total - failures)/\(total) checks passed")
exit(failures == 0 ? 0 : 1)
