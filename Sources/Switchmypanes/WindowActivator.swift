import AppKit

/// Brings a chosen window to the front.
///
/// Recent macOS versions restrict one app activating another, and a background menu bar app is
/// exactly that case. What works reliably with public API: ask the target APPLICATION to become
/// frontmost through Accessibility (`AXFrontmost`), raise the specific WINDOW, and mark it main/focused.
/// If a future macOS breaks this, the fallback to try is the private SkyLight "SLPS" calls (Phase 2,
/// would live in this same file behind the same method).
@MainActor
final class WindowActivator {
    private let finder: AXWindowFinder
    init(ids: WindowIDProvider) { finder = AXWindowFinder(ids: ids) }

    func activate(_ info: WindowInfo) {
        let appEl = AX.app(pid: info.pid)
        let window = finder.find(pid: info.pid, windowID: info.id, frame: info.frame, title: info.title)

        AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window {
            // The window may be minimized (Phase 2 lists those); make sure it is not.
            if AX.bool(window, kAXMinimizedAttribute) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, window)
        }
        // Belt and braces: the normal AppKit request as well.
        NSRunningApplication(processIdentifier: info.pid)?.activate()
    }
}
