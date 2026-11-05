import AppKit
import SwitchmypanesCore

// Diagnostic: `Switchmypanes --list-windows` prints the windows the switcher would show (with their
// desktop / minimized status), then exits. Handy for checking what macOS reports. Prints to the terminal only.
if CommandLine.arguments.contains("--list-windows") {
    MainActor.assumeIsolated {
        // `--exclude=com.example.App` applies the "hide from switcher" exclusion, to check the rule against real windows.
        let excluded = CommandLine.arguments.compactMap { $0.hasPrefix("--exclude=") ? String($0.dropFirst(10)) : nil }
        let inventory = WindowInventory(ids: PrivateAXWindowIDProvider(), spaces: makeSpaceProvider(), options: { SpaceFilterOptions() },
                                        exclusions: { excluded.map { AppExclusion(pattern: $0) } })
        inventory.startTracking()
        RunLoop.current.run(until: Date().addingTimeInterval(3.5))   // lets the background minimized / hidden check finish
        let windows = inventory.snapshot(includeOtherSpaces: true, for: excluded.isEmpty ? nil : .switcher)
        let thumbnails = ThumbnailService()
        thumbnails.captureInBackground(windowIDs: windows.filter(\.isOnCurrentSpace).map(\.id), minInterval: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(3))     // let the captures finish
        for w in windows {
            let t = thumbnails.cached(w.id).map { "thumbnail \(Int($0.size.width))x\(Int($0.size.height))" } ?? "no thumbnail"
            print("\(w.id)\t\(w.appName)\t\(w.title)\t\(w.spaceLabel ?? "this desktop")\t\(t)")
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar app: no Dock icon
app.run()
