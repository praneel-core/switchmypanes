import AppKit
import ApplicationServices

/// Reads and requests the three macOS privacy permissions we use.
@MainActor
enum PermissionManager {
    struct Status: Equatable {
        var accessibility: Bool
        var inputMonitoring: Bool
        var screenRecording: Bool
        /// What the shortcuts really need (Screen Recording is optional: it only adds previews).
        var shortcutsReady: Bool { accessibility && inputMonitoring }
    }

    static func current() -> Status {
        Status(accessibility: AXIsProcessTrusted(),
               inputMonitoring: CGPreflightListenEventAccess(),
               screenRecording: CGPreflightScreenCaptureAccess())
    }

    // Each request shows the standard macOS prompt (once) and registers the app in the Settings list.
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    static func requestInputMonitoring() { _ = CGRequestListenEventAccess() }
    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
        case screenRecording = "Privacy_ScreenCapture"
    }

    static func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
