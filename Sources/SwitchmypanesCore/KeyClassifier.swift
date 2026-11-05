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
    public init(switcherModifier: ShortcutModifiers = .option,
                snapModifiers: ShortcutModifiers = [.control, .option],
                switcherEnabled: Bool = true, snapEnabled: Bool = true) {
        self.switcherModifier = switcherModifier; self.snapModifiers = snapModifiers
        self.switcherEnabled = switcherEnabled; self.snapEnabled = snapEnabled
    }
}

public enum KeyAction: Equatable {
    case passThrough                       // not ours: let the app receive it
    case swallow                           // ours, but nothing to do (e.g. auto-repeat)
    case switcherOpen(reverse: Bool)
    case switcherNext, switcherPrevious
    case switcherMove(ArrowKey)
    case switcherCancel
    case switcherCommit                    // modifier released
    case snap(ArrowKey, moveToDisplay: Bool)
}

/// Decides what a key press means. The event tap only ever acts on what this returns,
/// so "which keys do we swallow" is defined in exactly one, testable, place.
public enum KeyClassifier {
    public static let tab: Int64 = 48, escape: Int64 = 53
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

    public static func classifyKeyDown(keyCode: Int64, flags: ShortcutModifiers, isRepeat: Bool,
                                       switcherActive: Bool, config: ShortcutConfig) -> KeyAction {
        if switcherActive {
            // Safety net: if we somehow missed the modifier release, commit now.
            guard flags.contains(config.switcherModifier) else { return .switcherCommit }
            switch keyCode {
            case tab: return flags.contains(.shift) ? .switcherPrevious : .switcherNext
            case escape: return .switcherCancel
            default:
                if let a = arrow(for: keyCode) { return .switcherMove(a) }
                return .passThrough
            }
        }
        if config.switcherEnabled, keyCode == tab, flags.subtracting(.shift) == config.switcherModifier {
            return isRepeat ? .swallow : .switcherOpen(reverse: flags.contains(.shift))
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
