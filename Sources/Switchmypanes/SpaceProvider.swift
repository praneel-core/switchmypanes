import CoreGraphics

/// Information about macOS Spaces (virtual desktops).
///
/// Phase 1 only lists windows on the CURRENT Space, which the public CoreGraphics API gives us.
/// Phase 2 will add an implementation based on the undocumented CoreGraphics "CGS" Spaces functions,
/// behind this same protocol and best-effort: if it fails, `CurrentSpaceOnlyProvider` is used.
protocol SpaceProvider {
    /// Window IDs on all Spaces (nil = unknown / not supported).
    func allSpacesWindowIDs() -> Set<CGWindowID>?
}

struct CurrentSpaceOnlyProvider: SpaceProvider {
    func allSpacesWindowIDs() -> Set<CGWindowID>? { nil }
}
