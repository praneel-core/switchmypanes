/// How shortcuts are shown to the user, and which ones are allowed. Pure logic, so it can be tested.
public enum ShortcutDisplay {
    /// Modifier symbols in the order macOS uses: ⌃ ⌥ ⇧ ⌘.
    public static func symbols(_ m: ShortcutModifiers) -> String {
        (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") +
        (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
    }

    /// Names for keys that have no printable character. Letters and digits use the label captured when recording
    /// (which follows the user's keyboard layout); this table is the fallback.
    public static func keyName(_ code: Int64) -> String {
        let names: [Int64: String] = [
            48: "Tab", 49: "Space", 36: "Return", 51: "Delete", 53: "Esc", 117: "Forward Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
            46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W",
            7: "X", 16: "Y", 6: "Z", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8",
            25: "9", 29: "0", 27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/",
            42: "\\", 50: "`",
        ]
        return names[code] ?? "Key \(code)"
    }

    public static func describe(_ m: ShortcutModifiers, key: String) -> String { symbols(m) + key }
}

public enum ShortcutKind: Equatable { case switcher, snap, layouts }

public enum ShortcutValidator {
    /// nil = the combination is fine. Otherwise a plain-language reason it is not.
    /// `current` is the configuration with the OTHER shortcuts, used to detect clashes.
    public static func validate(_ kind: ShortcutKind, modifiers m: ShortcutModifiers, keyCode: Int64,
                                current c: ShortcutConfig) -> String? {
        let tab = KeyClassifier.tab
        switch kind {
        case .switcher:
            if keyCode != tab { return "Press Tab together with your modifier keys, for example hold ⌥ and press Tab." }
            if m.isEmpty { return "Hold at least one modifier key (⌃ ⌥ ⌘) while pressing Tab." }
            if m.contains(.shift) { return "Shift is already used to go backwards. Use ⌃, ⌥ or ⌘." }
            if m == .command { return "⌘Tab belongs to macOS and is left alone. Try ⌥Tab, or add another modifier." }
            if (c.layoutsKeyCode == tab || c.layoutsKeyCode == KeyClassifier.backtick) && c.layoutsModifier.subtracting(.shift) == m {
                return "That is already the Snap Layouts shortcut."
            }
            return nil

        case .snap:
            guard KeyClassifier.arrow(for: keyCode) != nil else { return "Press an arrow key together with your modifier keys." }
            if m.contains(.shift) { return "Shift is added automatically to move a window to another display. Leave it out here." }
            if m.count < 2 { return "A single modifier clashes with macOS or text editing (for example ⌥← jumps a word). Use two, such as ⌃⌥." }
            if KeyClassifier.arrow(for: c.layoutsKeyCode) != nil &&
                (c.layoutsModifier == m || c.layoutsModifier == m.union(.shift)) { return "That is already the Snap Layouts shortcut." }
            return nil

        case .layouts:
            if m.subtracting(.shift).isEmpty { return "Include at least one of ⌃ ⌥ ⌘, otherwise typing would trigger it." }
            if keyCode == KeyClassifier.escape { return "Esc is used to close the picker. Pick another key." }
            if m == .command, [12, 13, 4, 46, 49, 48, 50].contains(keyCode) {
                return "⌘\(ShortcutDisplay.keyName(keyCode)) is a standard macOS shortcut. Pick another key."
            }
            if keyCode == tab && m.subtracting(.shift) == c.switcherModifier { return "That is already the window switcher shortcut." }
            if keyCode == KeyClassifier.backtick && c.appWindowsEnabled && m.subtracting(.shift) == c.switcherModifier {
                return "That is already the shortcut for cycling the windows of one app."
            }
            if KeyClassifier.arrow(for: keyCode) != nil &&
                (m == c.snapModifiers || m == c.snapModifiers.union(.shift)) { return "That is already the snapping shortcut." }
            return nil
        }
    }
}

public extension ShortcutModifiers {
    /// Number of modifier keys in the set.
    var count: Int { [ShortcutModifiers.control, .option, .command, .shift].filter { contains($0) }.count }
}
