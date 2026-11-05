import AppKit
import SwitchmypanesCore

// Diagnostic: `Switchmypanes --list-windows` prints the windows the switcher would show (with their
// desktop / minimized status), then exits. Handy for checking what macOS reports. Prints to the terminal only.
if CommandLine.arguments.contains("--list-windows") {
    MainActor.assumeIsolated {
        let inventory = WindowInventory(ids: PrivateAXWindowIDProvider(), spaces: makeSpaceProvider(), options: { SpaceFilterOptions() })
        inventory.startTracking()
        RunLoop.current.run(until: Date().addingTimeInterval(3.5))   // lets the background minimized / hidden check finish
        for w in inventory.snapshot(includeOtherSpaces: true) {
            print("\(w.id)\t\(w.appName)\t\(w.title)\t\(w.spaceLabel ?? "this desktop")")
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar app: no Dock icon
app.run()
