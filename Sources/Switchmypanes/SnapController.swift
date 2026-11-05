import AppKit
import SwitchmypanesCore

/// Keyboard snapping: finds the front window, works out what it is doing now, asks the SnapEngine
/// what should happen, and applies it.
@MainActor
final class SnapController {
    private struct WindowKey: Hashable { let pid: pid_t; let id: Int }

    private let settings: SettingsStore
    private let ids: WindowIDProvider
    private var restore = RestoreMemory<WindowKey>()
    let motion = SnapMotion()

    /// Called just before we move a window ourselves (so a linked group can let go of it).
    var onWillMoveWindow: (pid_t, CGWindowID?) -> Void = { _, _ in }
    /// Called at the start of every snap attempt (lets Snap Assist close itself / cancel a pending offer).
    var onBeforeSnap: () -> Void = {}
    /// Called after a window was snapped to a zone: (zone, display, pid, window id if known, the frame it was given, the window).
    var onSnapped: (SnapZone, DisplayInfo, pid_t, CGWindowID?, CGRect, AXUIElement) -> Void = { _, _, _, _, _, _ in }

    init(settings: SettingsStore, ids: WindowIDProvider) {
        self.settings = settings; self.ids = ids
        motion.isEnabled = { [settings] in settings.snapAnimationsEnabled }
    }

    func handle(_ key: ArrowKey, moveToDisplay: Bool) {
        onBeforeSnap()
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        guard !AppExclusions.isExcluded(bundleID: app.bundleIdentifier, for: .snapping, in: settings.appExclusions) else { return }
        let appEl = AX.app(pid: app.processIdentifier)
        guard let window = AX.focusedWindow(of: appEl),
              AX.bool(window, "AXFullScreen") != true,            // full-screen windows are managed by macOS
              let frame = AX.frame(window) else { return }

        let layout = DisplayProvider.layout()
        guard let display = layout.display(containing: frame) else { return }
        let gap = CGFloat(settings.gap)
        let state = SnapEngine.detectZone(of: frame, in: display.visibleFrame, gap: gap)
        let left = layout.neighbor(of: display, .left), right = layout.neighbor(of: display, .right)

        let action = moveToDisplay
            ? SnapEngine.moveTransition(from: state, key: key, hasDisplayLeft: left != nil, hasDisplayRight: right != nil)
            : SnapEngine.transition(from: state, key: key, hasDisplayLeft: left != nil, hasDisplayRight: right != nil)

        let wid = ids.windowID(of: window).map { Int($0) } ?? Int(truncatingIfNeeded: CFHash(window))
        let k = WindowKey(pid: app.processIdentifier, id: wid)
        if action != .none { onWillMoveWindow(app.processIdentifier, ids.windowID(of: window)) }

        switch action {
        case .none:
            break
        case .snap(let zone):
            restore.willSnap(k, currentFrame: frame, wasSnapped: state != nil)
            let target = SnapEngine.frame(for: zone, in: display.visibleFrame, gap: gap)
            WindowMover.apply(target, to: window, bounds: display.visibleFrame)
            motion.play(from: frame, to: target)
            onSnapped(zone, display, app.processIdentifier, ids.windowID(of: window), target, window)
        case .restore:
            let target = restore.take(k) ?? SnapEngine.defaultRestoreFrame(in: display.visibleFrame)
            let bounds = layout.display(containing: target)?.visibleFrame ?? display.visibleFrame
            WindowMover.apply(target, to: window, bounds: bounds)
            motion.play(from: frame, to: target)
        case .minimize:
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        case .moveToDisplay(let dir, let zone):
            guard let target = (dir == .left ? left : right) else { return }
            let newFrame = SnapEngine.frameOnDisplay(zone: zone, window: frame, from: display.visibleFrame,
                                                     to: target.visibleFrame, gap: gap)
            WindowMover.apply(newFrame, to: window, bounds: target.visibleFrame)
            motion.play(from: frame, to: newFrame)
        }
    }

    /// Put a window into a frame chosen by a picker or a drag, remembering where it was BEFORE
    /// so that "Down" (restore) puts it back there.
    func place(window: AXUIElement, pid: pid_t, target: CGRect, on display: DisplayInfo, preFrame: CGRect, animateFrom: CGRect? = nil) {
        onWillMoveWindow(pid, ids.windowID(of: window))
        let wid = ids.windowID(of: window).map { Int($0) } ?? Int(truncatingIfNeeded: CFHash(window))
        restore.willSnap(WindowKey(pid: pid, id: wid), currentFrame: preFrame, wasSnapped: false)
        WindowMover.apply(target, to: window, bounds: display.visibleFrame)
        motion.play(from: animateFrom ?? preFrame, to: target)
    }

    /// Snaps a window chosen elsewhere (for example from the switcher's right-click menu) to a zone. False if it cannot be
    /// done: not on this desktop, snapping off, the app excluded from snapping, or the window cannot be reached.
    @discardableResult
    func snap(_ info: WindowInfo, to zone: SnapZone) -> Bool {
        guard info.isOnCurrentSpace, settings.snapEnabled,
              !AppExclusions.isExcluded(bundleID: info.bundleID, for: .snapping, in: settings.appExclusions),
              let window = AXWindowFinder(ids: ids).find(pid: info.pid, windowID: info.id, frame: info.frame, title: info.title),
              let display = DisplayProvider.layout().display(containing: info.frame) else { return false }
        onBeforeSnap()
        let target = SnapEngine.frame(for: zone, in: display.visibleFrame, gap: CGFloat(settings.gap))
        place(window: window, pid: info.pid, target: target, on: display, preFrame: info.frame)
        onSnapped(zone, display, info.pid, info.id, target, window)         // lets Snap Assist offer the other half
        return true
    }

    /// Called when a window was dragged to an edge.
    func snapDragged(window: AXUIElement, pid: pid_t, to zone: SnapZone, on display: DisplayInfo, preDragFrame: CGRect, releasedAt: CGRect? = nil) {
        onBeforeSnap()
        let target = SnapEngine.frame(for: zone, in: display.visibleFrame, gap: CGFloat(settings.gap))
        place(window: window, pid: pid, target: target, on: display, preFrame: preDragFrame, animateFrom: releasedAt)
        onSnapped(zone, display, pid, ids.windowID(of: window), target, window)
    }
}
