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

    init(settings: SettingsStore, ids: WindowIDProvider) { self.settings = settings; self.ids = ids }

    func handle(_ key: ArrowKey, moveToDisplay: Bool) {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
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

        switch action {
        case .none:
            break
        case .snap(let zone):
            restore.willSnap(k, currentFrame: frame, wasSnapped: state != nil)
            WindowMover.apply(SnapEngine.frame(for: zone, in: display.visibleFrame, gap: gap), to: window, bounds: display.visibleFrame)
        case .restore:
            let target = restore.take(k) ?? SnapEngine.defaultRestoreFrame(in: display.visibleFrame)
            let bounds = layout.display(containing: target)?.visibleFrame ?? display.visibleFrame
            WindowMover.apply(target, to: window, bounds: bounds)
        case .minimize:
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        case .moveToDisplay(let dir, let zone):
            guard let target = (dir == .left ? left : right) else { return }
            let newFrame = SnapEngine.frameOnDisplay(zone: zone, window: frame, from: display.visibleFrame,
                                                     to: target.visibleFrame, gap: gap)
            WindowMover.apply(newFrame, to: window, bounds: target.visibleFrame)
        }
    }

    /// Called when a window was dragged to an edge: snap it, remembering where it was BEFORE the drag
    /// so that "Down" (restore) puts it back there.
    func snapDragged(window: AXUIElement, pid: pid_t, to zone: SnapZone, on display: DisplayInfo, preDragFrame: CGRect) {
        let wid = ids.windowID(of: window).map { Int($0) } ?? Int(truncatingIfNeeded: CFHash(window))
        restore.willSnap(WindowKey(pid: pid, id: wid), currentFrame: preDragFrame, wasSnapped: false)
        WindowMover.apply(SnapEngine.frame(for: zone, in: display.visibleFrame, gap: CGFloat(settings.gap)),
                          to: window, bounds: display.visibleFrame)
    }
}
