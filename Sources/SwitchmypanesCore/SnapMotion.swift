import CoreGraphics
import Foundation

/// When and how long the snap animation plays. Pure rules, tested.
public enum SnapMotionPolicy {
    /// Animate only when it is wanted, motion is allowed (macOS "Reduce motion" off), and the window really moves or
    /// changes size. A nudge of a few points is not worth a flourish.
    public static func shouldAnimate(from: CGRect, to: CGRect, enabled: Bool, reduceMotion: Bool, minimumChange: CGFloat = 8) -> Bool {
        guard enabled, !reduceMotion, !from.isEmpty, !to.isEmpty else { return false }
        let moved = hypot(from.midX - to.midX, from.midY - to.midY)
        let resized = max(abs(from.width - to.width), abs(from.height - to.height))
        return max(moved, resized) >= minimumChange
    }

    /// Short for small moves, a little longer for big ones (never below 0.16 s or above 0.30 s).
    public static func duration(from: CGRect, to: CGRect) -> TimeInterval {
        let travel = hypot(from.midX - to.midX, from.midY - to.midY)
        let size = max(abs(from.width - to.width), abs(from.height - to.height))
        let amount = max(travel, size)
        return min(0.30, max(0.16, 0.16 + Double(amount) / 4000))
    }
}
