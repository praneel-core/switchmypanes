import AppKit
import ScreenCaptureKit

/// Window thumbnails via ScreenCaptureKit. Needs the Screen Recording permission; without it
/// every call quietly does nothing and the switcher shows app icons instead.
@MainActor
final class ThumbnailService {
    private var cache: [CGWindowID: NSImage] = [:]
    private var currentTask: Task<Void, Never>?

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// The most recent thumbnail we have (may be from an earlier time the switcher opened).
    func cached(_ id: CGWindowID) -> NSImage? { cache[id] }

    /// Capture fresh thumbnails for these windows; `update` is called on the main thread as each one arrives.
    func refresh(windowIDs: [CGWindowID], maxPixelWidth: Int = 480,
                 update: @escaping @MainActor (CGWindowID, NSImage) -> Void) {
        currentTask?.cancel()
        guard hasPermission else { return }
        currentTask = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for id in windowIDs {
                    guard let scWindow = byID[id] else { continue }
                    group.addTask { (id, await Self.capture(scWindow, maxPixelWidth: maxPixelWidth)) }
                }
                for await (id, cg) in group {
                    guard !Task.isCancelled, let cg, let self else { continue }
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.cache[id] = img
                    update(id, img)
                }
            }
        }
    }

    func cancel() { currentTask?.cancel() }

    private nonisolated static func capture(_ window: SCWindow, maxPixelWidth: Int) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        let aspect = window.frame.height / max(window.frame.width, 1)
        cfg.width = min(maxPixelWidth, Int(window.frame.width * 2))
        cfg.height = max(1, Int(CGFloat(cfg.width) * aspect))
        cfg.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}
