import AppKit
import ServiceManagement

/// "Open at login", using macOS's own login-item mechanism (SMAppService). It appears in
/// System Settings > General > Login Items, where you can also switch it off.
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    /// macOS sometimes wants you to approve the item once in System Settings.
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on { if status != .enabled { try SMAppService.mainApp.register() } }
        else { try SMAppService.mainApp.unregister() }
    }

    /// Login items point at the app's location, so it should live in an Applications folder, not in `build/`.
    static var runsFromApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
