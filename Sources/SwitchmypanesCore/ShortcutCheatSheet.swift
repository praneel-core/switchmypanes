import Foundation

/// The content of the "Shortcuts" cheat sheet, built from the CURRENT settings so it stays right after you re-record a shortcut.
public enum ShortcutCheatSheet {
    public struct Row: Equatable { public let title: String; public let keys: String
        public init(_ title: String, _ keys: String) { self.title = title; self.keys = keys } }
    public struct Section: Equatable { public let title: String; public let rows: [Row]
        public init(_ title: String, _ rows: [Row]) { self.title = title; self.rows = rows } }

    /// A feature that is switched off still shows, marked "(off)", so the sheet never silently hides a shortcut.
    public static func sections(config c: ShortcutConfig, layoutsKeyLabel: String) -> [Section] {
        func off(_ on: Bool) -> String { on ? "" : " (off)" }
        let sw = ShortcutDisplay.symbols(c.switcherModifier)
        let snap = ShortcutDisplay.symbols(c.snapModifiers)
        let snapShift = ShortcutDisplay.symbols(c.snapModifiers.union(.shift))
        return [
            Section("Window switcher" + off(c.switcherEnabled), [
                Row("Open (hold, then press)", "\(sw)⇥"),
                Row("Next / previous window", "⇥  ⇧⇥"),
                Row("Move around the tiles", "← → ↑ ↓"),
                Row("Search by app or title", "just type"),
                Row("Clear the search, then cancel", "esc"),
                Row("Close the highlighted window", "⌘W"),
                Row("Switch", "release \(sw)"),
                Row("More actions", "right-click a tile"),
            ]),
            Section("Snapping" + off(c.snapEnabled), [
                Row("Left / right half", "\(snap)← →"),
                Row("Maximize", "\(snap)↑"),
                Row("Restore (or minimize)", "\(snap)↓"),
                Row("A quarter", "left or right, then ↑ or ↓"),
                Row("Move to another display", "\(snapShift)← →"),
                Row("Snap by dragging", "drag a title bar to an edge or corner"),
            ]),
            Section("Snap Layouts" + off(c.layoutsEnabled), [
                Row("Open the layout picker", ShortcutDisplay.describe(c.layoutsModifier, key: layoutsKeyLabel)),
                Row("Pick a layout", "← → ↑ ↓ ↩  or  1–9"),
                Row("Skip an area / finish", "space  /  esc"),
            ]),
        ]
    }
}

/// Pausing for a while: when does it end, and has it ended?
public enum PauseSchedule {
    public static func endDate(afterSeconds seconds: TimeInterval, from now: Date) -> Date { now.addingTimeInterval(seconds) }
    /// nil = paused until the user resumes. A timed pause has ended once its deadline has passed.
    public static func hasEnded(until: Date?, now: Date) -> Bool { until.map { now >= $0 } ?? false }
}
