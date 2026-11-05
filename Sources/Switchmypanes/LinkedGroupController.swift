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
        init(id: Int, pid: pid_t, windowID: CGWindowID, element: AXUIElement, frame: CGRect) {
            self.id = id; self.pid = pid; self.windowID = windowID; self.element = element; self.frame = frame
        }
    }
    private final class Group {
        var members: [Int: Member] = [:]
        let gap: CGFloat
        let bounds: CGRect                      // the display's usable area, for WindowMover's min-size handling
        init(gap: CGFloat, bounds: CGRect) { self.gap = gap; self.bounds = bounds }
    }

    struct Placed { let pid: pid_t; let windowID: CGWindowID; let element: AXUIElement }

    private let settings: SettingsStore
    private var groups: [Group] = []
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
                guard let f = AX.frame(p.element) else { continue }
                group.members[i] = Member(id: i, pid: p.pid, windowID: p.windowID, element: p.element, frame: f)
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
        if Date() < m.ignoreUntil { m.frame = actual; return }          // echo of our own change

        switch LinkedResize.classify(old: m.frame, new: actual) {
        case .none:
            return
        case .moved:
            remove(m, from: g)                                          // dragged away: it leaves the group
        case .resized:
            let current = g.members.mapValues(\.frame)
            let result = LinkedResize.resolve(members: current, changed: m.id, newFrame: actual, gap: g.gap)
            for (id, target) in result {
                guard let member = g.members[id] else { continue }
                let from = id == m.id ? actual : member.frame
                if LinkedResize.classify(old: from, new: target) == .none { member.frame = target; continue }
                member.ignoreUntil = Date().addingTimeInterval(0.3)
                WindowMover.apply(target, to: member.element, bounds: g.bounds)
                member.frame = AX.frame(member.element) ?? target       // what the app really did (it may refuse tiny sizes)
            }
        }
    }
}
