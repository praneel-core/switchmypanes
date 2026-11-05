import AppKit
import SwiftUI
import SwitchmypanesCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, KeyboardMonitorDelegate {
    private let settings = SettingsStore.shared
    private let ids = PrivateAXWindowIDProvider()
    private lazy var inventory = WindowInventory(ids: ids)
    private let thumbnails = ThumbnailService()
    private lazy var activator = WindowActivator(ids: ids)
    private lazy var switcher = SwitcherController(inventory: inventory, thumbnails: thumbnails, activator: activator)
    private lazy var snapper = SnapController(settings: settings, ids: ids)
    private lazy var dragSnapper = DragSnapController(settings: settings, ids: ids, snapper: snapper)
    private let monitor = KeyboardMonitor()
    private lazy var statusItem = StatusItemController(settings: settings)
    private lazy var onboarding = OnboardingWindowController(keyboardActive: { [weak self] in self?.monitor.isRunning ?? false })
    private var preferencesWindow: NSWindow?
    private var retryTimer: Timer?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        statusItem.onPreferences = { [weak self] in self?.showPreferences() }
        statusItem.onPermissions = { [weak self] in self?.onboarding.show() }
        statusItem.onTogglePause = { [weak self] in self?.setPaused(!(self?.settings.paused ?? false)) }
        statusItem.keyboardActive = { [weak self] in self?.monitor.isRunning ?? false }
        _ = statusItem

        monitor.delegate = self
        monitor.configProvider = { [settings] in settings.config }
        inventory.startTracking()
        dragSnapper.start()

        if !monitor.start() || !PermissionManager.current().shortcutsReady {
            onboarding.show()
        }
        // Keep trying: the tap starts working as soon as the permissions are granted, without a restart.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.monitor.start() }
        }
    }

    /// Never leave a tap or overlay behind.
    func applicationWillTerminate(_ notification: Notification) {
        switcher.cancel()
        monitor.stop()
        dragSnapper.stop()
        inventory.stopTracking()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: pause / preferences / URL scheme

    private func setPaused(_ paused: Bool) {
        settings.paused = paused
        monitor.isPaused = paused
        if paused { switcher.cancel(); dragSnapper.reset() }
    }

    private func showPreferences() {
        if preferencesWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView(settings: settings)))
            w.title = "Switchmypanes Preferences"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            preferencesWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.center()
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    /// switchmypanes://preferences | permissions | pause | resume
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let host = URL(string: s)?.host else { return }
        switch host {
        case "preferences": showPreferences()
        case "permissions": onboarding.show()
        case "pause": setPaused(true)
        case "resume": setPaused(false)
        default: break
        }
    }

    // MARK: KeyboardMonitorDelegate

    var switcherActive: Bool { switcher.isActive }

    func keyboardMonitor(_ monitor: KeyboardMonitor, perform action: KeyAction) {
        switch action {
        case .switcherOpen(let reverse): switcher.begin(reverse: reverse)
        case .switcherNext: switcher.next()
        case .switcherPrevious: switcher.previous()
        case .switcherMove(let key): switcher.move(key)
        case .switcherCancel: switcher.cancel()
        case .switcherCommit: switcher.commit()
        case .snap(let key, let moveToDisplay):
            // Run after the tap callback returns, so a slow app can never make macOS disable our tap.
            DispatchQueue.main.async { [snapper] in snapper.handle(key, moveToDisplay: moveToDisplay) }
        case .passThrough, .swallow: break
        }
    }
}
