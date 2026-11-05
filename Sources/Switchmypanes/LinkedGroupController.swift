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

    struct Placed { let pid: pid_t; let windowID: CGWindowID; let element: AXUIElement }

    private let settings: SettingsStore
    private var groups: [Group] = []
    private var learnedMin: [pid_t: CGSize] = [:]      // an app's windows share their minimum, so remember it per app
    private var observers: [pid_t: AXObserver] = [:]
    private let notifications = [kAXResizedNotification, kAXMovedNotification, kAXUIElementDestroyedNotification]

    init(settings: SettingsStore) {
        self.settings = settings
        // A different display setup invalidates every remembered frame.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAll() }
        }
    }

    // MARK: lifecycle of groups

    /// Called when Snap Layouts finishes. Needs at least two placed windows.
    func register(_ placed: [Placed], gap: CGFloat, bounds: CGRect) {
        guard settings.linkedResizeEnabled, placed.count >= 2, AXIsProcessTrusted() else { return }
        for p in placed { unlink(pid: p.pid, windowID: p.windowID) }      // a window belongs to one group at a time
        // Give the apps a moment to settle, then record where the windows REALLY are (some refuse exact sizes).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let group = Group(gap: gap, bounds: bounds)
            for (i, p) in placed.enumerated() {
                // A window that cannot be resized at all would only break the group's flush edges: leave it out.
                guard let f = AX.frame(p.element), AX.isSettable(p.element, kAXSizeAttribute) else { continue }
                let m = Member(id: i, pid: p.pid, windowID: p.windowID, element: p.element, frame: f)
                m.minSize = self.learnedMin[p.pid]
                group.members[i] = m
            }
            guard group.members.count >= 2 else { return }
            self.groups.append(group)
            for m in group.members.values { self.watch(m) }
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
        for (_, o) in observers { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes) }
        observers.removeAll()
    }

    private func remove(_ m: Member, from g: Group) {
        unwatch(m)
        g.members.removeValue(forKey: m.id)
        if g.members.count < 2 {                       // a group of one is not a group
            for rest in g.members.values { unwatch(rest) }
            groups.removeAll { $0 === g }
        }
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
        for n in notifications { AXObserverAddNotification(observer, m.element, n as CFString, me) }
    }

    private func unwatch(_ m: Member) {
        guard let observer = observers[m.pid] else { return }
        for n in notifications { AXObserverRemoveNotification(observer, m.element, n as CFString) }
    }

    private func changed(_ element: AXUIElement, _ notification: String) {
        for g in groups {
            guard let m = g.members.values.first(where: { CFEqual($0.element, element) }) else { continue }
            if notification == kAXUIElementDestroyedNotification { remove(m, from: g); return }
            handle(m, in: g)
            return
        }
    }

    private func handle(_ m: Member, in g: Group) {
        guard settings.linkedResizeEnabled, !settings.paused, let actual = AX.frame(m.element) else { return }
        if Date() < m.ignoreUntil { return }                             // echo of our own change

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
                member.ignoreUntil = Date().addingTimeInterval(0.3)
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
