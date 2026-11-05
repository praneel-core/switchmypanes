import Foundation

/// Matches app bundle IDs against a pattern. An entry ending in "*" matches any ID starting with the text before it;
/// otherwise the ID must match exactly. Case-insensitive.
public enum BundlePattern {
    public static func matches(_ pattern: String, bundleID: String) -> Bool {
        let p = pattern.lowercased(), id = bundleID.lowercased()
        return p.hasSuffix("*") ? id.hasPrefix(String(p.dropLast())) : id == p
    }
}

public enum ExclusionScope: Equatable { case switcher, snapping }

/// An app that Switchmypanes should leave alone, with a separate switch for each job.
public struct AppExclusion: Codable, Equatable, Hashable, Identifiable {
    public var pattern: String          // bundle ID, or a prefix ending in "*"
    public var inSwitcher: Bool         // do not list its windows in Option+Tab
    public var inSnapping: Bool         // never move its windows (shortcuts, drag, Snap Assist, Snap Layouts)
    public var id: String { pattern }
    public init(pattern: String, inSwitcher: Bool = true, inSnapping: Bool = true) {
        self.pattern = pattern; self.inSwitcher = inSwitcher; self.inSnapping = inSnapping
    }
}

public enum AppExclusions {
    public static func isExcluded(bundleID: String?, for scope: ExclusionScope, in list: [AppExclusion]) -> Bool {
        guard let bundleID else { return false }
        return list.contains { e in
            (scope == .switcher ? e.inSwitcher : e.inSnapping) && BundlePattern.matches(e.pattern, bundleID: bundleID)
        }
    }

    /// Add an app (or return the list unchanged if it is already there).
    public static func adding(_ pattern: String, to list: [AppExclusion]) -> [AppExclusion] {
        list.contains { $0.pattern.lowercased() == pattern.lowercased() } ? list : list + [AppExclusion(pattern: pattern)]
    }

    // Saved as JSON in UserDefaults. A corrupt or missing value simply means "no exclusions".
    public static func encode(_ list: [AppExclusion]) -> Data? { try? JSONEncoder().encode(list) }
    public static func decode(_ data: Data?) -> [AppExclusion] {
        guard let data, let list = try? JSONDecoder().decode([AppExclusion].self, from: data) else { return [] }
        return list
    }
}
