import AppKit
import ScreenCaptureKit

/// Window thumbnails via ScreenCaptureKit. Needs the Screen Recording permission; without it
/// every call quietly does nothing and the switcher shows app icons instead.
@MainActor
final class ThumbnailService {
    private var cache: [CGWindowID: NSImage] = [:]
    private var cachedAt: [CGWindowID: Date] = [:]
    private var currentTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    private let maxCached = 60

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
                    self.store(img, for: id)
                    update(id, img)
                }
            }
        }
    }

    func cancel() { currentTask?.cancel() }

    /// macOS cannot capture a window that is not showing (another desktop, a full-screen app you left), so
    /// the overlay can only show the LAST picture we took while it was visible. To always have one, this takes
    /// pictures of the windows that are visible right now, quietly, at most once per `minInterval` per window.
    /// Pictures live in memory only: nothing is written to disk or sent anywhere.
    func captureInBackground(windowIDs: [CGWindowID], minInterval: TimeInterval = 15) {
        guard hasPermission, backgroundTask == nil else { return }
        let now = Date()
        let due = windowIDs.filter { now.timeIntervalSince(cachedAt[$0] ?? .distantPast) >= minInterval }
        guard !due.isEmpty else { return }
        backgroundTask = Task { [weak self] in
            defer { self?.backgroundTask = nil }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            for id in due {
                guard !Task.isCancelled, let scWindow = byID[id] else { continue }
                guard let cg = await Self.capture(scWindow, maxPixelWidth: 480), let self else { continue }
                self.store(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), for: id)
            }
        }
    }

    private func store(_ image: NSImage, for id: CGWindowID) {
        cache[id] = image
        cachedAt[id] = Date()
        // Keep memory bounded: drop the oldest pictures beyond `maxCached` (usually those of closed windows).
        if cache.count > maxCached {
            for (old, _) in cachedAt.sorted(by: { $0.value < $1.value }).prefix(cache.count - maxCached) {
                cache.removeValue(forKey: old); cachedAt.removeValue(forKey: old)
            }
        }
    }

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
