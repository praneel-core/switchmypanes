import AppKit
import SwitchmypanesCore

/// The snap animation: a soft glowing outline that travels from where the window WAS to where it LANDS, then pulses and
/// fades. The window itself still snaps instantly and reliably, exactly as before.
///
/// Why not slide the real window? Apps apply resizes late and sometimes drop half of an update (a lesson from linked
/// resizing), so stepping a window's frame stutters; and a picture of the window sliding would need the real window
/// hidden meanwhile, which macOS does not let us do cleanly. Animating an outline shows the motion with none of that
/// risk, needs no screen-capture permission, and cannot disturb the window.
@MainActor
final class SnapMotion {
    private let panel: NSPanel
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
        panel.alphaValue = 0

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.26).cgColor
        box.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
        box.layer?.borderWidth = 2.5
        box.layer?.shadowColor = NSColor.controlAccentColor.cgColor
        box.layer?.shadowOpacity = 0.55
        box.layer?.shadowRadius = 16
        box.layer?.shadowOffset = .zero
        panel.contentView = box
    }

    /// Frames are in top-left coordinates (what the snap code works in). A newer snap cancels an older animation.
    func play(from: CGRect, to: CGRect) {
        guard SnapMotionPolicy.shouldAnimate(from: from, to: to, enabled: isEnabled(),
                                             reduceMotion: !OverlayTheme.motionEnabled) else { return }
        generation += 1
        let mine = generation
        let converter = DisplayProvider.converter
        let start = converter.flip(from), end = converter.flip(to)
        let travel = SnapMotionPolicy.duration(from: from, to: to)

        panel.setFrame(start, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // 1. travel from the old frame to the new one, appearing as it leaves
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = travel
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine else { return }
                // 2. landing pulse: swell a little and fade out
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.panel.animator().setFrame(end.insetBy(dx: -7, dy: -7), display: true)
                    self.panel.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == mine else { return }
                        self.panel.orderOut(nil)
                    }
                })
            }
        })
    }

    /// Stops any animation and hides the outline at once (pause, quit).
    func cancel() { generation += 1; panel.orderOut(nil); panel.alphaValue = 0 }
    var debugIsVisible: Bool { panel.isVisible }
}
