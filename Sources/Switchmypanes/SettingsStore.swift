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
    /// How see-through the overlays are: "glass" (default), "frosted" or "dark".
    @Published var overlayStyle: String { didSet { d.set(overlayStyle, forKey: "overlayStyle") } }
    /// A glowing outline travels from the window's old frame to its new one when it snaps.
    @Published var snapAnimationsEnabled: Bool { didSet { d.set(snapAnimationsEnabled, forKey: "snapAnimationsEnabled") } }
    /// Drag a window to a screen edge or corner to snap it.
    @Published var dragSnapEnabled: Bool { didSet { d.set(dragSnapEnabled, forKey: "dragSnapEnabled") } }
    /// Modifier combination for snapping (Control+Option by default). Stored as the raw bit set.
    @Published var snapModifiers: ShortcutModifiers { didSet { d.set(snapModifiers.rawValue, forKey: "snapModifiers") } }
    /// Windows placed together by Snap Layouts resize together when you drag the divider between them.
    @Published var linkedResizeEnabled: Bool { didSet { d.set(linkedResizeEnabled, forKey: "linkedResizeEnabled") } }
    /// Apps to leave alone: hidden from the switcher and/or never moved by snapping (per app).
    @Published var appExclusions: [AppExclusion] { didSet { d.set(AppExclusions.encode(appExclusions), forKey: "appExclusions") } }
    /// Modifier(s) held for the window switcher (then Tab). Option by default.
    @Published var switcherModifier: ShortcutModifiers { didSet { d.set(switcherModifier.rawValue, forKey: "switcherModifier") } }
    /// Snap Layouts shortcut: modifiers + one key (Option+Z by default). `layoutsKeyLabel` is what to show for the key.
    @Published var layoutsModifier: ShortcutModifiers { didSet { d.set(layoutsModifier.rawValue, forKey: "layoutsModifier") } }
    @Published var layoutsKeyCode: Int { didSet { d.set(layoutsKeyCode, forKey: "layoutsKeyCode") } }
    @Published var layoutsKeyLabel: String { didSet { d.set(layoutsKeyLabel, forKey: "layoutsKeyLabel") } }
    /// True while a shortcut is being recorded in Preferences: the keyboard listener steps aside so the keys
    /// you press reach the recorder instead of triggering the shortcut itself. Not saved.
    var isRecordingShortcut = false
    /// Space in points between snapped windows and the screen edge.
    @Published var gap: Double { didSet { d.set(gap, forKey: "gap") } }
    /// Not saved: pausing lasts until you resume or quit.
    @Published var paused = false

    private init() {
        d.register(defaults: ["switcherEnabled": true, "snapEnabled": true, "dragSnapEnabled": true, "layoutsEnabled": true, "snapAssistEnabled": true, "includeOtherDesktops": true, "includeFullScreen": true, "includeMinimized": true, "keepPreviewsFresh": true, "snapAnimationsEnabled": true, "overlayStyle": "glass", "linkedResizeEnabled": true, "previewExcludedApps": PreviewPolicy.defaultExcludedApps, "gap": 0.0,
                              "snapModifiers": ShortcutModifiers([.control, .option]).rawValue,
                              "switcherModifier": ShortcutModifiers.option.rawValue,
                              "layoutsModifier": ShortcutModifiers.option.rawValue, "layoutsKeyCode": 6, "layoutsKeyLabel": "Z"])
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
        linkedResizeEnabled = d.bool(forKey: "linkedResizeEnabled")
        snapAnimationsEnabled = d.bool(forKey: "snapAnimationsEnabled")
        overlayStyle = d.string(forKey: "overlayStyle") ?? "glass"
        appExclusions = AppExclusions.decode(d.data(forKey: "appExclusions"))
        switcherModifier = ShortcutModifiers(rawValue: d.integer(forKey: "switcherModifier"))
        layoutsModifier = ShortcutModifiers(rawValue: d.integer(forKey: "layoutsModifier"))
        layoutsKeyCode = d.integer(forKey: "layoutsKeyCode")
        layoutsKeyLabel = d.string(forKey: "layoutsKeyLabel") ?? "Z"
    }

    var spaceFilter: SpaceFilterOptions {
        SpaceFilterOptions(includeOtherDesktops: includeOtherDesktops, includeFullScreen: includeFullScreen,
                           includeMinimized: includeMinimized)
    }

    var config: ShortcutConfig {
        ShortcutConfig(switcherModifier: switcherModifier, snapModifiers: snapModifiers,
                       switcherEnabled: switcherEnabled, snapEnabled: snapEnabled, layoutsEnabled: layoutsEnabled,
                       layoutsModifier: layoutsModifier, layoutsKeyCode: Int64(layoutsKeyCode))
    }

    func resetToDefaults() {
        switcherEnabled = true; snapEnabled = true; dragSnapEnabled = true; layoutsEnabled = true; snapAssistEnabled = true; includeOtherDesktops = true; includeFullScreen = true; includeMinimized = true; keepPreviewsFresh = true; snapAnimationsEnabled = true; overlayStyle = "glass"; linkedResizeEnabled = true; appExclusions = []; previewExcludedApps = PreviewPolicy.defaultExcludedApps; gap = 0
        resetShortcuts()
    }

    func resetShortcuts() {
        switcherModifier = .option
        snapModifiers = [.control, .option]
        layoutsModifier = .option; layoutsKeyCode = 6; layoutsKeyLabel = "Z"
    }
}
