import CoreGraphics

/// A Snap Layout: a named arrangement of zones, each a rectangle in unit space (0...1, y down).
/// Zones are listed in the order the user is asked to fill them (left to right, top to bottom).
public struct SnapLayout: Equatable {
    public let name: String
    public let zones: [CGRect]
    public init(name: String, zones: [CGRect]) { self.name = name; self.zones = zones }

    /// Frame of zone `index` inside `visible`. `gap` is the space between zones and to the screen edge.
    /// Edges are rounded to whole points BEFORE the gap is applied, so neighbouring zones always meet exactly.
    public func frame(ofZone index: Int, in visible: CGRect, gap: CGFloat = 0) -> CGRect {
        let u = zones[index]
        let inner = visible.insetBy(dx: gap, dy: gap)
        func x(_ f: CGFloat) -> CGFloat { (inner.minX + f * inner.width).rounded() }
        func y(_ f: CGFloat) -> CGFloat { (inner.minY + f * inner.height).rounded() }
        let eps: CGFloat = 0.001
        let x0 = x(u.minX) + (u.minX > eps ? gap / 2 : 0)
        let x1 = x(u.maxX) - (u.maxX < 1 - eps ? gap / 2 : 0)
        let y0 = y(u.minY) + (u.minY > eps ? gap / 2 : 0)
        let y1 = y(u.maxY) - (u.maxY < 1 - eps ? gap / 2 : 0)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private static func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// The built-in layouts. Nine of them, so the digit keys 1...9 can pick one.
    public static let presets: [SnapLayout] = {
        let t: CGFloat = 1.0 / 3.0
        return [
            SnapLayout(name: "Halves", zones: [r(0, 0, 0.5, 1), r(0.5, 0, 0.5, 1)]),
            SnapLayout(name: "Two thirds + one third", zones: [r(0, 0, 2 * t, 1), r(2 * t, 0, t, 1)]),
            SnapLayout(name: "One third + two thirds", zones: [r(0, 0, t, 1), r(t, 0, 2 * t, 1)]),
            SnapLayout(name: "Three columns", zones: [r(0, 0, t, 1), r(t, 0, t, 1), r(2 * t, 0, t, 1)]),
            SnapLayout(name: "Grid 2 × 2", zones: [r(0, 0, 0.5, 0.5), r(0.5, 0, 0.5, 0.5), r(0, 0.5, 0.5, 0.5), r(0.5, 0.5, 0.5, 0.5)]),
            SnapLayout(name: "Main + two stacked", zones: [r(0, 0, 0.5, 1), r(0.5, 0, 0.5, 0.5), r(0.5, 0.5, 0.5, 0.5)]),
            SnapLayout(name: "Two stacked + main", zones: [r(0, 0, 0.5, 0.5), r(0.5, 0, 0.5, 1), r(0, 0.5, 0.5, 0.5)]),
            SnapLayout(name: "Top and bottom", zones: [r(0, 0, 1, 0.5), r(0, 0.5, 1, 0.5)]),
            SnapLayout(name: "Wide centre", zones: [r(0, 0, 0.25, 1), r(0.25, 0, 0.5, 1), r(0.75, 0, 0.25, 1)]),
        ]
    }()
}
