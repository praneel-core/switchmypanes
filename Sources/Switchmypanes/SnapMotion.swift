import AppKit
import QuartzCore
import SwitchmypanesCore

/// The snap animation: a soft glowing outline that glides from where the window WAS to where it LANDS (a spring, so it
/// accelerates, overshoots a touch and settles), then fades. The window itself still snaps instantly and reliably.
///
/// Why not slide the real window? Apps apply resizes late and sometimes drop half of an update (a lesson from linked
/// resizing), so stepping a window's frame stutters; and a picture of the window sliding would need the real window hidden
/// meanwhile, which macOS does not let us do cleanly. Animating an outline shows the motion with none of that risk, needs no
/// screen-capture permission, and cannot disturb the window.
///
/// It is drawn as a Core Animation layer inside one transparent, click-through panel (not by resizing a window), so the
/// motion is composited on the GPU and stays smooth, and the glow is never clipped.
@MainActor
final class SnapMotion {
    private let panel: NSPanel
    private let root = NSView()
    private let outline = CALayer()          // the glowing rounded rectangle that moves
    private let echo = CALayer()             // a fainter copy that trails it slightly, for a sense of speed
    private var generation = 0
    /// Whether animations are switched on in Preferences.
    var isEnabled: () -> Bool = { true }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar               // above normal windows, below the switcher's overlays
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true        // never gets in the way
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]

        root.wantsLayer = true
        panel.contentView = root
        for (layer, fill, border, glow) in [(echo, 0.10, 0.45, 0.20), (outline, 0.22, 0.95, 0.60)] as [(CALayer, CGFloat, CGFloat, Float)] {
            layer.cornerRadius = 14
            layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(fill).cgColor
            layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(border).cgColor
            layer.borderWidth = 2.5
            layer.shadowColor = NSColor.controlAccentColor.cgColor
            layer.shadowOpacity = glow
            layer.shadowRadius = 18
            layer.shadowOffset = .zero
            layer.opacity = 0
            root.layer?.addSublayer(layer)
        }
    }

    /// A spring from `from` to `to` for one property. Slightly under-damped: a little overshoot, then it settles.
    private func spring(_ keyPath: String, from: NSValue, to: NSValue, delay: CFTimeInterval = 0, stiffness: CGFloat = 230) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.fromValue = from; a.toValue = to
        a.mass = 1; a.stiffness = stiffness; a.damping = 21; a.initialVelocity = 0
        a.duration = a.settlingDuration
        a.beginTime = CACurrentMediaTime() + delay
        a.fillMode = .backwards                // hold the start value during the delay
        return a
    }

    /// Frames are in top-left coordinates (what the snap code works in). A newer snap cancels an older animation.
    func play(from: CGRect, to: CGRect) {
        guard SnapMotionPolicy.shouldAnimate(from: from, to: to, enabled: isEnabled(),
                                             reduceMotion: !OverlayTheme.motionEnabled) else { return }
        generation += 1
        let mine = generation
        let converter = DisplayProvider.converter
        let start = converter.flip(from), end = converter.flip(to)        // AppKit (bottom-left) global coordinates

        // One panel big enough for the whole trip, with room for the glow all around.
        let area = start.union(end).insetBy(dx: -90, dy: -90)
        panel.setFrame(area, display: false)
        root.frame = NSRect(origin: .zero, size: area.size)
        func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -area.minX, dy: -area.minY) }
        let a = local(start), b = local(end)

        let total = SnapMotionPolicy.duration(from: from, to: to) + 0.34        // travel, then hold and fade
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [echo, outline] {
            layer.removeAllAnimations()
            layer.bounds = CGRect(origin: .zero, size: b.size)               // final values (the animations start from the old ones)
            layer.position = CGPoint(x: b.midX, y: b.midY)
            layer.opacity = 0
        }
        CATransaction.commit()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // fade: quick in, hold while travelling, slow out
        func fade(_ delay: CFTimeInterval, peak: Float) -> CAKeyframeAnimation {
            let f = CAKeyframeAnimation(keyPath: "opacity")
            f.values = [0, peak, peak, 0]
            f.keyTimes = [0, 0.10, 0.58, 1]
            f.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeIn)]
            f.duration = total
            f.beginTime = CACurrentMediaTime() + delay
            f.fillMode = .backwards
            return f
        }
        for (layer, delay, peak, stiffness) in [(echo, 0.045, Float(0.55), CGFloat(190)), (outline, 0.0, Float(1), CGFloat(230))] as [(CALayer, CFTimeInterval, Float, CGFloat)] {
            layer.add(spring("position", from: NSValue(point: CGPoint(x: a.midX, y: a.midY)), to: NSValue(point: CGPoint(x: b.midX, y: b.midY)),
                             delay: delay, stiffness: stiffness), forKey: "position")
            layer.add(spring("bounds", from: NSValue(rect: CGRect(origin: .zero, size: a.size)), to: NSValue(rect: CGRect(origin: .zero, size: b.size)),
                             delay: delay, stiffness: stiffness), forKey: "bounds")
            layer.add(fade(delay, peak: peak), forKey: "fade")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.12) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Stops any animation and hides the outline at once (pause, quit).
    func cancel() {
        generation += 1
        for layer in [echo, outline] { layer.removeAllAnimations(); layer.opacity = 0 }
        panel.orderOut(nil)
    }
    var debugIsVisible: Bool { panel.isVisible }
}
