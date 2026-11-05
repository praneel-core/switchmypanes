import CoreGraphics
import Foundation
import SwitchmypanesCore

struct SpaceSnapshot {
    let activeSpaces: Set<Int>        // the Space currently showing on each display
    let kinds: [Int: SpaceKind]
    let labels: [Int: String]         // "Desktop 2", "Full screen"
}

/// Information about macOS Spaces (virtual desktops).
///
/// The public API cannot say which Space a window is on, so the real implementation below uses
/// undocumented CoreGraphics ("CGS") functions. Everything private lives in this file, behind this
/// protocol. If anything is missing or behaves unexpectedly, `makeSpaceProvider()` hands back
/// `CurrentSpaceOnlyProvider` and the switcher simply lists the current desktop only.
protocol SpaceProvider {
    /// nil = no Spaces information available.
    func snapshot() -> SpaceSnapshot?
    /// IDs of the Spaces this window belongs to (empty = none or unknown).
    func spaces(ofWindow id: CGWindowID) -> [Int]
    /// Does the window server consider the window really showing (somewhere)? nil = unknown.
    func isOrderedIn(window id: CGWindowID) -> Bool?
    /// Makes the desktop (Space) that holds this window the current one on its display, then calls `completion(true)`
    /// (on the main thread). Takes a moment: the switch is an animation driven by macOS's Dock.
    func switchToSpace(ofWindow id: CGWindowID, completion: @escaping (Bool) -> Void)
}

struct CurrentSpaceOnlyProvider: SpaceProvider {
    func snapshot() -> SpaceSnapshot? { nil }
    func spaces(ofWindow id: CGWindowID) -> [Int] { [] }
    func isOrderedIn(window id: CGWindowID) -> Bool? { nil }
    func switchToSpace(ofWindow id: CGWindowID, completion: @escaping (Bool) -> Void) { completion(false) }
}

// ─────────────────────────────────────────────────────────────────────────────
// PRIVATE API, ISOLATED. Looked up by name at runtime (dlsym): if a macOS update removes one,
// `init?` fails and we fall back. Return values are parsed defensively: unexpected shapes give
// "no information", never a crash.
//   CGSMainConnectionID()                      -> connection to the window server
//   CGSCopyManagedDisplaySpaces(cid)           -> per display: its Spaces and its current Space
//   CGSCopySpacesForWindows(cid, mask, [wid])  -> IDs of the Spaces a window is on (mask 7 = all)
//   CGSWindowIsOrderedIn(cid, wid, &flag)      -> is the window really showing? (OPTIONAL: if missing we just don't filter ghosts)
//   CGSGetSymbolicHotKeyValue / CGSIsSymbolicHotKeyEnabled -> the user's "Move left/right a space" keyboard shortcuts.
//                                                  Switching desktops = pressing THOSE keys (synthetic key events), so the Dock, which
//                                                  owns desktops, does the switching and stays consistent. (OPTIONAL)
//   CGSManagedDisplaySetCurrentSpace(cid, displayUUID, spaceID) -> switch a display directly. LAST RESORT only: it works but
//                                                  bypasses the Dock, which then shows stale Mission Control / Dock UI.
// ─────────────────────────────────────────────────────────────────────────────
struct CGSSpaceProvider: SpaceProvider {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManaged = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias IsOrderedIn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<DarwinBoolean>) -> Int32
    private typealias SetCurrentSpace = @convention(c) (Int32, CFString, Int) -> Int32
    private typealias HotKeyEnabled = @convention(c) (Int32) -> Bool
    private typealias HotKeyValue = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32

    private let mainConnection: MainConnection
    private let copyManaged: CopyManaged
    private let copySpaces: CopySpaces
    private let orderedIn: IsOrderedIn?
    private let setCurrentSpace: SetCurrentSpace?
    private let hotKeyEnabled: HotKeyEnabled?
    private let hotKeyValue: HotKeyValue?

    init?() {
        func load(_ name: String) -> UnsafeMutableRawPointer? { dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) }
        guard let a = load("CGSMainConnectionID"), let b = load("CGSCopyManagedDisplaySpaces"),
              let c = load("CGSCopySpacesForWindows") else { return nil }
        mainConnection = unsafeBitCast(a, to: MainConnection.self)
        copyManaged = unsafeBitCast(b, to: CopyManaged.self)
        copySpaces = unsafeBitCast(c, to: CopySpaces.self)
        orderedIn = load("CGSWindowIsOrderedIn").map { unsafeBitCast($0, to: IsOrderedIn.self) }
        setCurrentSpace = load("CGSManagedDisplaySetCurrentSpace").map { unsafeBitCast($0, to: SetCurrentSpace.self) }
        hotKeyEnabled = load("CGSIsSymbolicHotKeyEnabled").map { unsafeBitCast($0, to: HotKeyEnabled.self) }
        hotKeyValue = load("CGSGetSymbolicHotKeyValue").map { unsafeBitCast($0, to: HotKeyValue.self) }
        // Self-test: if the answer does not look like what we expect, do not use it at all.
        guard snapshot() != nil else { return nil }
    }

    func snapshot() -> SpaceSnapshot? {
        guard let displays = copyManaged(mainConnection())?.takeRetainedValue() as? [[String: Any]], !displays.isEmpty else { return nil }
        var active = Set<Int>(), kinds: [Int: SpaceKind] = [:], labels: [Int: String] = [:]
        for d in displays {
            if let cur = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int { active.insert(cur) }
            var desktopNumber = 0
            for s in (d["Spaces"] as? [[String: Any]]) ?? [] {
                guard let id = s["ManagedSpaceID"] as? Int else { continue }
                switch s["type"] as? Int {
                case 0?: desktopNumber += 1; kinds[id] = .desktop; labels[id] = "Desktop \(desktopNumber)"
                case 4?: kinds[id] = .fullScreen; labels[id] = "Full screen"
                default: kinds[id] = .other; labels[id] = "Other desktop"
                }
            }
        }
        return active.isEmpty ? nil : SpaceSnapshot(activeSpaces: active, kinds: kinds, labels: labels)
    }

    func spaces(ofWindow id: CGWindowID) -> [Int] {
        (copySpaces(mainConnection(), 7, [id] as CFArray)?.takeRetainedValue() as? [Int]) ?? []
    }

    func switchToSpace(ofWindow id: CGWindowID, completion: @escaping (Bool) -> Void) {
        guard let target = spaces(ofWindow: id).first,
              let displays = copyManaged(mainConnection())?.takeRetainedValue() as? [[String: Any]],
              let d = displays.first(where: { ($0["Spaces"] as? [[String: Any]])?.contains { $0["ManagedSpaceID"] as? Int == target } == true }),
              let displayID = d["Display Identifier"] as? String,
              let order = (d["Spaces"] as? [[String: Any]])?.compactMap({ $0["ManagedSpaceID"] as? Int }),
              let current = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int else { completion(false); return }
        if current == target { completion(true); return }

        func activeNow() -> Int? {
            let ds = copyManaged(mainConnection())?.takeRetainedValue() as? [[String: Any]]
            return ds?.first { ($0["Display Identifier"] as? String) == displayID }
                .flatMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int }
        }
        func lastResort() {                                  // the direct call: works, but the Dock is not told
            let ok = setCurrentSpace.map { $0(mainConnection(), displayID as CFString, target) == 0 } ?? false
            completion(ok)
        }

        // The normal way: press the user's own "Move left / right a space" shortcut once per desktop to cross.
        guard let from = order.firstIndex(of: current), let to = order.firstIndex(of: target),
              let key = shortcut(forwards: to > from) else { lastResort(); return }
        let steps = abs(to - from)
        for n in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32 * Double(n)) { Self.press(key) }
        }
        // Wait until macOS has really arrived (it animates), then give it a moment to settle.
        let started = Date()
        func poll() {
            if activeNow() == target {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { completion(true) }
            } else if Date().timeIntervalSince(started) > 1.0 + 0.5 * Double(steps) {
                lastResort()                                 // the shortcut did not work (disabled? blocked?)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
    }

    /// The configured keyboard shortcut for "Move right a space" (81) or "Move left a space" (79), if it is switched on.
    private func shortcut(forwards: Bool) -> (virtualKey: UInt16, flags: CGEventFlags)? {
        let id: Int32 = forwards ? 81 : 79
        guard let hotKeyEnabled, let hotKeyValue, hotKeyEnabled(id) else { return nil }
        var keyEquivalent: UInt16 = 0, virtualKey: UInt16 = 0, modifiers: UInt32 = 0
        guard hotKeyValue(id, &keyEquivalent, &virtualKey, &modifiers) == 0 else { return nil }
        return (virtualKey, CGEventFlags(rawValue: UInt64(modifiers)))
    }

    /// Presses and releases that key, with exactly those modifiers (whatever the user is physically holding, such as
    /// the Option key of the window switcher, is not included).
    private static func press(_ key: (virtualKey: UInt16, flags: CGEventFlags)) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key.virtualKey, keyDown: down) else { continue }
            e.flags = key.flags
            e.post(tap: .cghidEventTap)
        }
    }

    func isOrderedIn(window id: CGWindowID) -> Bool? {
        guard let orderedIn else { return nil }
        var flag = DarwinBoolean(false)
        return orderedIn(mainConnection(), id, &flag) == 0 ? flag.boolValue : nil
    }
}

func makeSpaceProvider() -> SpaceProvider { CGSSpaceProvider() ?? CurrentSpaceOnlyProvider() }
