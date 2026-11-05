import CoreGraphics

/// Converts between AppKit coordinates (origin bottom-left of the PRIMARY screen, y up)
/// and Accessibility / CoreGraphics coordinates (origin top-left of the primary screen, y down).
///
/// The flip is always relative to the height of the primary screen, no matter which screen a
/// rect is on. The formula is its own inverse, which is why there is only one function.
/// All other code in the app works in top-left coordinates; AppKit values are converted at the edge.
public struct CoordinateConverter: Equatable {
    public let primaryHeight: CGFloat
    public init(primaryHeight: CGFloat) { self.primaryHeight = primaryHeight }

    public func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    public func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
}

public enum HorizontalDirection: Equatable { case left, right }

/// One display, with all rects in top-left global coordinates.
public struct DisplayInfo: Equatable {
    public let id: UInt32
    public let frame: CGRect          // whole display
    public let visibleFrame: CGRect   // minus menu bar and Dock
    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame
    }
}

public struct DisplayLayout {
    public let displays: [DisplayInfo]
    public init(displays: [DisplayInfo]) { self.displays = displays }

    /// The display holding most of the window (falls back to the nearest one by centre distance).
    public func display(containing window: CGRect) -> DisplayInfo? {
        var best: (DisplayInfo, CGFloat)?
        for d in displays {
            let i = d.frame.intersection(window)
            let area = i.isNull ? 0 : i.width * i.height
            if area > (best?.1 ?? 0) { best = (d, area) }
        }
        if let b = best { return b.0 }
        let c = CGPoint(x: window.midX, y: window.midY)
        return displays.min { dist($0.frame, c) < dist($1.frame, c) }
    }

    /// Neighbouring display to the left or right, by horizontal position.
    public func neighbor(of display: DisplayInfo, _ dir: HorizontalDirection) -> DisplayInfo? {
        let others = displays.filter { $0.id != display.id }
        switch dir {
        case .left:  return others.filter { $0.frame.midX < display.frame.midX }.max { $0.frame.midX < $1.frame.midX }
        case .right: return others.filter { $0.frame.midX > display.frame.midX }.min { $0.frame.midX < $1.frame.midX }
        }
    }

    private func dist(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = p.x - r.midX, dy = p.y - r.midY
        return dx * dx + dy * dy
    }
}
