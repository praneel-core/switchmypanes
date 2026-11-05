import AppKit
import SwiftUI
import SwitchmypanesCore

struct PreferencesView: View {
    @ObservedObject var settings: SettingsStore
    private let spacesAvailable = makeSpaceProvider() is CGSSpaceProvider

    private func binding(_ m: ShortcutModifiers) -> Binding<Bool> {
        Binding(get: { settings.snapModifiers.contains(m) },
                set: { on in if on { settings.snapModifiers.insert(m) } else { settings.snapModifiers.remove(m) } })
    }

    private struct AppChoice { let id: String; let name: String }

    private func runningApps() -> [AppChoice] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .map { AppChoice(id: $0.bundleIdentifier!, name: $0.localizedName ?? $0.bundleIdentifier!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addExcluded(_ bundleID: String) {
        if !settings.previewExcludedApps.contains(bundleID) { settings.previewExcludedApps.append(bundleID) }
    }

    /// "1Password" for a bundle ID if the app is installed, otherwise the raw pattern.
    private func displayName(for entry: String) -> String {
        if !entry.hasSuffix("*"), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return entry
    }

    var body: some View {
        Form {
            Section("Window switcher") {
                Toggle("Option+Tab switches between windows", isOn: $settings.switcherEnabled)
                Toggle("Include windows from other desktops", isOn: $settings.includeOtherDesktops)
                    .disabled(!settings.switcherEnabled || !spacesAvailable)
                Toggle("Include full-screen apps", isOn: $settings.includeFullScreen)
                    .disabled(!settings.switcherEnabled || !spacesAvailable)
                Toggle("Include minimized and hidden windows", isOn: $settings.includeMinimized)
                    .disabled(!settings.switcherEnabled || !spacesAvailable)
                if !spacesAvailable {
                    Label("macOS did not provide desktop information, so only visible windows on the current desktop are listed.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Text("Hold Option and press Tab. Tab / Shift+Tab or the arrow keys move, release Option to switch, Esc cancels. Cmd+Tab is not changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Snapping") {
                Toggle("Keyboard snapping", isOn: $settings.snapEnabled)
                Toggle("Snap Assist: after snapping to a half, offer other windows for the empty half", isOn: $settings.snapAssistEnabled)
                    .disabled(!settings.snapEnabled)
                Toggle("Drag a window to a screen edge or corner to snap it", isOn: $settings.dragSnapEnabled)
                    .disabled(!settings.snapEnabled)
                HStack {
                    Text("Shortcut modifiers")
                    Spacer()
                    Toggle("Control", isOn: binding(.control)).toggleStyle(.checkbox)
                    Toggle("Option", isOn: binding(.option)).toggleStyle(.checkbox)
                    Toggle("Command", isOn: binding(.command)).toggleStyle(.checkbox)
                }
                .disabled(!settings.snapEnabled)
                if settings.snapEnabled && settings.snapModifiers.isEmpty {
                    Label("Pick at least one modifier, otherwise snapping is off.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if settings.snapEnabled && settings.snapModifiers == .command {
                    Label("Command+Arrow is used for text editing in most apps. Add another modifier.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                VStack(alignment: .leading) {
                    Text("Gap between windows: \(Int(settings.gap)) pt")
                    Slider(value: $settings.gap, in: 0...24, step: 1)
                }
                Text("Modifier + Left / Right = half, Up = maximize, Down = restore or minimize. Left then Up = top-left quarter, and so on. Add Shift to move the window to another display. Dragging: left / right edge = half, top edge = maximize, corners = quarters.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Window previews") {
                Toggle("Keep previews ready for windows on other desktops", isOn: $settings.keepPreviewsFresh)
                    .disabled(!settings.switcherEnabled)
                Text("macOS cannot take a picture of a window that is not showing. With this on, a picture is taken of a window when you leave it, and once after you settle into it (not on a timer, and not while the screen is locked, you are idle, or Low Power Mode is on). Pictures stay in memory; nothing is saved or sent. When off, only windows visible when you open the overlay get a picture.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Never take previews of")
                        Spacer()
                        Menu("Add app…") {
                            ForEach(runningApps(), id: \.id) { app in
                                Button(app.name) { addExcluded(app.id) }
                            }
                        }.fixedSize()
                    }
                    ForEach(settings.previewExcludedApps, id: \.self) { entry in
                        HStack {
                            Text(displayName(for: entry)).font(.callout)
                            Spacer()
                            Button { settings.previewExcludedApps.removeAll { $0 == entry } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    if settings.previewExcludedApps != PreviewPolicy.defaultExcludedApps {
                        Button("Restore default list (password managers)") { settings.previewExcludedApps = PreviewPolicy.defaultExcludedApps }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
            Section("Snap Layouts") {
                Toggle("Option+Z opens the Snap Layouts picker", isOn: $settings.layoutsEnabled)
                Text("Pick a layout (arrow keys, Return, or press 1–9), then choose a window for each area. Space skips an area, Esc stops. Note: Option+Z normally types “Ω”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset to defaults") { settings.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
