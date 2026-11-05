import AppKit
import CoreGraphics
import SwitchmypanesCore

@MainActor
protocol KeyboardMonitorDelegate: AnyObject {
    var switcherActive: Bool { get }
    var pickerActive: Bool { get }
    var pickerAssistMode: Bool { get }
    func keyboardMonitor(_ monitor: KeyboardMonitor, perform action: KeyAction)
}

/// The keyboard event tap.
///
/// WHAT IT READS: for every key press it looks at two numbers only: the key code and which modifier
/// keys are down, and asks `KeyClassifier` whether that is one of OUR shortcuts. If not, the event is
/// passed on untouched. It never looks at characters, never stores or logs key presses, and does
/// nothing at all with text typed into any app.
/// WHAT IT SWALLOWS: only Option+Tab (and while the switcher is open: Tab, arrows, Esc) and the snap
/// shortcuts (Control+Option+Arrows by default). Nothing else.
@MainActor
final class KeyboardMonitor {
    weak var delegate: KeyboardMonitorDelegate?
    var isPaused = false
    var configProvider: () -> ShortcutConfig = { ShortcutConfig() }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedKeyUps = Set<Int64>()

    var isRunning: Bool { tap != nil }

    /// Returns false when macOS refuses (permissions missing). Safe to call again later.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // The tap is installed on the main run loop, so we are on the main thread here.
            return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t; source = src
        return true
    }

    func stop() {
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        tap = nil; source = nil; swallowedKeyUps.removeAll()
    }

    private static func modifiers(_ f: CGEventFlags) -> ShortcutModifiers {
        var m: ShortcutModifiers = []
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskCommand) { m.insert(.command) }
        if f.contains(.maskShift) { m.insert(.shift) }
        return m
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard let delegate else { return pass }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it is ever too slow. Turn it back on, and never leave the switcher stuck open.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if delegate.switcherActive { delegate.keyboardMonitor(self, perform: .switcherCancel) }
            if delegate.pickerActive { delegate.keyboardMonitor(self, perform: .pickerCancel) }
            swallowedKeyUps.removeAll()
            return pass

        case .keyDown:
            if isPaused { return pass }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            func classify() -> KeyAction {
                KeyClassifier.classifyKeyDown(keyCode: code, flags: Self.modifiers(event.flags), isRepeat: isRepeat,
                                              switcherActive: delegate.switcherActive, pickerActive: delegate.pickerActive,
                                              assistMode: delegate.pickerAssistMode, config: configProvider())
            }
            var action = classify()
            if action == .pickerDismiss {            // Snap Assist: close it, then handle the key as if it had never been open
                delegate.keyboardMonitor(self, perform: .pickerCancel)
                action = classify()
            }
            switch action {
            case .passThrough:
                return pass
            case .switcherCommit:           // modifier no longer held: finish, and let this key through
                delegate.keyboardMonitor(self, perform: action)
                return pass
            case .swallow:
                swallowedKeyUps.insert(code)
                return nil
            default:
                swallowedKeyUps.insert(code)
                delegate.keyboardMonitor(self, perform: action)
                return nil
            }

        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            return swallowedKeyUps.remove(code) != nil ? nil : pass

        case .flagsChanged:
            if isPaused { return pass }
            let action = KeyClassifier.classifyFlagsChanged(flags: Self.modifiers(event.flags),
                                                            switcherActive: delegate.switcherActive, config: configProvider())
            if action != .passThrough { delegate.keyboardMonitor(self, perform: action) }
            return pass

        default:
            return pass
        }
    }
}
