import AppKit
import SwitchmypanesCore

/// Snap Layouts: Option+Z, pick a layout, then pick a window for each zone.
///
/// Step 1  `.choosingLayout`: grid of layout pictures.
/// Step 2  `.choosingWindow`: for each zone in turn, the zone is outlined on screen and you pick a
///         window for it (windows already placed are removed from the list). A window is moved as soon
///         as you pick it, so Esc halfway keeps what you have done so far.
@MainActor
final class LayoutPickerController {
    private enum Stage { case choosingLayout, choosingWindow }

    private let inventory: WindowInventory
    private let thumbnails: ThumbnailService
    private let activator: WindowActivator
    private let snapper: SnapController
    private let settings: SettingsStore
    private let finder: AXWindowFinder

    private let layoutPanel = LayoutChoicePanel()
    private let windowPanel = SwitcherPanel()
    private let zonePreview = ZonePreviewOverlay()

    private(set) var isActive = false
    private var stage = Stage.choosingLayout
    private let layouts = SnapLayout.presets
    private var layoutSelection = SwitcherSelection(count: 0)
    private var chosen: SnapLayout?
    private var zoneIndex = 0
    private var available: [WindowInfo] = []
    private var windowSelection = SwitcherSelection(count: 0)
    private var windowColumns = 1
    private var screen: NSScreen?
    private var display: DisplayInfo?
    private var outsideClickMonitor: Any?
    private var watchdog: Timer?
    private var startedAt = Date()

    init(inventory: WindowInventory, thumbnails: ThumbnailService, activator: WindowActivator,
         snapper: SnapController, settings: SettingsStore, ids: WindowIDProvider) {
        self.inventory = inventory; self.thumbnails = thumbnails; self.activator = activator
        self.snapper = snapper; self.settings = settings; self.finder = AXWindowFinder(ids: ids)
        layoutPanel.onClick = { [weak self] i in self?.layoutSelection.select(i); self?.confirm() }
        layoutPanel.onHover = { [weak self] i in self?.layoutSelection.select(i); self?.refreshLayoutSelection() }
        windowPanel.onClick = { [weak self] i in self?.windowSelection.select(i); self?.confirm() }
        windowPanel.onHover = { [weak self] i in self?.windowSelection.select(i); self?.windowPanel.setSelected(i) }
    }

    // MARK: entry points (called from the keyboard monitor)

    func begin() {
        guard !isActive, AXIsProcessTrusted() else { return }
        inventory.noteFrontmost()
        let list = inventory.snapshot(for: .snapping)
        guard !list.isEmpty else { return }
        let scr = DisplayProvider.screenUnderMouse()
        let id = DisplayProvider.displayID(of: scr)
        guard let d = DisplayProvider.layout().displays.first(where: { $0.id == id }) else { return }

        screen = scr; display = d; available = list; chosen = nil; zoneIndex = 0
        layoutSelection = SwitcherSelection(count: layouts.count); layoutSelection.select(0)   // start on the first layout, not the second
        stage = .choosingLayout
        isActive = true
        startedAt = Date()
        layoutPanel.present(layouts: layouts, selected: 0, on: scr)
        installSafetyNets()
    }

    func move(_ key: ArrowKey) {
        guard isActive else { return }
        switch stage {
        case .choosingLayout:
            layoutSelection.move(key, columns: LayoutChoicePanel.columns)
            refreshLayoutSelection()
        case .choosingWindow:
            windowSelection.move(key, columns: windowColumns)
            windowPanel.setSelected(windowSelection.index)
        }
    }

    func choose(number: Int) {
        guard isActive, stage == .choosingLayout, number >= 1, number <= layouts.count else { return }
        layoutSelection.select(number - 1)
        confirm()
    }

    func confirm() {
        guard isActive else { return }
        switch stage {
        case .choosingLayout:
            chosen = layouts[layoutSelection.index]
            layoutPanel.dismiss()
            stage = .choosingWindow
            zoneIndex = 0
            showWindowStep(refreshThumbnails: true)
        case .choosingWindow:
            guard let layout = chosen, let display, windowSelection.index < available.count else { return }
            let w = available.remove(at: windowSelection.index)
            place(w, into: layout.frame(ofZone: zoneIndex, in: display.visibleFrame, gap: CGFloat(settings.gap)), display: display)
            advance()
        }
    }

    func skip() {
        guard isActive, stage == .choosingWindow else { return }
        advance()
    }

    /// Always safe to call; tears everything down.
    func cancel() {
        watchdog?.invalidate(); watchdog = nil
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        thumbnails.cancel()
        layoutPanel.dismiss(); windowPanel.dismiss(); zonePreview.hide()
        isActive = false
        available = []; chosen = nil
    }

    // MARK: steps

    private func advance() {
        guard let layout = chosen else { return cancel() }
        zoneIndex += 1
        if zoneIndex >= layout.zones.count || available.isEmpty { cancel() } else { showWindowStep(refreshThumbnails: false) }
    }

    private func showWindowStep(refreshThumbnails: Bool) {
        guard let layout = chosen, let display, let screen else { return cancel() }
        zonePreview.show(frame: layout.frame(ofZone: zoneIndex, in: display.visibleFrame, gap: CGFloat(settings.gap)))
        let plan = SwitcherLayout.plan(count: available.count, screen: screen)
        if available.count > plan.capacity { available = Array(available.prefix(plan.capacity)) }
        windowColumns = plan.columns
        windowSelection = SwitcherSelection(count: available.count); windowSelection.select(0)   // frontmost window first
        let caption = "Area \(zoneIndex + 1) of \(layout.zones.count) (outlined)  ·  Return to place  ·  Space to skip  ·  Esc to stop"
        windowPanel.present(windows: available, layout: plan, selected: 0, on: screen, caption: caption,
                            thumbnail: { [thumbnails] in thumbnails.cached($0) })
        if refreshThumbnails {
            thumbnails.refresh(windowIDs: available.map(\.id)) { [weak self] id, image in
                guard let self, self.isActive else { return }
                self.windowPanel.setThumbnail(image, for: id)
            }
        }
    }

    private func place(_ w: WindowInfo, into target: CGRect, display: DisplayInfo) {
        guard let ax = finder.find(pid: w.pid, windowID: w.id, frame: w.frame, title: w.title) else { return }
        snapper.place(window: ax, pid: w.pid, target: target, on: display, preFrame: w.frame)
        activator.activate(w)          // bring it to the front so placed windows are not hidden behind others
        inventory.markUsed(w.id)
    }

    private func refreshLayoutSelection() { layoutPanel.setSelected(layoutSelection.index) }

    /// The picker owns the keyboard, so it must never be possible to get stuck inside it.
    private func installSafetyNets() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        // Global monitors only see clicks that go to OTHER apps/windows: a click outside the picker closes it.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                if Date().timeIntervalSince(self.startedAt) > 180 { self.cancel() }   // nobody leaves it open for 3 minutes
            }
        }
    }
}
