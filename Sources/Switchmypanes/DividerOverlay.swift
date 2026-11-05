import AppKit
import SwitchmypanesCore

/// The line drawn between linked windows. It shows that the windows are linked, and it is the handle you drag:
/// Switchmypanes then sets BOTH windows itself, one step at a time, so it never depends on the apps reporting resizes.
final class DividerView: NSView {
    var divider: Divider
    var onBegin: (() -> Void)?
    var onMove: ((CGFloat) -> Void)?      // wanted position of the divider line, in top-left screen coordinates
    var onEnd: (() -> Void)?
    private var dragging = false
    private var hovering = false
    private var grabOffset: CGFloat = 0
    private let converter: () -> CoordinateConverter

    init(divider: Divider, converter: @escaping () -> CoordinateConverter) {
        self.divider = divider; self.converter = converter
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    private var vertical: Bool { divider.axis == .vertical }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let thickness: CGFloat = (dragging || hovering) ? 4 : 3
        let line: NSRect = vertical
            ? NSRect(x: bounds.midX - thickness / 2, y: 0, width: thickness, height: bounds.height)
            : NSRect(x: 0, y: bounds.midY - thickness / 2, width: bounds.width, height: thickness)
        accent.withAlphaComponent(dragging ? 1 : 0.85).setFill()
        NSBezierPath(roundedRect: line, xRadius: thickness / 2, yRadius: thickness / 2).fill()
        // a small grip in the middle, so it reads as "drag me"
        let grip: NSRect = vertical
            ? NSRect(x: bounds.midX - 3, y: bounds.midY - 18, width: 6, height: 36)
            : NSRect(x: bounds.midX - 18, y: bounds.midY - 3, width: 36, height: 6)
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 3, yRadius: 3).fill()
        accent.setStroke()
        let outline = NSBezierPath(roundedRect: grip, xRadius: 3, yRadius: 3); outline.lineWidth = 1; outline.stroke()
    }

    private func mousePosition() -> CGFloat {
        let p = converter().flip(NSEvent.mouseLocation)
        return vertical ? p.x : p.y
    }

    override func cursorUpdate(with event: NSEvent) { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        dragging = true; needsDisplay = true
        grabOffset = mousePosition() - divider.position      // keep the point you grabbed under the cursor
        onBegin?()
    }
    override func mouseDragged(with event: NSEvent) { onMove?(mousePosition() - grabOffset) }
    override func mouseUp(with event: NSEvent) { dragging = false; needsDisplay = true; onEnd?() }
}

/// A thin, non-activating panel holding one divider line. It never takes focus from the app you are using.
final class DividerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    let dividerView: DividerView

    init(divider: Divider, converter: @escaping () -> CoordinateConverter) {
        dividerView = DividerView(divider: divider, converter: converter)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating                     // above ordinary windows
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        // No .canJoinAllSpaces: the divider stays on the desktop where the windows are.
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        contentView = dividerView
    }
}

/// Keeps one panel per divider, positioned over the gap between the windows.
@MainActor
final class DividerOverlay {
    private var panels: [DividerPanel] = []
    var onBegin: (Int) -> Void = { _ in }
    var onMove: (Int, CGFloat) -> Void = { _, _ in }
    var onEnd: () -> Void = {}
    private let hitWidth: CGFloat = 12

    /// Shows exactly these dividers (reusing panels so a divider being dragged does not flicker).
    func show(_ dividers: [Divider]) {
        while panels.count > dividers.count { panels.removeLast().orderOut(nil) }
        for (i, d) in dividers.enumerated() {
            let panel: DividerPanel
            if i < panels.count { panel = panels[i] } else {
                panel = DividerPanel(divider: d, converter: { DisplayProvider.converter })
                panels.append(panel)
            }
            let view = panel.dividerView
            view.divider = d
            view.onBegin = { [weak self] in self?.onBegin(i) }
            view.onMove = { [weak self] pos in self?.onMove(i, pos) }
            view.onEnd = { [weak self] in self?.onEnd() }
            // Top-left coordinates: the line plus a few points either side, so it is easy to grab.
            let rect: CGRect = d.axis == .vertical
                ? CGRect(x: d.position - hitWidth / 2, y: d.start, width: hitWidth, height: d.end - d.start)
                : CGRect(x: d.start, y: d.position - hitWidth / 2, width: d.end - d.start, height: hitWidth)
            panel.setFrame(DisplayProvider.converter.flip(rect), display: true)
            view.needsDisplay = true
            panel.orderFrontRegardless()
        }
    }

    func hide() { panels.forEach { $0.orderOut(nil) } }
    func removeAll() { panels.forEach { $0.orderOut(nil) }; panels.removeAll() }
}
