import SwiftUI
import SwitchmypanesCore

struct PreferencesView: View {
    @ObservedObject var settings: SettingsStore
    private let spacesAvailable = makeSpaceProvider() is CGSSpaceProvider

    private func binding(_ m: ShortcutModifiers) -> Binding<Bool> {
        Binding(get: { settings.snapModifiers.contains(m) },
                set: { on in if on { settings.snapModifiers.insert(m) } else { settings.snapModifiers.remove(m) } })
    }

    var body: some View {
        Form {
            Section("Window switcher") {
                Toggle("Option+Tab switches between windows", isOn: $settings.switcherEnabled)
                Toggle("Include windows from other desktops", isOn: $settings.includeOtherDesktops)
                    .disabled(!settings.switcherEnabled || !spacesAvailable)
                Toggle("Include full-screen apps", isOn: $settings.includeFullScreen)
                    .disabled(!settings.switcherEnabled || !spacesAvailable)
                if !spacesAvailable {
                    Label("macOS did not provide desktop information, so only windows on the current desktop are listed.",
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
