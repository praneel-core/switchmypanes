import AppKit
import SwitchmypanesCore

/// Runs one Alt-Tab session: open (second window preselected) -> cycle -> commit or cancel.
@MainActor
final class SwitcherController {
    private let inventory: WindowInventory
    private let thumbnails: ThumbnailService
    private let activator: WindowActivator
    private let panel = SwitcherPanel()

    private(set) var isActive = false
    private var windows: [WindowInfo] = []
    private var selection = SwitcherSelection(count: 0)
    private var columns = 1
    private var showWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var startedAt = Date()

    /// A quick tap commits before this delay, so the overlay never flashes on screen.
    private let showDelay: TimeInterval = 0.12

    init(inventory: WindowInventory, thumbnails: ThumbnailService, activator: WindowActivator) {
        self.inventory = inventory; self.thumbnails = thumbnails; self.activator = activator
        panel.onClick = { [weak self] index in self?.clicked(index) }
        panel.onHover = { [weak self] index in self?.hovered(index) }
    }

    func begin(reverse: Bool) {
        guard !isActive else { return }
        inventory.noteFrontmost()
        var list = inventory.snapshot()
        guard !list.isEmpty else { return }

        let screen = DisplayProvider.screenUnderMouse()
        let layout = SwitcherLayout.plan(count: list.count, screen: screen)
        if list.count > layout.capacity { list = Array(list.prefix(layout.capacity)) }   // only on huge window counts
        windows = list
        columns = layout.columns
        selection = SwitcherSelection(count: list.count, reverse: reverse)
        isActive = true
        startedAt = Date()
        startWatchdog()

        let work = DispatchWorkItem { [weak self] in self?.showPanel(layout: layout, screen: screen) }
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

    private func showPanel(layout: SwitcherLayout, screen: NSScreen) {
        guard isActive else { return }
        panel.present(windows: windows, layout: layout, selected: selection.index, on: screen,
                      thumbnail: { [thumbnails] in thumbnails.cached($0) })
        thumbnails.refresh(windowIDs: windows.map(\.id)) { [weak self] id, image in
            guard let self, self.isActive else { return }
            self.panel.setThumbnail(image, for: id)
        }
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

    /// Belt and braces against a stuck overlay: if the Option key is physically up, or the overlay
    /// has been open for a very long time, close it, even if the event tap missed something.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                if !flags.contains(.maskAlternate) {
                    // The user let go of Option while the event tap did not report it.
                    // The mouse-click path also ends the session, so only commit here.
                    self.commit()
                } else if Date().timeIntervalSince(self.startedAt) > 60 {
                    self.cancel()
                }
            }
        }
    }
}
