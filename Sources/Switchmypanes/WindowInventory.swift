import AppKit
import SwitchmypanesCore

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String          // window title, or the app name when macOS won't tell us
    let frame: CGRect          // top-left coordinates
    let icon: NSImage?
}

/// Knows which windows exist and in which most-recently-used order.
@MainActor
final class WindowInventory {
    private var mru = MRUList<CGWindowID>()
    private let ids: WindowIDProvider
    private var titleCache: [CGWindowID: String] = [:]
    private var titleRefreshInFlight = false
    private var timer: Timer?

    init(ids: WindowIDProvider) { self.ids = ids }

    /// Start tracking which window is in front (so MRU order is right even for windows
    /// that were never opened through our switcher).
    func startTracking() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.noteFrontmost() } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteFrontmost() }
        }
        noteFrontmost()
    }

    func stopTracking() { timer?.invalidate(); timer = nil }

    /// Move the window that is currently in front to the top of the MRU list.
    func noteFrontmost() {
        let raw = rawWindows()
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let top = raw.first(where: { $0.pid == front }) else { return }
        mru.reconcile(live: raw.map(\.id))
        mru.touch(top.id)
    }

    func markUsed(_ id: CGWindowID) { mru.touch(id) }

    /// Windows of the current Space in MRU order.
    func snapshot() -> [WindowInfo] {
        let raw = rawWindows()
        let order = mru.ordered(live: raw.map(\.id))
        let byID = Dictionary(raw.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let result = order.compactMap { byID[$0] }
        if result.contains(where: { $0.title == $0.appName }) { refreshTitlesInBackground(pids: Set(result.map(\.pid))) }
        return result
    }

    // MARK: Reading the window list

    private func rawWindows() -> [WindowInfo] {
        // Public API: windows on the current Space, front to back.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = getpid()
        var out: [WindowInfo] = []
        var apps: [pid_t: NSRunningApplication?] = [:]
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,              // normal windows only
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let num = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  frame.width >= 80, frame.height >= 50 else { continue }
            if apps[pid] == nil { apps[pid] = NSRunningApplication(processIdentifier: pid) }
            guard let app = apps[pid] ?? nil, app.activationPolicy == .regular else { continue }
            let appName = app.localizedName ?? "App"
            // kCGWindowName is only filled in when Screen Recording is allowed; otherwise use the AX title cache.
            var title = (w[kCGWindowName as String] as? String) ?? ""
            if title.isEmpty { title = titleCache[num] ?? "" }
            out.append(WindowInfo(id: num, pid: pid, appName: appName, title: title.isEmpty ? appName : title,
                                  frame: frame, icon: app.icon))
        }
        return out
    }

    /// Window titles via Accessibility, fetched off the main thread because a slow app can take a while to answer.
    private func refreshTitlesInBackground(pids: Set<pid_t>) {
        guard !titleRefreshInFlight, AXIsProcessTrusted() else { return }
        titleRefreshInFlight = true
        let ids = self.ids
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [CGWindowID: String] = [:]
            for pid in pids {
                for w in AX.windows(of: AX.app(pid: pid)) {
                    if let id = ids.windowID(of: w), let t = AX.string(w, kAXTitleAttribute), !t.isEmpty { found[id] = t }
                }
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.titleCache.merge(found) { _, new in new }
                    self.titleRefreshInFlight = false
                }
            }
        }
    }
}
