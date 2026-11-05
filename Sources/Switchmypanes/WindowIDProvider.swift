import ApplicationServices
import CoreGraphics
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// PRIVATE API, ISOLATED.
// The public Accessibility API cannot tell you the CoreGraphics window number of an AXUIElement,
// which we need to match "the window in the on-screen list" with "the window we can raise".
// Apple's own tools use the undocumented function `_AXUIElementGetWindow`. We look it up at runtime
// (dlsym), so if a macOS update removes it the lookup fails, `windowID` returns nil, and callers fall
// back to matching windows by frame and title. It can never crash the app.
// ─────────────────────────────────────────────────────────────────────────────
protocol WindowIDProvider: Sendable {
    func windowID(of element: AXUIElement) -> CGWindowID?
}

struct PrivateAXWindowIDProvider: WindowIDProvider {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private let fn: GetWindowFn? = {
        // RTLD_DEFAULT is (void *)-2
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    var isAvailable: Bool { fn != nil }

    func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn else { return nil }
        var id: CGWindowID = 0
        return fn(element, &id) == .success && id != 0 ? id : nil
    }
}

/// Finds the Accessibility element for a window we know from the CoreGraphics list.
struct AXWindowFinder {
    let ids: WindowIDProvider

    func find(pid: pid_t, windowID: CGWindowID, frame: CGRect, title: String) -> AXUIElement? {
        let windows = AX.windows(of: AX.app(pid: pid))
        if let hit = windows.first(where: { ids.windowID(of: $0) == windowID }) { return hit }
        // Fallback (private lookup unavailable): same frame (±2 pt), preferring a matching title.
        let sameFrame = windows.filter {
            guard let f = AX.frame($0) else { return false }
            return abs(f.minX - frame.minX) < 2 && abs(f.minY - frame.minY) < 2 &&
                   abs(f.width - frame.width) < 2 && abs(f.height - frame.height) < 2
        }
        return sameFrame.first(where: { AX.string($0, kAXTitleAttribute) == title }) ?? sameFrame.first
    }
}
