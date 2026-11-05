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
        if info.isOnAnotherSpace {
            onOtherSpace(info) { [weak self] window, appEl in self?.raise(window: window, appElement: appEl, pid: info.pid) }
        } else {
            raise(info)               // visible, minimized or hidden: all reachable through Accessibility
        }
    }

    /// Window on another desktop / a full-screen app.
    ///
    /// Accessibility cannot see (or raise) windows on a Space that is not showing, so the order is:
    /// 1. ask the application to come to the front. With macOS's default setting ("When switching to an
    ///    application, switch to a Space with open windows for the application") this makes macOS
    ///    switch to that app's Space by itself;
    /// 2. once the Space has switched (there is an animation), the window IS visible to Accessibility,
    ///    so retry the exact raise a few times while it settles.
    /// Limits: if the same app also has a window on the CURRENT Space, macOS may just focus that one
    /// instead of switching. A stricter private-API route exists (SkyLight "SLPS" calls); it would be
    /// added in this file if real-world testing shows it is needed.
    private func onOtherSpace(_ info: WindowInfo, perform: @escaping (AXUIElement, AXUIElement) -> Void) {
        let appEl = AX.app(pid: info.pid)
        if let app = NSRunningApplication(processIdentifier: info.pid), app.isHidden { app.unhide() }
        AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: info.pid)?.activate()
        let done = Flag()
        for delay in [0.3, 0.6, 1.0, 1.6, 2.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !done.value,
                      let window = self.finder.find(pid: info.pid, windowID: info.id, frame: info.frame, title: info.title)
                else { return }
                done.value = true            // act exactly once, as soon as the window becomes reachable
                perform(window, appEl)
            }
        }
    }

    private final class Flag { var value = false }

    private func raise(_ info: WindowInfo) {
        // A hidden app (Cmd+H) must be shown first; a minimized window is restored in raise(window:...).
        if let app = NSRunningApplication(processIdentifier: info.pid), app.isHidden { app.unhide() }
        let appEl = AX.app(pid: info.pid)
        AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = finder.find(pid: info.pid, windowID: info.id, frame: info.frame, title: info.title) {
            raise(window: window, appElement: appEl, pid: info.pid)
        } else {
            NSRunningApplication(processIdentifier: info.pid)?.activate()
        }
    }

    private func raise(window: AXUIElement, appElement appEl: AXUIElement, pid: pid_t) {
        // Restore the window if it is minimized.
        if AX.bool(window, kAXMinimizedAttribute) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, window)
        NSRunningApplication(processIdentifier: pid)?.activate()   // belt and braces: the normal AppKit request as well
    }

    /// Closes the window by pressing its close button through Accessibility (so apps behave exactly as if
    /// you had clicked it: "Save changes?" sheets appear, unclosable windows stay). Returns false when the
    /// window cannot be found or has no close button.
    @discardableResult
    func close(_ info: WindowInfo) -> Bool {
        if info.isOnAnotherSpace {
            // Accessibility cannot reach a window on a desktop that is not showing. So: switch to its desktop
            // (as for activation), then press its close button once it is reachable. When the window was a
            // full-screen one, macOS usually returns you to your previous desktop afterwards.
            onOtherSpace(info) { window, _ in
                if let button = AX.element(window, kAXCloseButtonAttribute) {
                    AXUIElementPerformAction(button, kAXPressAction as CFString)
                }
            }
            return true
        }
        guard let window = finder.find(pid: info.pid, windowID: info.id, frame: info.frame, title: info.title),
              let button = AX.element(window, kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }
}
