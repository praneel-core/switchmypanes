/// Modifier keys, independent of AppKit/CoreGraphics so the logic can be tested.
public struct ShortcutModifiers: OptionSet, Equatable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option  = ShortcutModifiers(rawValue: 1 << 1)
    public static let command = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift   = ShortcutModifiers(rawValue: 1 << 3)
}

public struct ShortcutConfig: Equatable {
    public var switcherModifier: ShortcutModifiers
    public var snapModifiers: ShortcutModifiers
    public var switcherEnabled: Bool
    public var snapEnabled: Bool
    /// Option+Z opens the Snap Layouts picker.
    public var layoutsEnabled: Bool
    public var layoutsModifier: ShortcutModifiers
    public init(switcherModifier: ShortcutModifiers = .option,
                snapModifiers: ShortcutModifiers = [.control, .option],
                switcherEnabled: Bool = true, snapEnabled: Bool = true,
                layoutsEnabled: Bool = true, layoutsModifier: ShortcutModifiers = .option) {
        self.switcherModifier = switcherModifier; self.snapModifiers = snapModifiers
        self.switcherEnabled = switcherEnabled; self.snapEnabled = snapEnabled
        self.layoutsEnabled = layoutsEnabled; self.layoutsModifier = layoutsModifier
    }
}

public enum KeyAction: Equatable {
    case passThrough                       // not ours: let the app receive it
    case swallow                           // ours, but nothing to do (e.g. auto-repeat)
    case switcherOpen(reverse: Bool)
    case switcherNext, switcherPrevious
    case switcherMove(ArrowKey)
    case switcherCancel
    case switcherClose                     // close the highlighted window (Delete or W)
    case switcherCommit                    // modifier released
    case snap(ArrowKey, moveToDisplay: Bool)
    // Snap Layouts picker
    case layoutsOpen
    case pickerMove(ArrowKey)
    case pickerChoose(Int)                 // digit key, 1...9
    case pickerConfirm, pickerSkip, pickerCancel
    case pickerDismiss                     // Snap Assist only: close it, then treat this key press normally
}

/// Decides what a key press means. The event tap only ever acts on what this returns,
/// so "which keys do we swallow" is defined in exactly one, testable, place.
public enum KeyClassifier {
    public static let w: Int64 = 13, delete: Int64 = 51, forwardDelete: Int64 = 117, tab: Int64 = 48, escape: Int64 = 53, z: Int64 = 6, space: Int64 = 49, returnKey: Int64 = 36, enter: Int64 = 76
    public static let left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126

    public static func arrow(for keyCode: Int64) -> ArrowKey? {
        switch keyCode {
        case left: return .left
        case right: return .right
        case up: return .up
        case down: return .down
        default: return nil
        }
    }

    /// Digit row keys 1...9 (key codes are not in order on a Mac keyboard).
    public static func digit(for keyCode: Int64) -> Int? {
        [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9][keyCode]
    }

    public static func classifyKeyDown(keyCode: Int64, flags: ShortcutModifiers, isRepeat: Bool,
                                       switcherActive: Bool, pickerActive: Bool = false,
                                       assistMode: Bool = false, config: ShortcutConfig) -> KeyAction {
        if pickerActive && assistMode {
            // Snap Assist is a light overlay: its own few keys work, ANY other key closes it and then does
            // its normal job (so Control+Option+Up right after a snap still snaps; typing still types).
            if flags.contains(.command) { return .passThrough }
            if flags.isEmpty || flags == .shift {
                switch keyCode {
                case escape: return .pickerCancel
                case returnKey, enter: return .pickerConfirm
                case tab: return .pickerMove(flags.contains(.shift) ? .left : .right)
                default: if let a = arrow(for: keyCode) { return .pickerMove(a) }
                }
            }
            return .pickerDismiss
        }
        if pickerActive {
            // The picker is modal: it owns the keyboard, so stray typing never reaches the app behind it.
            // Command shortcuts (Cmd+Q, Cmd+H, ...) are left alone.
            if flags.contains(.command) { return .passThrough }
            switch keyCode {
            case escape: return .pickerCancel
            case returnKey, enter: return .pickerConfirm
            case space: return .pickerSkip
            case tab: return .pickerMove(flags.contains(.shift) ? .left : .right)
            default:
                if let a = arrow(for: keyCode) { return .pickerMove(a) }
                if let n = digit(for: keyCode) { return .pickerChoose(n) }
                return .swallow
            }
        }
        if switcherActive {
            // Safety net: if we somehow missed the modifier release, commit now.
            guard flags.contains(config.switcherModifier) else { return .switcherCommit }
            switch keyCode {
            case tab: return flags.contains(.shift) ? .switcherPrevious : .switcherNext
            case escape: return .switcherCancel
            case delete, forwardDelete, w: return .switcherClose
            default:
                if let a = arrow(for: keyCode) { return .switcherMove(a) }
                return .passThrough
            }
        }
        if config.switcherEnabled, keyCode == tab, flags.subtracting(.shift) == config.switcherModifier {
            return isRepeat ? .swallow : .switcherOpen(reverse: flags.contains(.shift))
        }
        if config.layoutsEnabled, keyCode == z, flags == config.layoutsModifier {
            return isRepeat ? .swallow : .layoutsOpen
        }
        if config.snapEnabled, let a = arrow(for: keyCode), !config.snapModifiers.isEmpty {
            if flags == config.snapModifiers { return isRepeat ? .swallow : .snap(a, moveToDisplay: false) }
            if flags == config.snapModifiers.union(.shift) { return isRepeat ? .swallow : .snap(a, moveToDisplay: true) }
        }
        return .passThrough
    }

    /// Modifier flags changed (nothing is ever swallowed here).
    public static func classifyFlagsChanged(flags: ShortcutModifiers, switcherActive: Bool,
                                            config: ShortcutConfig) -> KeyAction {
        switcherActive && !flags.contains(config.switcherModifier) ? .switcherCommit : .passThrough
    }
}
