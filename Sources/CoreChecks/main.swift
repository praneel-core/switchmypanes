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
    var g = SwitcherSelection(count: 7); g.select(1)
    g.move(.down, columns: 3); eq(g.index, 4, "down moves one row")
    g.move(.down, columns: 3); eq(g.index, 4, "down at the last row stays")
    g.move(.up, columns: 3); g.move(.up, columns: 3); eq(g.index, 1, "up stops at the first row")
    g.select(99); eq(g.index, 1, "out-of-range select ignored")
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
    let all = SpaceFilterOptions(), none = SpaceFilterOptions(includeOtherDesktops: false, includeFullScreen: false)
    check(SpaceClassifier.isIncluded(.currentSpace, options: none), "current Space always included")
    check(SpaceClassifier.isIncluded(.otherSpace(.desktop), options: all), "other desktops on")
    check(!SpaceClassifier.isIncluded(.otherSpace(.desktop), options: none), "other desktops off")
    check(SpaceClassifier.isIncluded(.otherSpace(.fullScreen), options: SpaceFilterOptions(includeOtherDesktops: false)), "full-screen independent of desktops")
    check(!SpaceClassifier.isIncluded(.otherSpace(.fullScreen), options: SpaceFilterOptions(includeFullScreen: false)), "full-screen off")
    check(!SpaceClassifier.isIncluded(.hiddenOrMinimized, options: all) && !SpaceClassifier.isIncluded(.noSpace, options: all), "junk and minimized excluded")
}

print("\n\(total - failures)/\(total) checks passed")
exit(failures == 0 ? 0 : 1)
