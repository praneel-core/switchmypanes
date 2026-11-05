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
    private let focus: WindowFocusProvider?
    private let spaces: SpaceProvider
    init(ids: WindowIDProvider, focus: WindowFocusProvider? = SkyLightWindowFocus(), spaces: SpaceProvider = makeSpaceProvider()) {
        finder = AXWindowFinder(ids: ids); self.focus = focus; self.spaces = spaces
    }

    func activate(_ info: WindowInfo) {
        if info.isOnAnotherSpace {
            onOtherSpace(info) { [weak self] window, appEl in self?.raise(window: window, appElement: appEl, pid: info.pid) }
        } else {
            raise(info)               // visible, minimized or hidden: all reachable through Accessibility
        }
    }

    /// Window on another desktop / a full-screen app.
    ///
    /// Accessibility cannot see (or raise) windows on a Space that is not showing, so: switch to the desktop, focus the
    /// window (both via isolated private calls, see `SpaceProvider` / `WindowFocusProvider`), then raise it through
    /// Accessibility once it is reachable. The original public-only order, still used as the fallback, was:
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
        // 1. Switch to the window's desktop (through the Dock, by pressing the user's own "move a space" shortcut).
        //    Asking the APP to come forward is not enough when the app has another window on the desktop you are looking
        //    at: macOS then just focuses that one and never switches.
        let done = Flag()
        spaces.switchToSpace(ofWindow: info.id) { [weak self] switched in
            guard let self else { return }
            // 2. Focus that exact window (also makes its app frontmost and the window the key window).
            let focused = self.focus?.focus(pid: info.pid, windowID: info.id) ?? false
            // 3. Last resort: ask the app itself (enough when the app has no window on this desktop).
            if !switched && !focused {
                AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                NSRunningApplication(processIdentifier: info.pid)?.activate()
            }
            self.raiseWhenReachable(info, appEl: appEl, done: done, perform: perform)
        }
    }

    /// Once the desktop has switched the window is visible to Accessibility: raise / act on it, exactly once.
    private func raiseWhenReachable(_ info: WindowInfo, appEl: AXUIElement, done: Flag,
                                    perform: @escaping (AXUIElement, AXUIElement) -> Void) {
        for delay in [0.05, 0.3, 0.6, 1.0, 1.6, 2.4] {
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

    /// Minimizes a window on the current desktop through Accessibility. Returns false if it cannot be found.
    @discardableResult
    func minimize(_ info: WindowInfo) -> Bool {
        guard info.isOnCurrentSpace,
              let window = finder.find(pid: info.pid, windowID: info.id, frame: info.frame, title: info.title) else { return false }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }
}
