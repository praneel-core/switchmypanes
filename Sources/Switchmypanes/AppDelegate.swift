import AppKit
import Combine
import SwiftUI
import SwitchmypanesCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, KeyboardMonitorDelegate {
    private let settings = SettingsStore.shared
    private let ids = PrivateAXWindowIDProvider()
    private lazy var inventory = WindowInventory(ids: ids, spaces: makeSpaceProvider(),
                                                 options: { [settings] in settings.spaceFilter },
                                                 exclusions: { [settings] in settings.appExclusions })
    private let thumbnails = ThumbnailService()
    private lazy var previewKeeper = PreviewKeeper(thumbnails: thumbnails, settings: settings)
    private lazy var activator = WindowActivator(ids: ids)
    private lazy var switcher = SwitcherController(inventory: inventory, thumbnails: thumbnails, activator: activator)
    private lazy var snapper = SnapController(settings: settings, ids: ids)
    private lazy var picker = LayoutPickerController(inventory: inventory, thumbnails: thumbnails, activator: activator,
                                                      snapper: snapper, settings: settings, ids: ids)
    private lazy var assist = SnapAssistController(inventory: inventory, thumbnails: thumbnails, activator: activator,
                                                    snapper: snapper, settings: settings, ids: ids)
    private lazy var linked = LinkedGroupController(settings: settings)
    private lazy var dragSnapper = DragSnapController(settings: settings, ids: ids, snapper: snapper)
    private let monitor = KeyboardMonitor()
    private lazy var statusItem = StatusItemController(settings: settings)
    private lazy var onboarding = OnboardingWindowController(keyboardActive: { [weak self] in self?.monitor.isRunning ?? false })
    private var preferencesWindow: NSWindow?
    private var retryTimer: Timer?
    private var styleObserver: AnyCancellable?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        statusItem.onPreferences = { [weak self] in self?.showPreferences() }
        statusItem.onPermissions = { [weak self] in self?.onboarding.show() }
        statusItem.onTogglePause = { [weak self] in self?.setPaused(!(self?.settings.paused ?? false)) }
        statusItem.keyboardActive = { [weak self] in self?.monitor.isRunning ?? false }
        _ = statusItem

        // The overlay look follows Preferences (panels pick it up the next time they appear).
        styleObserver = settings.$overlayStyle.sink { OverlayTheme.style = OverlayTheme.Style(rawValue: $0) ?? .glass }
        monitor.delegate = self
        monitor.isSuspended = { [settings] in settings.isRecordingShortcut }
        switcher.requiredModifierFlags = { [settings] in settings.switcherModifier.cgFlags }
        monitor.configProvider = { [settings] in settings.config }
        thumbnails.isAllowed = { [weak self] id in
            guard let self else { return true }
            return !PreviewPolicy.isExcluded(bundleID: self.inventory.bundleID(ofWindow: id), excluded: self.settings.previewExcludedApps)
        }
        inventory.onFrontWindowChanged = { [weak self] left, arrived in
            guard let self, self.settings.switcherEnabled, !self.switcher.isActive, !self.picker.isActive else { return }
            self.previewKeeper.frontWindowChanged(left: left, arrived: arrived)
        }
        // A divider line must never float over a window that is not in its group: re-check when the front window changes.
        let previous = inventory.onFrontWindowChanged
        inventory.onFrontWindowChanged = { [weak self] left, arrived in
            previous?(left, arrived)
            self?.linked.windowsChanged()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.linked.windowsChanged() }
        }
        inventory.startTracking()
        dragSnapper.start()
        picker.onGroupPlaced = { [weak self] placed, gap, bounds in self?.linked.register(placed, gap: gap, bounds: bounds) }
        snapper.onWillMoveWindow = { [weak self] pid, id in self?.linked.unlink(pid: pid, windowID: id) }
        snapper.onBeforeSnap = { [weak self] in self?.assist.cancel() }
        snapper.onSnapped = { [weak self] zone, display, pid, id, frame, element in
            self?.assist.offer(afterSnapTo: zone, on: display, pid: pid, windowID: id, snappedFrame: frame, element: element)
        }
        assist.onPairPlaced = { [weak self] placed, gap, bounds in self?.linked.register(placed, gap: gap, bounds: bounds) }

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
        picker.cancel()
        assist.cancel()
        monitor.stop()
        dragSnapper.stop()
        previewKeeper.stop()
        linked.removeAll()
        snapper.motion.cancel()
        inventory.stopTracking()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: pause / preferences / URL scheme

    private func setPaused(_ paused: Bool) {
        settings.paused = paused
        monitor.isPaused = paused
        if paused { switcher.cancel(); picker.cancel(); assist.cancel(); dragSnapper.reset(); linked.removeAll(); snapper.motion.cancel() }
    }

    private func showPreferences() {
        if preferencesWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView(settings: settings)))
            w.title = "Switchmypanes Preferences"
            w.styleMask = [.titled, .closable, .resizable]      // scrolls: there are many settings
            w.isReleasedWhenClosed = false
            let room = (NSScreen.main?.visibleFrame.height ?? 800) - 80
            w.setContentSize(NSSize(width: 620, height: min(580, max(440, room))))
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
    var pickerActive: Bool { picker.isActive || assist.isActive }
    var pickerAssistMode: Bool { assist.isActive }

    func keyboardMonitor(_ monitor: KeyboardMonitor, perform action: KeyAction) {
        switch action {
        case .switcherOpen(let reverse): switcher.begin(reverse: reverse)
        case .switcherNext: switcher.next()
        case .switcherPrevious: switcher.previous()
        case .switcherMove(let key): switcher.move(key)
        case .switcherCancel: switcher.cancel()
        case .switcherClose: switcher.closeSelected()
        case .switcherCommit: switcher.commit()
        case .snap(let key, let moveToDisplay):
            // Run after the tap callback returns, so a slow app can never make macOS disable our tap.
            DispatchQueue.main.async { [snapper] in snapper.handle(key, moveToDisplay: moveToDisplay) }
        case .layoutsOpen: picker.begin()
        case .pickerMove(let key): if assist.isActive { assist.move(key) } else { picker.move(key) }
        case .pickerChoose(let n): picker.choose(number: n)
        case .pickerConfirm: if assist.isActive { assist.confirm() } else { picker.confirm() }
        case .pickerSkip: picker.skip()
        case .pickerCancel: assist.cancel(); picker.cancel()
        case .pickerDismiss: break    // resolved inside the keyboard monitor
        case .passThrough, .swallow: break
        }
    }
}
