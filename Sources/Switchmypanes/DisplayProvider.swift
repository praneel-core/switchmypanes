import AppKit
import SwitchmypanesCore

/// The ONE place where AppKit's bottom-left screen coordinates become the top-left coordinates
/// used by the Accessibility API and by all of our own logic.
@MainActor
enum DisplayProvider {
    static var converter: CoordinateConverter {
        // NSScreen.screens[0] is always the screen with the menu bar, whose origin is (0,0).
        CoordinateConverter(primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    static func layout() -> DisplayLayout {
        let c = converter
        return DisplayLayout(displays: NSScreen.screens.map {
            DisplayInfo(id: displayID(of: $0), frame: c.flip($0.frame), visibleFrame: c.flip($0.visibleFrame))
        })
    }

    static func displayID(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
