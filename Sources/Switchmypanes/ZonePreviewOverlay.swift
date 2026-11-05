import AppKit

/// The translucent rectangle that shows where a dragged window will land.
/// Click-through and non-activating, so it never interferes with the drag itself.
@MainActor
final class ZonePreviewOverlay {
    private let panel: NSPanel
    private var isShown = false

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        box.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        box.layer?.borderWidth = 3
        panel.contentView = box
    }

    /// `frame` is in top-left coordinates (what the snap maths produces).
    func show(frame: CGRect) {
        let target = DisplayProvider.converter.flip(frame)
        if isShown {
            panel.animator().setFrame(target, display: true)   // glide between zones
        } else {
            panel.setFrame(target, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.animator().alphaValue = 1
            isShown = true
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        panel.orderOut(nil)
    }
}
