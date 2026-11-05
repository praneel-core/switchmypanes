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
        acceptsMouseMovedEvents = true        // so a revealed divider keeps seeing the cursor, and can tell when you leave
        alphaValue = 0                        // hidden until you hover the middle of the seam...
        ignoresMouseEvents = true             // ...and then it must not get in the way of clicks on the windows
        contentView = dividerView
    }

    func setRevealed(_ revealed: Bool) {
        ignoresMouseEvents = !revealed
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = revealed ? 0.12 : 0.2
            animator().alphaValue = revealed ? 1 : 0
        }
    }
}

/// Keeps one panel per divider, positioned over the gap between the windows. A divider is invisible (and click-through)
/// until the cursor goes to the MIDDLE of the seam; it then fades in, stays while the cursor is near the line or while
/// you drag it, and fades out shortly after the cursor leaves.
@MainActor
final class DividerOverlay {
    private var panels: [DividerPanel] = []
    private var dividers: [Divider] = []
    private var revealed: [Bool] = []
    private var hideWork: [Int: DispatchWorkItem] = [:]
    private var draggingIndex: Int?
    private var monitors: [Any] = []
    var onBegin: (Int) -> Void = { _ in }
    var onMove: (Int, CGFloat) -> Void = { _, _ in }
    var onEnd: () -> Void = {}
    private let hitWidth: CGFloat = 12
    private let hideDelay: TimeInterval = 0.35

    /// Diagnostics: show the lines all the time.
    var alwaysVisible = false
    var debugRevealedCount: Int { revealed.filter { $0 }.count }

    /// Shows exactly these dividers (reusing panels so a divider being dragged does not flicker).
    func show(_ new: [Divider]) {
        if new.count != dividers.count {
            hideWork.values.forEach { $0.cancel() }; hideWork.removeAll()
            revealed = Array(repeating: alwaysVisible, count: new.count)
        }
        dividers = new
        while panels.count > new.count { panels.removeLast().orderOut(nil) }
        for (i, d) in new.enumerated() {
            let panel: DividerPanel
            if i < panels.count { panel = panels[i] } else {
                panel = DividerPanel(divider: d, converter: { DisplayProvider.converter })
                panels.append(panel)
            }
            let view = panel.dividerView
            view.divider = d
            view.onBegin = { [weak self] in self?.began(i) }
            view.onMove = { [weak self] pos in self?.onMove(i, pos) }
            view.onEnd = { [weak self] in self?.ended() }
            // Top-left coordinates: the line plus a few points either side, so it is easy to grab.
            let rect: CGRect = d.axis == .vertical
                ? CGRect(x: d.position - hitWidth / 2, y: d.start, width: hitWidth, height: d.end - d.start)
                : CGRect(x: d.start, y: d.position - hitWidth / 2, width: d.end - d.start, height: hitWidth)
            panel.setFrame(DisplayProvider.converter.flip(rect), display: true)
            view.needsDisplay = true
            panel.orderFrontRegardless()
            if alwaysVisible && !revealed[i] { revealed[i] = true; panel.setRevealed(true) }
        }
        updateMonitors()
    }

    func hide() { panels.forEach { $0.setRevealed(false) }; revealed = revealed.map { _ in false } }

    func removeAll() {
        hideWork.values.forEach { $0.cancel() }; hideWork.removeAll()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll(); dividers = []; revealed = []; draggingIndex = nil
        updateMonitors()
    }

    // MARK: hover

    private func began(_ i: Int) { draggingIndex = i; cancelHide(i); onBegin(i) }
    private func ended() { draggingIndex = nil; onEnd(); cursorMoved() }

    /// Watches the cursor only while there are dividers. A global monitor sees the cursor over other apps' windows
    /// (where a hidden, click-through divider lives); a local one sees it over our own revealed panel.
    private func updateMonitors() {
        if dividers.isEmpty {
            monitors.forEach { NSEvent.removeMonitor($0) }; monitors.removeAll()
        } else if monitors.isEmpty {
            if let g = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.cursorMoved() }
            }) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] e in
                MainActor.assumeIsolated { self?.cursorMoved() }
                return e
            }) { monitors.append(l) }
        }
    }

    /// `at` (top-left coordinates) lets tests feed a cursor position without moving the real cursor.
    func cursorMoved(at point: CGPoint? = nil) {
        guard !alwaysVisible else { return }
        let p = point ?? DisplayProvider.converter.flip(NSEvent.mouseLocation)
        for (i, d) in dividers.enumerated() where i < panels.count && i != draggingIndex {
            if revealed[i] {
                if d.keepZone().contains(p) { cancelHide(i) } else { scheduleHide(i) }
            } else if d.revealZone().contains(p) {
                reveal(i)
            }
        }
    }

    private func reveal(_ i: Int) {
        cancelHide(i)
        revealed[i] = true
        panels[i].setRevealed(true)
    }

    private func scheduleHide(_ i: Int) {
        guard hideWork[i] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, i < self.panels.count, self.draggingIndex != i else { return }
            self.hideWork[i] = nil
            self.revealed[i] = false
            self.panels[i].setRevealed(false)
        }
        hideWork[i] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }

    private func cancelHide(_ i: Int) { hideWork[i]?.cancel(); hideWork[i] = nil }
}
