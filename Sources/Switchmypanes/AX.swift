import ApplicationServices
import AppKit

/// Thin, forgiving wrappers around the Accessibility API. Every call can fail (apps may not
/// support it, may be busy, or may have closed the window), so everything returns optionals.
enum AX {
    static func app(pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        // A frozen app must not freeze us: give up on any single call after 0.4 s.
        AXUIElementSetMessagingTimeout(el, 0.4)
        return el
    }

    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &out) == .success ? out : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? { value(el, attr) as? String }
    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? { (value(el, attr) as? NSNumber)?.boolValue }
    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
    }

    static func position(_ w: AXUIElement) -> CGPoint? {
        guard let v = value(w, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ w: AXUIElement) -> CGSize? {
        guard let v = value(w, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func frame(_ w: AXUIElement) -> CGRect? {
        guard let p = position(w), let s = size(w) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult static func setPosition(_ w: AXUIElement, _ p: CGPoint) -> Bool {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) == .success
    }

    @discardableResult static func setSize(_ w: AXUIElement, _ s: CGSize) -> Bool {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) == .success
    }

    static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success && settable.boolValue
    }
}
