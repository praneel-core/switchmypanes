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
    public static func resolve(members: [Int: CGRect], changed: Int, newFrame: CGRect, gap: CGFloat = 0,
                               minSize: CGSize = defaultMinSize, tolerance: CGFloat = 6) -> [Int: CGRect] {
        guard let old = members[changed] else { return members }
        let eps: CGFloat = 0.5
        var frames = members

        // Vertical dividers: the left/right edges of the changed window.
        let dRight = newFrame.maxX - old.maxX, dLeft = newFrame.minX - old.minX
        if abs(dRight) > eps { shiftDivider(&frames, changed, movesTrailingEdge: true, delta: dRight, gap: gap, minLength: minSize.width, tol: tolerance) }
        if abs(dLeft) > eps { shiftDivider(&frames, changed, movesTrailingEdge: false, delta: dLeft, gap: gap, minLength: minSize.width, tol: tolerance) }

        // Horizontal dividers: the same routine on transposed frames (swap x and y), then transpose back.
        var t = frames.mapValues(transposed)
        let dBottom = newFrame.maxY - old.maxY, dTop = newFrame.minY - old.minY
        if abs(dBottom) > eps { shiftDivider(&t, changed, movesTrailingEdge: true, delta: dBottom, gap: gap, minLength: minSize.height, tol: tolerance) }
        if abs(dTop) > eps { shiftDivider(&t, changed, movesTrailingEdge: false, delta: dTop, gap: gap, minLength: minSize.height, tol: tolerance) }
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
                                     delta requested: CGFloat, gap: CGFloat, minLength: CGFloat, tol: CGFloat) {
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
            if isBefore(r) { lo = max(lo, minLength - r.width) }       // before-window grows by delta: width + delta >= min
            if isAfter(r) { hi = min(hi, r.width - minLength) }        // after-window shrinks by delta: width - delta >= min
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
