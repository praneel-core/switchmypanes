import CoreGraphics
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// PRIVATE API, ISOLATED.
// Asking an APP to come forward is not enough when it has windows on several desktops: if the app already has a window
// on the desktop you are looking at, macOS simply focuses that one and never switches desktops. To go to a SPECIFIC
// window on ANOTHER desktop (for example a full-screen VS Code while another VS Code window is on this desktop), the
// window server has to be told which window to focus. SkyLight has an undocumented call for exactly that
// (`_SLPSSetFrontProcessWithOptions` with a window ID) plus an event record that makes the window the key window.
// All symbols are looked up by name at runtime; if any is missing `init?` fails and `WindowActivator` falls back to the
// public approach (which works whenever the app has no window on the current desktop). Nothing here can crash the app.
// ─────────────────────────────────────────────────────────────────────────────
protocol WindowFocusProvider {
    /// Brings that exact window forward, switching desktops if needed. Returns false if the request could not be made.
    func focus(pid: pid_t, windowID: CGWindowID) -> Bool
}

struct SkyLightWindowFocus: WindowFocusProvider {
    /// Diagnostics (self-test): receives a description of each call and its result codes.
    nonisolated(unsafe) static var debug: ((String) -> Void)?

    /// Layout-compatible with the legacy ProcessSerialNumber (two 32-bit values).
    private struct PSN { var high: UInt32 = 0; var low: UInt32 = 0 }
    // (the process serial number is passed as a raw pointer to the PSN struct above)
    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias SetFront = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias PostEvent = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32

    private let getPSN: GetPSN
    private let setFront: SetFront
    private let postEvent: PostEvent

    init?() {
        // GetProcessForPID lives in ApplicationServices; make sure it is loaded before looking for it.
        let appServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        func find(_ names: [String], in handle: UnsafeMutableRawPointer? = nil) -> UnsafeMutableRawPointer? {
            for n in names {
                if let h = handle, let p = dlsym(h, n) { return p }
                if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), n) { return p }   // RTLD_DEFAULT
            }
            return nil
        }
        guard let a = find(["GetProcessForPID"], in: appServices),
              let b = find(["_SLPSSetFrontProcessWithOptions", "SLPSSetFrontProcessWithOptions"]),
              let c = find(["SLPSPostEventRecordTo"]) else { return nil }
        getPSN = unsafeBitCast(a, to: GetPSN.self)
        setFront = unsafeBitCast(b, to: SetFront.self)
        postEvent = unsafeBitCast(c, to: PostEvent.self)
    }

    func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        var psn = PSN()
        let got = getPSN(pid, &psn)
        guard got == 0 else { Self.debug?("GetProcessForPID(\(pid)) failed: \(got)"); return false }
        // 0x200 = "user generated": the window server treats it like the user clicking that window.
        let result = setFront(&psn, windowID, 0x200)
        Self.debug?("psn=(\(psn.high),\(psn.low)) SLPSSetFrontProcessWithOptions(window \(windowID)) -> \(result)")
        makeKeyWindow(&psn, windowID)
        return result == 0
    }

    /// Makes the window the app's key window (the one that receives the keyboard), as a click on it would.
    private func makeKeyWindow(_ psn: inout PSN, _ windowID: CGWindowID) {
        var wid = windowID
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        memcpy(&bytes[0x3c], &wid, MemoryLayout<UInt32>.size)
        memset(&bytes[0x20], 0xff, 0x10)
        bytes[0x08] = 0x01
        let r1 = postEvent(&psn, &bytes)
        bytes[0x08] = 0x02
        let r2 = postEvent(&psn, &bytes)
        Self.debug?("SLPSPostEventRecordTo -> \(r1), \(r2)")
    }
}
