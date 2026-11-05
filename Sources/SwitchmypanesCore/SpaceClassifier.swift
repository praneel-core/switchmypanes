/// What kind of Space (virtual desktop) a window lives on.
public enum SpaceKind: Equatable { case desktop, fullScreen, other }

/// Where a window is, from the switcher's point of view.
public enum WindowPlacement: Equatable {
    case currentSpace                    // visible on a Space you can currently see
    case otherSpace(SpaceKind)           // lives on a Space that is not showing right now
    case hiddenOrMinimized               // on a visible Space but not drawn: minimized, or its app is hidden
    case noSpace                         // belongs to no Space: helper / off-screen junk windows
}

public struct SpaceFilterOptions: Equatable {
    public var includeOtherDesktops: Bool
    public var includeFullScreen: Bool
    public init(includeOtherDesktops: Bool = true, includeFullScreen: Bool = true) {
        self.includeOtherDesktops = includeOtherDesktops; self.includeFullScreen = includeFullScreen
    }
}

public enum SpaceClassifier {
    /// - Parameters:
    ///   - isOnScreen: macOS says the window is currently drawn
    ///   - windowSpaces: IDs of the Spaces the window belongs to
    ///   - activeSpaces: the Space currently showing on each display
    ///   - kinds: kind of every known Space
    public static func classify(isOnScreen: Bool, windowSpaces: [Int], activeSpaces: Set<Int>,
                                kinds: [Int: SpaceKind]) -> WindowPlacement {
        if isOnScreen { return .currentSpace }
        guard let first = windowSpaces.first else { return .noSpace }
        if windowSpaces.contains(where: { activeSpaces.contains($0) }) { return .hiddenOrMinimized }
        return .otherSpace(kinds[first] ?? .other)
    }

    /// Phase 2 scope: current Space plus (optionally) other desktops and full-screen apps.
    /// Minimized / hidden windows are a separate feature and stay excluded here.
    public static func isIncluded(_ placement: WindowPlacement, options: SpaceFilterOptions) -> Bool {
        switch placement {
        case .currentSpace: return true
        case .otherSpace(.fullScreen): return options.includeFullScreen
        case .otherSpace: return options.includeOtherDesktops
        case .hiddenOrMinimized, .noSpace: return false
        }
    }
}
