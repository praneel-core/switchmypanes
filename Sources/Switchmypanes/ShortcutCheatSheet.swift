import AppKit
import SwiftUI
import SwitchmypanesCore

/// A small window listing every shortcut, built from the CURRENT settings (so it is right after you re-record one).
struct ShortcutCheatSheetView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(ShortcutCheatSheet.sections(config: settings.config, layoutsKeyLabel: settings.layoutsKeyLabel), id: \.title) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title).font(.headline)
                        ForEach(section.rows, id: \.title) { row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.title)
                                Spacer(minLength: 16)
                                Text(row.keys)
                                    .font(.system(.callout, design: .rounded).weight(.semibold))
                                    .padding(.horizontal, 9).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
                            }
                            .font(.callout)
                        }
                    }
                }
                Text("Change any of these in Preferences → Shortcuts.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(width: 540, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
final class ShortcutCheatSheetController {
    private var window: NSWindow?
    private let settings: SettingsStore
    init(settings: SettingsStore) { self.settings = settings }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ShortcutCheatSheetView(settings: settings)))
            w.title = "Switchmypanes shortcuts"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
