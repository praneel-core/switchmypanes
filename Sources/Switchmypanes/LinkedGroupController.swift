import AppKit
import ApplicationServices
import SwitchmypanesCore

/// Windows placed side by side by Snap Layouts form a group. Drag the divider between two of them and the others
/// that touch it follow, so the group stays flush. The geometry is `LinkedResize` (Core, tested); this class
/// watches the windows and applies the result.
///
/// It watches only windows we placed ourselves, through public Accessibility notifications (resized / moved /
/// destroyed). A window leaves its group as soon as it is dragged away, snapped elsewhere, or closed, and a group
/// of fewer than two windows disappears.
@MainActor
final class LinkedGroupController {
    private final class Member {
        let id: Int
        let pid: pid_t
        let windowID: CGWindowID
        let element: AXUIElement
        var frame: CGRect
        var ignoreUntil = Date.distantPast      // our own changes echo back as notifications: ignore those briefly
        var minSize: CGSize?                    // the REAL minimum, learned when the app refuses to get smaller
        var refusals = 0                        // consecutive checks in which the app was bigger than asked
        init(id: Int, pid: pid_t, windowID: CGWindowID, element: AXUIElement, frame: CGRect) {
            self.id = id; self.pid = pid; self.windowID = windowID; self.element = element; self.frame = frame
        }
    }
    private final class Group {
        var members: [Int: Member] = [:]
        let gap: CGFloat
        let bounds: CGRect                      // the display's usable area, for WindowMover's min-size handling
        var lastDrag: (changed: Int, baseline: [Int: CGRect], userFrame: CGRect)?   // for re-checking after things settle
        var settleWork: DispatchWorkItem?       // debounced: runs once the drag has calmed down
        var verifyPending = false               // throttled: runs at most every 0.15 s while dragging
        init(gap: CGFloat, bounds: CGRect) { self.gap = gap; self.bounds = bounds }
    }

    /// Diagnostics only (self-test, or SWITCHMYPANES_DEBUG=1): describes what the controller is doing.
    var debugLog: ((String) -> Void)? = ProcessInfo.processInfo.environment["SWITCHMYPANES_DEBUG"] == "1" ? { FileHandle.standardError.write(Data(("[linked] " + $0 + "\n").utf8)) } : nil
    private func log(_ s: @autoclosure () -> String) { debugLog?(s()) }

    struct Placed { let pid: pid_t; let windowID: CGWindowID; let element: AXUIElement }

    private let settings: SettingsStore
    private var groups: [Group] = []
    private var learnedMin: [pid_t: CGSize] = [:]      // an app's windows share their minimum, so remember it per app
    private var observers: [pid_t: AXObserver] = [:]
    // Apps differ in which notifications they send for a window's size / position, so ask for all of them.
    private let notifications = [kAXResizedNotification, kAXWindowResizedNotification, kAXMovedNotification,
                                 kAXWindowMovedNotification, kAXUIElementDestroyedNotification]
    /// Tests can switch notifications off to prove the mouse-drag polling works on its own.
    var useNotifications = true
    private var mouseMonitors: [Any] = []
    /// Diagnostics: show the lines even when the group's apps are not in front.
    var forceShowDividers = false
    private let overlay = DividerOverlay()
    private var shown: [(group: Group, divider: Divider)] = []
    private var dragging: (group: Group, divider: Divider)?
    private var activationObserver: NSObjectProtocol?

    init(settings: SettingsStore) {
        self.settings = settings
        overlay.onBegin = { [weak self] i in self?.dividerBegan(i) }
        overlay.onMove = { [weak self] i, pos in self?.dividerMoved(i, to: pos) }
        overlay.onEnd = { [weak self] in self?.dividerEnded() }
        // Show the lines only while you are working in one of the linked windows' apps; otherwise another app's
        // window may be covering them and a floating line would look out of place.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDividers() }
        }
        // A different display setup invalidates every remembered frame.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAll() }
        }
    }

    // MARK: lifecycle of groups

    /// Called when Snap Layouts finishes. Needs at least two placed windows.
    func register(_ placed: [Placed], gap: CGFloat, bounds: CGRect) {
        log("register called with \(placed.count) windows; enabled=\(settings.linkedResizeEnabled) trusted=\(AXIsProcessTrusted())")
        guard settings.linkedResizeEnabled, placed.count >= 2, AXIsProcessTrusted() else { return }
        for p in placed { unlink(pid: p.pid, windowID: p.windowID) }      // a window belongs to one group at a time
        // Give the apps a moment to settle, then record where the windows REALLY are (some refuse exact sizes).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let group = Group(gap: gap, bounds: bounds)
            for (i, p) in placed.enumerated() {
                // A window that cannot be resized at all would only break the group's flush edges: leave it out.
                let frame = AX.frame(p.element), resizable = AX.isSettable(p.element, kAXSizeAttribute)
                self.log("member \(i): pid \(p.pid) window \(p.windowID) frame \(frame.map { "\($0)" } ?? "nil") resizable \(resizable)")
                guard let f = frame, resizable else { continue }
                let m = Member(id: i, pid: p.pid, windowID: p.windowID, element: p.element, frame: f)
                m.minSize = self.learnedMin[p.pid]
                group.members[i] = m
            }
            self.log("group has \(group.members.count) linked members")
            guard group.members.count >= 2 else { return }
            self.groups.append(group)
            for m in group.members.values { self.watch(m) }
            self.updateMouseMonitors()
            self.refreshDividers()
        }
    }

    /// A window is about to be moved by us (snap shortcut, drag-to-edge, Snap Assist, a newer layout): leave its group.
    func unlink(pid: pid_t, windowID: CGWindowID?) {
        guard let windowID else { return }
        for g in groups { for m in g.members.values where m.pid == pid && m.windowID == windowID { remove(m, from: g) } }
    }

    func removeAll() {
        for g in groups { for m in g.members.values { unwatch(m) } }
        groups.removeAll()
        overlay.removeAll(); shown = []
        for (_, o) in observers { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes) }
        observers.removeAll()
        updateMouseMonitors()
        refreshDividers()
    }

    private func remove(_ m: Member, from g: Group) {
        unwatch(m)
        g.members.removeValue(forKey: m.id)
        if g.members.count < 2 {                       // a group of one is not a group
            for rest in g.members.values { unwatch(rest) }
            groups.removeAll { $0 === g }
            updateMouseMonitors()
        }
        refreshDividers()
    }

    // MARK: the visible divider lines (and dragging them)

    /// Draws a line for every divider of every group, at the windows' CURRENT positions.
    private func refreshDividers() {
        guard settings.linkedResizeEnabled, !settings.paused, !groups.isEmpty else { overlay.removeAll(); shown = []; return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var items: [(group: Group, divider: Divider)] = []
        for g in groups {
            // visible when you are in one of the group's apps (or are dragging the line itself, when our own app is in front)
            guard forceShowDividers || front == getpid() || g.members.values.contains(where: { $0.pid == front }) else { continue }
            let frames = g.members.mapValues(\.frame)
            items += LinkedResize.dividers(members: frames, gap: g.gap).map { (g, $0) }
        }
        shown = items
        log("showing \(items.count) divider line(s)")
        overlay.show(items.map(\.divider))
    }

    /// Diagnostics: performs the same steps as dragging the first divider with the mouse (self-test only).
    func debugDragFirstDivider(through positions: [CGFloat], pause: () -> Void) {
        refreshDividers()
        guard !shown.isEmpty else { log("no divider to drag"); return }
        dividerBegan(0)
        for p in positions { dividerMoved(0, to: p); pause() }
        dividerEnded()
    }

    /// Diagnostics: where the first divider line currently is (top-left coordinates), if any.
    var debugFirstDividerPosition: CGFloat? { shown.first?.divider.position }

    private func dividerBegan(_ index: Int) {
        guard index < shown.count else { return }
        dragging = shown[index]
        log("divider grabbed (\(shown[index].divider.axis))")
    }

    /// The user drags the line. We decide where every window goes, set them all, then READ BACK what the apps
    /// really did: if a window refused to get smaller, the line stops there instead of overlapping it.
    private func dividerMoved(_ index: Int, to position: CGFloat) {
        guard let (g, divider) = dragging else { return }
        func readActual() -> [Int: CGRect] { g.members.mapValues { AX.frame($0.element) ?? $0.frame } }
        func place(_ targets: [Int: CGRect], current: [Int: CGRect]) {
            for (id, target) in targets {
                guard let m = g.members[id], LinkedResize.classify(old: current[id] ?? m.frame, new: target) != .none else { continue }
                m.ignoreUntil = Date().addingTimeInterval(0.5)          // the app's own notifications about OUR change
                WindowMover.apply(target, to: m.element, bounds: g.bounds)
            }
        }
        let minSizes = g.members.compactMapValues(\.minSize)
        var current = readActual()
        var targets = LinkedResize.dragDivider(members: current, divider: divider, to: position, gap: g.gap, minSizes: minSizes)
        place(targets, current: current)

        var real = readActual()
        // Reality check: a window that did not get as small as asked would now overlap its neighbour.
        // Pull the line back to where the stubborn window actually is.
        for _ in 0..<2 {
            let beforeEdge = divider.before.compactMap { real[$0] }.map { divider.axis == .vertical ? $0.maxX : $0.maxY }.max() ?? 0
            let afterEdge = divider.after.compactMap { real[$0] }.map { divider.axis == .vertical ? $0.minX : $0.minY }.min() ?? 0
            guard beforeEdge + g.gap > afterEdge + 3 else { break }
            current = real
            targets = LinkedResize.dragDivider(members: real, divider: divider, to: afterEdge - g.gap / 2, gap: g.gap, minSizes: minSizes)
            place(targets, current: current)
            real = readActual()
        }
        // Learn real minimums (only when a window stays too big for several drag events in a row, so a slow app is not blamed).
        for id in divider.before + divider.after {
            guard let m = g.members[id], let target = targets[id], let r = real[id] else { continue }
            let outcome = MinSizeLearning.check(intended: target, real: r, refusals: m.refusals, current: m.minSize, confirmations: 6)
            m.refusals = outcome.refusals
            if outcome.learned, let min = outcome.minSize { m.minSize = min; learnedMin[m.pid] = min; log("learned minimum \(min) for window \(m.windowID)") }
        }
        for (id, f) in real { g.members[id]?.frame = f }                 // the model follows reality
        refreshDividers()                                                // so the line shows where the divider really is
    }

    private func dividerEnded() {
        dragging = nil
        refreshDividers()
    }

    // MARK: mouse-drag polling (does not depend on the dragged app sending notifications)

    /// While a group exists, every mouse-drag event re-reads the group's windows. That is how a resize by the mouse is
    /// noticed even for apps that send no (or late) Accessibility notifications. Mouse events need no extra permission.
    private func updateMouseMonitors() {
        if groups.isEmpty {
            mouseMonitors.forEach { NSEvent.removeMonitor($0) }
            mouseMonitors.removeAll()
        } else if mouseMonitors.isEmpty {
            for mask: NSEvent.EventTypeMask in [.leftMouseDragged, .leftMouseUp] {
                if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                    MainActor.assumeIsolated { self?.poll() }
                }) { mouseMonitors.append(m) }
            }
        }
    }

    /// Looks at every member of every group. Changes are applied exactly as for a notification (and a change that was
    /// already handled is simply "no change").
    func poll() {
        for g in groups { for m in Array(g.members.values) where g.members[m.id] != nil { handle(m, in: g) } }
    }

    // MARK: Accessibility observers

    private let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let controller = Unmanaged<LinkedGroupController>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { controller.changed(element, notification as String) }
    }

    private func watch(_ m: Member) {
        var observer = observers[m.pid]
        if observer == nil {
            var created: AXObserver?
            guard AXObserverCreate(m.pid, callback, &created) == .success, let created else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
            observers[m.pid] = created
            observer = created
        }
        guard let observer else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in notifications where useNotifications {
            let r = AXObserverAddNotification(observer, m.element, n as CFString, me)
            log("watch window \(m.windowID) \(n): \(r == .success ? "ok" : "ERROR \(r.rawValue)")")
        }
    }

    private func unwatch(_ m: Member) {
        guard let observer = observers[m.pid] else { return }
        for n in notifications { AXObserverRemoveNotification(observer, m.element, n as CFString) }
    }

    private func changed(_ element: AXUIElement, _ notification: String) {
        log("notification \(notification)")
        for g in groups {
            guard let m = g.members.values.first(where: { CFEqual($0.element, element) }) else { continue }
            if notification == (kAXUIElementDestroyedNotification as String) { remove(m, from: g); return }
            handle(m, in: g)
            return
        }
    }

    private func handle(_ m: Member, in g: Group) {
        guard settings.linkedResizeEnabled, !settings.paused, let actual = AX.frame(m.element) else { return }
        if Date() < m.ignoreUntil { return }                             // echo of our own change

        log("window \(m.windowID): model \(m.frame) actual \(actual) -> \(LinkedResize.classify(old: m.frame, new: actual))")
        switch LinkedResize.classify(old: m.frame, new: actual) {
        case .none:
            return
        case .moved:
            remove(m, from: g)                                          // dragged away: it leaves the group
        case .resized:
            let baseline = g.members.mapValues(\.frame)          // the last known-good, flush layout
            m.frame = actual
            g.lastDrag = (m.id, baseline, actual)
            followDrag(in: g)
            scheduleVerify(g)
            scheduleSettle(g)
            refreshDividers()
        }
    }

    /// Computes where every window should be for the latest drag and applies it. The model keeps the INTENDED
    /// frames; `verify` later compares them with reality.
    private func followDrag(in g: Group) {
        guard let drag = g.lastDrag else { return }
        let minSizes = g.members.compactMapValues(\.minSize)
        let result = LinkedResize.resolve(members: drag.baseline, changed: drag.changed, newFrame: drag.userFrame,
                                          gap: g.gap, minSizes: minSizes)
        for (id, target) in result {
            guard let member = g.members[id] else { continue }
            if LinkedResize.classify(old: member.frame, new: target) != .none {
                // Ignore this window while the app catches up: it must not be mistaken for the user resizing it back.
                member.ignoreUntil = Date().addingTimeInterval(0.5)
                WindowMover.apply(target, to: member.element, bounds: g.bounds)
            }
            member.frame = target
        }
    }

    /// Looks at where the windows REALLY are. An app that stays bigger than we asked, on two checks in a row (so a
    /// merely slow app is not mistaken for a stubborn one), has a real minimum size: remember it and pull the group
    /// back into line, so the divider stops there instead of one window overlapping another.
    private func verify(_ g: Group) {
        guard groups.contains(where: { $0 === g }) else { return }
        var learned = false
        for member in g.members.values {
            guard let real = AX.frame(member.element) else { continue }
            let outcome = MinSizeLearning.check(intended: member.frame, real: real, refusals: member.refusals, current: member.minSize)
            member.refusals = outcome.refusals
            if outcome.learned, let min = outcome.minSize {
                member.minSize = min
                learnedMin[member.pid] = min
                learned = true
            }
            if member.refusals == 0 { member.frame = real }      // reality wins once we have decided what it means
        }
        if learned { followDrag(in: g); scheduleVerify(g) }      // re-apply with the new minimum, then check once more
    }

    private func scheduleVerify(_ g: Group) {
        guard !g.verifyPending else { return }
        g.verifyPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak g] in
            g?.verifyPending = false
            if let self, let g { self.verify(g) }
        }
    }

    private func scheduleSettle(_ g: Group) {
        g.settleWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak g] in if let self, let g { self.verify(g) } }
        g.settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
}
