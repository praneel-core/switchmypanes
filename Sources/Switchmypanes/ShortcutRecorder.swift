import AppKit
import SwiftUI
import SwitchmypanesCore

/// Listens for ONE key combination after you click the button, then reports it.
@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published var isRecording = false
    @Published var error: String?
    /// (modifiers, key code, key label) -> a problem description, or nil when the shortcut was accepted.
    var onCapture: ((ShortcutModifiers, Int64, String) -> String?)?
    private var monitor: Any?

    func start() {
        stop()
        error = nil
        isRecording = true
        SettingsStore.shared.isRecordingShortcut = true      // the global keyboard listener steps aside
        // A local monitor sees keys before the window does, so even ⌘W or Tab reach us instead of being acted on.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = ShortcutModifiers(event.modifierFlags)
            if event.keyCode == 53 && mods.isEmpty { self.stop(); return nil }          // plain Esc cancels
            let label = (event.charactersIgnoringModifiers ?? "").uppercased()
            self.error = self.onCapture?(mods, Int64(event.keyCode), label)
            self.stop()
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        isRecording = false
        SettingsStore.shared.isRecordingShortcut = false
    }
}

/// One row in Preferences: a label, a button showing the current shortcut (click it, then press the new one),
/// and a reset arrow when it differs from the default.
struct ShortcutRow: View {
    let title: String
    let display: String
    let isDefault: Bool
    let onCapture: (ShortcutModifiers, Int64, String) -> String?
    let onReset: () -> Void
    @StateObject private var model = ShortcutRecorderModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Button(model.isRecording ? "Press the shortcut…  (Esc cancels)" : display) {
                    if model.isRecording { model.stop() } else { model.start() }
                }
                .buttonStyle(.bordered)
                .tint(model.isRecording ? .accentColor : nil)
                if !isDefault {
                    Button { model.stop(); model.error = nil; onReset() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).help("Reset to the default")
                }
            }
            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { model.onCapture = onCapture }
        .onDisappear { model.stop() }
    }
}
