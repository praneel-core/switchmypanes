import AppKit

/// The look shared by every overlay (window switcher, Snap Assist, Snap Layouts): a glass panel, keycap-style hints,
/// and colour-coded tags. Kept in one place so all overlays stay consistent.
enum OverlayTheme {
    /// Set by the offscreen renderer (`--render-overlay`): a real blur needs the window server, so a flat translucent
    /// dark fill stands in for it when a picture of the overlay is rendered to a file.
    nonisolated(unsafe) static var offscreenRender = false

    static let panelRadius: CGFloat = 26
    static let hintBarHeight: CGFloat = 42
    static let captionHeight: CGFloat = 34

    /// macOS "Reduce motion" is respected: no animation at all when it is on.
    static var motionEnabled: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The rounded glass background every overlay sits on.
    static func makeGlass() -> NSView {
        let v: NSView
        if offscreenRender {
            v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 0.74).cgColor
        } else {
            let fx = NSVisualEffectView()
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.appearance = NSAppearance(named: .vibrantDark)      // light text on a dark glass, whatever the system theme
            fx.wantsLayer = true
            v = fx
        }
        v.layer?.cornerRadius = panelRadius
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor     // a fine light edge, like glass
        return v
    }

    /// Colour of a window's tag ("Desktop 2", "Full screen", "Minimized", "Hidden").
    static func tagColor(for label: String) -> NSColor {
        let l = label.lowercased()
        if l.contains("full") { return NSColor.systemPurple }
        if l.contains("minimized") || l.contains("hidden") { return NSColor.systemOrange }
        return NSColor.systemBlue
    }

    static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        // Visible on every Space and above full-screen apps.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }

    /// Fades a panel in (a quick, subtle entrance); instant when Reduce motion is on.
    static func fadeIn(_ panel: NSPanel, duration: TimeInterval = 0.12) {
        guard motionEnabled else { panel.alphaValue = 1; panel.orderFrontRegardless(); return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }
}

/// One keyboard hint: the key in a keycap, and what it does.
struct Hint { let key: String; let label: String }

extension Array where Element == Hint {
    /// Hints for the window switcher. `modifier` is the held key's symbol (⌥ by default).
    static func switcher(modifier: String) -> [Hint] {
        [Hint(key: modifier, label: "Release to switch"), Hint(key: "⇥", label: "Next"), Hint(key: "⇧⇥", label: "Back"),
         Hint(key: "⌫", label: "Close"), Hint(key: "esc", label: "Cancel")]
    }
    static let assist: [Hint] = [Hint(key: "↩", label: "Place here"), Hint(key: "⇥", label: "Next"), Hint(key: "esc", label: "Close")]
    static let layoutWindow: [Hint] = [Hint(key: "↩", label: "Place here"), Hint(key: "space", label: "Skip this area"), Hint(key: "esc", label: "Done")]
    static let layoutChoice: [Hint] = [Hint(key: "←↑↓→", label: "Move"), Hint(key: "↩", label: "Select"), Hint(key: "1–9", label: "Quick pick"), Hint(key: "esc", label: "Cancel")]
}

/// The row of keycap hints along the bottom of an overlay.
final class HintBarView: NSView {
    var hints: [Hint] = [] { didSet { needsDisplay = true } }

    private static let keyFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let labelFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    private static let keyAttrs: [NSAttributedString.Key: Any] = [.font: keyFont, .foregroundColor: NSColor.white.withAlphaComponent(0.92)]
    private static let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.white.withAlphaComponent(0.62)]
    private static let keyPad: CGFloat = 7, gap: CGFloat = 7, between: CGFloat = 20

    static func preferredWidth(for hints: [Hint]) -> CGFloat {
        guard !hints.isEmpty else { return 0 }
        var w: CGFloat = 0
        for h in hints {
            w += max(20, (h.key as NSString).size(withAttributes: keyAttrs).width + 2 * keyPad) + gap
            w += (h.label as NSString).size(withAttributes: labelAttrs).width
        }
        return w + CGFloat(hints.count - 1) * between
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !hints.isEmpty else { return }
        var x = (bounds.width - Self.preferredWidth(for: hints)) / 2
        for h in hints {
            let keySize = (h.key as NSString).size(withAttributes: Self.keyAttrs)
            let capW = max(20, keySize.width + 2 * Self.keyPad), capH: CGFloat = 20
            let cap = NSRect(x: x, y: bounds.midY - capH / 2, width: capW, height: capH)
            NSColor.white.withAlphaComponent(0.13).setFill()
            let path = NSBezierPath(roundedRect: cap, xRadius: 6, yRadius: 6)
            path.fill()
            NSColor.white.withAlphaComponent(0.20).setStroke()
            path.lineWidth = 0.75; path.stroke()
            (h.key as NSString).draw(at: NSPoint(x: cap.midX - keySize.width / 2, y: cap.midY - keySize.height / 2), withAttributes: Self.keyAttrs)
            x += capW + Self.gap
            let labelSize = (h.label as NSString).size(withAttributes: Self.labelAttrs)
            (h.label as NSString).draw(at: NSPoint(x: x, y: bounds.midY - labelSize.height / 2), withAttributes: Self.labelAttrs)
            x += labelSize.width + Self.between
        }
    }
}

/// A small coloured tag ("Desktop 2", "Full screen", "Minimized").
final class TagView: NSView {
    private let text: String
    private let color: NSColor
    private static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)

    init(_ text: String) {
        self.text = text; self.color = OverlayTheme.tagColor(for: text)
        let w = (text as NSString).size(withAttributes: [.font: Self.font]).width + 16
        super.init(frame: NSRect(x: 0, y: 0, width: w.rounded(.up), height: 18))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2), withAttributes: attrs)
    }
}
