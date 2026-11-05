import AppKit
import SwitchmypanesCore

/// Snap Assist: after a window is snapped to one half, show the other windows over the EMPTY half;
/// pick one (click, or arrows + Return) and it fills the space.
///
/// Lightweight on purpose: it appears after a short delay (so chained snaps like Left-then-Up never
/// flash it), and any key other than its own few keys closes it and then works normally.
@MainActor
final class SnapAssistController {
    private let inventory: WindowInventory
    private let thumbnails: ThumbnailService
    private let activator: WindowActivator
    private let snapper: SnapController
    private let settings: SettingsStore
    private let finder: AXWindowFinder

    private let panel = SwitcherPanel()
    private let zonePreview = ZonePreviewOverlay()

    private(set) var isActive = false
    private var pending: DispatchWorkItem?
    private var available: [WindowInfo] = []
    private var selection = SwitcherSelection(count: 0)
    private var columns = 1
    private var target: (frame: CGRect, display: DisplayInfo)?
    private var outsideClickMonitor: Any?
    private var snapped: LinkedGroupController.Placed?          // the window that was just snapped (the other half of the pair)
    /// Called when a window was chosen for the empty half: the pair (snapped window, chosen window), gap, usable area.
    var onPairPlaced: ([LinkedGroupController.Placed], CGFloat, CGRect) -> Void = { _, _, _ in }
    private var timeout: DispatchWorkItem?

    private let showDelay: TimeInterval = 0.25
    private let autoCloseAfter: TimeInterval = 45

    init(inventory: WindowInventory, thumbnails: ThumbnailService, activator: WindowActivator,
         snapper: SnapController, settings: SettingsStore, ids: WindowIDProvider) {
        self.inventory = inventory; self.thumbnails = thumbnails; self.activator = activator
        self.snapper = snapper; self.settings = settings; self.finder = AXWindowFinder(ids: ids)
        panel.onClick = { [weak self] i in self?.selection.select(i); self?.confirm() }
        panel.onHover = { [weak self] i in self?.selection.select(i); self?.panel.setSelected(i) }
    }

    /// Call after every snap. Does nothing unless the snap left an empty half.
    func offer(afterSnapTo zone: SnapZone, on display: DisplayInfo, pid: pid_t, windowID: CGWindowID?, snappedFrame: CGRect,
               element: AXUIElement) {
        cancel()
        snapped = windowID.map { .init(pid: pid, windowID: $0, element: element) }
        guard settings.snapAssistEnabled, settings.snapEnabled, !settings.paused,
              let free = SnapEngine.assistTarget(afterSnappingTo: zone) else { return }
        let freeFrame = SnapEngine.frame(for: free, in: display.visibleFrame, gap: CGFloat(settings.gap))
        let work = DispatchWorkItem { [weak self] in
            self?.show(freeFrame: freeFrame, display: display, pid: pid, windowID: windowID, snappedFrame: snappedFrame)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    func move(_ key: ArrowKey) {
        guard isActive else { return }
        selection.move(key, columns: columns)
        panel.setSelected(selection.index)
    }

    func confirm() {
        guard isActive, let target, selection.index < available.count else { return }
        let w = available[selection.index]
        let pair = [snapped].compactMap { $0 }          // cancel() below clears the stored window
        cancel()
        guard let ax = finder.find(pid: w.pid, windowID: w.id, frame: w.frame, title: w.title) else { return }
        snapper.place(window: ax, pid: w.pid, target: target.frame, on: target.display, preFrame: w.frame)
        if let first = pair.first { onPairPlaced([first, .init(pid: w.pid, windowID: w.id, element: ax)], CGFloat(settings.gap), target.display.visibleFrame) }
        activator.activate(w)
        inventory.markUsed(w.id)
    }

    /// Always safe to call: cancels a pending offer and tears down anything visible.
    func cancel() {
        pending?.cancel(); pending = nil
        timeout?.cancel(); timeout = nil
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        thumbnails.cancel()
        panel.dismiss(); zonePreview.hide()
        isActive = false
        available = []; target = nil; snapped = nil
    }

    // MARK: private

    private func show(freeFrame: CGRect, display: DisplayInfo, pid: pid_t, windowID: CGWindowID?, snappedFrame: CGRect) {
        pending = nil
        // Everything except the window we just snapped.
        let list = inventory.snapshot(for: .snapping).filter { w in
            if let windowID, w.id == windowID { return false }
            return !(w.pid == pid && abs(w.frame.minX - snappedFrame.minX) < 8 && abs(w.frame.minY - snappedFrame.minY) < 8
                     && abs(w.frame.width - snappedFrame.width) < 8)
        }
        guard !list.isEmpty,
              let screen = NSScreen.screens.first(where: { DisplayProvider.displayID(of: $0) == display.id }) else { return }

        let plan = SwitcherLayout.plan(count: list.count, bounds: freeFrame.size, widthFraction: 0.95, heightFraction: 0.9)
        available = Array(list.prefix(plan.capacity))
        columns = plan.columns
        selection = SwitcherSelection(count: available.count); selection.select(0)
        target = (freeFrame, display)
        isActive = true

        zonePreview.show(frame: freeFrame)
        let c = DisplayProvider.converter.flip(CGPoint(x: freeFrame.midX, y: freeFrame.midY))
        panel.present(windows: available, layout: plan, selected: 0, on: screen,
                      caption: "Snap Assist: pick a window for the empty area",
                      center: NSPoint(x: c.x, y: c.y), thumbnail: { [thumbnails] in thumbnails.cached($0) })
        thumbnails.refresh(windowIDs: available.map(\.id)) { [weak self] id, image in
            guard let self, self.isActive else { return }
            self.panel.setThumbnail(image, for: id)
        }

        // Safety nets: a click anywhere outside closes it; it also closes itself after a while.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        let t = DispatchWorkItem { [weak self] in self?.cancel() }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + autoCloseAfter, execute: t)
    }
}
