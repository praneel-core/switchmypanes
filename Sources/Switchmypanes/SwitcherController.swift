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
    /// While the right-click menu is open the overlay is "pinned": it stays up even if Option is released, and the keyboard
    /// listener steps aside so the menu's own keys work.
    private(set) var isPinned = false
    var isCapturingKeys: Bool { isActive && !isPinned }
    /// Set by the app: snap a window to a zone / hide an app from the switcher (the menu's actions).
    var snapWindow: (WindowInfo, SnapZone) -> Bool = { _, _ in false }
    var excludeFromSwitcher: (WindowInfo) -> Void = { _ in }
    private var fullList: [WindowInfo] = []        // every window (most recently used first), before searching
    private var windows: [WindowInfo] = []         // what is shown: the list filtered by the query
    private var query = ""                          // what you have typed while the overlay is open; kept in memory only
    private var startedReversed = false
    private var selection = SwitcherSelection(count: 0)
    private var columns = 1
    private var screen: NSScreen?
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
        panel.onContextMenu = { [weak self] index, event in self?.showContextMenu(for: index, event: event) }
    }

    func begin(reverse: Bool) {
        guard !isActive else { return }
        inventory.noteFrontmost()
        let list = inventory.snapshot(includeOtherSpaces: true, for: .switcher)
        guard !list.isEmpty else { return }

        fullList = list
        query = ""
        startedReversed = reverse
        screen = DisplayProvider.screenUnderMouse()
        panelVisible = false
        rebuild(resetSelection: true)
        isActive = true
        startedAt = Date()
        startWatchdog()

        let work = DispatchWorkItem { [weak self] in self?.showPanel() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    /// Applies the typed query to the full list, lays the result out, and (optionally) resets the highlight.
    private func rebuild(resetSelection: Bool) {
        let filtered = query.isEmpty ? fullList
            : WindowSearch.filter(fullList, query: query, texts: { [$0.appName, $0.title, $0.spaceLabel ?? ""] })
        guard !filtered.isEmpty, let screen else {
            windows = []; columns = 1; selection = SwitcherSelection(count: 0); return
        }
        let layout = SwitcherLayout.plan(count: filtered.count, screen: screen)
        windows = filtered.count > layout.capacity ? Array(filtered.prefix(layout.capacity)) : filtered   // only on huge window counts
        columns = layout.columns
        guard resetSelection else { return }
        if query.isEmpty {
            selection = SwitcherSelection(count: windows.count, reverse: startedReversed)
            // Normally entry 0 is the window you are in and the quick tap goes to entry 1. If you are in an app that is
            // excluded (or has no window), nothing listed is "where you are", so start on the first entry instead.
            if !startedReversed, windows.first?.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier { selection.select(0) }
        } else {
            selection = SwitcherSelection(count: windows.count)
            selection.select(0)                         // while searching, the best (most recent) match is highlighted
        }
    }

    // MARK: type to search

    /// A character typed while the overlay is open (the keyboard listener only reads characters while it is open).
    func type(_ text: String) {
        guard isActive else { return }
        query += text.lowercased()
        queryChanged()
    }

    func backspace() {
        guard isActive, !query.isEmpty else { return }       // never closes anything: an empty search just ignores it
        query.removeLast()
        queryChanged()
    }

    /// Esc: clears the search first; a second Esc closes the overlay.
    func escape() {
        guard isActive else { return }
        if query.isEmpty { cancel() } else { query = ""; queryChanged() }
    }

    private func queryChanged() {
        rebuild(resetSelection: true)
        showWork?.cancel(); showWork = nil              // typing means you want to see it now
        showPanel()
    }

    // MARK: test seam (`--selftest-search`): drive the search flow without drawing anything

    var debugSuppressPanel = false
    func debugBegin(with list: [WindowInfo]) {
        fullList = list; query = ""; startedReversed = false; screen = DisplayProvider.screenUnderMouse(); panelVisible = false
        rebuild(resetSelection: true)
        isActive = true
    }
    var debugState: (active: Bool, shown: [String], query: String, selected: Int) {
        (isActive, windows.map(\.appName), query, selection.index)
    }

    func next()     { guard isActive else { return }; selection.next(); updateSelection() }
    func previous() { guard isActive else { return }; selection.previous(); updateSelection() }
    func move(_ key: ArrowKey) { guard isActive, !windows.isEmpty else { return }; selection.move(key, columns: columns); updateSelection() }

    func commit() {
        guard isActive else { return }
        guard !windows.isEmpty else { end(); return }              // nothing matches what you typed: just close
        let target = windows[selection.index]
        end()
        activator.activate(target)
        inventory.markUsed(target.id)
    }

    /// Always safe to call; tears everything down.
    func cancel() { end() }

    // MARK: private

    /// Draws the overlay for the current list of windows (when it first appears, after a window is closed, as you type).
    private func showPanel() {
        guard isActive, let screen, !debugSuppressPanel else { return }
        if windows.isEmpty {
            panel.presentMessage("No windows match \u{201C}\(query)\u{201D}", query: query, on: screen)
        } else {
            let layout = SwitcherLayout.plan(count: windows.count, screen: screen)
            columns = layout.columns
            panel.present(windows: windows, layout: layout, selected: selection.index, on: screen, query: query.isEmpty ? nil : query,
                          thumbnail: { [thumbnails] in thumbnails.cached($0) })
        }
        guard !panelVisible else { return }       // thumbnails are only (re)captured when the overlay first appears
        panelVisible = true
        // Windows on other Spaces cannot be captured; they show their last cached picture, or the app icon.
        // (All windows, not just the shown ones, so a search finds windows that already have their picture.)
        thumbnails.refresh(windowIDs: fullList.filter(\.isOnCurrentSpace).map(\.id)) { [weak self] id, image in
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
        guard !inventory.snapshot(includeOtherSpaces: true, for: .switcher).contains(where: { $0.id == id }) else { return }
        windows.remove(at: i)
        fullList.removeAll { $0.id == id }
        selection.didRemove(at: i, newCount: windows.count)
        if fullList.isEmpty { end(); return }          // nothing left to switch to
        if panelVisible { showPanel() }
    }

    private func updateSelection() { panel.setSelected(selection.index) }
    private func clicked(_ index: Int) { guard isActive else { return }; selection.select(index); commit() }
    private func hovered(_ index: Int) { guard isActive else { return }; selection.select(index); updateSelection() }

    // MARK: right-click menu on a tile

    private final class MenuAction: NSMenuItem {
        private let handler: () -> Void
        init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
            isEnabled = enabled
        }
        required init(coder: NSCoder) { fatalError() }
        @objc func run() { handler() }
    }

    private func shortened(_ s: String, _ n: Int = 34) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    /// What the menu offers for a window. Actions that need the window on THIS desktop are greyed out for other desktops.
    private func makeMenu(for info: WindowInfo) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let here = info.isOnCurrentSpace
        let canSnap = here && !AppExclusions.isExcluded(bundleID: info.bundleID, for: .snapping, in: SettingsStore.shared.appExclusions) && SettingsStore.shared.snapEnabled
        func act(_ then: @escaping () -> Void) -> () -> Void { { [weak self] in self?.menuActionTaken = true; then(); self?.end() } }

        menu.addItem(MenuAction("Switch to “\(shortened(info.title))”", handler: act { [weak self] in
            self?.activator.activate(info); self?.inventory.markUsed(info.id) }))
        menu.addItem(.separator())
        menu.addItem(MenuAction("Close window", handler: act { [weak self] in _ = self?.activator.close(info) }))
        menu.addItem(MenuAction("Minimize", enabled: here, handler: act { [weak self] in _ = self?.activator.minimize(info) }))
        let snap = NSMenuItem(title: "Snap", action: nil, keyEquivalent: "")
        let sub = NSMenu(); sub.autoenablesItems = false
        for (title, zone) in [("Left half", SnapZone.left), ("Right half", .right), ("Maximize", .maximize)] {
            sub.addItem(MenuAction(title, enabled: canSnap, handler: act { [weak self] in _ = self?.snapWindow(info, zone) }))
        }
        snap.submenu = sub; snap.isEnabled = canSnap
        menu.addItem(snap)
        menu.addItem(.separator())
        menu.addItem(MenuAction("Hide “\(info.appName)” from the switcher", enabled: info.bundleID != nil,
                                handler: act { [weak self] in self?.excludeFromSwitcher(info) }))
        return menu
    }

    private var menuActionTaken = false

    private func showContextMenu(for index: Int, event: NSEvent) {
        guard isActive, !isPinned, index >= 0, index < windows.count else { return }
        selection.select(index); updateSelection()
        isPinned = true; menuActionTaken = false
        let menu = makeMenu(for: windows[index])
        if let after = debugMenuAutoCancelAfter { DispatchQueue.main.asyncAfter(deadline: .now() + after) { menu.cancelTracking() } }
        NSMenu.popUpContextMenu(menu, with: event, for: panel.contentView ?? NSView())      // returns when the menu closes
        isPinned = false
        // Dismissed without choosing: carry on only if the key is still held, otherwise the overlay has nothing to wait for.
        if isActive && !menuActionTaken && !CGEventSource.flagsState(.combinedSessionState).contains(requiredModifierFlags()) { end() }
    }

    // test seam (`--selftest-menu`)
    func debugMenu(for info: WindowInfo) -> [(title: String, enabled: Bool)] {
        var out: [(String, Bool)] = []
        for item in makeMenu(for: info).items where !item.isSeparatorItem {
            if let sub = item.submenu { for s in sub.items { out.append(("\(item.title) ▸ \(s.title)", s.isEnabled)) } } else { out.append((item.title, item.isEnabled)) }
        }
        return out
    }
    func debugPerform(_ title: String, for info: WindowInfo) {
        var flat: [(String, NSMenuItem)] = []
        for item in makeMenu(for: info).items where !item.isSeparatorItem {
            if let sub = item.submenu { for s in sub.items { flat.append(("\(item.title) ▸ \(s.title)", s)) } } else { flat.append((item.title, item)) }
        }
        if let item = flat.first(where: { $0.0 == title })?.1, item.isEnabled, let target = item.target, let action = item.action { _ = target.perform(action) }
    }
    func debugSetPinned(_ pinned: Bool) { isPinned = pinned }
    var debugMenuAutoCancelAfter: TimeInterval?
    func debugShow() { showPanel() }
    var debugPanelVisible: Bool { panel.isVisible }
    func debugContextMenu(on index: Int, event: NSEvent) { showContextMenu(for: index, event: event) }
    var debugPanelWindowNumber: Int { panel.windowNumber }
    var debugPanelCenter: NSPoint { NSPoint(x: panel.frame.midX, y: panel.frame.midY) }

    private func end() {
        showWork?.cancel(); showWork = nil
        watchdog?.invalidate(); watchdog = nil
        thumbnails.cancel()
        panel.dismiss()
        isActive = false
        windows = []; fullList = []; query = ""        // the typed text is forgotten the moment the overlay closes
    }

    /// Belt and braces against a stuck overlay: if the modifier key is physically up, or the overlay
    /// has been open for a very long time, close it, even if the event tap missed something.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                if self.isPinned {
                    if Date().timeIntervalSince(self.startedAt) > 120 { self.cancel() }      // (a menu left open for two minutes)
                } else if !flags.contains(self.requiredModifierFlags()) {
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
