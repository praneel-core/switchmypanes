import AppKit
import SwitchmypanesCore

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String          // window title, or the app name when macOS won't tell us
    let frame: CGRect          // top-left coordinates
    let icon: NSImage?
    var placement: WindowPlacement = .currentSpace
    var spaceLabel: String? = nil       // "Desktop 2" / "Full screen" for windows on other Spaces
    var isOnCurrentSpace: Bool { placement == .currentSpace }
}

/// Knows which windows exist and in which most-recently-used order.
@MainActor
final class WindowInventory {
    private var mru = MRUList<CGWindowID>()
    private let ids: WindowIDProvider
    private let spaces: SpaceProvider
    private let options: () -> SpaceFilterOptions
    private var titleCache: [CGWindowID: String] = [:]
    private var titleRefreshInFlight = false
    private var timer: Timer?

    init(ids: WindowIDProvider, spaces: SpaceProvider, options: @escaping () -> SpaceFilterOptions) {
        self.ids = ids; self.spaces = spaces; self.options = options
    }

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

    /// Windows in MRU order. By default only the current Space (what snapping features need, since
    /// Accessibility cannot move windows on other Spaces); the switcher passes `true` to include
    /// other desktops / full-screen apps according to the user's settings.
    func snapshot(includeOtherSpaces: Bool = false) -> [WindowInfo] {
        let o = options()
        let raw = rawWindows(includeOtherSpaces: includeOtherSpaces && (o.includeOtherDesktops || o.includeFullScreen), filter: o)
        let order = mru.ordered(live: raw.map(\.id))
        let byID = Dictionary(raw.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let result = order.compactMap { byID[$0] }
        if result.contains(where: { $0.title == $0.appName }) { refreshTitlesInBackground(pids: Set(result.map(\.pid))) }
        return result
    }

    // MARK: Reading the window list

    private func rawWindows(includeOtherSpaces: Bool = false, filter: SpaceFilterOptions = SpaceFilterOptions()) -> [WindowInfo] {
        // With Spaces information we can list ALL windows and decide per window; without it (or when the
        // user wants the current desktop only) we use the public on-screen list: current Space, front to back.
        let snap = includeOtherSpaces ? spaces.snapshot() : nil
        let listOptions: CGWindowListOption = snap == nil ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll]
        guard let list = CGWindowListCopyWindowInfo(listOptions, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let canReadTitles = CGPreflightScreenCaptureAccess()
        let me = getpid()
        var out: [WindowInfo] = []
        var apps: [pid_t: NSRunningApplication?] = [:]
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,              // normal windows only
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let num = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  frame.width >= 80, frame.height >= 50 else { continue }
            if apps[pid] == nil { apps[pid] = NSRunningApplication(processIdentifier: pid) }
            guard let app = apps[pid] ?? nil, app.activationPolicy == .regular else { continue }
            let appName = app.localizedName ?? "App"
            // kCGWindowName is only filled in when Screen Recording is allowed; otherwise use the AX title cache.
            var title = (w[kCGWindowName as String] as? String) ?? ""
            if title.isEmpty { title = titleCache[num] ?? "" }

            var placement = WindowPlacement.currentSpace
            var label: String?
            let onScreen = snap == nil ? true : ((w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
            if onScreen {
                guard (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { continue }
            } else if let snap {
                // Not drawn right now: another desktop, a full-screen app, a minimized window, or a helper window.
                let windowSpaces = spaces.spaces(ofWindow: num)
                placement = SpaceClassifier.classify(isOnScreen: false, windowSpaces: windowSpaces,
                                                     activeSpaces: snap.activeSpaces, kinds: snap.kinds)
                guard SpaceClassifier.isIncluded(placement, options: filter) else { continue }
                // Off-Space windows cannot be double-checked through Accessibility, so drop untitled ones
                // (almost always internal helper windows) whenever we are allowed to read titles.
                if canReadTitles && ((w[kCGWindowName as String] as? String) ?? "").isEmpty { continue }
                label = windowSpaces.first.flatMap { snap.labels[$0] }
            }
            out.append(WindowInfo(id: num, pid: pid, appName: appName, title: title.isEmpty ? appName : title,
                                  frame: frame, icon: app.icon, placement: placement, spaceLabel: label))
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
