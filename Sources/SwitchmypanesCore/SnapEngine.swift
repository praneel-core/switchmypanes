import CoreGraphics

public enum ArrowKey: Equatable { case left, right, up, down }

/// Where a window can be snapped to. `nil` (in the APIs below) means "not snapped".
public enum SnapZone: String, CaseIterable, Equatable {
    case maximize, left, right, topLeft, topRight, bottomLeft, bottomRight
}

public enum SnapAction: Equatable {
    case snap(SnapZone)
    case restore                                   // go back to the size before the first snap
    case minimize
    case moveToDisplay(HorizontalDirection, SnapZone?)  // zone to use on arrival (nil = keep relative position)
    case none
}

/// Pure geometry and the Windows-style state machine. Everything is in top-left coordinates.
public enum SnapEngine {

    // MARK: Zone geometry

    /// Frame of a zone inside `visible`. `gap` is the space between windows AND to the screen edge.
    public static func frame(for zone: SnapZone, in visible: CGRect, gap: CGFloat = 0) -> CGRect {
        let inner = visible.insetBy(dx: gap, dy: gap)
        let leftW = ((inner.width - gap) / 2).rounded(.down)
        let rightW = inner.width - gap - leftW
        let topH = ((inner.height - gap) / 2).rounded(.down)
        let botH = inner.height - gap - topH
        let rightX = inner.minX + leftW + gap
        let botY = inner.minY + topH + gap
        switch zone {
        case .maximize:    return inner
        case .left:        return CGRect(x: inner.minX, y: inner.minY, width: leftW, height: inner.height)
        case .right:       return CGRect(x: rightX, y: inner.minY, width: rightW, height: inner.height)
        case .topLeft:     return CGRect(x: inner.minX, y: inner.minY, width: leftW, height: topH)
        case .topRight:    return CGRect(x: rightX, y: inner.minY, width: rightW, height: topH)
        case .bottomLeft:  return CGRect(x: inner.minX, y: botY, width: leftW, height: botH)
        case .bottomRight: return CGRect(x: rightX, y: botY, width: rightW, height: botH)
        }
    }

    /// Which zone the window currently occupies (all four edges within `tolerance` points), if any.
    /// Detecting from the real frame means we never need to remember state, and it still works
    /// if the user moved the window by hand in between.
    public static func detectZone(of window: CGRect, in visible: CGRect, gap: CGFloat = 0,
                                  tolerance: CGFloat = 12) -> SnapZone? {
        for zone in SnapZone.allCases {
            let f = frame(for: zone, in: visible, gap: gap)
            if abs(f.minX - window.minX) <= tolerance && abs(f.minY - window.minY) <= tolerance &&
               abs(f.maxX - window.maxX) <= tolerance && abs(f.maxY - window.maxY) <= tolerance {
                return zone
            }
        }
        return nil
    }

    // MARK: Snap Assist

    /// After a window is snapped to `zone`, which zone is left empty for Snap Assist to offer?
    /// Halves only: a half-screen snap leaves exactly one obvious empty half.
    public static func assistTarget(afterSnappingTo zone: SnapZone) -> SnapZone? {
        switch zone {
        case .left: return .right
        case .right: return .left
        default: return nil
        }
    }

    // MARK: Drag to edge

    /// Which zone a dragged window would snap to, from the cursor position (top-left coordinates).
    /// Edges: left = left half, right = right half, top = maximize, corners = quarters. No bottom-edge zone (as in Windows).
    /// An edge shared with another display is not a snap edge, otherwise dragging a window between
    /// monitors would trigger snapping.
    public static func dragZone(at p: CGPoint, in display: CGRect, edge: CGFloat = 6, corner: CGFloat = 80,
                                leftIsSnapEdge: Bool = true, rightIsSnapEdge: Bool = true) -> SnapZone? {
        let nl = leftIsSnapEdge && p.x - display.minX <= edge
        let nr = rightIsSnapEdge && display.maxX - p.x <= edge
        let nt = p.y - display.minY <= edge
        let nb = display.maxY - p.y <= edge
        let cl = p.x - display.minX <= corner, cr = display.maxX - p.x <= corner
        let ct = p.y - display.minY <= corner, cb = display.maxY - p.y <= corner
        if (nt && cl && leftIsSnapEdge) || (nl && ct) { return .topLeft }
        if (nt && cr && rightIsSnapEdge) || (nr && ct) { return .topRight }
        if (nb && cl && leftIsSnapEdge) || (nl && cb) { return .bottomLeft }
        if (nb && cr && rightIsSnapEdge) || (nr && cb) { return .bottomRight }
        if nt { return .maximize }
        if nl { return .left }
        if nr { return .right }
        return nil
    }

    // MARK: Windows-style transitions (Win+Arrow)

    public static func transition(from state: SnapZone?, key: ArrowKey,
                                  hasDisplayLeft: Bool, hasDisplayRight: Bool) -> SnapAction {
        switch (state, key) {
        case (nil, .left):  return .snap(.left)
        case (nil, .right): return .snap(.right)
        case (nil, .up):    return .snap(.maximize)
        case (nil, .down):  return .minimize

        case (.maximize?, .left):  return .snap(.left)
        case (.maximize?, .right): return .snap(.right)
        case (.maximize?, .up):    return .none
        case (.maximize?, .down):  return .restore

        case (.left?, .left):  return hasDisplayLeft ? .moveToDisplay(.left, .right) : .none
        case (.left?, .right): return .restore
        case (.left?, .up):    return .snap(.topLeft)
        case (.left?, .down):  return .snap(.bottomLeft)

        case (.right?, .left):  return .restore
        case (.right?, .right): return hasDisplayRight ? .moveToDisplay(.right, .left) : .none
        case (.right?, .up):    return .snap(.topRight)
        case (.right?, .down):  return .snap(.bottomRight)

        case (.topLeft?, .left):  return hasDisplayLeft ? .moveToDisplay(.left, .topRight) : .none
        case (.topLeft?, .right): return .snap(.topRight)
        case (.topLeft?, .up):    return .snap(.maximize)
        case (.topLeft?, .down):  return .snap(.bottomLeft)

        case (.topRight?, .left):  return .snap(.topLeft)
        case (.topRight?, .right): return hasDisplayRight ? .moveToDisplay(.right, .topLeft) : .none
        case (.topRight?, .up):    return .snap(.maximize)
        case (.topRight?, .down):  return .snap(.bottomRight)

        case (.bottomLeft?, .left):  return hasDisplayLeft ? .moveToDisplay(.left, .bottomRight) : .none
        case (.bottomLeft?, .right): return .snap(.bottomRight)
        case (.bottomLeft?, .up):    return .snap(.topLeft)
        case (.bottomLeft?, .down):  return .restore

        case (.bottomRight?, .left):  return .snap(.bottomLeft)
        case (.bottomRight?, .right): return hasDisplayRight ? .moveToDisplay(.right, .bottomLeft) : .none
        case (.bottomRight?, .up):    return .snap(.topRight)
        case (.bottomRight?, .down):  return .restore
        }
    }

    /// Shift+arrow: move to the neighbouring display, keeping the snapped position.
    public static func moveTransition(from state: SnapZone?, key: ArrowKey,
                                      hasDisplayLeft: Bool, hasDisplayRight: Bool) -> SnapAction {
        switch key {
        case .left:  return hasDisplayLeft ? .moveToDisplay(.left, state) : .none
        case .right: return hasDisplayRight ? .moveToDisplay(.right, state) : .none
        case .up, .down: return .none
        }
    }

    /// Frame on a new display: the zone's frame, or (not snapped) the same relative position and size.
    public static func frameOnDisplay(zone: SnapZone?, window: CGRect, from source: CGRect,
                                      to target: CGRect, gap: CGFloat = 0) -> CGRect {
        if let zone { return frame(for: zone, in: target, gap: gap) }
        guard source.width > 0, source.height > 0 else { return window }
        let w = min(window.width * target.width / source.width, target.width)
        let h = min(window.height * target.height / source.height, target.height)
        let x = target.minX + (window.minX - source.minX) * target.width / source.width
        let y = target.minY + (window.minY - source.minY) * target.height / source.height
        return CGRect(x: min(max(x, target.minX), target.maxX - w),
                      y: min(max(y, target.minY), target.maxY - h), width: w, height: h)
    }

    /// Fallback "restored" frame when we never saw the window's original size: centred, 60% of the screen.
    public static func defaultRestoreFrame(in visible: CGRect) -> CGRect {
        let w = (visible.width * 0.6).rounded(), h = (visible.height * 0.6).rounded()
        return CGRect(x: (visible.midX - w / 2).rounded(), y: (visible.midY - h / 2).rounded(), width: w, height: h)
    }
}

/// Remembers the frame a window had before its first snap, so Down / opposite-arrow can restore it.
public struct RestoreMemory<Key: Hashable> {
    private var frames: [Key: CGRect] = [:]
    public init() {}

    /// Call before applying a snap. Only an UNSNAPPED window's frame is worth remembering;
    /// while it hops between zones we keep the original.
    public mutating func willSnap(_ key: Key, currentFrame: CGRect, wasSnapped: Bool) {
        if !wasSnapped || frames[key] == nil { frames[key] = currentFrame }
    }
    public mutating func take(_ key: Key) -> CGRect? { frames.removeValue(forKey: key) }
    public mutating func forget(_ key: Key) { frames.removeValue(forKey: key) }
    public func peek(_ key: Key) -> CGRect? { frames[key] }
}
