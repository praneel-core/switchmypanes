import AppKit

/// The look shared by every overlay (window switcher, Snap Assist, Snap Layouts): a glass panel and colour-coded tags. Kept in one place so all overlays stay consistent.
enum OverlayTheme {
    /// Set by the offscreen renderer (`--render-overlay`): a real blur needs the window server, so a flat translucent
    /// dark fill stands in for it when a picture of the overlay is rendered to a file.
    nonisolated(unsafe) static var offscreenRender = false

    static let panelRadius: CGFloat = 26
    static let captionHeight: CGFloat = 34

    /// macOS "Reduce motion" is respected: no animation at all when it is on.
    static var motionEnabled: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// How see-through the overlays are. Chosen in Preferences.
    enum Style: String, CaseIterable {
        case glass, frosted, dark
        var title: String { switch self { case .glass: return "Glass"; case .frosted: return "Frosted"; case .dark: return "Dark" } }
    }
    /// The look currently in use (set from Preferences; panels pick it up the next time they appear).
    nonisolated(unsafe) static var style: Style = .glass

    /// A glass background plus the view that holds the overlay's content.
    struct Glass {
        let root: NSView          // becomes the panel's content view
        let content: NSView       // add the overlay's subviews here
        let style: Style
    }

    /// The rounded glass background every overlay sits on.
    ///  - macOS 26+: real Liquid Glass (`NSGlassEffectView`): clear for Glass, regular for Frosted, tinted for Dark.
    ///  - older macOS: a system blur material, lighter for Glass and heavier for Dark.
    static func makeGlass(_ style: Style = OverlayTheme.style) -> Glass {
        if offscreenRender {
            // Offscreen pictures have no window server to blur with: a flat translucent fill stands in, with the same
            // relative see-through-ness as the real thing.
            let alpha: CGFloat = [Style.glass: 0.34, .frosted: 0.58, .dark: 0.78][style] ?? 0.5
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: alpha).cgColor
            v.layer?.cornerRadius = panelRadius
            v.layer?.masksToBounds = true
            v.layer?.borderWidth = 1
            v.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            return Glass(root: v, content: v, style: style)
        }
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = panelRadius
            switch style {
            case .glass: g.style = .clear
            case .frosted: g.style = .regular
            case .dark: g.style = .regular; g.tintColor = NSColor.black.withAlphaComponent(0.42)
            }
            let content = NSView()
            content.autoresizingMask = [.width, .height]
            g.contentView = content
            return Glass(root: g, content: content, style: style)
        }
        let fx = NSVisualEffectView()
        fx.material = style == .dark ? .hudWindow : (style == .frosted ? .popover : .underWindowBackground)
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)      // light text on a dark glass, whatever the system theme
        fx.wantsLayer = true
        fx.layer?.cornerRadius = panelRadius
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor     // a fine light edge, like glass
        return Glass(root: fx, content: fx, style: style)
    }

    /// A soft shadow behind text so it stays readable on clear glass over a bright desktop.
    static func softTextShadow() -> NSShadow {
        let s = NSShadow()
        s.shadowBlurRadius = 3; s.shadowOffset = NSSize(width: 0, height: -1)
        s.shadowColor = NSColor.black.withAlphaComponent(style == .dark ? 0.25 : 0.5)
        return s
    }

    /// How dark the little backing frame behind each thumbnail is: lighter on clearer glass.
    static var thumbnailBackdropAlpha: CGFloat { [Style.glass: 0.22, .frosted: 0.28, .dark: 0.34][style] ?? 0.3 }

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
    static func fadeIn(_ panel: NSPanel, duration: TimeInterval = 0.14) {
        guard motionEnabled else { panel.alphaValue = 1; panel.orderFrontRegardless(); return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().alphaValue = 1
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
