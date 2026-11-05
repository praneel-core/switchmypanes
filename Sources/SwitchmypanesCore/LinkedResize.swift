import CoreGraphics

public enum FrameChange: Equatable { case none, moved, resized }

/// Resizing snapped windows together: when you drag the divider between windows that were placed side by side
/// (for example by Snap Layouts), every window touching that divider follows, so the group stays flush.
/// Pure geometry in top-left coordinates, no UI. Members are identified by small integer IDs.
public enum LinkedResize {
    public static let defaultMinSize = CGSize(width: 120, height: 90)

    /// What happened to a window between two readings: nothing, dragged elsewhere (same size), or resized.
    public static func classify(old: CGRect, new: CGRect, tolerance: CGFloat = 1.5) -> FrameChange {
        let sameSize = abs(old.width - new.width) <= tolerance && abs(old.height - new.height) <= tolerance
        let sameOrigin = abs(old.minX - new.minX) <= tolerance && abs(old.minY - new.minY) <= tolerance
        if sameSize && sameOrigin { return .none }
        return sameSize ? .moved : .resized
    }

    /// The new frames of ALL members after `changed` was resized to `newFrame`.
    /// - `gap`: space between windows (the group's gap), so facing edges stay `gap` apart.
    /// - `minSize`: no window is made smaller than this; the divider stops instead (the changed window is pulled back too).
    /// Only edges shared with other windows drag neighbours along; an outer edge just resizes that one window.
    /// - `minSizes`: real minimum sizes learned per member (an app that refused to get smaller). They override `minSize`.
    public static func resolve(members: [Int: CGRect], changed: Int, newFrame: CGRect, gap: CGFloat = 0,
                               minSize: CGSize = defaultMinSize, minSizes: [Int: CGSize] = [:],
                               tolerance: CGFloat = 6) -> [Int: CGRect] {
        guard let old = members[changed] else { return members }
        let eps: CGFloat = 0.5
        var frames = members

        // Vertical dividers: the left/right edges of the changed window.
        let dRight = newFrame.maxX - old.maxX, dLeft = newFrame.minX - old.minX
        if abs(dRight) > eps { shiftDivider(&frames, changed, movesTrailingEdge: true, delta: dRight, gap: gap, minLength: { minSizes[$0]?.width ?? minSize.width }, tol: tolerance) }
        if abs(dLeft) > eps { shiftDivider(&frames, changed, movesTrailingEdge: false, delta: dLeft, gap: gap, minLength: { minSizes[$0]?.width ?? minSize.width }, tol: tolerance) }

        // Horizontal dividers: the same routine on transposed frames (swap x and y), then transpose back.
        var t = frames.mapValues(transposed)
        let dBottom = newFrame.maxY - old.maxY, dTop = newFrame.minY - old.minY
        if abs(dBottom) > eps { shiftDivider(&t, changed, movesTrailingEdge: true, delta: dBottom, gap: gap, minLength: { minSizes[$0]?.height ?? minSize.height }, tol: tolerance) }
        if abs(dTop) > eps { shiftDivider(&t, changed, movesTrailingEdge: false, delta: dTop, gap: gap, minLength: { minSizes[$0]?.height ?? minSize.height }, tol: tolerance) }
        return t.mapValues { rounded(transposed($0)) }
    }

    // MARK: internals

    private static func transposed(_ r: CGRect) -> CGRect { CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width) }
    private static func rounded(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
    }

    /// Moves one vertical divider by `delta`. "Trailing" = the changed window's right edge; otherwise its left edge.
    /// All windows touching that divider (on either side, connected to the changed window along it) move with it.
    private static func shiftDivider(_ frames: inout [Int: CGRect], _ changed: Int, movesTrailingEdge: Bool,
                                     delta requested: CGFloat, gap: CGFloat, minLength: (Int) -> CGFloat, tol: CGFloat) {
        guard let f = frames[changed] else { return }
        // The divider sits between a window's right edge (L) and the next window's left edge (R = L + gap).
        let L = movesTrailingEdge ? f.maxX : f.minX - gap
        let R = L + gap
        func isBefore(_ r: CGRect) -> Bool { abs(r.maxX - L) <= tol }     // window ending at the divider
        func isAfter(_ r: CGRect) -> Bool { abs(r.minX - R) <= tol }      // window starting at the divider
        func connected(_ a: CGRect, _ b: CGRect) -> Bool { a.minY <= b.maxY + gap + tol && b.minY <= a.maxY + gap + tol }

        // Flood fill along the divider: windows touching it whose vertical extent links up with the changed window.
        var group: Set<Int> = [changed]
        var grew = true
        while grew {
            grew = false
            for (id, r) in frames where !group.contains(id) && (isBefore(r) || isAfter(r)) {
                if group.contains(where: { connected(frames[$0]!, r) }) { group.insert(id); grew = true }
            }
        }

        // Do not let any window shrink below the minimum: stop the divider instead.
        var lo = -CGFloat.greatestFiniteMagnitude, hi = CGFloat.greatestFiniteMagnitude
        for id in group {
            let r = frames[id]!
            if isBefore(r) { lo = max(lo, minLength(id) - r.width) }       // before-window grows by delta: width + delta >= min
            if isAfter(r) { hi = min(hi, r.width - minLength(id)) }        // after-window shrinks by delta: width - delta >= min
        }
        let delta = lo > hi ? 0 : min(max(requested, lo), hi)
        guard abs(delta) > 0.001 else { return }

        for id in group {
            var r = frames[id]!
            if isBefore(r) { r.size.width += delta }
            else if isAfter(r) { r.origin.x += delta; r.size.width -= delta }
            frames[id] = r
        }
    }
}

/// A divider between linked windows: the line you drag to resize the windows on both sides at once.
public struct Divider: Equatable {
    public enum Axis: Equatable { case vertical, horizontal }
    public var axis: Axis
    public var position: CGFloat      // the line itself: x for a vertical divider, y for a horizontal one (centre of the gap)
    public var start: CGFloat         // how far the line extends (y range for a vertical divider, x range for a horizontal one)
    public var end: CGFloat
    public var before: [Int]          // windows left of / above the line
    public var after: [Int]           // windows right of / below it

    public init(axis: Axis, position: CGFloat, start: CGFloat, end: CGFloat, before: [Int], after: [Int]) {
        self.axis = axis; self.position = position; self.start = start; self.end = end
        self.before = before; self.after = after
    }
}

public extension Divider {
    /// Where hovering REVEALS the divider: the middle of the line (40% of its length, but between 120 and 300 points
    /// long, never beyond the line itself) and `across` points to either side of it. Keeping the trigger to the middle
    /// leaves the rest of the seam (scrollbars, resize corners) untouched until you actually go for the divider.
    func revealZone(across: CGFloat = 14) -> CGRect {
        let length = end - start, mid = (start + end) / 2
        let half = min(max(length * 0.2, 60), 150)
        let lo = max(start, mid - half), hi = min(end, mid + half)
        return axis == .vertical
            ? CGRect(x: position - across, y: lo, width: across * 2, height: hi - lo)
            : CGRect(x: lo, y: position - across, width: hi - lo, height: across * 2)
    }

    /// The two spots to look at to see what is actually on screen at this seam: the middle of the line, just inside the
    /// window on each side (`gap` is the space between the windows).
    func probePoints(gap: CGFloat = 0) -> (before: CGPoint, after: CGPoint) {
        let mid = (start + end) / 2, off = gap / 2 + 6
        return axis == .vertical
            ? (CGPoint(x: position - off, y: mid), CGPoint(x: position + off, y: mid))
            : (CGPoint(x: mid, y: position - off), CGPoint(x: mid, y: position + off))
    }

    /// A divider may only be shown when the seam is really visible: the topmost window at each probe point must be one of
    /// the group's windows on that side. If any other window covers the seam (even another window of the same app), the
    /// line would float over a window that is not part of the group, so it must stay hidden.
    func isUncovered<ID: Hashable>(topBefore: ID?, topAfter: ID?, beforeWindows: Set<ID>, afterWindows: Set<ID>) -> Bool {
        guard let b = topBefore, let a = topAfter else { return false }
        return beforeWindows.contains(b) && afterWindows.contains(a)
    }

    /// While the cursor stays inside this (the whole line plus a margin) an already revealed divider stays visible.
    func keepZone(across: CGFloat = 14, margin: CGFloat = 6) -> CGRect {
        axis == .vertical
            ? CGRect(x: position - across, y: start - margin, width: across * 2, height: end - start + margin * 2)
            : CGRect(x: start - margin, y: position - across, width: end - start + margin * 2, height: across * 2)
    }
}

public extension LinkedResize {
    /// Every divider in a group of windows. A divider exists where windows on both sides meet along a shared line
    /// (a gap apart); windows that only touch the line on one side (an outer edge) have none.
    static func dividers(members: [Int: CGRect], gap: CGFloat = 0, tolerance: CGFloat = 6) -> [Divider] {
        var out = verticalDividers(members, gap: gap, tol: tolerance)
        let transposedMembers = members.mapValues { CGRect(x: $0.minY, y: $0.minX, width: $0.height, height: $0.width) }
        out += verticalDividers(transposedMembers, gap: gap, tol: tolerance).map { d in var h = d; h.axis = .horizontal; return h }
        return out
    }

    /// Where every window goes when `divider` is dragged so that its line sits at `position`.
    /// Limits (minimum sizes) apply, so the divider stops where a window cannot get any smaller.
    static func dragDivider(members: [Int: CGRect], divider: Divider, to position: CGFloat, gap: CGFloat = 0,
                            minSize: CGSize = defaultMinSize, minSizes: [Int: CGSize] = [:]) -> [Int: CGRect] {
        guard let id = divider.before.first, var f = members[id] else { return members }
        switch divider.axis {
        case .vertical:   f.size.width = (position - gap / 2) - f.minX
        case .horizontal: f.size.height = (position - gap / 2) - f.minY
        }
        return resolve(members: members, changed: id, newFrame: f, gap: gap, minSize: minSize, minSizes: minSizes)
    }

    private static func verticalDividers(_ frames: [Int: CGRect], gap: CGFloat, tol: CGFloat) -> [Divider] {
        var lines: [CGFloat] = []
        for f in frames.values where !lines.contains(where: { abs($0 - f.maxX) <= tol }) { lines.append(f.maxX) }
        func connected(_ a: CGRect, _ b: CGRect) -> Bool { a.minY <= b.maxY + gap + tol && b.minY <= a.maxY + gap + tol }
        var out: [Divider] = []
        for L in lines.sorted() {
            let R = L + gap
            let before = frames.filter { abs($0.value.maxX - L) <= tol }.keys.sorted()
            let after = frames.filter { abs($0.value.minX - R) <= tol }.keys.sorted()
            guard !before.isEmpty, !after.isEmpty else { continue }
            var unseen = Set(before + after)
            while let seed = unseen.min() {
                var comp: Set<Int> = [seed], grew = true
                while grew {
                    grew = false
                    for id in unseen where !comp.contains(id) && comp.contains(where: { connected(frames[$0]!, frames[id]!) }) {
                        comp.insert(id); grew = true
                    }
                }
                unseen.subtract(comp)
                let b = before.filter(comp.contains), a = after.filter(comp.contains)
                guard !b.isEmpty, !a.isEmpty else { continue }
                let rects = comp.map { frames[$0]! }
                out.append(Divider(axis: .vertical, position: L + gap / 2, start: rects.map(\.minY).min()!,
                                   end: rects.map(\.maxY).max()!, before: b, after: a))
            }
        }
        return out
    }
}

/// Learning an app's REAL minimum size from how it reacts to being asked to shrink.
/// A single "still too big" reading proves nothing (some apps apply a resize a moment late), so a window must be
/// bigger than asked on `confirmations` checks in a row before its size is accepted as a minimum.
public enum MinSizeLearning {
    public struct Outcome: Equatable {
        public var refusals: Int            // consecutive readings that were too big (0 = the app complied)
        public var minSize: CGSize?         // the minimum to use from now on (unchanged until confirmed)
        public var learned: Bool            // true exactly when a new minimum was just confirmed
    }

    public static func check(intended: CGRect, real: CGRect, refusals: Int, current: CGSize?,
                             confirmations: Int = 2, tolerance: CGFloat = 2) -> Outcome {
        let tooWide = real.width > intended.width + tolerance
        let tooTall = real.height > intended.height + tolerance
        guard tooWide || tooTall else { return Outcome(refusals: 0, minSize: current, learned: false) }
        let count = refusals + 1
        guard count >= confirmations else { return Outcome(refusals: count, minSize: current, learned: false) }
        var min = current ?? LinkedResize.defaultMinSize
        if tooWide { min.width = max(min.width, real.width) }
        if tooTall { min.height = max(min.height, real.height) }
        return Outcome(refusals: 0, minSize: min, learned: true)
    }
}
