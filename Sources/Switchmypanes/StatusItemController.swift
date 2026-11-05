import AppKit

/// The menu bar icon and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settings: SettingsStore

    var onPreferences: () -> Void = {}
    var onPermissions: () -> Void = {}
    var onTogglePause: () -> Void = {}
    var keyboardActive: () -> Bool = { false }

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Switchmypanes")
            b.image?.isTemplate = true
            b.toolTip = "Switchmypanes"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(make("Preferences…", #selector(prefs), ","))
        menu.addItem(make("Permissions…", #selector(perms), ""))
        menu.addItem(.separator())
        pauseItem.target = self; pauseItem.action = #selector(pause)
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(make("Quit Switchmypanes", #selector(quit), "q"))
        item.menu = menu
    }

    private func make(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        m.target = self
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        statusLine.title = settings.paused ? "Paused" : (keyboardActive() ? "Shortcuts active" : "Shortcuts not active: check Permissions")
        pauseItem.title = settings.paused ? "Resume Switchmypanes" : "Pause Switchmypanes"
    }

    @objc private func prefs() { onPreferences() }
    @objc private func perms() { onPermissions() }
    @objc private func pause() { onTogglePause() }
    @objc private func quit() { NSApp.terminate(nil) }
}
