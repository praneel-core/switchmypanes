import AppKit
import SwitchmypanesCore

/// Keeps a recent picture of each window you work in, so that windows on OTHER desktops (which macOS cannot
/// capture while hidden) still have a preview in the overlay.
///
/// It does NOT poll. It acts at three moments only:
///  1. you leave a window (immediately, while it is usually still visible);
///  2. you have been in a window for a few seconds (it has settled, so the picture is representative);
///  3. you stay in the same window for a long time (a slow refresh, one window only).
/// It stays out of the way when switched off, paused, the screen is locked, you have been idle, or Low Power
/// Mode is on, and it never captures apps on the exclusion list (see `ThumbnailService.isAllowed`).
@MainActor
final class PreviewKeeper {
    private let thumbnails: ThumbnailService
    private let settings: SettingsStore
    private var watching: CGWindowID?
    private var work: DispatchWorkItem?

    private let settleDelay: TimeInterval = 3
    private let refreshEvery: TimeInterval = 60

    init(thumbnails: ThumbnailService, settings: SettingsStore) { self.thumbnails = thumbnails; self.settings = settings }

    /// Call when the front window changes.
    func frontWindowChanged(left: WindowInfo?, arrived: WindowInfo) {
        work?.cancel()
        if let left, allowed(idleLimited: false) { thumbnails.captureInBackground(windowIDs: [left.id], minInterval: 2) }
        watching = arrived.id
        schedule(after: settleDelay, id: arrived.id)
    }

    func stop() { work?.cancel(); work = nil; watching = nil }

    private func schedule(after delay: TimeInterval, id: CGWindowID) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.watching == id else { return }
            if self.allowed(idleLimited: true) { self.thumbnails.captureInBackground(windowIDs: [id], minInterval: 10) }
            self.schedule(after: self.refreshEvery, id: id)      // slow refresh while you stay in this window
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func allowed(idleLimited: Bool) -> Bool {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        return PreviewPolicy.allowsAutomaticCapture(enabled: settings.keepPreviewsFresh, paused: settings.paused,
                                                    screenLocked: locked, idleSeconds: idleLimited ? idle : 0,
                                                    lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
