import AppKit
import CoreGraphics
import SwitchmypanesCore

extension ShortcutModifiers {
    /// From the modifier flags of a NSEvent (used by the shortcut recorder).
    init(_ f: NSEvent.ModifierFlags) {
        var m: ShortcutModifiers = []
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.shift) { m.insert(.shift) }
        self = m
    }

    /// As CoreGraphics event flags (used to check which modifiers are physically held).
    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.control) { f.insert(.maskControl) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.command) { f.insert(.maskCommand) }
        if contains(.shift) { f.insert(.maskShift) }
        return f
    }
}
