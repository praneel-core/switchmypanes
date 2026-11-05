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
    /// Accessibility can act on it directly (raise, close): visible windows and minimized / hidden ones.
    /// Windows on other desktops need a desktop switch first.
    var isAccessible: Bool { placement == .currentSpace || placement == .hiddenOrMinimized }
    var isOnAnotherSpace: Bool {
        switch placement { case .otherSpace, .orderedOutElsewhere: return true; default: return false }
    }
}

/// Knows which windows exist and in which most-recently-used order.
@MainActor
final class WindowInventory {
    private var mru = MRUList<CGWindowID>()
    private let ids: WindowIDProvider
    private let spaces: SpaceProvider
    private let options: () -> SpaceFilterOptions
    private var titleCache: [CGWindowID: String] = [:]
    // Which windows Accessibility knows, per app. Used to hide helper windows (for example Chrome's full-screen
    // toolbar strip): they are drawn on screen but are not real windows, and clicking them does nothing.
    private var axKnownIDs: [pid_t: Set<CGWindowID>] = [:]
    private var axKnownAt: [pid_t: Date] = [:]
    private var axRefreshPIDs: Set<pid_t> = []
    private var titleRefreshInFlight = false
    private var timer: Timer?
    private var tick = 0
    /// The front window changed: (the window you just left, if it is still visible; the window you arrived in).
    var onFrontWindowChanged: ((WindowInfo?, WindowInfo) -> Void)?
    private var lastFrontID: CGWindowID?
    private var bundleIDs: [CGWindowID: String] = [:]
    func bundleID(ofWindow id: CGWindowID) -> String? { bundleIDs[id] }

    // Minimized / hidden windows look identical to macOS's window list, so Accessibility tells them apart.
    // That can be slow for a sluggish app, so it runs in the background and the result is cached here.
    private struct HiddenLabel { let text: String; let when: Date }     // text "" = "not a real minimized window"
    private var hiddenLabels: [CGWindowID: HiddenLabel] = [:]
    private var hiddenRefreshInFlight = false
    private var unlabeledCandidates: [WindowInfo] = []
    private var seenHiddenIDs: Set<CGWindowID> = []      // every not-drawn window seen by the latest scan
    private lazy var finder = AXWindowFinder(ids: ids)

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
            MainActor.assumeIsolated {
                guard let self else { return }
                self.noteFrontmost()
                self.tick += 1
                if self.tick % 2 == 0 { self.refreshHiddenLabelsInBackground() }   // about once a second
            }
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
        if top.id != lastFrontID {
            let left = raw.first { $0.id == lastFrontID }      // nil if it is no longer visible (e.g. you changed desktop)
            lastFrontID = top.id
            onFrontWindowChanged?(left, top)
        }
    }

    func markUsed(_ id: CGWindowID) { mru.touch(id) }

    /// Windows in MRU order. By default only the current Space (what snapping features need, since
    /// Accessibility cannot move windows on other Spaces); the switcher passes `true` to include
    /// other desktops / full-screen apps according to the user's settings.
    func snapshot(includeOtherSpaces: Bool = false) -> [WindowInfo] {
        let o = options()
        let raw = rawWindows(includeOtherSpaces: includeOtherSpaces && o.needsFullWindowList, filter: o)
        let order = mru.ordered(live: raw.map(\.id))
        let byID = Dictionary(raw.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let result = order.compactMap { byID[$0] }
        var pids = Set<pid_t>()
        if result.contains(where: { $0.title == $0.appName }) { pids.formUnion(result.map(\.pid)) }
        pids.formUnion(axRefreshPIDs); axRefreshPIDs.removeAll()
        if !pids.isEmpty { refreshTitlesInBackground(pids: pids) }
        return result
    }

    // MARK: Reading the window list

    private func rawWindows(includeOtherSpaces: Bool = false, filter: SpaceFilterOptions = SpaceFilterOptions()) -> [WindowInfo] {
        unlabeledCandidates.removeAll()
        seenHiddenIDs.removeAll()
        if bundleIDs.count > 1500 { bundleIDs.removeAll() }   // bound memory; refilled on the next scan
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

            if let b = app.bundleIdentifier { bundleIDs[num] = b }
            var placement = WindowPlacement.currentSpace
            var label: String?
            let onScreen = snap == nil ? true : ((w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
            if onScreen {
                guard (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { continue }
                // An untitled window that the app's Accessibility list does not contain is a helper, not a real
                // window. (Only trusted when that list is non-empty, i.e. the app supports Accessibility at all.)
                if title.isEmpty, let known = axKnownIDs[pid], !known.isEmpty, !known.contains(num) {
                    if Date().timeIntervalSince(axKnownAt[pid] ?? .distantPast) > 1 { axRefreshPIDs.insert(pid) }   // maybe brand new: re-check
                    continue
                }
            } else if let snap {
                // Not drawn right now: another desktop, a full-screen app, a minimized window, or a helper window.
                let windowSpaces = spaces.spaces(ofWindow: num)
                placement = SpaceClassifier.classify(isOnScreen: false, windowSpaces: windowSpaces,
                                                     activeSpaces: snap.activeSpaces, kinds: snap.kinds,
                                                     isOrderedIn: spaces.isOrderedIn(window: num))
                guard SpaceClassifier.isIncluded(placement, options: filter) else { continue }
                let candidate = WindowInfo(id: num, pid: pid, appName: appName, title: title.isEmpty ? appName : title,
                                           frame: frame, icon: app.icon, placement: placement, spaceLabel: nil)
                if placement == .orderedOutElsewhere {
                    // On another desktop and not showing: usually a window the app "closed" to the background
                    // (Claude, Slack...), which must not be listed. A genuinely minimized / hidden window is
                    // only listed if Accessibility confirmed it while its desktop was visible (remembered here).
                    seenHiddenIDs.insert(num)
                    guard let known = hiddenLabels[num], !known.text.isEmpty else { continue }
                    label = known.text
                } else if placement == .hiddenOrMinimized {
                    seenHiddenIDs.insert(num)
                    // Only windows Accessibility confirmed as minimized (or whose app is hidden) are listed.
                    if let known = hiddenLabels[num], !known.text.isEmpty { label = known.text }
                    else { unlabeledCandidates.append(candidate); continue }
                } else {
                    // Other-desktop windows cannot be double-checked through Accessibility, so drop untitled ones
                    // (almost always internal helper windows) whenever we are allowed to read titles.
                    if canReadTitles && ((w[kCGWindowName as String] as? String) ?? "").isEmpty { continue }
                    label = windowSpaces.first.flatMap { snap.labels[$0] }
                }
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
            var known: [pid_t: Set<CGWindowID>] = [:]
            for pid in pids {
                var set = Set<CGWindowID>()
                for w in AX.windows(of: AX.app(pid: pid)) {
                    guard let id = ids.windowID(of: w) else { continue }
                    set.insert(id)
                    if let t = AX.string(w, kAXTitleAttribute), !t.isEmpty { found[id] = t }
                }
                known[pid] = set
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.titleCache.merge(found) { _, new in new }
                    let now = Date()
                    for (pid, set) in known { self.axKnownIDs[pid] = set; self.axKnownAt[pid] = now }
                    self.titleRefreshInFlight = false
                }
            }
        }
    }

    /// Decide, off the main thread, which "not drawn" windows are really minimized (or belong to a hidden app).
    private func refreshHiddenLabelsInBackground() {
        let o = options()
        guard o.includeMinimized, !hiddenRefreshInFlight, AXIsProcessTrusted() else { return }
        _ = rawWindows(includeOtherSpaces: true, filter: SpaceFilterOptions())    // fills unlabeledCandidates
        let now = Date()
        // Forget labels for windows that are no longer candidates (they were restored or closed), and
        // retry "not real" verdicts after a few seconds, since a window can be minimized later.
        hiddenLabels = hiddenLabels.filter { seenHiddenIDs.contains($0.key) && ($0.value.text.isEmpty ? now.timeIntervalSince($0.value.when) < 5 : true) }
        let todo = unlabeledCandidates.filter { hiddenLabels[$0.id] == nil }
        guard !todo.isEmpty else { return }
        hiddenRefreshInFlight = true
        let finder = self.finder
        let hiddenPIDs = Set(NSWorkspace.shared.runningApplications.filter(\.isHidden).map(\.processIdentifier))
        DispatchQueue.global(qos: .utility).async {
            var found: [CGWindowID: HiddenLabel] = [:]
            for w in todo {
                var text = ""
                if hiddenPIDs.contains(w.pid) { text = "Hidden" }
                else if let ax = finder.find(pid: w.pid, windowID: w.id, frame: w.frame, title: w.title),
                        AX.bool(ax, kAXMinimizedAttribute) == true { text = "Minimized" }
                found[w.id] = HiddenLabel(text: text, when: Date())
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hiddenLabels.merge(found) { _, new in new }
                    self.hiddenRefreshInFlight = false
                }
            }
        }
    }
}
