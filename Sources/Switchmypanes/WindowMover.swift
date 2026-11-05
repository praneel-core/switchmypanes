import ApplicationServices
import CoreGraphics

/// Applies a target frame to a window through Accessibility, coping with apps that push back.
enum WindowMover {
    /// - Parameters:
    ///   - target: wanted frame (top-left coordinates)
    ///   - bounds: the display's usable area; the result is kept inside it
    @discardableResult
    static func apply(_ target: CGRect, to window: AXUIElement, bounds: CGRect) -> Bool {
        let canResize = AX.isSettable(window, kAXSizeAttribute)
        let canMove = AX.isSettable(window, kAXPositionAttribute)
        guard canMove || canResize else { return false }

        if canResize { AX.setSize(window, target.size) }       // shrink first, so the move fits on the new display
        if canMove { AX.setPosition(window, target.origin) }
        if canResize { AX.setSize(window, target.size) }       // a move across displays can clamp the size: set it again

        // Some windows refuse to be as small as asked (minimum size) or cannot be resized at all.
        // Keep them on the side of the target region they were meant for, and inside the screen.
        guard canMove, let actual = AX.frame(window) else { return true }
        if abs(actual.width - target.width) > 1 || abs(actual.height - target.height) > 1 {
            let wantsRight = target.midX > bounds.midX
            var x = wantsRight ? target.maxX - actual.width : target.minX
            var y = target.minY
            x = min(max(x, bounds.minX), max(bounds.minX, bounds.maxX - actual.width))
            y = min(max(y, bounds.minY), max(bounds.minY, bounds.maxY - actual.height))
            AX.setPosition(window, CGPoint(x: x, y: y))
        }
        return true
    }
}
