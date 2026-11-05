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
}

struct CurrentSpaceOnlyProvider: SpaceProvider {
    func snapshot() -> SpaceSnapshot? { nil }
    func spaces(ofWindow id: CGWindowID) -> [Int] { [] }
    func isOrderedIn(window id: CGWindowID) -> Bool? { nil }
}

// ─────────────────────────────────────────────────────────────────────────────
// PRIVATE API, ISOLATED. Looked up by name at runtime (dlsym): if a macOS update removes one,
// `init?` fails and we fall back. Return values are parsed defensively: unexpected shapes give
// "no information", never a crash.
//   CGSMainConnectionID()                      -> connection to the window server
//   CGSCopyManagedDisplaySpaces(cid)           -> per display: its Spaces and its current Space
//   CGSCopySpacesForWindows(cid, mask, [wid])  -> IDs of the Spaces a window is on (mask 7 = all)
//   CGSWindowIsOrderedIn(cid, wid, &flag)      -> is the window really showing? (OPTIONAL: if missing we just don't filter ghosts)
// ─────────────────────────────────────────────────────────────────────────────
struct CGSSpaceProvider: SpaceProvider {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManaged = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias IsOrderedIn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<DarwinBoolean>) -> Int32

    private let mainConnection: MainConnection
    private let copyManaged: CopyManaged
    private let copySpaces: CopySpaces
    private let orderedIn: IsOrderedIn?

    init?() {
        func load(_ name: String) -> UnsafeMutableRawPointer? { dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) }
        guard let a = load("CGSMainConnectionID"), let b = load("CGSCopyManagedDisplaySpaces"),
              let c = load("CGSCopySpacesForWindows") else { return nil }
        mainConnection = unsafeBitCast(a, to: MainConnection.self)
        copyManaged = unsafeBitCast(b, to: CopyManaged.self)
        copySpaces = unsafeBitCast(c, to: CopySpaces.self)
        orderedIn = load("CGSWindowIsOrderedIn").map { unsafeBitCast($0, to: IsOrderedIn.self) }
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

    func isOrderedIn(window id: CGWindowID) -> Bool? {
        guard let orderedIn else { return nil }
        var flag = DarwinBoolean(false)
        return orderedIn(mainConnection(), id, &flag) == 0 ? flag.boolValue : nil
    }
}

func makeSpaceProvider() -> SpaceProvider { CGSSpaceProvider() ?? CurrentSpaceOnlyProvider() }
