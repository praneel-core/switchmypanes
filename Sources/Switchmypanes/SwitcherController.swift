import AppKit
import SwitchmypanesCore

/// Runs one Alt-Tab session: open (second window preselected) -> cycle -> commit or cancel.
@MainActor
final class SwitcherController {
    private let inventory: WindowInventory
    private let thumbnails: ThumbnailService
    private let activator: WindowActivator
    private let panel = SwitcherPanel()

    /// The modifier flags that must stay held for the overlay to stay open (the configured switcher modifier).
    var requiredModifierFlags: () -> CGEventFlags = { .maskAlternate }
    private(set) var isActive = false
    private var windows: [WindowInfo] = []
    private var selection = SwitcherSelection(count: 0)
    private var columns = 1
    private var screen: NSScreen?
    private var caption: String?              // shown above the tiles in per-app mode
    private var panelVisible = false
    private var showWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var startedAt = Date()

    /// A quick tap commits before this delay, so the overlay never flashes on screen.
    private let showDelay: TimeInterval = 0.12

    init(inventory: WindowInventory, thumbnails: ThumbnailService, activator: WindowActivator) {
        self.inventory = inventory; self.thumbnails = thumbnails; self.activator = activator
        panel.onClick = { [weak self] index in self?.clicked(index) }
        panel.onHover = { [weak self] index in self?.hovered(index) }
        panel.onClose = { [weak self] index in self?.close(at: index) }
    }

    enum Scope { case allWindows, frontmostApp }

    func begin(reverse: Bool, scope: Scope = .allWindows) {
        guard !isActive else { return }
        inventory.noteFrontmost()
        var list = inventory.snapshot(includeOtherSpaces: true)
        caption = nil
        if scope == .frontmostApp {
            // Per-app cycling: only the windows of the app you are in, same most-recently-used order.
            guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
            list = list.filter { $0.pid == app.processIdentifier }
            guard list.count > 1 else { return }          // nothing to cycle between
            caption = "\(app.localizedName ?? "App")  ·  \(list.count) windows"
        }
        guard !list.isEmpty else { return }

        let screen = DisplayProvider.screenUnderMouse()
        let layout = SwitcherLayout.plan(count: list.count, screen: screen)
        if list.count > layout.capacity { list = Array(list.prefix(layout.capacity)) }   // only on huge window counts
        windows = list
        self.screen = screen
        panelVisible = false
        columns = layout.columns
        selection = SwitcherSelection(count: list.count, reverse: reverse)
        isActive = true
        startedAt = Date()
        startWatchdog()

        let work = DispatchWorkItem { [weak self] in self?.showPanel() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    func next()     { guard isActive else { return }; selection.next(); updateSelection() }
    func previous() { guard isActive else { return }; selection.previous(); updateSelection() }
    func move(_ key: ArrowKey) { guard isActive else { return }; selection.move(key, columns: columns); updateSelection() }

    func commit() {
        guard isActive else { return }
        let target = windows[selection.index]
        end()
        activator.activate(target)
        inventory.markUsed(target.id)
    }

    /// Always safe to call; tears everything down.
    func cancel() { end() }

    // MARK: private

    /// Draws the overlay for the current list of windows (called when it first appears, and again after a window is closed).
    private func showPanel() {
        guard isActive, let screen else { return }
        let layout = SwitcherLayout.plan(count: windows.count, screen: screen)
        columns = layout.columns
        panel.present(windows: windows, layout: layout, selected: selection.index, on: screen, caption: caption,
                      thumbnail: { [thumbnails] in thumbnails.cached($0) })
        guard !panelVisible else { return }       // thumbnails are only (re)captured when the overlay first appears
        panelVisible = true
        // Windows on other Spaces cannot be captured; they show their last cached picture, or the app icon.
        thumbnails.refresh(windowIDs: windows.filter(\.isOnCurrentSpace).map(\.id)) { [weak self] id, image in
            guard let self, self.isActive else { return }
            self.panel.setThumbnail(image, for: id)
        }
    }

    // MARK: closing windows from the overlay

    func closeSelected() { guard isActive else { return }; close(at: selection.index) }

    func close(at index: Int) {
        guard isActive, index >= 0, index < windows.count else { return }
        let target = windows[index]
        guard activator.close(target) else { NSSound.beep(); return }   // window not found, or it has no close button
        // The app may ask "Save changes?" and keep the window, so only drop the tile once it is really gone.
        for delay in target.isOnAnotherSpace ? [1.0, 1.8, 2.8] : [0.25, 0.7] {   // a desktop switch takes a moment
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.removeIfGone(target.id) }
        }
    }

    private func removeIfGone(_ id: CGWindowID) {
        guard isActive, let i = windows.firstIndex(where: { $0.id == id }) else { return }
        guard !inventory.snapshot(includeOtherSpaces: true).contains(where: { $0.id == id }) else { return }
        windows.remove(at: i)
        selection.didRemove(at: i, newCount: windows.count)
        if windows.isEmpty { end(); return }          // nothing left to switch to
        if panelVisible { showPanel() }
    }

    private func updateSelection() { panel.setSelected(selection.index) }
    private func clicked(_ index: Int) { guard isActive else { return }; selection.select(index); commit() }
    private func hovered(_ index: Int) { guard isActive else { return }; selection.select(index); updateSelection() }

    private func end() {
        showWork?.cancel(); showWork = nil
        watchdog?.invalidate(); watchdog = nil
        thumbnails.cancel()
        panel.dismiss()
        isActive = false
        windows = []
    }

    /// Belt and braces against a stuck overlay: if the modifier key is physically up, or the overlay
    /// has been open for a very long time, close it, even if the event tap missed something.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                if !flags.contains(self.requiredModifierFlags()) {
                    // The user let go of the switcher modifier while the event tap did not report it.
                    // The mouse-click path also ends the session, so only commit here.
                    self.commit()
                } else if Date().timeIntervalSince(self.startedAt) > 60 {
                    self.cancel()
                }
            }
        }
    }
}
