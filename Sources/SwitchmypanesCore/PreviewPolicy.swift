/// Which apps never get window previews (no picture is ever taken of their windows).
public enum PreviewPolicy {
    /// Password managers and similar. An entry ending in "*" matches any bundle ID starting with the text before it.
    public static let defaultExcludedApps: [String] = [
        "com.1password.*", "com.agilebits.*", "com.bitwarden.*", "com.lastpass.*", "com.dashlane.*",
        "org.keepassxc.*", "in.sinew.Enpass-Desktop", "com.apple.keychainaccess", "com.apple.Passwords",
    ]

    public static func isExcluded(bundleID: String?, excluded: [String]) -> Bool {
        guard let bundleID else { return false }
        return excluded.contains { BundlePattern.matches($0, bundleID: bundleID) }
    }

    /// Should an automatic (background) capture happen right now? Manual captures, taken when you open the
    /// overlay, do not use this. Automatic ones stay out of the way: not while locked, idle, or saving power.
    public static func allowsAutomaticCapture(enabled: Bool, paused: Bool, screenLocked: Bool,
                                              idleSeconds: Double, lowPowerMode: Bool, maxIdle: Double = 60) -> Bool {
        enabled && !paused && !screenLocked && !lowPowerMode && idleSeconds <= maxIdle
    }
}

/// Which glass look the overlays actually use, given the user's choice and macOS's accessibility setting.
public enum OverlayAppearance {
    public static let validStyles = ["glass", "frosted", "dark"]
    public static let minimumOpacity = 0.3

    /// macOS "Reduce transparency" wins over everything: solid Dark at full strength. Otherwise the user's look, with an
    /// unknown name falling back to "glass" and the opacity kept in a usable range.
    public static func resolve(styleName: String, opacity: Double, reduceTransparency: Bool) -> (style: String, opacity: Double) {
        if reduceTransparency { return ("dark", 1.0) }
        let style = validStyles.contains(styleName) ? styleName : "glass"
        return (style, min(1.0, max(minimumOpacity, opacity)))
    }
}
