/// Which apps never get window previews (no picture is ever taken of their windows).
public enum PreviewPolicy {
    /// Password managers and similar. An entry ending in "*" matches any bundle ID starting with the text before it.
    public static let defaultExcludedApps: [String] = [
        "com.1password.*", "com.agilebits.*", "com.bitwarden.*", "com.lastpass.*", "com.dashlane.*",
        "org.keepassxc.*", "in.sinew.Enpass-Desktop", "com.apple.keychainaccess", "com.apple.Passwords",
    ]

    public static func isExcluded(bundleID: String?, excluded: [String]) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        for entry in excluded.map({ $0.lowercased() }) {
            if entry.hasSuffix("*") { if id.hasPrefix(String(entry.dropLast())) { return true } }
            else if id == entry { return true }
        }
        return false
    }

    /// Should an automatic (background) capture happen right now? Manual captures, taken when you open the
    /// overlay, do not use this. Automatic ones stay out of the way: not while locked, idle, or saving power.
    public static func allowsAutomaticCapture(enabled: Bool, paused: Bool, screenLocked: Bool,
                                              idleSeconds: Double, lowPowerMode: Bool, maxIdle: Double = 60) -> Bool {
        enabled && !paused && !screenLocked && !lowPowerMode && idleSeconds <= maxIdle
    }
}
