import AppKit
import SwitchmypanesCore

/// A menu item that runs a closure (no selectors to wire up).
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

/// The menu bar menu: status, quick toggles, pause, the shortcut cheat sheet, preferences, permissions, quit.
/// Kept separate from the status item itself so it can be built and checked without touching the real menu bar.
@MainActor
final class MenuBarMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let settings: SettingsStore
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var toggles: [(item: NSMenuItem, isOn: () -> Bool)] = []
    private let pauseRoot = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private var resumeItem: ActionMenuItem!

    var keyboardActive: () -> Bool = { false }
    var onPause: (TimeInterval?) -> Void = { _ in }
    var onResume: () -> Void = {}
    var onShortcuts: () -> Void = {}
    var onPreferences: () -> Void = {}
    var onPermissions: () -> Void = {}

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "Switchmypanes", action: nil, keyEquivalent: "")
        title.isEnabled = false
        title.attributedTitle = NSAttributedString(string: "Switchmypanes", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(title)
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        func toggle(_ name: String, _ isOn: @escaping () -> Bool, _ flip: @escaping () -> Void) {
            let item = ActionMenuItem(name, handler: flip)
            toggles.append((item, isOn))
            menu.addItem(item)
        }
        toggle("Window switcher", { settings.switcherEnabled }) { settings.switcherEnabled.toggle() }
        toggle("Snapping", { settings.snapEnabled }) { settings.snapEnabled.toggle() }
        toggle("Snap Layouts", { settings.layoutsEnabled }) { settings.layoutsEnabled.toggle() }
        toggle("Snap animations", { settings.snapAnimationsEnabled }) { settings.snapAnimationsEnabled.toggle() }
        menu.addItem(.separator())

        let pauseMenu = NSMenu()
        pauseMenu.autoenablesItems = false
        pauseMenu.addItem(ActionMenuItem("For 1 hour") { [weak self] in self?.onPause(3600) })
        pauseMenu.addItem(ActionMenuItem("Until I resume") { [weak self] in self?.onPause(nil) })
        pauseRoot.submenu = pauseMenu
        menu.addItem(pauseRoot)
        resumeItem = ActionMenuItem("Resume Switchmypanes") { [weak self] in self?.onResume() }
        menu.addItem(resumeItem)
        menu.addItem(.separator())

        menu.addItem(ActionMenuItem("Shortcuts…") { [weak self] in self?.onShortcuts() })
        menu.addItem(ActionMenuItem("Preferences…", key: ",") { [weak self] in self?.onPreferences() })
        menu.addItem(ActionMenuItem("Permissions…") { [weak self] in self?.onPermissions() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Quit Switchmypanes", key: "q") { NSApp.terminate(nil) })
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    /// Brings every item up to date (checkmarks, the status line, Pause / Resume).
    func refresh() {
        for (item, isOn) in toggles { item.state = isOn() ? .on : .off }
        let paused = settings.paused
        if paused {
            let until = settings.pausedUntil.map { d -> String in
                let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return " until \(f.string(from: d))"
            } ?? ""
            statusLine.title = "Paused\(until)"
        } else {
            statusLine.title = keyboardActive() ? "Shortcuts active" : "Shortcuts not active: check Permissions"
        }
        pauseRoot.isHidden = paused
        resumeItem.isHidden = !paused
    }

    // test seam (`--selftest-menu-bar`)
    var debugTitles: [String] { menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title) }
    func debugItem(_ title: String) -> NSMenuItem? {
        for item in menu.items { if item.title == title { return item }; if let hit = item.submenu?.items.first(where: { $0.title == title }) { return hit } }
        return nil
    }
    func debugClick(_ title: String) { if let item = debugItem(title), let t = item.target, let a = item.action { _ = t.perform(a) } }
}
