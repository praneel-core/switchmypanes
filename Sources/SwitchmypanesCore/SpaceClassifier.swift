/// What kind of Space (virtual desktop) a window lives on.
public enum SpaceKind: Equatable { case desktop, fullScreen, other }

/// Where a window is, from the switcher's point of view.
public enum WindowPlacement: Equatable {
    case currentSpace                    // visible on a Space you can currently see
    case otherSpace(SpaceKind)           // lives on a Space that is not showing right now
    case hiddenOrMinimized               // on a visible Space but not drawn: minimized, or its app is hidden
                                         // (macOS reports both the same way, so Accessibility tells them apart)
    case orderedOutElsewhere             // on another Space AND not showing anywhere: a window the app closed
                                         // to the background (Claude, Slack...), or one minimized / hidden there
    case noSpace                         // belongs to no Space: helper / off-screen junk windows
}

public struct SpaceFilterOptions: Equatable {
    public var includeOtherDesktops: Bool
    public var includeFullScreen: Bool
    /// Minimized windows and windows of hidden (Cmd+H) apps.
    public var includeMinimized: Bool
    public init(includeOtherDesktops: Bool = true, includeFullScreen: Bool = true, includeMinimized: Bool = true) {
        self.includeOtherDesktops = includeOtherDesktops; self.includeFullScreen = includeFullScreen
        self.includeMinimized = includeMinimized
    }

    /// True when at least one option needs the full (all Spaces) window list.
    public var needsFullWindowList: Bool { includeOtherDesktops || includeFullScreen || includeMinimized }
}

public enum SpaceClassifier {
    /// - Parameters:
    ///   - isOnScreen: macOS says the window is currently drawn
    ///   - windowSpaces: IDs of the Spaces the window belongs to
    ///   - activeSpaces: the Space currently showing on each display
    ///   - kinds: kind of every known Space
    ///   - isOrderedIn: whether the window server considers the window "in" (really showing, wherever it lives).
    ///     A real window on another desktop is ordered in; a closed-to-background window is not. nil = unknown.
    public static func classify(isOnScreen: Bool, windowSpaces: [Int], activeSpaces: Set<Int>,
                                kinds: [Int: SpaceKind], isOrderedIn: Bool? = nil) -> WindowPlacement {
        if isOnScreen { return .currentSpace }
        guard let first = windowSpaces.first else { return .noSpace }
        if windowSpaces.contains(where: { activeSpaces.contains($0) }) { return .hiddenOrMinimized }
        if isOrderedIn == false { return .orderedOutElsewhere }
        return .otherSpace(kinds[first] ?? .other)
    }

    /// The current Space is always included; other desktops, full-screen apps and minimized / hidden
    /// windows are each controlled by an option. Windows that belong to no Space are never included.
    public static func isIncluded(_ placement: WindowPlacement, options: SpaceFilterOptions) -> Bool {
        switch placement {
        case .currentSpace: return true
        case .otherSpace(.fullScreen): return options.includeFullScreen
        case .otherSpace: return options.includeOtherDesktops
        case .hiddenOrMinimized, .orderedOutElsewhere: return options.includeMinimized   // callers must also verify (see WindowInventory)
        case .noSpace: return false
        }
    }
}
