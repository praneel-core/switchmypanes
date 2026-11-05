import AppKit
import SwitchmypanesCore

/// Drag a window by its title bar to a screen edge or corner: a preview appears, release to snap.
///
/// How it works: global mouse monitors (no extra permission needed for mouse events). On mouse-down
/// we remember the window under the cursor and its frame. While the button is held, if THAT window has
/// moved (same size, new position) it is being dragged, so we check where the cursor is.
@MainActor
final class DragSnapController {
    private struct Tracked {
        let id: CGWindowID
        let pid: pid_t
        let startFrame: CGRect      // top-left coordinates
        let title: String
    }

    private let settings: SettingsStore
    private let snapper: SnapController
    private let finder: AXWindowFinder
    private let preview = ZonePreviewOverlay()
    private var monitors: [Any] = []
    private var tracked: Tracked?
    private var isDragging = false
    private var pendingZone: (zone: SnapZone, display: DisplayInfo)?

    /// The title bar band: mouse-downs lower than this inside a window are not window drags.
    private let titleBarHeight: CGFloat = 60

    init(settings: SettingsStore, ids: WindowIDProvider, snapper: SnapController) {
        self.settings = settings; self.snapper = snapper; self.finder = AXWindowFinder(ids: ids)
    }

    func start() {
        guard monitors.isEmpty else { return }
        let add: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Void = { mask, handler in
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { self.monitors.append(m) }
        }
        add(.leftMouseDown) { [weak self] _ in MainActor.assumeIsolated { self?.mouseDown() } }
        add(.leftMouseDragged) { [weak self] _ in MainActor.assumeIsolated { self?.mouseDragged() } }
        add(.leftMouseUp) { [weak self] _ in MainActor.assumeIsolated { self?.mouseUp() } }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        reset()
    }

    /// Tear down any in-progress drag (pause, quit, errors).
    func reset() {
        tracked = nil; isDragging = false; pendingZone = nil
        preview.hide()
    }

    // MARK: events

    private var enabled: Bool { settings.snapEnabled && settings.dragSnapEnabled && !settings.paused }

    private func mouseDown() {
        reset()
        guard enabled, AXIsProcessTrusted() else { return }
        let p = DisplayProvider.converter.flip(NSEvent.mouseLocation)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        let me = getpid()
        // Front-to-back: the first normal window containing the cursor is the one being clicked.
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bd as CFDictionary), frame.contains(p) else { continue }
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  p.y - frame.minY <= titleBarHeight else { return }
            tracked = Tracked(id: id, pid: pid, startFrame: frame, title: (w[kCGWindowName as String] as? String) ?? "")
            return
        }
    }

    private func mouseDragged() {
        guard enabled, let t = tracked else { return }
        if !isDragging {
            // Is the window actually moving (and not being resized or just text-selected)?
            guard let now = currentFrame(of: t.id),
                  abs(now.width - t.startFrame.width) < 1.5, abs(now.height - t.startFrame.height) < 1.5,
                  abs(now.minX - t.startFrame.minX) + abs(now.minY - t.startFrame.minY) > 4 else { return }
            isDragging = true
        }
        let cursor = DisplayProvider.converter.flip(NSEvent.mouseLocation)
        let layout = DisplayProvider.layout()
        guard let display = layout.displays.first(where: { $0.frame.contains(cursor) }) else { clearPreview(); return }
        let zone = SnapEngine.dragZone(at: cursor, in: display.frame,
                                       leftIsSnapEdge: layout.neighbor(of: display, .left) == nil,
                                       rightIsSnapEdge: layout.neighbor(of: display, .right) == nil)
        if let zone {
            pendingZone = (zone, display)
            preview.show(frame: SnapEngine.frame(for: zone, in: display.visibleFrame, gap: CGFloat(settings.gap)))
        } else {
            clearPreview()
        }
    }

    private func mouseUp() {
        defer { reset() }
        guard enabled, isDragging, let t = tracked, let pending = pendingZone else { return }
        preview.hide()
        // Let the app finish its own drag handling first, then place the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [snapper, finder] in
            guard let current = finder.find(pid: t.pid, windowID: t.id, frame: self.currentFrame(of: t.id) ?? t.startFrame, title: t.title)
            else { return }
            snapper.snapDragged(window: current, pid: t.pid, to: pending.zone, on: pending.display, preDragFrame: t.startFrame)
        }
    }

    private func clearPreview() { pendingZone = nil; preview.hide() }

    private func currentFrame(of id: CGWindowID) -> CGRect? {
        guard let arr = CGWindowListCreateDescriptionFromArray([id] as CFArray) as? [[String: Any]],
              let bd = arr.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bd as CFDictionary)
    }
}
