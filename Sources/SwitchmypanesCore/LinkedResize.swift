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
