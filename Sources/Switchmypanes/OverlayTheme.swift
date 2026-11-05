import AppKit
import SwitchmypanesCore

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
    /// The look the USER chose (set from Preferences; panels pick it up the next time they appear).
    nonisolated(unsafe) static var style: Style = .glass
    /// Tests / previews: pretend macOS's "Reduce transparency" is on (true) or off (false); nil = ask macOS.
    nonisolated(unsafe) static var reduceTransparencyOverride: Bool?
    static var reduceTransparency: Bool { reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    /// The look and opacity actually used: the user's choice, unless macOS asks for less transparency (then solid Dark).
    static var effective: (style: Style, opacity: CGFloat) {
        let r = OverlayAppearance.resolve(styleName: style.rawValue, opacity: Double(opacity), reduceTransparency: reduceTransparency)
        return (Style(rawValue: r.style) ?? .glass, CGFloat(r.opacity))
    }

    /// How much of the glass is visible: 1 = the system glass at full strength, lower = more see-through. Chosen in
    /// Preferences as "Transparency"; only the glass fades, the tiles and text on top stay sharp.
    nonisolated(unsafe) static var opacity: CGFloat = 0.65

    /// A glass background, with the view that holds the overlay's content ABOVE it (a sibling, not inside the glass), so
    /// the glass alone can be made more transparent.
    struct Glass {
        let root: NSView          // becomes the panel's content view
        let backdrop: NSView      // the glass itself
        let content: NSView       // add the overlay's subviews here
        let style: Style
        /// `opacity` is applied to the glass layer only.
        func applyOpacity(_ o: CGFloat) {
            if OverlayTheme.offscreenRender {
                let base: CGFloat = [Style.glass: 0.34, .frosted: 0.58, .dark: 0.78][style] ?? 0.5
                backdrop.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: base * o).cgColor
            } else {
                backdrop.alphaValue = o
            }
        }
    }

    /// The rounded glass background every overlay sits on.
    ///  - macOS 26+: real Liquid Glass (`NSGlassEffectView`): clear for Glass, regular for Frosted, tinted for Dark.
    ///  - older macOS: a system blur material, lighter for Glass and heavier for Dark.
    static func makeGlass(_ style: Style = OverlayTheme.effective.style) -> Glass {
        let root = NSView()
        root.autoresizingMask = [.width, .height]
        let content = NSView()
        content.autoresizingMask = [.width, .height]

        let backdrop: NSView
        if offscreenRender {
            // Offscreen pictures have no window server to blur with: a flat translucent fill stands in, with the same
            // relative see-through-ness as the real thing.
            let v = NSView()
            v.wantsLayer = true
            v.layer?.cornerRadius = panelRadius
            v.layer?.masksToBounds = true
            v.layer?.borderWidth = 1
            v.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            backdrop = v
        } else if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = panelRadius
            switch style {
            case .glass: g.style = .clear
            case .frosted: g.style = .regular
            case .dark: g.style = .regular; g.tintColor = NSColor.black.withAlphaComponent(0.42)
            }
            backdrop = g
        } else {
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
            backdrop = fx
        }
        backdrop.autoresizingMask = [.width, .height]
        root.addSubview(backdrop)
        root.addSubview(content)
        let glass = Glass(root: root, backdrop: backdrop, content: content, style: style)
        glass.applyOpacity(effective.opacity)
        return glass
    }

    /// A soft shadow behind text so it stays readable on clear glass over a bright desktop.
    static func softTextShadow() -> NSShadow {
        let s = NSShadow()
        s.shadowBlurRadius = 3; s.shadowOffset = NSSize(width: 0, height: -1)
        s.shadowColor = NSColor.black.withAlphaComponent(effective.style == .dark ? 0.25 : 0.5)
        return s
    }

    /// How dark the little backing frame behind each thumbnail is: lighter on clearer glass.
    static var thumbnailBackdropAlpha: CGFloat { [Style.glass: 0.22, .frosted: 0.28, .dark: 0.34][effective.style] ?? 0.3 }

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

/// The close button on a tile: a small dark glass disc with a fine light edge and a thin, rounded ×. It turns a soft red
/// only when you point at it, so it reads as part of the glass look instead of a stock red icon.
final class CloseButton: NSButton {
    private var hovering = false
    /// Tests / previews: draw the pointed-at state without a real mouse.
    var forceHover = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// While it is faded out it must not catch clicks meant for the tile.
    override func hitTest(_ point: NSPoint) -> NSView? { alphaValue < 0.5 ? nil : super.hitTest(point) }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let hot = hovering || forceHover
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        (hot ? NSColor.systemRed.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.42)).setFill()
        disc.fill()
        NSColor.white.withAlphaComponent(hot ? 0.35 : 0.28).setStroke()
        disc.lineWidth = 1
        disc.stroke()
        let c = NSPoint(x: bounds.midX, y: bounds.midY), r: CGFloat = 4
        let cross = NSBezierPath()
        cross.lineWidth = 1.7
        cross.lineCapStyle = .round
        cross.move(to: NSPoint(x: c.x - r, y: c.y - r)); cross.line(to: NSPoint(x: c.x + r, y: c.y + r))
        cross.move(to: NSPoint(x: c.x - r, y: c.y + r)); cross.line(to: NSPoint(x: c.x + r, y: c.y - r))
        NSColor.white.withAlphaComponent(0.96).setStroke()
        cross.stroke()
    }
}

/// The search field shown at the top of the overlay while you type: a magnifier and what you have typed so far.
final class SearchPillView: NSView {
    private let text: String
    private static let font = NSFont.systemFont(ofSize: 14, weight: .medium)

    init(query: String) {
        text = query
        let w = (query as NSString).size(withAttributes: [.font: Self.font]).width
        super.init(frame: NSRect(x: 0, y: 0, width: max(200, (w + 64).rounded(.up)), height: 28))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        NSColor.white.withAlphaComponent(0.14).setFill(); pill.fill()
        NSColor.white.withAlphaComponent(0.26).setStroke(); pill.lineWidth = 1; pill.stroke()
        if let icon = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
            let tinted = icon.copy() as! NSImage
            tinted.lockFocus(); NSColor.white.withAlphaComponent(0.75).set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
            tinted.draw(at: NSPoint(x: 12, y: bounds.midY - tinted.size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: 34, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}
