import AppKit
import SwiftUI
import SwitchmypanesCore

struct PreferencesView: View {
    @ObservedObject var settings: SettingsStore
    private let spacesAvailable = makeSpaceProvider() is CGSSpaceProvider

    @State private var loginOn = LoginItem.isEnabled
    @State private var loginNeedsApproval = LoginItem.needsApproval
    @State private var loginError: String?

    private func refreshLogin() { loginOn = LoginItem.isEnabled; loginNeedsApproval = LoginItem.needsApproval }

    private struct AppChoice { let id: String; let name: String }

    private func runningApps() -> [AppChoice] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .map { AppChoice(id: $0.bundleIdentifier!, name: $0.localizedName ?? $0.bundleIdentifier!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addExclusion(_ bundleID: String) {
        settings.appExclusions = AppExclusions.adding(bundleID, to: settings.appExclusions)
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
            Section("General") {
                Toggle("Open Switchmypanes when I log in", isOn: Binding(
                    get: { loginOn },
                    set: { on in
                        loginError = nil
                        do { try LoginItem.set(on) } catch { loginError = "macOS refused: \(error.localizedDescription)" }
                        refreshLogin()
                    }))
                if loginNeedsApproval {
                    HStack {
                        Label("macOS needs you to approve it once in System Settings → General → Login Items.", systemImage: "info.circle")
                            .font(.caption)
                        Spacer()
                        Button("Open Login Items") { LoginItem.openSystemSettings() }
                    }
                }
                if !LoginItem.runsFromApplications {
                    Label("This copy is not in an Applications folder. Move it to ~/Applications (./build.sh install does this) before turning this on.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if let loginError { Label(loginError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            Section("Shortcuts") {
                ShortcutRow(title: "Window switcher: hold, then press Tab",
                            display: ShortcutDisplay.describe(settings.switcherModifier, key: "Tab"),
                            isDefault: settings.switcherModifier == .option,
                            onCapture: { m, code, _ in
                                if let problem = ShortcutValidator.validate(.switcher, modifiers: m, keyCode: code, current: settings.config) { return problem }
                                settings.switcherModifier = m; return nil
                            }, onReset: { settings.switcherModifier = .option })
                ShortcutRow(title: "Snapping: press with an arrow key",
                            display: ShortcutDisplay.symbols(settings.snapModifiers) + " + arrows",
                            isDefault: settings.snapModifiers == [.control, .option],
                            onCapture: { m, code, _ in
                                if let problem = ShortcutValidator.validate(.snap, modifiers: m, keyCode: code, current: settings.config) { return problem }
                                settings.snapModifiers = m; return nil
                            }, onReset: { settings.snapModifiers = [.control, .option] })
                ShortcutRow(title: "Snap Layouts picker",
                            display: ShortcutDisplay.describe(settings.layoutsModifier, key: settings.layoutsKeyLabel),
                            isDefault: settings.layoutsModifier == .option && settings.layoutsKeyCode == 6,
                            onCapture: { m, code, label in
                                if let problem = ShortcutValidator.validate(.layouts, modifiers: m, keyCode: code, current: settings.config) { return problem }
                                settings.layoutsModifier = m; settings.layoutsKeyCode = Int(code)
                                settings.layoutsKeyLabel = label.isEmpty ? ShortcutDisplay.keyName(code) : label
                                return nil
                            }, onReset: { settings.layoutsModifier = .option; settings.layoutsKeyCode = 6; settings.layoutsKeyLabel = "Z" })
                Text("Click a shortcut, then press the new combination. Shift is reserved: with the switcher it goes backwards, with snapping it moves a window to another display. Combinations that clash with macOS or with text editing are refused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Window switcher") {
                Toggle("Window switcher shortcut enabled", isOn: $settings.switcherEnabled)
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
                Text("Hold \(ShortcutDisplay.symbols(settings.switcherModifier)) and press Tab. Tab / Shift+Tab or the arrow keys move, release to switch, Esc cancels, Delete or W closes the highlighted window. Cmd+Tab is not changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Snapping") {
                Toggle("Keyboard snapping", isOn: $settings.snapEnabled)
                Toggle("Snap Assist: after snapping to a half, offer other windows for the empty half", isOn: $settings.snapAssistEnabled)
                    .disabled(!settings.snapEnabled)
                Toggle("Drag a window to a screen edge or corner to snap it", isOn: $settings.dragSnapEnabled)
                    .disabled(!settings.snapEnabled)
                VStack(alignment: .leading) {
                    Text("Gap between windows: \(Int(settings.gap)) pt")
                    Slider(value: $settings.gap, in: 0...24, step: 1)
                }
                Text("Shortcut + Left / Right = half, Up = maximize, Down = restore or minimize. Left then Up = top-left quarter, and so on. Add Shift to move the window to another display. Dragging: left / right edge = half, top edge = maximize, corners = quarters.")
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
            Section("Excluded apps") {
                HStack {
                    Text("Apps Switchmypanes should leave alone")
                    Spacer()
                    Menu("Add app…") {
                        ForEach(runningApps(), id: \.id) { app in
                            Button(app.name) { addExclusion(app.id) }
                        }
                    }.fixedSize()
                }
                if settings.appExclusions.isEmpty {
                    Text("None yet. Add an app, then choose whether to hide it from the window switcher, stop snapping from moving it, or both.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($settings.appExclusions) { $entry in
                    HStack {
                        Text(displayName(for: entry.pattern)).font(.callout)
                        Spacer()
                        Toggle("Hide from switcher", isOn: $entry.inSwitcher).toggleStyle(.checkbox)
                        Toggle("Never snap", isOn: $entry.inSnapping).toggleStyle(.checkbox)
                        Button { settings.appExclusions.removeAll { $0.id == entry.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Text("“Hide from switcher”: its windows are not listed in the switcher. “Never snap”: the snap shortcuts, dragging to edges, Snap Assist and Snap Layouts all ignore its windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Snap Layouts") {
                Toggle("Snap Layouts shortcut enabled", isOn: $settings.layoutsEnabled)
                Toggle("Resize windows placed by Snap Layouts together", isOn: $settings.linkedResizeEnabled)
                    .disabled(!settings.layoutsEnabled)
                Text("After you fill a layout, dragging the divider between two of its windows moves the matching edge of the windows beside it, so they stay flush. Dragging a window away, snapping it, or closing it takes it out of the group.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Pick a layout (arrow keys, Return, or press 1–9), then choose a window for each area. Space skips an area, Esc stops. Note: with Option+Z as the shortcut, “Ω” can no longer be typed. Change the shortcut above if you need it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset to defaults") { settings.resetToDefaults() }
            }
        }
        .onAppear { refreshLogin() }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 360)
    }
}
