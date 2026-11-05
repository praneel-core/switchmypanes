import AppKit

/// The menu bar icon; its menu is `MenuBarMenu`.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menuBar: MenuBarMenu

    init(settings: SettingsStore) {
        menuBar = MenuBarMenu(settings: settings)
        super.init()
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Switchmypanes")
            b.image?.isTemplate = true
            b.toolTip = "Switchmypanes"
        }
        item.menu = menuBar.menu
    }
}
