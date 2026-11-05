import Foundation
import SwitchmypanesCore

/// User settings, saved in UserDefaults (local to this Mac, nothing is sent anywhere).
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let d = UserDefaults.standard

    @Published var switcherEnabled: Bool { didSet { d.set(switcherEnabled, forKey: "switcherEnabled") } }
    @Published var snapEnabled: Bool { didSet { d.set(snapEnabled, forKey: "snapEnabled") } }
    /// Option+Tab also lists windows on other desktops (Spaces).
    @Published var includeOtherDesktops: Bool { didSet { d.set(includeOtherDesktops, forKey: "includeOtherDesktops") } }
    /// Option+Tab also lists full-screen apps (each lives on its own Space).
    @Published var includeFullScreen: Bool { didSet { d.set(includeFullScreen, forKey: "includeFullScreen") } }
    /// Option+Tab also lists minimized windows and windows of hidden (Cmd+H) apps.
    @Published var includeMinimized: Bool { didSet { d.set(includeMinimized, forKey: "includeMinimized") } }
    /// Take a picture of a window when you leave it (and once you settle in one), so previews exist for windows
    /// on other desktops. Pictures stay in memory only.
    @Published var keepPreviewsFresh: Bool { didSet { d.set(keepPreviewsFresh, forKey: "keepPreviewsFresh") } }
    /// Apps that never get previews: bundle IDs, an entry ending in * is a prefix.
    @Published var previewExcludedApps: [String] { didSet { d.set(previewExcludedApps, forKey: "previewExcludedApps") } }
    /// After snapping to a half, offer the other windows for the empty half.
    @Published var snapAssistEnabled: Bool { didSet { d.set(snapAssistEnabled, forKey: "snapAssistEnabled") } }
    /// Option+Z opens the Snap Layouts picker.
    @Published var layoutsEnabled: Bool { didSet { d.set(layoutsEnabled, forKey: "layoutsEnabled") } }
    /// Drag a window to a screen edge or corner to snap it.
    @Published var dragSnapEnabled: Bool { didSet { d.set(dragSnapEnabled, forKey: "dragSnapEnabled") } }
    /// Modifier combination for snapping (Control+Option by default). Stored as the raw bit set.
    @Published var snapModifiers: ShortcutModifiers { didSet { d.set(snapModifiers.rawValue, forKey: "snapModifiers") } }
    /// Space in points between snapped windows and the screen edge.
    @Published var gap: Double { didSet { d.set(gap, forKey: "gap") } }
    /// Not saved: pausing lasts until you resume or quit.
    @Published var paused = false

    private init() {
        d.register(defaults: ["switcherEnabled": true, "snapEnabled": true, "dragSnapEnabled": true, "layoutsEnabled": true, "snapAssistEnabled": true, "includeOtherDesktops": true, "includeFullScreen": true, "includeMinimized": true, "keepPreviewsFresh": true, "previewExcludedApps": PreviewPolicy.defaultExcludedApps, "gap": 0.0,
                              "snapModifiers": ShortcutModifiers([.control, .option]).rawValue])
        switcherEnabled = d.bool(forKey: "switcherEnabled")
        snapEnabled = d.bool(forKey: "snapEnabled")
        dragSnapEnabled = d.bool(forKey: "dragSnapEnabled")
        layoutsEnabled = d.bool(forKey: "layoutsEnabled")
        snapAssistEnabled = d.bool(forKey: "snapAssistEnabled")
        includeOtherDesktops = d.bool(forKey: "includeOtherDesktops")
        includeFullScreen = d.bool(forKey: "includeFullScreen")
        includeMinimized = d.bool(forKey: "includeMinimized")
        keepPreviewsFresh = d.bool(forKey: "keepPreviewsFresh")
        previewExcludedApps = d.stringArray(forKey: "previewExcludedApps") ?? PreviewPolicy.defaultExcludedApps
        snapModifiers = ShortcutModifiers(rawValue: d.integer(forKey: "snapModifiers"))
        gap = d.double(forKey: "gap")
    }

    var spaceFilter: SpaceFilterOptions {
        SpaceFilterOptions(includeOtherDesktops: includeOtherDesktops, includeFullScreen: includeFullScreen,
                           includeMinimized: includeMinimized)
    }

    var config: ShortcutConfig {
        ShortcutConfig(switcherModifier: .option, snapModifiers: snapModifiers,
                       switcherEnabled: switcherEnabled, snapEnabled: snapEnabled, layoutsEnabled: layoutsEnabled)
    }

    func resetToDefaults() {
        switcherEnabled = true; snapEnabled = true; dragSnapEnabled = true; layoutsEnabled = true; snapAssistEnabled = true; includeOtherDesktops = true; includeFullScreen = true; includeMinimized = true; keepPreviewsFresh = true; previewExcludedApps = PreviewPolicy.defaultExcludedApps; gap = 0
        snapModifiers = [.control, .option]
    }
}
